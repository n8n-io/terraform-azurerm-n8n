# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Test fixture: caller-owned private DNS zones in the same apply ──────────
# Used only by tests/defaults.tftest.hcl's
# `caller_owned_private_dns_zones_created_in_the_same_apply` run, which plans
# (never applies) this configuration under the suite's mock providers. It is
# shaped like a real caller: it creates the three private DNS zones and
# passes their IDs to the root module in the same configuration, so every ID
# is unknown at plan time. A plan that succeeds proves the zone and VNet-link
# counts do not depend on those IDs (docs/customer-managed-infrastructure.md,
# rule 3). `terraform test` cannot feed an unknown value from one run into
# the next run's variables, which is why this is a caller module and not a
# setup run.

terraform {
  required_version = ">= 1.12"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
    random = {
      source = "hashicorp/random"
    }
    time = {
      source = "hashicorp/time"
    }
    kubectl = {
      source = "gavinbunney/kubectl"
    }
  }
}

locals {
  subnet_prefix = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet"
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = "connectivity-rg"
}

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = "connectivity-rg"
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = "connectivity-rg"
}

module "n8n" {
  source = "../../.."

  location                       = "eastus"
  resource_group_name            = "n8ntest-rg"
  friendly_name_prefix           = "n8ntest"
  vnet_id                        = local.subnet_prefix
  aks_subnet_id                  = "${local.subnet_prefix}/subnets/aks"
  postgres_subnet_id             = "${local.subnet_prefix}/subnets/postgres"
  redis_subnet_id                = "${local.subnet_prefix}/subnets/redis"
  appgw_subnet_id                = "${local.subnet_prefix}/subnets/appgw"
  private_endpoint_subnet_id     = "${local.subnet_prefix}/subnets/pe"
  n8n_domain                     = "n8n.example.com"
  app_gateway_tls_cert_secret_id = "https://n8ntest-shared-kv.vault.azure.net/secrets/n8n-tls-cert/abc123"
  n8n_license_key                = "test-license-key-value"

  create_postgres_private_dns_zone = false
  create_redis_private_dns_zone    = false
  create_blob_private_dns_zone     = false
  postgres_private_dns_zone_id     = azurerm_private_dns_zone.postgres.id
  redis_private_dns_zone_id        = azurerm_private_dns_zone.redis.id
  blob_private_dns_zone_id         = azurerm_private_dns_zone.blob.id
}
