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
#   - The module-managed private DNS zone name is fixed at
#     `privatelink.postgres.database.azure.com` (see the zone resource below
#     for why, and for the caller-supplied alternative).
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
# Generated once at apply time. Surfaced to the workload via
# `local.postgres_connection.password` below; never logged.
resource "random_password" "postgres_admin" {
  count = var.create_database ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Private DNS zone + VNet link (managed path only, unless caller-supplied) ──
# Azure accepts any private DNS zone name ending in
# `.postgres.database.azure.com` for a Flexible Server with private access
# (https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private#use-a-private-dns-zone).
# The module-managed zone uses `privatelink.postgres.database.azure.com`, the
# name landing zones conventionally centralize. Do not prefix it with
# `friendly_name_prefix`: changing the name replaces the zone. Not created on
# the external path: an external PostgreSQL endpoint's DNS is the caller's
# responsibility. Also not created when
# `var.create_postgres_private_dns_zone = false`: some landing zones
# centralize privatelink zones in a connectivity subscription (often under
# an Azure Policy DeployIfNotExists mandate), and a second same-named zone in
# the n8n resource group would conflict with that. The caller then owns the
# zone and its VNet link and passes its ID as
# `var.postgres_private_dns_zone_id`. Gated on the boolean, never on the ID
# being null, so the ID may come from a resource created in the same apply
# (docs/customer-managed-infrastructure.md, rule 3).
resource "azurerm_private_dns_zone" "postgres" {
  count = var.create_database && var.create_postgres_private_dns_zone ? 1 : 0

  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-zone" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  count = var.create_database && var.create_postgres_private_dns_zone ? 1 : 0

  name                  = "${var.friendly_name_prefix}-postgres-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres[0].name
  virtual_network_id    = var.vnet_id

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-link" })
}

# Reads the live server's actual storage_mb so
# pg_storage_drift_guard_enabled can compare it against var.pg_storage_mb
# before Terraform plans a change, instead of only discovering the mismatch
# once the destructive replace above is already underway. Deliberately has
# no depends_on / resource-attribute reference to
# azurerm_postgresql_flexible_server.n8n: that would make this read wait
# until after this apply's own changes to that resource land, which is one
# apply too late to guard a replace this same apply is about to cause.
# Reading it independently, by the same name/resource-group pair the
# resource itself uses, returns the server's state as it was BEFORE this
# plan. count depends only on create_database and the guard itself, not on
# the current value of pg_storage_auto_grow_enabled: Azure never shrinks
# storage, so a server that already auto-grew keeps its larger live
# storage_mb even after a caller later sets pg_storage_auto_grow_enabled
# back to false, and the guard must still catch that stale pg_storage_mb.
# count is false by default (and whenever create_database or the guard
# itself is off), so this never runs on the apply that first creates the
# server: the server does not exist yet, and this data source would error
# outright if it tried to read something.
#
# CAVEAT: this reads by `local.postgres_server_name` / `var.resource_group_name`,
# the SAME inputs the managed resource below derives its own name/RG from.
# There is no plan-time way to pin "the old identity" independent of those
# inputs without a much larger redesign (e.g. a separate caller-supplied
# prior-identity variable). So an apply that both enables this guard AND
# changes `friendly_name_prefix` or `resource_group_name` (a rename or a
# move) makes this data source look up a server at the NEW coordinates,
# which does not exist there yet (it is still at the old coordinates), and
# the apply fails with a 404 instead of the intended precondition failure.
# Set `pg_storage_drift_guard_enabled = false` for any apply that renames
# or moves the server, then re-enable it on a later apply once the server
# has settled at its new identity. The same not-found error occurs whenever
# this lookup runs after the server was deleted outside Terraform, including
# a `terraform destroy` refresh once the server is already gone (for example
# after a partially completed destroy). A plan-time lookup blocks the plan;
# a deferred one fails during apply. Set the guard to false to recover in
# those cases too.
#
# LIMIT: the guard only protects a plan in which this data source is read
# at plan time. Terraform defers the read to apply when the read depends on
# objects with pending changes, most commonly a caller's `depends_on` on the
# `module` block (examples/medium has one). The plan can then proceed
# without resolving the precondition, and Terraform may destroy the old
# server before it evaluates the create-side precondition: destroy steps do
# not check resource preconditions. Treat the guard as a best-effort early
# warning, not a deletion control. Callers must still review plans for a
# PostgreSQL delete or replace action and for this data source showing
# "(known after apply)", and should hold an existing caller-owned
# CanNotDelete management lock on the server, with lifecycle.prevent_destroy
# on the lock resource itself (docs/deletion-safety.md).
data "azurerm_postgresql_flexible_server" "current" {
  count = var.create_database && var.pg_storage_drift_guard_enabled ? 1 : 0

  name                = local.postgres_server_name
  resource_group_name = var.resource_group_name
}

# Selects the zone by the create_postgres_private_dns_zone switch, not by
# whether the caller's ID is null, so a supplied ID is ignored (and the
# postgres_private_dns_zone_inputs_ignored check warns) while the module
# still owns the zone. Consumed by the Flexible Server's
# `private_dns_zone_id` below.
locals {
  postgres_private_dns_zone_id = var.create_database ? (
    var.create_postgres_private_dns_zone
    ? one(azurerm_private_dns_zone.postgres[*].id)
    : var.postgres_private_dns_zone_id
  ) : null
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

  # When pg_storage_auto_grow_enabled = true, Azure grows storage_mb on the
  # live server without Terraform's knowledge. Terraform's next plan then
  # compares the drifted live value against the still-lower var.pg_storage_mb
  # and plans to shrink it back down. Azure Flexible Server does not support
  # shrinking storage in place, and azurerm's schema treats any decrease as
  # force-new: the plan is not a clean failure, it is DESTROY AND RECREATE
  # the entire server, losing all data. Callers who turn on autogrow MUST
  # bump pg_storage_mb to at least the live size (Azure portal / `az
  # postgres flexible-server show`) before their next apply. There's no
  # `lifecycle.ignore_changes` fix: it only accepts a static attribute list,
  # not a condition on var.pg_storage_auto_grow_enabled, so it can't be
  # scoped to "ignore only when autogrow is on" — always ignoring storage_mb
  # would silently break manual resizes for everyone. pg_storage_drift_guard_enabled
  # (below) turns this into a precondition failure instead, but only when its
  # data source is read at plan time (see the LIMIT note on that data source).
  storage_mb                   = var.pg_storage_mb
  auto_grow_enabled            = var.pg_storage_auto_grow_enabled
  backup_retention_days        = var.pg_backup_retention_days
  geo_redundant_backup_enabled = var.pg_geo_redundant_backup_enabled

  delegated_subnet_id           = var.postgres_subnet_id
  private_dns_zone_id           = local.postgres_private_dns_zone_id
  public_network_access_enabled = false

  administrator_login    = var.pg_admin_username
  administrator_password = random_password.postgres_admin[0].result

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

    # Azure rejects a zone named `<server name>.postgres.database.azure.com`
    # during provisioning (concepts-networking-private, "Use a private DNS
    # zone"). Only a caller-supplied zone can hit this; the module-managed
    # zone is always `privatelink.*`.
    precondition {
      condition = (
        local.postgres_private_dns_zone_id == null
        ? true
        : lower(element(split("/", local.postgres_private_dns_zone_id), 8)) != lower("${local.postgres_server_name}.postgres.database.azure.com")
      )
      error_message = "postgres_private_dns_zone_id names a zone identical to the module-managed server's own FQDN (${local.postgres_server_name}.postgres.database.azure.com). Azure rejects that zone name during provisioning. Use a different zone name, for example privatelink.postgres.database.azure.com."
    }

    # See the data source above: only reads when pg_storage_drift_guard_enabled
    # is true, so this is a no-op (condition trivially true) until a caller
    # opts in on an apply after the server already exists.
    precondition {
      # A conditional, not `||`: Terraform before 1.12 evaluates both sides of
      # `||`, so `current[0]` would fail with an invalid index while the guard
      # is off and the data source has count = 0.
      condition = (
        length(data.azurerm_postgresql_flexible_server.current) == 0
        ? true
        : var.pg_storage_mb >= data.azurerm_postgresql_flexible_server.current[0].storage_mb
      )
      error_message = join("", [
        "pg_storage_drift_guard_enabled = true and the live PostgreSQL Flexible Server's storage_mb (",
        tostring(try(data.azurerm_postgresql_flexible_server.current[0].storage_mb, 0)),
        ") is larger than the configured pg_storage_mb (", tostring(var.pg_storage_mb), "). Autogrow has ",
        "grown the live server past what Terraform still declares. Azure Database for PostgreSQL Flexible ",
        "Server cannot shrink storage_mb in place, so without this guard Terraform would plan to destroy ",
        "and recreate the entire server (data loss) to force it back down. Raise pg_storage_mb to at least ",
        "the live value shown above before applying.",
      ])
    }
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
    password  = var.create_database ? random_password.postgres_admin[0].result : var.postgres_external_password
    ssl_mode  = var.create_database ? var.postgres_managed_ssl_mode : var.postgres_external_ssl_mode
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
      var.pg_storage_auto_grow_enabled == false &&
      var.pg_storage_drift_guard_enabled == false &&
      var.pg_enable_high_availability == false &&
      var.pg_backup_retention_days == 7 &&
      var.pg_geo_redundant_backup_enabled == false &&
      var.postgres_managed_ssl_mode == "require"
    )
    error_message = join("", [
      "A PostgreSQL sizing, HA, or TLS input (pg_sku_name, pg_storage_mb, pg_storage_auto_grow_enabled, ",
      "pg_storage_drift_guard_enabled, pg_enable_high_availability, pg_backup_retention_days, ",
      "pg_geo_redundant_backup_enabled, postgres_managed_ssl_mode) is set while create_database = false. ",
      "The module creates no PostgreSQL Flexible Server in that mode, so none of them apply. Configure ",
      "these on the external database you supply via postgres_external_host.",
    ])
  }
}

