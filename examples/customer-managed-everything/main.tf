# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Every customer-managed boundary at once ──────────────────────────────────
# Combines every ownership boundary the customer-managed-infrastructure
# capability supports: existing AKS, external PostgreSQL, external Redis,
# existing Blob storage, an existing namespace and Secrets, a direct
# modules/controllers composition, caller-owned ingress, and a caller-owned
# webhook HPA. Each boundary is exercised the same way its single-purpose
# sibling example (customer-managed-cluster / -redis / -storage) exercises
# it; see those examples for a narrower walk-through of any one boundary.
#
# The caller-managed namespace is created before every Secret below. The
# module call's explicit dependencies then place the n8n Helm release after
# all four caller-managed credential Secrets.

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Topology  = "customer-managed-everything"
  }, var.common_tags)

  n8n_namespace  = "n8n"
  keda_namespace = "keda"
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
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. The module only creates and associates an NSG for appgw_subnet_id (see ingress.tf azurerm_subnet_network_security_group_association.appgw); aks_network_policy defaults to null and this example leaves it unset, so no AKS network-policy engine restricts pod traffic on the node subnet either.
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
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. This subnet is delegated to Microsoft.DBforPostgreSQL/flexibleServers for VNet integration; the stand-in azurerm_postgresql_flexible_server.existing below sets public_network_access_enabled = false and uses this delegated subnet plus a private DNS zone for connectivity, but no NSG restricts traffic inside the subnet.
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
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. This subnet hosts this example's own azurerm_private_endpoint.redis NIC for the external Azure Managed Redis stand-in (private_endpoint_network_policies = "Disabled"), so traffic reaches Redis exclusively via the private endpoint, but the subnet itself has no NSG.
  name                              = "redis-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.10.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "private_endpoints" {
  # checkov:skip=CKV2_AZURE_31:Known gap: no subnet-level NSG. This subnet hosts this example's own azurerm_private_endpoint.blob NIC for the external storage account stand-in (private_endpoint_network_policies = "Disabled"), so traffic reaches the storage account exclusively via the private endpoint, but the subnet itself has no NSG.
  name                              = "storage-private-endpoints"
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.n8n.name
  address_prefixes                  = ["10.0.11.0/24"]
  private_endpoint_network_policies = "Disabled"
}

# ── Caller-owned AKS stand-in ─────────────────────────────────────────────────

