# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── About this example ────────────────────────────────────────────────────────
# Complete end-to-end deployment that brings up everything needed for n8n in
# a single apply, demonstrating the canonical two-tier composition the
# registry-hardening Phase 5 split (US-014..US-024) introduced:
#
#   module "infra"     → modules/infra/    (Azure IaaS layer:
#                                           AKS, Postgres, Redis, Storage,
#                                           App Gateway, IAM, KV role-assign)
#   module "workload"  → modules/workload/ (Kubernetes layer:
#                                           KEDA, n8n Helm release, Ingress,
#                                           HPAs, federated identity wiring)
#
# Plus the example-owned plumbing the two modules consume but do not create:
#   - Two resource groups: a network RG (VNet + DNS + shared KV) and a
#     workload RG (the modules/infra/ resources land in this one), mirroring
#     the typical platform-team / workload-team split.
#   - Hand-rolled VNet + 5 subnets (sized for AKS / App Gateway / Postgres /
#     Redis PE / spare).
#   - Public Azure DNS zone + auto-managed A-record pointing at the App
#     Gateway public IP for single-apply DNS.
#   - Shared Key Vault holding the App Gateway TLS cert.
#   - The `modules/tls-self-signed/` submodule that issues a lab-grade cert
#     into the shared vault.
#
# Self-signed is the lab/internal-only default — browsers will warn on the
# cert. For Let's Encrypt production certs see `examples/complete-letsencrypt/`;
# for an explicit self-signed-only deployment see `examples/complete-self-signed/`.

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
# VNet uses 10.0.0.0/16 deliberately. The modules/infra/ submodule hardcodes
# the AKS cluster Service CIDR to 172.16.0.0/16 (see modules/infra/aks.tf) to
# dodge the azurerm default 10.0.0.0/16 service-CIDR collision; the VNet must
# NOT use 172.16.0.0/16 either for the same reason.
#
# Hand-rolled (vs the Azure/avm-res-network-virtualnetwork/azurerm AVM module)
# — keeps the example transparent and dependency-free for `terraform init`.

resource "azurerm_virtual_network" "n8n" {
  name                = "${var.friendly_name_prefix}-n8n-vnet"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  address_space       = ["10.0.0.0/16"]
  tags                = var.common_tags
}

# AKS node pool (Azure CNI). /22 = 1024 IPs — covers the default node-pool
# autoscaler bounds (2–6 nodes) plus per-pod IPs; bump to /21 if you raise
# aks_node_count_max above ~30.
resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.0.0/22"]
}

# Application Gateway. Must be dedicated (no other workloads); /24 is the
# Azure-recommended minimum for App Gateway v2 sizing.
resource "azurerm_subnet" "appgw" {
  name                 = "appgw"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.4.0/24"]
}

# PostgreSQL Flexible Server. VNet-injected — the entire subnet is consumed
# by Azure for Flexible Server, and the delegation is required by Azure to
# permit the service to allocate NICs into it.
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

# Redis Cache + private-endpoint subnet. Azure refuses to create a private
# endpoint in a subnet with network policies enforced — the string-form
# `private_endpoint_network_policies = "Disabled"` is the azurerm 4.x way
# (the legacy bool `private_endpoint_network_policies_enabled` is deprecated).
# Used by the modules/infra/ submodule for both `redis_subnet_id` (the Redis
# private endpoint NIC) and `private_endpoint_subnet_id` (any additional
# private endpoints US-018+ may add). Consolidating onto a single subnet
# keeps the example concise; production callers may prefer dedicated subnets.
resource "azurerm_subnet" "redis_pe" {
  name                              = "redis-pe"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.6.0/24"]
  private_endpoint_network_policies = "Disabled"
}

# Spare subnet — reserved for future Phase 2 work (e.g. a jumpbox, additional
# private endpoints for BYO Key Vault or storage). Not consumed by the n8n
# modules today.
resource "azurerm_subnet" "spare" {
  name                 = "spare"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.n8n.name
  address_prefixes     = ["10.0.7.0/24"]
}

# ── Public DNS zone ───────────────────────────────────────────────────────────
# Owned by the example; consumed by the example-owned `azurerm_dns_a_record.n8n`
# below to point `var.n8n_domain` at the App Gateway public IP. Single-apply
# DNS — no manual step in the middle.
#
# After the first apply the operator must take the zone's NS records (from
# `terraform output -json public_dns_zone_name_servers`) and configure them at
# their registrar to delegate var.public_dns_zone_name to Azure DNS.
# Terraform cannot do this delegation upstream — it lives at the domain
# registrar, outside Azure.
resource "azurerm_dns_zone" "public" {
  name                = var.public_dns_zone_name
  resource_group_name = azurerm_resource_group.network.name
  tags                = var.common_tags
}

