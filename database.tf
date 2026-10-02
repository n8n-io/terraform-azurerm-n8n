# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── PostgreSQL topologies ────────────────────────────────────────────────
# Moved from `modules/infra/database.tf` into this root concern file per
# align-azure-with-aws-capabilities section 3, gated behind `var.create_database`
# so a caller can point n8n at an external PostgreSQL endpoint (e.g. an
# existing Flexible Server, a different subscription's server, or any
# PostgreSQL-compatible service) instead of a module-managed one. Mirrors
# the AWS sibling's `database.tf` `create_database` toggle shape
# (`aws_db_instance.n8n` vs. `var.db_host`/`var.db_password`).
#
# Kept from `modules/infra/database.tf` (unchanged behavior, now gated by
# count instead of always-on):
#   - Private-only posture: `public_network_access_enabled = false`, no
#     caller-tunable knob to re-enable it.
#   - `privatelink.postgres.database.azure.com` private DNS zone name is
#     fixed (Azure's Flexible Server private-DNS auto-registration only
#     fires for that exact name).
#   - `azure.extensions = UUID-OSSP` server-level allowlist as a
#     forward-compatible safety belt (n8n's own migrations do not need it
#     — see the comment on `azurerm_postgresql_flexible_server_configuration
#     .uuid_ossp` below).
#   - `zone` / `high_availability[0].standby_availability_zone` are in
#     `lifecycle.ignore_changes` because Azure only allows changing them as
#     part of an HA failover, not via a plain `terraform apply`.
#
# New in this section (design.md decision 4, ported from
# `terraform-azurerm-terraform-enterprise-aks-hvd`):
#   - `backup_retention_days` / `geo_redundant_backup_enabled` are now
#     caller-tunable (`var.pg_backup_retention_days`,
#     `var.pg_geo_redundant_backup_enabled`) instead of hardcoded.
#   - `maintenance_window` (`var.pg_maintenance_window`, optional object).
#   - `zone` / `high_availability.standby_availability_zone` are now
#     caller-tunable (`var.pg_primary_zone`, `var.pg_standby_zone`) instead
#     of always Azure-picked, with a plan-time guard against setting them
#     identical while HA is enabled.
#   - The external-database path: `var.postgres_external_*` inputs plus
#     `local.postgres_connection`, the single canonical connection object
#     section 6/7 (n8n Helm values) and any future consumer read from
#     instead of branching on `var.create_database` themselves.

