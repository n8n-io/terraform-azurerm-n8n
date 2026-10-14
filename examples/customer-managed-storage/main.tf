# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Customer-managed Blob storage ─────────────────────────────────────────────
# This example is the customer-managed-infrastructure capability's Blob
# storage ownership boundary: the private storage account, container,
# private DNS zone and link, and private endpoint below are all owned
# outside `module "n8n"`, standing in for storage a platform team already
# runs. The module call sets create_blob_storage = false and supplies the
# account name, container name, container resource ID, and Blob endpoint —
# it never inspects this account or container through a data source
# (design.md decision 4). The module still creates its own n8n workload
# identity and grants that identity Storage Blob Data Contributor scoped to
# the supplied container (design.md decision 3) — this is the one exception
# to "the module owns nothing here", because n8n's own pods need a way to
# authenticate to Blob without a static credential. AKS, PostgreSQL, Azure
# Managed Redis, and ingress remain module-managed to isolate this example
# to the Blob storage ownership boundary alone.

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Topology  = "customer-managed-storage"
  }, var.common_tags)
}

# ── Azure foundations ────────────────────────────────────────────────────────

resource "azurerm_resource_group" "network" {
  name     = "${var.friendly_name_prefix}-network-rg"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "n8n" {
  name     = "${var.friendly_name_prefix}-n8n-rg"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "n8n" {
  name                = "${var.friendly_name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  address_space       = ["10.0.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.0.0/21"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "appgw"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.8.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.9.0/24"]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "postgres-flexible-server"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "redis" {
  name                              = "redis-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.10.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "storage-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.11.0/24"]
  private_endpoint_network_policies = "Disabled"
}

# ── Caller-owned Blob storage ──────────────────────────────────────────────────
# Same account, container, private DNS, and private-endpoint shape the
# module uses for its own managed path (storage.tf), owned outside
# module "n8n" instead to stand in for storage managed by another team or
# process.

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "existing" {
  name                = substr("${var.friendly_name_prefix}st${random_string.storage_suffix.result}", 0, 24)
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  shared_access_key_enabled       = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-shared-storage" })
}

resource "azurerm_role_assignment" "terraform_blob_data_contributor" {
  scope                = azurerm_storage_account.existing.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "storage_rbac" {
  depends_on      = [azurerm_role_assignment.terraform_blob_data_contributor]
  create_duration = "60s"
}

resource "azurerm_storage_container" "existing" {
  name                  = "n8n-data"
  storage_account_id    = azurerm_storage_account.existing.id
  container_access_type = "private"

  depends_on = [time_sleep.storage_rbac]
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.n8n.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "${var.friendly_name_prefix}-blob-vnet-link"
  resource_group_name   = azurerm_resource_group.n8n.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.n8n.id
  registration_enabled  = false

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-vnet-link" })
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.friendly_name_prefix}-blob-pe"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.friendly_name_prefix}-blob-connection"
    private_connection_resource_id = azurerm_storage_account.existing.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-private-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-blob-pe" })
}

# ── Key Vault and lab-grade certificate ──────────────────────────────────────

data "azurerm_client_config" "current" {}

resource "random_string" "key_vault_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "tls" {
  name                       = substr("${var.friendly_name_prefix}-tls-${random_string.key_vault_suffix.result}", 0, 24)
  resource_group_name        = azurerm_resource_group.network.name
  location                   = azurerm_resource_group.network.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
  tags                       = local.common_tags
}

resource "azurerm_role_assignment" "key_vault_operator" {
  scope                = azurerm_key_vault.tls.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "key_vault_rbac" {
  depends_on      = [azurerm_role_assignment.key_vault_operator]
  create_duration = "60s"
}

module "tls_self_signed" {
  source = "../../modules/tls-self-signed"

  domain_name          = var.n8n_domain
  key_vault_id         = azurerm_key_vault.tls.id
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = local.common_tags

  depends_on = [time_sleep.key_vault_rbac]
}

# ── n8n ──────────────────────────────────────────────────────────────────────
# create_blob_storage = false targets the caller-owned storage account and
# container above instead of creating its own. The module still grants its
# own n8n workload identity Storage Blob Data Contributor scoped to
# existing_blob_container_id — this example uses no azure_blob_connection_string
# or azure_blob_account_key, so that automatic-authentication role grant is
# active (design.md decision 3).

module "n8n" {
  source = "../.."

  location             = var.location
  resource_group_name  = azurerm_resource_group.n8n.name
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = local.common_tags

  vnet_id                    = azurerm_virtual_network.n8n.id
  aks_subnet_id              = azurerm_subnet.aks.id
  postgres_subnet_id         = azurerm_subnet.postgres.id
  redis_subnet_id            = azurerm_subnet.redis.id
  appgw_subnet_id            = azurerm_subnet.appgw.id
  private_endpoint_subnet_id = azurerm_subnet.private_endpoints.id

  aks_api_authorized_ip_ranges = var.aks_api_authorized_ip_ranges
  aks_node_vm_size             = var.aks_node_vm_size
  aks_availability_zones       = var.aks_availability_zones

  create_blob_storage                   = false
  existing_blob_storage_account_name    = azurerm_storage_account.existing.name
  existing_blob_container_name          = azurerm_storage_container.existing.name
  existing_blob_container_id            = azurerm_storage_container.existing.id
  existing_blob_endpoint                = azurerm_storage_account.existing.primary_blob_endpoint
  existing_blob_prerequisites_confirmed = true

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  pg_backup_retention_days = var.pg_backup_retention_days

  n8n_domain                                   = var.n8n_domain
  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = azurerm_key_vault.tls.id
  app_gateway_keyvault_role_assignment_enabled = true

  n8n_license_key = var.n8n_license_key

  depends_on = [
    azurerm_private_endpoint.blob,
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
  ]
}