resource "azurerm_kubernetes_cluster" "existing" {
  # checkov:skip=CKV_AZURE_4:The stand-in models a plausible minimum-viable customer AKS cluster: no oms_agent/Container Insights addon is configured. A real customer-managed cluster's actual logging posture is the owning platform team's decision.
  # checkov:skip=CKV_AZURE_7:No network_policy is set in network_profile, matching the module's own azurerm_kubernetes_cluster.n8n default (var.aks_network_policy defaults to null). The stand-in models the least-configured plausible estate, not a hardening recommendation.
  # checkov:skip=CKV_AZURE_115:private_cluster_enabled is left unset (public API server), matching the module's own default (var.aks_private_cluster_enabled defaults to false). The stand-in models a customer's pre-existing minimum-viable estate, not this module's hardened option.
  # checkov:skip=CKV_AZURE_116:The Azure Policy add-on is not enabled on this stand-in. A real customer-managed cluster's actual policy posture is the owning platform team's decision, not something this example should model.
  # checkov:skip=CKV_AZURE_117:No disk_encryption_set_id is configured, so the OS disk uses Azure's platform-managed key. Adding a caller-owned Disk Encryption Set is exactly the complexity a "pre-existing cluster" stand-in should not be modeling.
  # checkov:skip=CKV_AZURE_141:local_account_disabled is left unset (local accounts stay enabled), matching the module's own default (var.aks_local_account_disabled defaults to false, and requires Entra ID integration this stand-in does not configure).
  # checkov:skip=CKV_AZURE_168:default_node_pool has no max_pods override, so it uses Azure's provider default rather than an explicit floor of 50. The stand-in models a plausible minimum-viable customer cluster, not a capacity-tuning exercise.
  # checkov:skip=CKV_AZURE_170:sku_tier is left unset (Free tier, no financially-backed API server SLA), matching the module's own default (var.aks_sku_tier defaults to "Free"). A real customer-managed cluster's actual SLA tier is the owning platform team's decision.
  # checkov:skip=CKV_AZURE_171:automatic_upgrade_channel is left unset, so this stand-in does not opt into an upgrade channel. A real customer-managed cluster's actual upgrade policy is the owning platform team's decision, not something this example should model.
  # checkov:skip=CKV_AZURE_172:This stand-in does not use the Secrets Store CSI Driver addon at all, so there is no autorotation setting to configure. n8n gets its TLS certificate through the Application Gateway's own Key Vault integration (ingress.tf), not a CSI-mounted Secret.
  # checkov:skip=CKV_AZURE_226:default_node_pool uses Azure's default managed OS disk, not Ephemeral. Ephemeral disks require sizing the node's local (temp) disk to the OS disk, which is exactly the capacity-tuning complexity a "pre-existing cluster" stand-in should not be modeling.
  # checkov:skip=CKV_AZURE_227:No host-based encryption is configured on the default node pool. A real customer-managed cluster's actual host-encryption posture is the owning platform team's decision, not something this example should model.
  # checkov:skip=CKV_AZURE_232:only_critical_addons_enabled is left unset on the default node pool, so n8n and other workloads may still schedule onto the system pool. The stand-in models a plausible minimum-viable customer cluster without a dedicated user node pool, so segregating "critical" pods onto this one pool buys nothing extra.
  name                = "${var.friendly_name_prefix}-shared-aks"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  dns_prefix          = "${var.friendly_name_prefix}-shared-aks"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  node_provisioning_profile {
    mode = "Manual"
  }

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

# ── External PostgreSQL stand-in ──────────────────────────────────────────────

resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.n8n.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                = "${var.friendly_name_prefix}-postgres-dns-link"
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id
  virtual_network_id  = azurerm_virtual_network.n8n.id

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-postgres-dns-link" })
}

resource "azurerm_postgresql_flexible_server" "existing" {
  # checkov:skip=CKV_AZURE_136:geo_redundant_backup_enabled is left unset (false), matching the module's own cost-minimizing default (var.pg_geo_redundant_backup_enabled defaults to false). A real customer-managed server's actual backup posture is the owning platform team's decision.
  # checkov:skip=CKV2_AZURE_57:False positive: this stand-in uses delegated_subnet_id (VNet integration) plus public_network_access_enabled = false for private connectivity, the same shape as the module's own azurerm_postgresql_flexible_server.n8n (database.tf, also flagged for this check). PostgreSQL Flexible Server's VNet-integrated mode does not use a separate azurerm_private_endpoint resource, which is what this check looks for.
  name                = "${var.friendly_name_prefix}-shared-pg"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  version  = "16"
  sku_name = "GP_Standard_D2s_v3"

  storage_mb = 32768

  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = "n8nadmin"
  administrator_password = var.postgres_admin_password

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-shared-pg" })

  lifecycle {
    # storage_type (azurerm 5.4.0) is ForceNew with no state migration; see
    # the module's database.tf for why a 4.x-created server must ignore it.
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
      storage_type,
    ]
  }
}

resource "azurerm_postgresql_flexible_server_database" "existing" {
  name      = "n8n"
  server_id = azurerm_postgresql_flexible_server.existing.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# ── External Redis stand-in ───────────────────────────────────────────────────

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.n8n.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                = "${var.friendly_name_prefix}-redis-dns-link"
  private_dns_zone_id = azurerm_private_dns_zone.redis.id
  virtual_network_id  = azurerm_virtual_network.n8n.id
  tags                = local.common_tags
}

