# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Customer-managed AKS ──────────────────────────────────────────────────────
# This example is the customer-managed-infrastructure capability's AKS
# ownership boundary: `azurerm_kubernetes_cluster.existing` below is a
# caller-owned stand-in for a shared platform-team cluster. It is declared
# outside `module "n8n"` and the module never modifies it. The module call
# sets create_aks = false and points at this cluster by name and resource
# group; create_ingress must also be false (design.md decision 2) because
# the module cannot manage the AGIC addon on a cluster it does not own, so
# ingress.tf below installs a standalone AGIC release and Application
# Gateway the same way examples/split-ingress does. PostgreSQL, Redis, and
# Blob storage remain module-managed to isolate this example to the AKS
# ownership boundary alone — see examples/customer-managed-redis and
# examples/customer-managed-storage for those boundaries, and
# examples/customer-managed-everything for all of them combined.

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Topology  = "customer-managed-cluster"
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

# ── Caller-owned AKS stand-in ─────────────────────────────────────────────────
# Represents a cluster a platform team already runs and hands to n8n as a
# shared target. OIDC issuer and workload identity must be enabled (the
# existing_aks_cluster_prerequisites_confirmed attestation on the module call
# below asserts this) so the module can still federate its own n8n workload
# identity against this cluster's OIDC issuer.

resource "azurerm_kubernetes_cluster" "existing" {
  name                = "${var.friendly_name_prefix}-shared-aks"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  dns_prefix          = "${var.friendly_name_prefix}-shared-aks"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                        = "system"
    temporary_name_for_rotation = "systemtemp"
    vm_size                     = var.aks_node_vm_size
    vnet_subnet_id              = azurerm_subnet.aks.id

    node_count           = 2
    auto_scaling_enabled = true
    min_count            = 2
    max_count            = 6

    upgrade_settings {
      max_surge = "10%"
    }
  }

  network_profile {
    network_plugin    = "azure"
    service_cidr      = "172.16.0.0/16"
    dns_service_ip    = "172.16.0.10"
    load_balancer_sku = "standard"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.aks_api_authorized_ip_ranges) > 0 ? [1] : []

    content {
      authorized_ip_ranges = var.aks_api_authorized_ip_ranges
    }
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-shared-aks" })

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
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

# ── n8n ──────────────────────────────────────────────────────────────────────
# create_aks = false targets azurerm_kubernetes_cluster.existing above by name
# and resource group instead of creating its own cluster. create_ingress must
# be false for the same reason (design.md decision 2); ingress.tf installs a
# standalone AGIC release against the caller-owned gateway instead.

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

  create_aks                                   = false
  existing_aks_cluster_name                    = azurerm_kubernetes_cluster.existing.name
  existing_aks_resource_group_name             = azurerm_resource_group.n8n.name
  existing_aks_cluster_prerequisites_confirmed = true

  create_ingress                               = false
  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = null
  app_gateway_keyvault_role_assignment_enabled = false

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  pg_backup_retention_days   = var.pg_backup_retention_days
  blob_delete_retention_days = var.blob_delete_retention_days

  n8n_domain      = var.n8n_domain
  n8n_license_key = var.n8n_license_key

  depends_on = [
    time_sleep.storage_rbac,
    azurerm_kubernetes_cluster.existing,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
  ]
}
