# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Private Azure Blob storage ─────────────────────────────────────────────
# Azure Blob is the external data plane for n8n binary and execution data. The
# module always creates one private container and grants the n8n workload
# identity data-plane access to that container only.

resource "azurerm_storage_account" "n8n" {
  # checkov:skip=CKV_AZURE_33:The module uses Blob only; enabling Queue service logging for an unused data plane would create noise and does not protect n8n storage operations.
  # checkov:skip=CKV_AZURE_206:Replication is caller-configurable because ZRS/GZRS availability differs by region. LRS remains the portable default; production examples select stronger replication where their documented regions support it.
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

  tags = merge(local.common_tags, { Name = local.storage_account_name })
}

# ── Azure Blob container and private networking ───────────────────────────────

resource "azurerm_storage_container" "n8n" {
  name                  = var.azure_blob_container_name
  storage_account_id    = azurerm_storage_account.n8n.id
  container_access_type = "private"
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-dns" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "${var.friendly_name_prefix}-blob-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-vnet-link" })
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.friendly_name_prefix}-blob-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.friendly_name_prefix}-blob-connection"
    private_connection_resource_id = azurerm_storage_account.n8n.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-private-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-pe" })
}

# Storage Blob Data Contributor is the narrowest built-in role that supports
# n8n's complete Azure byte-store contract: container listing during startup,
# object read/write and properties calls, server-side copy, and delete. Scope it
# to this container rather than the storage account so the workload identity
# cannot read sibling containers a caller may add to the same account.
resource "azurerm_role_assignment" "n8n_blob_data_contributor" {
  scope                = azurerm_storage_container.n8n.id
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
  count = var.azure_blob_binary_retention_days == null ? 0 : (
    var.azure_blob_container_stores_execution_data ? 0 : 1
  )

  storage_account_id = azurerm_storage_account.n8n.id

  rule {
    name    = "expire-n8n-binary-data"
    enabled = true

    filters {
      prefix_match = ["${azurerm_storage_container.n8n.name}/"]
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