# A-record pointing var.n8n_domain at the App Gateway public IP from
# `module.infra`. The record `name` is computed as the leftmost label(s) of
# var.n8n_domain relative to the zone — e.g. n8n_domain `n8n.example.com` in
# zone `example.com` → name `n8n`; apex (n8n_domain == zone) → name `@`. TTL
# 300 keeps reverts cheap during incident response.
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
# `modules/infra/keyvault.tf`) grants the App Gateway UAMI runtime read
# access on this vault when `var.app_gateway_keyvault_id` is supplied.
#
# RBAC mode is used here to align with the modules/infra contract: when
# var.app_gateway_keyvault_role_assignment_enabled = true, the submodule
# grants the App Gateway UAMI a Key Vault RBAC role (Key Vault Secrets
# User). That role is silently ineffective on a vault in access-policy
# mode, which manifests at App Gateway provisioning time as an opaque
# `InternalServerError` (the data plane refuses the UAMI's cert fetch and
# Azure reports it as a generic resource-provider failure). Enabling RBAC
# here makes the role assignment authoritative for the App Gateway and
# requires the operator running terraform to also hold an RBAC role on
# this vault — see `azurerm_role_assignment.kv_operator` below.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "shared" {
  name                       = substr("${var.friendly_name_prefix}-tls-kv", 0, 24)
  resource_group_name        = azurerm_resource_group.network.name
  location                   = azurerm_resource_group.network.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true

  tags = merge(var.common_tags, { Name = "${var.friendly_name_prefix}-tls-kv" })
}

# Operator-side RBAC: grants the principal running terraform Key Vault
# Administrator on the shared vault so the tls-self-signed submodule can
# import the generated cert (Create/Import/Get on certificates and secrets).
# Required because the vault is in RBAC mode (enable_rbac_authorization =
# true) — without this assignment the cert-import in module.tls_self_signed
# fails with 403.
resource "azurerm_role_assignment" "kv_operator" {
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Absorb Azure RBAC propagation lag (typically 30–120 s for vault-scope
# role assignments) before the tls-self-signed submodule attempts a data-
# plane import. Without this gate the import races the role and trips a
# transient 403.
resource "time_sleep" "kv_operator_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.kv_operator]
  create_duration = "60s"
}

# ── Self-signed TLS submodule (registry-hardening US-010) ─────────────────────
# Generates a 2048-bit RSA key + an X.509 self-signed cert valid 1 year and
# imports the resulting PEM into the shared Key Vault above. The submodule's
# output (`app_gateway_tls_cert_secret_id`) is the versioned KV Secret URI
# `module.infra`'s App Gateway listener consumes.

module "tls_self_signed" {
  source = "../../modules/tls-self-signed"

  domain_name          = var.n8n_domain
  key_vault_id         = azurerm_key_vault.shared.id
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = var.common_tags

  depends_on = [time_sleep.kv_operator_rbac_propagation]
}

# ── Tier 1: Azure IaaS (modules/infra/) ───────────────────────────────────────
# Provisions AKS, PostgreSQL Flexible Server, Redis Cache, Storage Account /
# Azure Files share, Application Gateway, the user-assigned identities binding
# them, and the role assignments (including the `appgw_kv_secrets_user`
# scoped to the shared KV when `app_gateway_keyvault_id` is supplied). Every
# input below mirrors a `var.*` declared in modules/infra/variables.tf — see
# that file for the full caller-facing contract.

module "infra" {
  source = "../../modules/infra"

  location             = var.location
  resource_group_name  = azurerm_resource_group.n8n.name
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = var.common_tags

  # NOTE: low-quota dev-subscription overrides for the live-apply rehearsal.
  # Production deployments should leave these at their submodule defaults
  # (Standard_D4s_v4 × 2-6 nodes per pool). Reduced here so the example
  # fits inside a sub with only 10 vCPU quota in the regional core pool
  # (Standard_D4s_v4 × 2 nodes per pool would need 16 vCPU total). The
  # submodule's AGENTS.md documents the production sizing rationale.
  aks_node_vm_size   = "Standard_D2s_v3"
  aks_node_count_min = 1
  aks_node_count_max = 2

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
  # resolve at plan time. Pair with `app_gateway_keyvault_id` above (the
  # module's cross-variable validation rejects the toggle being on without
  # the ID).
  app_gateway_keyvault_role_assignment_enabled = true

  # Explicit module-level dependency mirrors the AWS sibling: keeps the entire
  # VNet (including the postgres delegation and the redis_pe network-policy
  # state) up until n8n's PaaS resources are fully torn down. Without this,
  # parallel destroy can race the subnet teardown against the private-endpoint
  # / VNet-injection cleanup.
  depends_on = [
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis_pe,
  ]
}

# ── Tier 2: Kubernetes workload (modules/workload/) ───────────────────────────
# Installs KEDA, the n8n Helm release, the chart-side Secrets (database /
# Redis / Azure Files credentials), the n8n Ingress (AGIC reads it), the
# webhook-processor HPA, and the KEDA TriggerAuthentication CR. Every
# cross-tier input below sources from `module.infra`'s outputs verbatim — the
# wiring is mechanical because workload-tier variable names mirror their
# upstream infra-tier output names one-to-one (registry-hardening US-021..US-024).

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
