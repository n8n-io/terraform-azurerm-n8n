# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Private Azure Blob storage ─────────────────────────────────────────────
# Azure Blob is the external data plane for n8n binary and execution data. When
# create_blob_storage = true (the default), the module creates one private
# container and grants the n8n workload identity data-plane access to that
# container only. When false, every resource below is gated to zero and
# local.effective_blob_* (locals.tf, section 6) selects the caller-supplied
# existing_blob_* references instead — the module never inspects a
# customer-managed storage account or container through a data source
# (design.md decision 4).

resource "azurerm_storage_account" "n8n" {
  # checkov:skip=CKV_AZURE_33:The module uses Blob only; enabling Queue service logging for an unused data plane would create noise and does not protect n8n storage operations.
  # checkov:skip=CKV_AZURE_206:Replication is caller-configurable because ZRS/GZRS availability differs by region. LRS remains the portable default; production examples select stronger replication where their documented regions support it.
  count = var.create_blob_storage ? 1 : 0

  name                = local.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = var.storage_account_replication_type
  account_kind             = "StorageV2"

  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  shared_access_key_enabled = (
    var.azure_blob_connection_string != null ||
    var.azure_blob_account_key != null
  )

  dynamic "blob_properties" {
    for_each = var.blob_delete_retention_days != null ? [1] : []
    content {
      delete_retention_policy {
        days = var.blob_delete_retention_days
      }
      container_delete_retention_policy {
        days = var.blob_delete_retention_days
      }
    }
  }

  tags = merge(local.common_tags, { Name = local.storage_account_name })
}

# ── Azure Blob container and private networking ───────────────────────────────

resource "azurerm_storage_container" "n8n" {
  count = var.create_blob_storage ? 1 : 0

  name                  = var.azure_blob_container_name
  storage_account_id    = azurerm_storage_account.n8n[0].id
  container_access_type = "private"
}

# Not created when `var.create_blob_private_dns_zone = false`: some landing
# zones centralize privatelink zones in a connectivity subscription (often
# under an Azure Policy DeployIfNotExists mandate), and a second same-named
# zone in the n8n resource group would conflict with that. The caller then
# owns the zone and its VNet link and passes its ID as
# `var.blob_private_dns_zone_id`. Gated on the boolean, never on the ID being
# null, so the ID may come from a resource created in the same apply
# (docs/customer-managed-infrastructure.md, rule 3).
resource "azurerm_private_dns_zone" "blob" {
  count = var.create_blob_storage && var.create_blob_private_dns_zone ? 1 : 0

  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-dns" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count = var.create_blob_storage && var.create_blob_private_dns_zone ? 1 : 0

  name                  = "${var.friendly_name_prefix}-blob-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-vnet-link" })
}

# Selects the zone by the create_blob_private_dns_zone switch, not by
# whether the caller's ID is null, so a supplied ID is ignored (and the
# blob_private_dns_zone_inputs_ignored check warns) while the module still
# owns the zone. Consumed by the private endpoint's `private_dns_zone_group`
# below.
locals {
  blob_private_dns_zone_id = var.create_blob_storage ? (
    var.create_blob_private_dns_zone
    ? one(azurerm_private_dns_zone.blob[*].id)
    : var.blob_private_dns_zone_id
  ) : null
}

