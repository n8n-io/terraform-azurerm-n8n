# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── About this example ────────────────────────────────────────────────────────
# Explicit self-signed-only deployment that wires the registry-hardening
# Phase 5 two-tier composition (US-014..US-026):
#
#   module "infra"     → modules/infra/    (Azure IaaS layer:
#                                           AKS, Postgres, Redis, Storage,
#                                           App Gateway, IAM, KV role-assign)
#   module "workload"  → modules/workload/ (Kubernetes layer:
#                                           KEDA, n8n Helm release, Ingress,
#                                           HPAs, federated identity wiring)
#
# The TLS cert is issued by `modules/tls-self-signed/` (US-010) — same shape
# as `examples/complete/` but with `var.tls_validity_period_hours` exposed so
# the operator can tune the cert's lifetime explicitly. Self-signed mode is
# lab/internal-only — browsers will warn on the cert because the chain ends
# at the cert itself rather than at a public CA root. For Let's Encrypt
# production certs see `../complete-letsencrypt/`.

# ── Resource groups ──────────────────────────────────────────────────────────
# Two RGs to mirror the platform-team / workload-team split. The network RG
# holds the example-owned plumbing (VNet, DNS zone, shared KV); the workload
# RG holds everything the n8n modules create. The modules/infra/ submodule
# does NOT create its own RG — it accepts a pre-existing RG via
# `var.resource_group_name` (registry-hardening US-014 BYO-RG contract).

resource "azurerm_resource_group" "network" {
  name     = "${var.friendly_name_prefix}-n8n-network-rg"
  location = var.location
  tags     = var.common_tags
}

resource "azurerm_resource_group" "n8n" {
  name     = "${var.friendly_name_prefix}-n8n-rg"
  location = var.location
  tags     = var.common_tags
}

# ── VNet + 5 subnets ──────────────────────────────────────────────────────────
# Same shape as `examples/complete/`. VNet uses 10.0.0.0/16 deliberately —
# the modules/infra/ submodule hardcodes the AKS Service CIDR to
# 172.16.0.0/16 to dodge the azurerm default 10.0.0.0/16 collision; the VNet
# must NOT use 172.16.0.0/16 either for the same reason.

resource "azurerm_virtual_network" "n8n" {
  name                = "${var.friendly_name_prefix}-n8n-vnet"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  address_space       = ["10.0.0.0/16"]
  tags                = var.common_tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.0.0/22"]
}

resource "azurerm_subnet" "appgw" {
  name                 = "appgw"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.4.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.5.0/24"]

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

resource "azurerm_subnet" "redis_pe" {
  name                              = "redis-pe"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.6.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "spare" {
  name                 = "spare"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.7.0/24"]
}

# ── Public DNS zone + A-record ────────────────────────────────────────────────
# The zone the example writes `var.n8n_domain`'s A-record into. Self-signed
# mode does not require any DNS-01 challenge (the cert is generated locally),
# so unlike the LE sibling example, this zone is only used for the A-record.

resource "azurerm_dns_zone" "public" {
  name                = var.public_dns_zone_name
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.common_tags
}

resource "azurerm_dns_a_record" "n8n" {
  name                = var.n8n_domain == azurerm_dns_zone.public.name ? "@" : trimsuffix(var.n8n_domain, ".${azurerm_dns_zone.public.name}")
  zone_name           = azurerm_dns_zone.public.name
  resource_group_name = azurerm_dns_zone.public.resource_group_name
  ttl                 = 300
  records             = [module.infra.appgw_public_ip_address]
  tags                = merge(var.common_tags, { Name = "${var.friendly_name_prefix}-n8n-public-a" })
}

# ── Shared Key Vault (TLS submodule cert destination) ─────────────────────────
# The `modules/tls-self-signed` submodule imports its generated PEM into this
# vault. The App Gateway listener (inside `module.infra`) reads back the
# imported cert via the secret URI exposed as the submodule's
# `app_gateway_tls_cert_secret_id` output. The infra submodule's role
# assignment (`azurerm_role_assignment.appgw_kv_secrets_user` in
# `modules/infra/keyvault.tf`) grants the App Gateway UAMI runtime read access
# on this vault when `var.app_gateway_keyvault_id` is supplied.
#
# Access-policy mode (not RBAC) is used here so the operator running terraform
# doesn't need a separate role assignment to import certs — the inline
# access_policy below grants the running principal full cert/secret control.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "shared" {
  name                       = substr("${var.friendly_name_prefix}-tls-kv", 0, 24)
  resource_group_name        = azurerm_resource_group.network.name
  location                   = azurerm_resource_group.network.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    certificate_permissions = [
      "Create",
      "Delete",
      "DeleteIssuers",
      "Get",
      "GetIssuers",
      "Import",
      "List",
      "ListIssuers",
      "ManageContacts",
      "ManageIssuers",
      "Purge",
      "Recover",
      "SetIssuers",
      "Update",
    ]

    secret_permissions = [
      "Delete",
      "Get",
      "List",
      "Purge",
      "Recover",
      "Set",
    ]
  }

  tags = merge(var.common_tags, { Name = "${var.friendly_name_prefix}-tls-kv" })
}