# ── Admin password (managed path only) ──
# Generated once at apply time and surfaced to the workload via
# `local.postgres_connection.password` below; never logged. Skipped when
# `var.postgres_password_write_only` is true — that path feeds
# `var.postgres_admin_password_wo` straight into the server's write-only
# `administrator_password_wo` argument instead, so there is no plain-text
# value for this resource to generate or store.
resource "random_password" "postgres_admin" {
  count = (var.create_database && !var.postgres_password_write_only) ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Private DNS zone + VNet link (managed path only) ──
# The DNS zone name MUST be `privatelink.postgres.database.azure.com`
# verbatim — Azure's Flexible Server private-DNS auto-registration only fires
# for that exact name. Do not prefix with `friendly_name_prefix` or otherwise
# customize. Not created on the external path: an external PostgreSQL
# endpoint's DNS is the caller's responsibility.
resource "azurerm_private_dns_zone" "postgres" {
  count = var.create_database ? 1 : 0

  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-zone" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  count = var.create_database ? 1 : 0

  name                  = "${var.friendly_name_prefix}-postgres-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres[0].name
  virtual_network_id    = var.vnet_id

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-link" })
}

# ── PostgreSQL Flexible Server (managed path only) ──
# Public network access is hardcoded off — the private-only posture is the
# whole point of attaching the server to a delegated subnet + private DNS
# zone; no caller-tunable knob would re-enable the public endpoint without
# subverting the trust model.
resource "azurerm_postgresql_flexible_server" "n8n" {
  count = var.create_database ? 1 : 0

  name                = local.postgres_server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  version  = var.pg_version
  sku_name = var.pg_sku_name

  storage_mb                   = var.pg_storage_mb
  backup_retention_days        = var.pg_backup_retention_days
  geo_redundant_backup_enabled = var.pg_geo_redundant_backup_enabled

  delegated_subnet_id           = var.postgres_subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres[0].id
  public_network_access_enabled = false

  administrator_login               = var.pg_admin_username
  administrator_password            = var.postgres_password_write_only ? null : random_password.postgres_admin[0].result
  administrator_password_wo         = var.postgres_password_write_only ? var.postgres_admin_password_wo : null
  administrator_password_wo_version = var.postgres_password_write_only ? var.postgres_admin_password_wo_version : null

  # Zone selection. Both default to null, which leaves Azure to pick a zone
  # at create time (see the lifecycle.ignore_changes note below for why a
  # subsequent plan must not fight that choice).
  zone = var.pg_primary_zone

  dynamic "high_availability" {
    for_each = var.pg_enable_high_availability ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = var.pg_standby_zone
    }
  }

  dynamic "maintenance_window" {
    for_each = var.pg_maintenance_window != null ? [var.pg_maintenance_window] : []
    content {
      day_of_week  = maintenance_window.value.day_of_week
      start_hour   = maintenance_window.value.start_hour
      start_minute = maintenance_window.value.start_minute
    }
  }

  # The VNet link must exist before the server is created so the server's
  # auto-registered A record resolves from inside the VNet on first apply.
  # azurerm does not infer this dependency from `private_dns_zone_id` alone
  # because the link is a sibling resource, not a child of the zone.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  tags = merge(local.common_tags, { Name = local.postgres_server_name })

  # Azure picks an availability zone at create time when the caller doesn't
  # specify one (var.pg_primary_zone defaults to null). On a subsequent
  # `terraform plan` Azure can return a different zone in the read response,
  # which the provider would then try to push back via an in-place update —
  # Azure rejects that with
  #
  #   Error: `zone` can only be changed when exchanged with the zone
  #   specified in `high_availability.0.standby_availability_zone`
  #
  # because zone moves are only legal as part of an HA failover. Ignoring
  # `zone` (and the symmetric `high_availability.0.standby_availability_zone`)
  # keeps reapplies idempotent without forcing a re-create. Callers who do
  # care about pinning a specific zone should manage it out-of-band; the
  # module's contract is "the caller (or Azure) picks the zone once,
  # Terraform doesn't fight it afterward".
  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

# ── azure.extensions allowlist (managed path only) ──
# `azure.extensions` is a server-level parameter. The value is an
# upper-case, comma-separated list of extension names the platform will
# allow `CREATE EXTENSION` to load. Without uuid-ossp on this allowlist,
# any in-VNet `CREATE EXTENSION "uuid-ossp"` returns `permission denied to
# create extension` even when running as the server admin. Allowlisting it
# costs nothing if no client ever issues the SQL — leave this resource in
# place as a forward-compatible safety belt. n8n's own migrations do NOT
# issue `CREATE EXTENSION "uuid-ossp"` on Postgres (verified against
# `packages/@n8n/db/AGENTS.md`: identifiers are generated in application
# code via `node:crypto.randomUUID()`, not via `uuid_generate_v4()`).
resource "azurerm_postgresql_flexible_server_configuration" "uuid_ossp" {
  count = var.create_database ? 1 : 0

  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.n8n[0].id
  value     = "UUID-OSSP"
}

# ── n8n database (managed path only) ──
# n8n's connection string points at this database. Charset/collation match
# what n8n expects (UTF8 + en_US.utf8 — n8n migrations use mixed-case
# identifiers and the default collation matters for index ordering).
resource "azurerm_postgresql_flexible_server_database" "n8n" {
  count = var.create_database ? 1 : 0

  name      = "n8n"
  server_id = azurerm_postgresql_flexible_server.n8n[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ── Canonical database connection ────────────────────────────────────────
# Single source of truth for "what does n8n connect to", selecting between
# the module-managed server and the caller-supplied external endpoint based
# on `var.create_database`. Section 6/7 (n8n Helm values) read from this
# local exclusively rather than re-branching on `var.create_database`
# themselves, preventing drift between what the module creates and what it
# tells n8n to use. Mirrors the AWS sibling's inline `var.create_database ?
# aws_db_instance.n8n[0].address : var.db_host` pattern in `n8n.tf`, but
# collected into one object so every field (host, port, database, username,
# password, ssl_mode, pool_size) is derived exactly once.
locals {
  postgres_connection = {
    host      = var.create_database ? azurerm_postgresql_flexible_server.n8n[0].fqdn : var.postgres_external_host
    port      = var.create_database ? 5432 : var.postgres_external_port
    database  = var.create_database ? azurerm_postgresql_flexible_server_database.n8n[0].name : var.postgres_external_database
    username  = var.create_database ? var.pg_admin_username : var.postgres_external_username
    password  = var.create_database ? (var.postgres_password_write_only ? null : random_password.postgres_admin[0].result) : var.postgres_external_password
    ssl_mode  = var.create_database ? "require" : var.postgres_external_ssl_mode
    pool_size = var.postgres_pool_size
  }
}

# ── Diagnostics: incompatible / ignored database settings ────────────────
# A cross-variable input mistake has two directions, and only one of them
# is a hard error (enforced by validation blocks on the postgres_external_*
# variables below: they're required when create_database = false). This
# check block covers the other, silent direction: a caller who sets
# postgres_external_* while create_database defaults to true (or stays
# true) gets a module-managed Flexible Server anyway, and n8n connects to
# that — both a managed server and the (unused) external inputs exist, the
# apply succeeds, and workflows land somewhere the caller isn't looking.
# Mirrors the AWS sibling's `external_db_inputs_require_create_database_false`
# check in `database.tf`.
check "external_postgres_inputs_require_create_database_false" {
  assert {
    condition = var.create_database ? (
      var.postgres_external_host == null &&
      var.postgres_external_username == null &&
      var.postgres_external_password == null
    ) : true
    error_message = join("", [
      "postgres_external_host, postgres_external_username, or postgres_external_password is set while ",
      "create_database = true, so all three are ignored: the module creates its own PostgreSQL Flexible ",
      "Server and points n8n at that, not at the database you supplied. Set create_database = false to ",
      "use an external PostgreSQL endpoint.",
    ])
  }
}

# The inverse: managed-server sizing/HA inputs left at anything other than
# their documented defaults while create_database = false have no effect —
# azurerm_postgresql_flexible_server.n8n does not exist in that mode.
# Mirrors the AWS sibling's `rds_tuning_requires_module_managed_database`
# check. KEEP THESE LITERALS IN LOCKSTEP WITH variables.tf defaults: a
# default bumped there without updating this check makes every
# create_database = false caller who left the input alone warn spuriously.
check "postgres_tuning_requires_module_managed_database" {
  assert {
    condition = var.create_database ? true : (
      var.pg_sku_name == "GP_Standard_D2s_v3" &&
      var.pg_storage_mb == 32768 &&
      var.pg_enable_high_availability == false &&
      var.pg_backup_retention_days == 7 &&
      var.pg_geo_redundant_backup_enabled == false
    )
    error_message = join("", [
      "A PostgreSQL sizing or HA input (pg_sku_name, pg_storage_mb, pg_enable_high_availability, ",
      "pg_backup_retention_days, pg_geo_redundant_backup_enabled) is set while create_database = false. ",
      "The module creates no PostgreSQL Flexible Server in that mode, so none of them apply. Configure ",
      "these on the external database you supply via postgres_external_host.",
    ])
  }
}