resource "azurerm_private_endpoint" "blob" {
  count = var.create_blob_storage ? 1 : 0

  name                = "${var.friendly_name_prefix}-blob-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.friendly_name_prefix}-blob-connection"
    private_connection_resource_id = azurerm_storage_account.n8n[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-private-dns"
    private_dns_zone_ids = [local.blob_private_dns_zone_id]
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-pe" })
}

# Storage Blob Data Contributor is the narrowest built-in role that supports
# n8n's complete Azure byte-store contract: container listing during startup,
# object read/write and properties calls, server-side copy, and delete. Scoped
# to local.effective_blob_container_id rather than the storage account so the
# workload identity cannot read sibling containers a caller may add to the same
# account. Applies on both the module-managed container (create_blob_storage =
# true) and a customer-managed container when automatic authentication is
# selected (design.md decision 3), and only while local.n8n_azure_storage_enabled
# (an Azure storage mode, or azure_blob_retain_read_access): a database-only
# deployment gets no Blob permissions. Omitted for the connection-string and
# account-key compatibility credential modes because n8n does not use
# workload identity for Blob access in those modes. A customer-managed
# container requires the applying identity to hold role-assignment
# permission at local.effective_blob_container_id's scope, which may sit in
# a different resource group or subscription than var.resource_group_name.
resource "azurerm_role_assignment" "n8n_blob_data_contributor" {
  count = local.n8n_azure_storage_enabled && local.azure_blob_connection.auth_auto_detect ? 1 : 0

  scope                = local.effective_blob_container_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.n8n_workload.principal_id
}

# ── Binary-only lifecycle expiry ──────────────────────────────────────────────
# n8n owns execution-data pruning. Azure lifecycle expiry is therefore safe only
# while this container is dedicated to binary data. Object paths cannot express
# one static prefix that selects every binary object while excluding execution
# bundles because both paths contain variable workflow and execution IDs before
# the distinguishing segment. The policy is omitted when execution data shares
# the container, even when a retention period is supplied.
resource "azurerm_storage_management_policy" "n8n_binary" {
  count = (var.create_blob_storage && var.azure_blob_binary_retention_days != null) ? (
    var.azure_blob_container_stores_execution_data ? 0 : 1
  ) : 0

  storage_account_id = azurerm_storage_account.n8n[0].id

  rule {
    name    = "expire-n8n-binary-data"
    enabled = true

    filters {
      prefix_match = ["${azurerm_storage_container.n8n[0].name}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.azure_blob_binary_retention_days
      }
    }
  }
}

check "azure_blob_lifecycle_requires_binary_only_container" {
  assert {
    condition = var.azure_blob_container_stores_execution_data ? (
      var.azure_blob_binary_retention_days == null
    ) : true
    error_message = "azure_blob_binary_retention_days is set while azure_blob_container_stores_execution_data is true, so the module omits lifecycle expiry. n8n owns execution-data pruning, and a container-wide or workflows/ lifecycle rule can delete execution bundles n8n still references. Binary objects remain indefinitely unless the caller separates the data types into dedicated containers."
  }
}

# Module-managed sizing/lifecycle inputs left at anything other than their
# documented defaults while create_blob_storage = false have no effect —
# azurerm_storage_account.n8n, its container, private endpoint, private DNS,
# and lifecycle policy do not exist in that mode. Retention, networking, and
# encryption are owned by whoever created the supplied storage account and
# container; existing_blob_prerequisites_confirmed is the caller's
# attestation that those properties are already correct. Mirrors
# `aks_tuning_requires_module_managed_aks`. KEEP THIS LITERAL IN LOCKSTEP
# WITH variables.tf's storage_account_replication_type default.
check "blob_tuning_requires_module_managed_blob_storage" {
  assert {
    condition = var.create_blob_storage ? true : (
      var.storage_account_replication_type == "LRS" &&
      var.azure_blob_binary_retention_days == null &&
      var.blob_delete_retention_days == null
    )
    error_message = join("", [
      "A storage_account_replication_type, azure_blob_binary_retention_days, or blob_delete_retention_days ",
      "override is set while create_blob_storage = false. The module creates no storage account, container, ",
      "or lifecycle policy in that mode, so none of them apply. Replication, retention, networking, and ",
      "encryption are properties of the existing Blob storage account and container you supplied.",
    ])
  }
}

# Same contract as database.tf's postgres_private_dns_zone_inputs_ignored:
# the zone inputs only take effect with create_blob_storage = true and
# create_blob_private_dns_zone = false. Warn, do not fail, on any other
# combination that changes either input from its default.
check "blob_private_dns_zone_inputs_ignored" {
  assert {
    # Keep this a single-line ternary. With checkov 3.3.17, a parenthesized
    # multi-line ternary here made the scan silently drop its findings for
    # the module.n8n resources in this file, as evaluated through the
    # examples. Found while reviewing PR #43. Equivalent to "valid only when the
    # module manages the blob resource and not its zone, or when nothing
    # was supplied".
    condition = var.create_blob_private_dns_zone ? var.blob_private_dns_zone_id == null : var.create_blob_storage
    error_message = join("", [
      "blob_private_dns_zone_id or create_blob_private_dns_zone is set but has no effect. ",
      var.create_blob_storage
      ? "With create_blob_private_dns_zone left at true the module creates and uses its own zone and never reads blob_private_dns_zone_id. Set create_blob_private_dns_zone = false to attach the private endpoint to the zone you supplied."
      : "With create_blob_storage = false the module creates no storage account or private endpoint, so neither private DNS zone input applies. Private networking and DNS are properties of the existing Blob storage account you supplied.",
    ])
  }
}
