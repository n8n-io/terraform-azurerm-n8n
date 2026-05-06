# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Database (PostgreSQL Flexible Server) ────────────────────────────────────
# Private-only PostgreSQL Flexible Server moved into modules/infra/ as part of
# Phase 5 R5.1c (registry-hardening US-016). Reachable from the AKS pods via
# the caller-supplied `var.postgres_subnet_id` (delegated to the
# `Microsoft.DBforPostgreSQL/flexibleServers` service) and the Azure private
# DNS zone created here (`privatelink.postgres.database.azure.com`, linked to
# `var.vnet_id`). With this wiring the server's FQDN resolves to its private
# IP from inside the VNet — no public endpoint is ever exposed.
#
# `azure.extensions = UUID-OSSP` is allowlisted at the server level so any
# `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"` issued from inside the VNet
# (whether by n8n's own migrations or by an operator running `psql` from a
# debug pod) succeeds without `permission denied to create extension`. The
# allowlist is server-side only — no Terraform-orchestrated bootstrap Job is
# needed (registry-hardening US-001 retired the pre-Phase-1 Job);
# `terraform-azurerm-terraform-enterprise-hvd` follows the same pattern with
# `azure.extensions = "CITEXT,HSTORE,UUID-OSSP"`.
#
# Deferred wiring (added in later Phase 5 stories so terraform validate stays
# green while modules/infra/ is built up incrementally):
#
#   - Customer-managed key (CMK) wiring — the `dynamic "identity"` /
#     `dynamic "customer_managed_key"` blocks the legacy root database.tf
#     carries are NOT moved here. The `postgres_cmk` UAMI + role assignment
#     live in iam.tf which migrates with the App Gateway in US-019; that
#     story can re-introduce the CMK toggle as a follow-on input + dynamic
#     blocks once the identity is local to this submodule.

# ── Admin password ──
# Generated once at apply time. Surfaced to `modules/workload/` (US-023) via
# the `postgres_admin_password` output below; never logged.
resource "random_password" "postgres_admin" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Private DNS zone + VNet link ──
# The DNS zone name MUST be `privatelink.postgres.database.azure.com`
# verbatim — Azure's Flexible Server private-DNS auto-registration only fires
# for that exact name. Do not prefix with `friendly_name_prefix` or otherwise
# customize.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-zone" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.friendly_name_prefix}-postgres-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = var.vnet_id

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-link" })
}

# ── PostgreSQL Flexible Server ──
# Public network access is hardcoded off — the private-only posture is the
# whole point of attaching the server to a delegated subnet + private DNS
# zone; no caller-tunable knob would re-enable the public endpoint without
# subverting the trust model. `backup_retention_days` and
# `geo_redundant_backup_enabled` are hardcoded to Azure-platform defaults
# (7 days, off) in this Phase 5 R5.1c slice; a follow-up story can lift them
# back to inputs if/when an operator demands a different cadence.
resource "azurerm_postgresql_flexible_server" "n8n" {
  name                = local.postgres_server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  version  = var.pg_version
  sku_name = var.pg_sku_name

  storage_mb                   = var.pg_storage_mb
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  delegated_subnet_id           = var.postgres_subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = var.pg_admin_username
  administrator_password = random_password.postgres_admin.result

  dynamic "high_availability" {
    for_each = var.pg_enable_high_availability ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  # The VNet link must exist before the server is created so the server's
  # auto-registered A record resolves from inside the VNet on first apply.
  # azurerm does not infer this dependency from `private_dns_zone_id` alone
  # because the link is a sibling resource, not a child of the zone.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  tags = merge(local.common_tags, { Name = local.postgres_server_name })

  # Azure picks an availability zone at create time when the caller doesn't
  # specify one (the module deliberately doesn't expose `var.pg_zone` so a
  # green-field apply lands on whichever zone the platform thinks is best).
  # On a subsequent `terraform plan` Azure can return a different zone in
  # the read response, which the provider would then try to push back via
  # an in-place update — Azure rejects that with
  #
  #   Error: `zone` can only be changed when exchanged with the zone
  #   specified in `high_availability.0.standby_availability_zone`
  #
  # because zone moves are only legal as part of an HA failover. Ignoring
  # `zone` (and the symmetric `high_availability.0.standby_availability_zone`)
  # keeps reapplies idempotent without forcing a re-create. Callers who do
  # care about pinning a specific zone should manage it out-of-band; the
  # module's contract is "Azure picks the zone, Terraform doesn't fight it".
  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

# ── azure.extensions allowlist ──
# `azure.extensions` is a server-level parameter. The value is an
# upper-case, comma-separated list of extension names the platform will
# allow `CREATE EXTENSION` to load. Without uuid-ossp on this allowlist,
# any in-VNet `CREATE EXTENSION "uuid-ossp"` returns `permission denied to
# create extension` even when running as the server admin. Allowlisting it
# costs nothing if no client ever issues the SQL — leave this resource in
# place as a forward-compatible safety belt.
resource "azurerm_postgresql_flexible_server_configuration" "uuid_ossp" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.n8n.id
  value     = "UUID-OSSP"
}

# ── n8n database ──
# n8n's connection string points at this database. Charset/collation match
# what n8n expects (UTF8 + en_US.utf8 — n8n migrations use mixed-case
# identifiers and the default collation matters for index ordering).
#
# n8n's own migrations do NOT issue `CREATE EXTENSION "uuid-ossp"` on
# Postgres (verified against `packages/@n8n/db/AGENTS.md` + the
# `postgresdb/` migrations: identifiers are generated in application code
# via `node:crypto.randomUUID()`, not via `uuid_generate_v4()`). The
# server-level allowlist above is retained as a forward-compatible safety
# belt — no in-cluster bootstrap Job is needed.
resource "azurerm_postgresql_flexible_server_database" "n8n" {
  name      = "n8n"
  server_id = azurerm_postgresql_flexible_server.n8n.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
