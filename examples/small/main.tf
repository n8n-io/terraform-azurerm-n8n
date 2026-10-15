# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Tier      = "small"
  }, var.common_tags)

  tier = {
    aks_node_vm_size         = var.aks_node_vm_size
    aks_availability_zones   = var.aks_availability_zones
    aks_node_count_min       = 2
    aks_node_count_max       = 6
    pg_sku_name              = "GP_Standard_D2s_v3"
    pg_storage_mb            = 32768
    pg_backup_retention_days = var.pg_backup_retention_days
    redis_sku_name           = "Balanced_B0"
    storage_replication_type = "LRS"
    webhook_max_replicas     = 8
    main_min_replicas        = var.n8n_main_hpa_min_replicas
  }
}

# ── Azure foundations ────────────────────────────────────────────────────────

resource "azurerm_resource_group" "network" {
  name     = "${var.friendly_name_prefix}-network-rg"
  location = coalesce(var.resource_group_location, var.location)
  tags     = local.common_tags
}

resource "azurerm_resource_group" "n8n" {
  name     = "${var.friendly_name_prefix}-n8n-rg"
  location = coalesce(var.resource_group_location, var.location)
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "n8n" {
  name                = "${var.friendly_name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. The module only creates and associates an NSG for appgw_subnet_id (see ingress.tf azurerm_subnet_network_security_group_association.appgw); aks_network_policy defaults to null and this example leaves it unset, so no AKS network-policy engine restricts pod traffic on the node subnet either.
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.0.0/21"]
}

resource "azurerm_subnet" "appgw" {
  # checkov:skip=CKV2_AZURE_31:False positive: this subnet is attached to azurerm_network_security_group.appgw via azurerm_subnet_network_security_group_association.appgw inside the module (ingress.tf), created because this example passes appgw_subnet_id and leaves create_ingress at its default of true. Checkov's graph check cannot see the cross-module association.
  name                 = "appgw"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.8.0/24"]
}

resource "azurerm_subnet" "postgres" {
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. This subnet is delegated to Microsoft.DBforPostgreSQL/flexibleServers for VNet integration; the module's azurerm_postgresql_flexible_server sets public_network_access_enabled = false and uses this delegated subnet plus a private DNS zone for connectivity (see database.tf), but no NSG restricts traffic inside the subnet.
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.9.0/24"]

  service_endpoint {
    service = "Microsoft.Storage"
  }

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
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. This subnet hosts only the Azure Managed Redis private endpoint NIC (private_endpoint_network_policies = "Disabled", passed to the module as redis_subnet_id; see redis.tf), so traffic reaches Redis exclusively via the private endpoint, but the subnet itself has no NSG.
  name                              = "redis-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.10.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "private_endpoints" {
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. This subnet hosts only the storage account private endpoint NIC (private_endpoint_network_policies = "Disabled", passed to the module as private_endpoint_subnet_id; see storage.tf), so traffic reaches the storage account exclusively via the private endpoint, but the subnet itself has no NSG.
  name                              = "storage-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.11.0/24"]
  private_endpoint_network_policies = "Disabled"
}

# ── Public DNS and lab TLS certificate ───────────────────────────────────────

resource "azurerm_dns_zone" "public" {
  name                = var.public_dns_zone_name
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.common_tags
}

data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "terraform_blob_data_contributor" {
  scope                = azurerm_resource_group.n8n.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "storage_rbac" {
  depends_on      = [azurerm_role_assignment.terraform_blob_data_contributor]
  create_duration = "60s"
}

resource "random_string" "key_vault_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "tls" {
  # checkov:skip=CKV_AZURE_42:Teardown-friendly example setting: purge_protection_enabled = false is deliberate so the soft-deleted lab TLS vault that `terraform destroy` leaves behind can be purged manually and its name reused (see README.md: "The example keeps teardown-friendly Key Vault and database settings").
  # checkov:skip=CKV_AZURE_110:Same requirement as CKV_AZURE_42 above: purge protection is intentionally disabled for teardown-friendly lab usage.
  # checkov:skip=CKV_AZURE_109:Known gap: this vault has no network_acls block, so it allows public access from all networks; it only stores a self-signed TLS cert created by modules/tls-self-signed and consumed via app_gateway_tls_cert_secret_id, so a firewall restriction is unnecessary lab convenience, not production data.
  # checkov:skip=CKV_AZURE_189:Known gap: same as CKV_AZURE_109, public_network_access_enabled defaults to true and no network_acls restrict it, consistent with the lab-only self-signed TLS cert this vault holds.
  # checkov:skip=CKV2_AZURE_32:Known gap: a private endpoint only helps with restricted network access, which this vault does not implement (see CKV_AZURE_189 above).
  name                       = substr("${var.friendly_name_prefix}-tls-${random_string.key_vault_suffix.result}", 0, 24)
  resource_group_name        = azurerm_resource_group.network.name
  location                   = var.location
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

  aks_node_vm_size             = local.tier.aks_node_vm_size
  aks_node_count_min           = local.tier.aks_node_count_min
  aks_node_count_max           = local.tier.aks_node_count_max
  aks_availability_zones       = local.tier.aks_availability_zones
  aks_api_authorized_ip_ranges = var.aks_api_authorized_ip_ranges

  aks_node_pools_follow_cluster_version = var.aks_node_pools_follow_cluster_version

  pg_sku_name              = local.tier.pg_sku_name
  pg_storage_mb            = local.tier.pg_storage_mb
  pg_backup_retention_days = local.tier.pg_backup_retention_days

  redis_sku_name = local.tier.redis_sku_name

  storage_account_replication_type = local.tier.storage_replication_type

  blob_delete_retention_days = var.blob_delete_retention_days

  n8n_webhook_hpa_max_replicas = local.tier.webhook_max_replicas
  n8n_main_hpa_min_replicas    = local.tier.main_min_replicas

  n8n_domain                                   = var.n8n_domain
  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = azurerm_key_vault.tls.id
  app_gateway_keyvault_role_assignment_enabled = true

  create_public_dns_record = true
  public_dns_zone_id       = azurerm_dns_zone.public.id

  n8n_license_key             = var.n8n_license_key
  n8n_license_cert_secret_ref = var.n8n_license_cert_secret_ref
  n8n_extra_ca_pem            = var.n8n_extra_ca_pem
  n8n_extra_env               = var.n8n_extra_env
  n8n_image_tag               = var.n8n_image_tag

  depends_on = [
    time_sleep.storage_rbac,
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
  ]
}
