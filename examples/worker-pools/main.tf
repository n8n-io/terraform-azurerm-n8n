# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

locals {
  common_tags = merge({
    ManagedBy = "terraform"
    Project   = "n8n"
    Tier      = "worker-pools"
  }, var.common_tags)

  # ── Worker pools ────────────────────────────────────────────────────────────
  # The topology this example exists to show, kept as a local rather than a
  # variable: it is the point of the example, not a knob, and a local is
  # reachable from tests/defaults.tftest.hcl where a literal at the module call
  # site would not be.
  #
  # Each entry becomes its own worker Deployment plus its own KEDA ScaledObject
  # watching that pool's `jobs-<name>` queue. Assign a project to a pool in the
  # n8n UI under Project, Settings, Worker Pools; its executions then run only
  # on that pool's workers.
  #
  # Declaring any pool switches N8N_WORKER_POOLS_ENABLED on across mains,
  # workers and webhook pods, which the feature needs in order to route at all.
  # NOT wired into module "n8n" below by default: uncomment the
  # n8n_worker_pools line in that block to actually deploy these pools. Until
  # then this local exists purely as the documented topology (also read by
  # outputs.worker_pool_names and this example's tests), and a plain
  # `terraform apply` against this file creates no pools and needs no
  # feat:workerPools entitlement.
  worker_pools = [
    # Heavier executions, given more CPU and memory and a lower concurrency so
    # each worker takes fewer jobs at once. Still CPU-only: this example runs
    # the same node pools as small and sets no node placement, so "heavy"
    # means bigger requests, not different hardware.
    {
      name           = "heavy"
      min_replicas   = 1
      max_replicas   = 4
      concurrency    = 5
      cpu_request    = "1"
      cpu_limit      = "2"
      memory_request = "2Gi"
      memory_limit   = "4Gi"
    },

    # An isolated set for one team's projects, at the module's default worker
    # sizing.
    {
      name         = "secteam"
      min_replicas = 1
      max_replicas = 3
    },

    # Scales to zero when idle and wakes when a pinned project runs something;
    # the job waits on jobs-itop rather than falling back. Bootstrap caveat: a
    # pool with no live workers is not offered in a project's Worker Pools
    # setting, so a project cannot be pinned to it for the first time while it
    # sits at 0. Raise min_replicas to 1, assign the projects, then put it back
    # to 0; the stored assignment survives the scale-down.
    {
      name         = "itop"
      min_replicas = 0
      max_replicas = 3
    },
  ]

  tier = {
    aks_node_vm_size       = var.aks_node_vm_size
    aks_availability_zones = var.aks_availability_zones
    aks_node_count_min     = 2

    # ── Node capacity ─────────────────────────────────────────────────────────
    # The one place this example is not sizing-equivalent to examples/small.
    # Pools are additional autoscalers on the same node pools, and each can
    # reach its own ceiling independently, so their pods have to fit alongside
    # the main, default-worker and webhook ceilings rather than instead of
    # them once the three pools above are uncommented into module "n8n".
    #
    # scaling.tf's advisory model, worked through for this example:
    #   - main:    6 x (1000m + 200m task-runner)          =  7,200m
    #   - worker:  10 x (500m + 200m task-runner)           =  7,000m
    #   - webhook: 8 x 300m                                 =  2,400m
    #   - pools:   4 x (1000m + 200m)   [heavy]              =  4,800m
    #            + 3 x (500m + 200m)    [secteam]            =  2,100m
    #            + 3 x (500m + 200m)    [itop]                =  2,100m
    #   peak demand                                          = 25,600m
    #
    # Supply at aks_node_vm_size = Standard_D4s_v5 (4 vCPU/node) and
    # aks_node_count_max = 7, both node pools counted per scaling.tf's model:
    #   (7 x 2 nodes) x (4,000m - 140m kube-reserved - 260m daemons)
    #     - 820m cluster control
    #   = 14 x 3,600m - 820m = 49,580m schedulable
    #
    # 49,580m comfortably clears the 25,600m peak with the three pools active.
    # See check "autoscaling_maxima_fit_aks_capacity" in the root module's
    # scaling.tf and README.md, "The pool topology", for the arithmetic if any
    # of these numbers change.
    aks_node_count_max = 7

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

  n8n_license_key = var.n8n_license_key
  n8n_image_tag   = var.n8n_image_tag

  # ── Chart ───────────────────────────────────────────────────────────────────
  # Required by this example: the module default n8n_chart_version predates
  # queueMode.workerGroups and would render no pools. See the variable's
  # comment and README.md, "Getting a chart that renders pools". The module
  # hardcodes the chart's repository (n8n.tf) to the same oci://ghcr.io
  # registry the official preview build publishes to, so no repository
  # override is needed or available here.
  n8n_chart_version               = var.n8n_chart_version
  n8n_worker_pools_chart_verified = var.n8n_worker_pools_chart_verified

  # ── Worker pools ────────────────────────────────────────────────────────────
  # The chart's own unlabelled worker deployment keeps serving the default
  # `jobs` queue for every project that is not pinned to a pool. Size it here.
  n8n_worker_keda_min_replicas = var.n8n_worker_keda_min_replicas
  n8n_worker_keda_max_replicas = var.n8n_worker_keda_max_replicas

  # EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE. Uncomment to deploy the
  # three pools documented in local.worker_pools above and in README.md, "The
  # pool topology". Needs an n8n Enterprise license carrying feat:workerPools
  # (plus feat:multipleMainInstances unless n8n_main_hpa_min_replicas = 1) and
  # a chart that renders queueMode.workerGroups; see README.md before
  # uncommenting.
  n8n_worker_pools = local.worker_pools

  depends_on = [
    time_sleep.storage_rbac,
    azurerm_subnet.aks,
    azurerm_subnet.appgw,
    azurerm_subnet.postgres,
    azurerm_subnet.redis,
    azurerm_subnet.private_endpoints,
  ]
}