resource "azurerm_managed_redis" "existing" {
  name                = "${var.friendly_name_prefix}-shared-redis"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  sku_name              = "Balanced_B0"
  public_network_access = "Disabled"

  default_database {
    clustering_policy = "NoCluster"
    client_protocol   = "Encrypted"
    # NoEviction: this stand-in models good practice for a caller-owned
    # Redis feeding n8n's Bull queue, same rationale as redis.tf's
    # module-managed default. See docs/redis.md "Eviction policy".
    eviction_policy                    = "NoEviction"
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

# ── Existing Blob storage stand-in ────────────────────────────────────────────

data "azurerm_client_config" "current" {}

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "existing" {
  # checkov:skip=CKV_AZURE_59:Public network access is disabled through public_network_access = "Disabled" (azurerm 5.5.0+); checkov still inspects only the deprecated public_network_access_enabled, which azurerm removes in 6.0.
  # checkov:skip=CKV_AZURE_206:account_replication_type = "LRS" matches the module's own cost-minimizing default (var.storage_account_replication_type defaults to "LRS"). The stand-in models a plausible minimum-viable customer storage account, not this module's zone/region-redundant option.
  # checkov:skip=CKV_AZURE_33:This account's Queue service is never used: n8n's workload only accesses the Blob container below (storage_container.existing), the same gap as the module's own azurerm_storage_account.n8n (storage.tf). Enabling diagnostic logging for a service nothing reads from would not improve this stand-in's posture.
  # checkov:skip=CKV2_AZURE_1:Encrypted with the Storage-managed default key, not a Customer Managed Key: the module's own azurerm_storage_account.n8n (storage.tf) has no customer_managed_key support either, so this stand-in models a plausible minimum-viable customer storage account, not a CMK-capable posture. A real customer-managed account's actual key is the owning team's decision.
  name                = substr("${var.friendly_name_prefix}st${random_string.storage_suffix.result}", 0, 24)
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  public_network_access           = "Disabled"
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
  # checkov:skip=CKV2_AZURE_21:Known gap: no diagnostic setting routes Blob read-request logs to a Log Analytics workspace or storage account. The stand-in models a plausible minimum-viable customer storage account; a real customer-managed account's actual logging posture is the owning team's decision.
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
  name                 = "${var.friendly_name_prefix}-blob-vnet-link"
  private_dns_zone_id  = azurerm_private_dns_zone.blob.id
  virtual_network_id   = azurerm_virtual_network.n8n.id
  registration_enabled = false

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

resource "random_string" "key_vault_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "tls" {
  # checkov:skip=CKV_AZURE_42:Teardown-friendly example setting: purge_protection_enabled = false is deliberate so the soft-deleted lab TLS vault that `terraform destroy` leaves behind can be purged manually and its name reused.
  # checkov:skip=CKV_AZURE_110:Same requirement as CKV_AZURE_42 above: purge protection is intentionally disabled for teardown-friendly lab usage.
  # checkov:skip=CKV_AZURE_109:This vault has no network_acls block, so it allows public access from all networks; it only stores a self-signed TLS cert created by modules/tls-self-signed and consumed via app_gateway_tls_cert_secret_id, so a firewall restriction is unnecessary lab convenience, not production data.
  # checkov:skip=CKV_AZURE_189:Same requirement as CKV_AZURE_109: public_network_access_enabled defaults to true and no network_acls restrict it, consistent with the lab-only self-signed TLS cert this vault holds.
  # checkov:skip=CKV2_AZURE_32:A private endpoint only helps with restricted network access, which this vault does not implement (see CKV_AZURE_189 above).
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

# ── Existing namespace and caller-managed Secrets ─────────────────────────────
# All are created directly against the caller-owned AKS stand-in. Resource
# references order the namespace before the Secrets, and module "n8n" depends
# explicitly on every Secret below.

resource "kubernetes_namespace" "n8n" {
  metadata {
    name = local.n8n_namespace
  }

  depends_on = [azurerm_kubernetes_cluster.existing]
}

resource "kubernetes_secret" "n8n_license" {
  metadata {
    name      = "n8n-license"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    license-key = var.n8n_license_key
  }

  type = "Opaque"
}

resource "random_password" "n8n_encryption_key" {
  length  = 48
  special = false
}

resource "kubernetes_secret" "n8n_encryption_key" {
  metadata {
    name      = "n8n-encryption-key"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    N8N_ENCRYPTION_KEY = random_password.n8n_encryption_key.result
    N8N_HOST           = var.n8n_domain
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = "http"
  }

  type = "Opaque"
}

resource "kubernetes_secret" "postgres_password" {
  metadata {
    name      = "n8n-postgres-external-credentials"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    password = var.postgres_admin_password
  }

  type = "Opaque"
}

resource "kubernetes_secret" "redis_password" {
  metadata {
    name      = "n8n-redis-external-credentials"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    password = azurerm_managed_redis.existing.default_database[0].primary_access_key
  }

  type = "Opaque"
}

# ── Direct modules/controllers composition ────────────────────────────────────
# install_keda = false on the module call below means module "n8n" installs
# no KEDA of its own; this direct call is what actually installs it. The
# n8n root call's depends_on = [module.controllers] preserves the install
# and destroy ordering design.md decision 6 requires of a direct caller.

module "controllers" {
  source = "../../modules/controllers"

  keda_namespace = local.keda_namespace
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

  create_aks                                   = false
  existing_aks_cluster_name                    = azurerm_kubernetes_cluster.existing.name
  existing_aks_resource_group_name             = azurerm_resource_group.n8n.name
  existing_aks_cluster_prerequisites_confirmed = true

  create_database            = false
  postgres_external_host     = azurerm_postgresql_flexible_server.existing.fqdn
  postgres_external_username = "n8nadmin"
  postgres_password_secret_ref = {
    name = kubernetes_secret.postgres_password.metadata[0].name
    key  = "password"
  }

  create_redis               = false
  redis_external_host        = azurerm_managed_redis.existing.hostname
  redis_external_port        = azurerm_managed_redis.existing.default_database[0].port
  redis_external_tls_enabled = true
  redis_password_secret_ref = {
    name = kubernetes_secret.redis_password.metadata[0].name
    key  = "password"
  }

  create_blob_storage                   = false
  existing_blob_storage_account_name    = azurerm_storage_account.existing.name
  existing_blob_container_name          = azurerm_storage_container.existing.name
  existing_blob_container_id            = azurerm_storage_container.existing.id
  existing_blob_endpoint                = azurerm_storage_account.existing.primary_blob_endpoint
  existing_blob_prerequisites_confirmed = true

  create_namespace = false
  n8n_namespace    = kubernetes_namespace.n8n.metadata[0].name

  install_keda                          = false
  keda_namespace                        = local.keda_namespace
  existing_keda_prerequisites_confirmed = true

  n8n_license_key_secret_ref = {
    name = kubernetes_secret.n8n_license.metadata[0].name
    key  = "license-key"
  }
  n8n_encryption_key_secret_ref = {
    name = kubernetes_secret.n8n_encryption_key.metadata[0].name
    key  = "N8N_ENCRYPTION_KEY"
  }

  create_ingress                               = false
  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = null
  app_gateway_keyvault_role_assignment_enabled = false

  n8n_webhook_hpa_enabled = false

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  n8n_domain = var.n8n_domain

  depends_on = [
    module.controllers,
    kubernetes_secret.n8n_license,
    kubernetes_secret.n8n_encryption_key,
    kubernetes_secret.postgres_password,
    kubernetes_secret.redis_password,
    azurerm_postgresql_flexible_server_database.existing,
    azurerm_private_endpoint.redis,
    azurerm_private_endpoint.blob,
    azurerm_subnet.appgw,
  ]
}
