# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Tier      = "large"
  }, var.common_tags)

  tier = {
    aks_node_vm_size             = "Standard_D16s_v5"
    aks_node_count_min           = 5
    aks_node_count_max           = 20
    postgres_sku_name            = "GP_Standard_D8s_v3"
    postgres_storage_mb          = 524288
    postgres_zone_redundant      = true
    pgbouncer_replicas           = 2
    redis_sku_name               = "MemoryOptimized_M20"
    redis_high_availability      = true
    storage_replication_type     = "ZRS"
    private_blob_enabled         = true
    binary_data_storage_mode     = "azure"
    execution_data_storage_mode  = "azure"
    main_min_replicas            = var.n8n_main_hpa_min_replicas
    main_max_replicas            = 60
    webhook_min_replicas         = 20
    webhook_max_replicas         = 80
    worker_min_replicas          = 20
    worker_max_replicas          = 160
    worker_concurrency           = 40
    appgw_autoscale_min_capacity = 2
    appgw_autoscale_max_capacity = 30
  }
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
  address_space       = ["10.0.0.0/15"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.0.0/18"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "appgw"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.64.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.65.0/24"]
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
  address_prefixes                  = ["10.0.66.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "storage-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.67.0/24"]
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
  aks_sku_tier                 = "Standard"
  aks_api_authorized_ip_ranges = var.aks_api_authorized_ip_ranges

  create_database            = false
  postgres_external_host     = "${kubernetes_service.pgbouncer.metadata[0].name}.${kubernetes_namespace.pgbouncer.metadata[0].name}.svc.cluster.local"
  postgres_external_port     = 5432
  postgres_external_database = azurerm_postgresql_flexible_server_database.n8n.name
  postgres_external_username = azurerm_postgresql_flexible_server.n8n.administrator_login
  postgres_external_password = random_password.postgres.result
  postgres_external_ssl_mode = "disable"
  postgres_pool_size         = 5

  redis_sku_name                  = local.tier.redis_sku_name
  redis_high_availability_enabled = local.tier.redis_high_availability

  storage_account_replication_type           = local.tier.storage_replication_type
  blob_delete_retention_days                 = var.blob_delete_retention_days
  azure_blob_container_stores_execution_data = true
  n8n_binary_data_storage_mode               = local.tier.binary_data_storage_mode
  n8n_execution_data_storage_mode            = local.tier.execution_data_storage_mode

  n8n_main_hpa_min_replicas    = local.tier.main_min_replicas
  n8n_main_hpa_max_replicas    = local.tier.main_max_replicas
  n8n_webhook_hpa_min_replicas = local.tier.webhook_min_replicas
  n8n_webhook_hpa_max_replicas = local.tier.webhook_max_replicas
  n8n_worker_keda_min_replicas = local.tier.worker_min_replicas
  n8n_worker_keda_max_replicas = local.tier.worker_max_replicas
  n8n_worker_concurrency       = local.tier.worker_concurrency

  n8n_webhook_cpu_request    = "500m"
  n8n_webhook_cpu_limit      = "1500m"
  n8n_webhook_memory_request = "1Gi"
  n8n_webhook_memory_limit   = "4Gi"

  n8n_execution_concurrency_limit = 2000
  n8n_pruning_max_age             = 24
  n8n_pruning_max_count           = 5000000
  n8n_helm_timeout                = 1800

  appgw_autoscaling_enabled    = true
  appgw_autoscale_min_capacity = local.tier.appgw_autoscale_min_capacity
  appgw_autoscale_max_capacity = local.tier.appgw_autoscale_max_capacity
  appgw_waf_mode               = "Prevention"

  n8n_domain                                   = var.n8n_domain
  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = azurerm_key_vault.tls.id
  app_gateway_keyvault_role_assignment_enabled = true

  create_public_dns_record = true
  public_dns_zone_id       = azurerm_dns_zone.public.id

  n8n_license_key = var.n8n_license_key

  depends_on = [
    time_sleep.storage_rbac,
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
    azurerm_postgresql_flexible_server_configuration.uuid_ossp,
  ]
}
