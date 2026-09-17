# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Split ingress ─────────────────────────────────────────────────────────────
# Two Application Gateways instead of the module's single one:
#
#   webhook AGW (public)   -> n8n-webhook-processor   webhook/form/waiting/MCP
#   admin AGW (private)    -> n8n-main                editor UI and REST API
#
# The point is blast radius: only the endpoints that must accept unauthenticated
# internet traffic are exposed, and the admin surface never leaves the VNet.
# create_ingress = false hands routing to ingress.tf, which creates both
# gateways plus two standalone (non-addon) AGIC Helm releases so each gateway
# gets its own controller identity. The module still builds AKS, PostgreSQL,
# Redis, storage, and the n8n workload — only ingress is caller-owned.

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Topology  = "split-ingress"
  }, var.common_tags)

  webhook_domain = "${var.webhook_subdomain}.${var.n8n_domain}"
}

# ── Azure foundations ────────────────────────────────────────────────────────
# Same shape as examples/small, sized identically since this example does not
# introduce its own sizing tier. The appgw subnet is unchanged from small's
# /24: two Application Gateways with dynamic private frontend allocation both
# fit comfortably within it.

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

# ── Key Vault and lab-grade certificates ─────────────────────────────────────
# Two self-signed certificates, one per hostname, imported into one shared
# Key Vault. Each Application Gateway in ingress.tf attaches only the
# certificate for the hostname it terminates. Replace both
# module.tls_self_signed_* calls with the Let's Encrypt helper or a
# certificate from your public key infrastructure for production — every
# name below is self-signed, so browsers and webhook clients will not trust
# it.

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

module "tls_self_signed_admin" {
  source = "../../modules/tls-self-signed"

  domain_name          = var.n8n_domain
  key_vault_id         = azurerm_key_vault.tls.id
  friendly_name_prefix = "${var.friendly_name_prefix}a"
  common_tags          = local.common_tags

  depends_on = [time_sleep.key_vault_rbac]
}

module "tls_self_signed_webhook" {
  source = "../../modules/tls-self-signed"

  domain_name          = local.webhook_domain
  key_vault_id         = azurerm_key_vault.tls.id
  friendly_name_prefix = "${var.friendly_name_prefix}w"
  common_tags          = local.common_tags

  depends_on = [time_sleep.key_vault_rbac]
}

# ── n8n ──────────────────────────────────────────────────────────────────────
# create_ingress = false leaves AKS, PostgreSQL, Redis, storage, and the n8n
# Helm release module-managed, but hands both Application Gateways, both AGIC
# installs, and both Kubernetes Ingress objects to ingress.tf. The module
# still requires a syntactically valid app_gateway_tls_cert_secret_id even
# though it creates no gateway to use it; the admin certificate satisfies
# that contract inertly.

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

  create_ingress                               = false
  app_gateway_tls_cert_secret_id               = module.tls_self_signed_admin.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = null
  app_gateway_keyvault_role_assignment_enabled = false

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  n8n_domain      = var.n8n_domain
  n8n_webhook_url = "https://${local.webhook_domain}"
  n8n_license_key = var.n8n_license_key

  depends_on = [
    time_sleep.storage_rbac,
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
  ]
}
