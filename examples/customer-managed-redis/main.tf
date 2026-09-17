# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Customer-managed Redis ────────────────────────────────────────────────────
# This example is the customer-managed-infrastructure capability's Redis
# ownership boundary: `azurerm_managed_redis.existing` below is a caller-owned
# stand-in for a Redis instance the module does not create — for example an
# Azure Managed Redis instance in another subscription, or any other
# Redis-compatible endpoint. The module call sets create_redis = false and
# supplies the connection contract via redis_external_host / _port /
# _tls_enabled, with the password delivered through
# `kubernetes_secret.redis_password` (created directly in this example, not
# by the module) referenced by `redis_password_secret_ref` — the module never
# reads that Secret's value. AKS, PostgreSQL, Azure Blob storage, and ingress
# remain module-managed to isolate this example to the Redis ownership
# boundary alone.
#
# Ordering note: module.n8n.n8n_namespace depends on the module-managed
# namespace. The Secret uses that output as its namespace, and the module call
# uses the Secret's name in redis_password_secret_ref. These references order
# the namespace, Secret, and n8n Helm release during one apply.

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Topology  = "customer-managed-redis"
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

# ── Caller-owned Redis stand-in ───────────────────────────────────────────────
# Same resource type and private-endpoint shape the module uses for its own
# managed path (redis.tf), owned outside module "n8n" instead to stand in for
# an independently managed Redis instance.

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.n8n.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "${var.friendly_name_prefix}-redis-dns-link"
  resource_group_name   = azurerm_resource_group.n8n.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.n8n.id
  tags                  = local.common_tags
}

resource "azurerm_managed_redis" "existing" {
  name                = "${var.friendly_name_prefix}-shared-redis"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  sku_name              = "Balanced_B0"
  public_network_access = "Disabled"

  default_database {
    clustering_policy                  = "NoCluster"
    client_protocol                    = "Encrypted"
    access_keys_authentication_enabled = true
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-shared-redis" })
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.friendly_name_prefix}-redis-pe"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  subnet_id           = azurerm_subnet.redis.id

  private_service_connection {
    name                           = "${var.friendly_name_prefix}-redis-psc"
    private_connection_resource_id = azurerm_managed_redis.existing.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${var.friendly_name_prefix}-redis-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.redis]

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-pe" })
}

# ── Key Vault and lab-grade certificate ──────────────────────────────────────

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

# ── Caller-managed Redis password Secret ─────────────────────────────────────
# Created in the module-managed n8n namespace (module.n8n.n8n_namespace),
# never by the module itself. redis_password_secret_ref on the module call
# below names this Secret and key; the module renders only that name and key
# into the n8n chart and the KEDA TriggerAuthentication, never the value.

resource "kubernetes_secret" "redis_password" {
  metadata {
    name      = "n8n-redis-external-credentials"
    namespace = module.n8n.n8n_namespace
  }

  data = {
    password = azurerm_managed_redis.existing.default_database[0].primary_access_key
  }

  type = "Opaque"
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

  aks_api_authorized_ip_ranges = var.aks_api_authorized_ip_ranges

  create_redis               = false
  redis_external_host        = azurerm_managed_redis.existing.hostname
  redis_external_port        = azurerm_managed_redis.existing.default_database[0].port
  redis_external_tls_enabled = true
  redis_password_secret_ref = {
    name = kubernetes_secret.redis_password.metadata[0].name
    key  = "password"
  }

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  n8n_domain                                   = var.n8n_domain
  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = azurerm_key_vault.tls.id
  app_gateway_keyvault_role_assignment_enabled = true

  n8n_license_key = var.n8n_license_key

  depends_on = [
    time_sleep.storage_rbac,
    azurerm_private_endpoint.redis,
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
  ]
}