# ── Self-signed submodule (registry-hardening US-010) ────────────────────────
# Generates a 2048-bit RSA key + an X.509 self-signed cert valid for
# `var.tls_validity_period_hours` (default 1 year). Imports the resulting PEM
# into `azurerm_key_vault.shared`. The submodule's output
# (`app_gateway_tls_cert_secret_id`) is the versioned KV Secret URI both
# `module.infra`'s App Gateway listener and `module.workload`'s Ingress
# annotation consume.

module "tls_self_signed" {
  source = "../../modules/tls-self-signed"

  domain_name           = var.n8n_domain
  key_vault_id          = azurerm_key_vault.shared.id
  friendly_name_prefix  = var.friendly_name_prefix
  validity_period_hours = var.tls_validity_period_hours
  common_tags           = var.common_tags
}

# ── Tier 1: Azure IaaS (modules/infra/) ───────────────────────────────────────

module "infra" {
  source = "../../modules/infra"

  location             = var.location
  resource_group_name  = azurerm_resource_group.n8n.name
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = var.common_tags

  vnet_id                    = azurerm_virtual_network.n8n.id
  aks_subnet_id              = azurerm_subnet.aks.id
  postgres_subnet_id         = azurerm_subnet.postgres.id
  redis_subnet_id            = azurerm_subnet.redis_pe.id
  appgw_subnet_id            = azurerm_subnet.appgw.id
  private_endpoint_subnet_id = azurerm_subnet.redis_pe.id

  n8n_domain                     = var.n8n_domain
  app_gateway_tls_cert_secret_id = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id        = azurerm_key_vault.shared.id

  # Plan-time-known toggle that drives the count on the BYO Key Vault
  # role assignment. The vault is built in the SAME plan, so its `.id` is
  # unknown until apply — the toggle is the literal that lets `count`
  # resolve at plan time.
  app_gateway_keyvault_role_assignment_enabled = true

  depends_on = [
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis_pe,
  ]
}

# ── Tier 2: Kubernetes workload (modules/workload/) ───────────────────────────

module "workload" {
  source = "../../modules/workload"

  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = var.common_tags

  aks_cluster_name    = module.infra.aks_cluster_name
  aks_oidc_issuer_url = module.infra.aks_oidc_issuer_url

  postgres_fqdn           = module.infra.postgres_fqdn
  postgres_admin_username = module.infra.postgres_admin_username
  postgres_admin_password = module.infra.postgres_admin_password
  postgres_database_name  = module.infra.postgres_database_name

  redis_hostname           = module.infra.redis_hostname
  redis_ssl_port           = module.infra.redis_ssl_port
  redis_primary_access_key = module.infra.redis_primary_access_key

  storage_account_name               = module.infra.storage_account_name
  storage_account_primary_access_key = module.infra.storage_account_primary_access_key
  storage_share_name                 = module.infra.storage_share_name

  n8n_workload_uami_client_id = module.infra.n8n_workload_uami_client_id

  n8n_domain                     = var.n8n_domain
  app_gateway_id                 = module.infra.app_gateway_id
  app_gateway_tls_cert_secret_id = module.tls_self_signed.app_gateway_tls_cert_secret_id
  key_vault_id                   = module.infra.key_vault_id

  n8n_license_key = var.n8n_license_key
}