# The private DNS zone inputs only take effect together: the module attaches
# the server to postgres_private_dns_zone_id only when it manages the server
# (create_database = true) and does not manage the zone
# (create_postgres_private_dns_zone = false). Any other combination that
# changes either input from its default plans and applies cleanly while
# discarding it. Warn rather than fail, matching the tuning check above and
# the AWS sibling's db_kms_key_arn check: staging the zone inputs in tfvars
# ahead of a cutover is a legitimate thing to do.
check "postgres_private_dns_zone_inputs_ignored" {
  assert {
    # Keep this a single-line ternary. With checkov 3.3.17, a parenthesized
    # multi-line ternary here made the scan silently drop its findings for
    # the module.n8n resources in this file, as evaluated through the
    # examples. Found while reviewing PR #43. Equivalent to "valid only when the
    # module manages the postgres resource and not its zone, or when nothing
    # was supplied".
    condition = var.create_postgres_private_dns_zone ? var.postgres_private_dns_zone_id == null : var.create_database
    error_message = join("", [
      "postgres_private_dns_zone_id or create_postgres_private_dns_zone is set but has no effect. ",
      var.create_database
      ? "With create_postgres_private_dns_zone left at true the module creates and uses its own zone and never reads postgres_private_dns_zone_id. Set create_postgres_private_dns_zone = false to attach the server to the zone you supplied."
      : "With create_database = false the module creates no PostgreSQL Flexible Server, so neither private DNS zone input applies. Configure DNS for the external database you supply via postgres_external_host.",
    ])
  }
}

# postgres_ssl_ca_pem is shared by both database paths, so the advisory below
# keys off the effective local.postgres_connection.ssl_mode rather than
# var.create_database. In any mode other than verify-ca/verify-full the module
# ignores the CA entirely (local.postgres_ssl_ca_active in locals.tf: no
# database.ssl.ca chart value), so a warning is enough here. The condition
# reads the local.postgres_ssl_ca_set boolean rather than the variable so the
# diagnostic does not print the whole PEM bundle. It is not
# a plan failure because callers may stage the CA before switching modes.
check "postgres_ssl_ca_requires_verify_mode" {
  assert {
    condition = !local.postgres_ssl_ca_set || local.postgres_ssl_ca_active
    error_message = join("", [
      "postgres_ssl_ca_pem is set but the effective ssl_mode (", local.postgres_connection.ssl_mode, ") is ",
      "not verify-ca or verify-full, so the module ignores it and does not pass it to the n8n chart. ",
      "Set postgres_managed_ssl_mode or postgres_external_ssl_mode to ",
      "verify-ca or verify-full, or remove postgres_ssl_ca_pem.",
    ])
  }
}
