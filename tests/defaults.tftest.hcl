# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for the root module's contract skeleton
# (align-azure-with-aws-capabilities, section 1). Asserts on the
# naming/networking locals and variable-validation surface section 1
# establishes; subsequent sections (2 onward) add resource-specific
# assertions as AKS, PostgreSQL, Redis, Storage, and the Kubernetes/Helm
# controllers move into root concern files.
#
# Run: terraform test
#   (from the repo root. No Azure/Kubernetes credentials needed — every
#    provider this module declares is mocked so `terraform init` /
#    `terraform test` succeed without an azurerm/kubernetes/helm backend.)

mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg"
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "kubectl" {}

variables {
  location                       = "eastus"
  resource_group_name            = "n8ntest-rg"
  friendly_name_prefix           = "n8ntest"
  common_tags                    = { Environment = "test" }
  vnet_id                        = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet"
  aks_subnet_id                  = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/aks"
  postgres_subnet_id             = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/postgres"
  redis_subnet_id                = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/redis"
  appgw_subnet_id                = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/appgw"
  private_endpoint_subnet_id     = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/pe"
  n8n_domain                     = "n8n.example.com"
  app_gateway_tls_cert_secret_id = "https://n8ntest-shared-kv.vault.azure.net/secrets/n8n-tls-cert/abc123"
  n8n_license_key                = "test-license-key-value"
}

# ── Baseline plan: naming locals + tag merge ────────────────────────────────

run "skeleton_plans_clean_with_defaults" {
  command = plan

  assert {
    condition     = local.cluster_name == "${var.friendly_name_prefix}-aks"
    error_message = "local.cluster_name must be '<friendly_name_prefix>-aks'."
  }

  assert {
    condition     = local.postgres_server_name == "${var.friendly_name_prefix}-postgres"
    error_message = "local.postgres_server_name must be '<friendly_name_prefix>-postgres'."
  }

  assert {
    condition     = local.redis_name == "${var.friendly_name_prefix}-redis"
    error_message = "local.redis_name must be '<friendly_name_prefix>-redis'."
  }

  assert {
    condition     = local.storage_account_name == substr("${var.friendly_name_prefix}n8nfiles", 0, 24)
    error_message = "local.storage_account_name must be the substr-truncated '<friendly_name_prefix>n8nfiles' (Storage Account names cap at 24 chars, alnum-lowercase)."
  }

  assert {
    condition     = local.n8n_namespace == "n8n"
    error_message = "local.n8n_namespace must be 'n8n'."
  }

  assert {
    condition     = local.common_tags["ManagedBy"] == "terraform"
    error_message = "local.common_tags must always include ManagedBy = 'terraform'."
  }

  assert {
    condition     = local.common_tags["Project"] == "n8n"
    error_message = "local.common_tags must always include Project = 'n8n'."
  }

  assert {
    condition     = local.common_tags["Environment"] == "test"
    error_message = "local.common_tags must merge caller-supplied var.common_tags on top of the built-ins."
  }
}

# ── Required-input rejection (fails at the variable boundary) ───────────────

run "rejects_malformed_location" {
  command = plan

  variables {
    location = "East US"
  }

  expect_failures = [
    var.location,
  ]
}

run "rejects_malformed_resource_group_name" {
  command = plan

  variables {
    resource_group_name = ""
  }

  expect_failures = [
    var.resource_group_name,
  ]
}

run "rejects_malformed_friendly_name_prefix" {
  command = plan

  variables {
    friendly_name_prefix = "TooLongPrefixValue"
  }

  expect_failures = [
    var.friendly_name_prefix,
  ]
}

# ── Resource-ID validation (single-module-deployment spec: "Reject an
#    invalid subnet identifier") ────────────────────────────────────────────

run "rejects_malformed_vnet_id" {
  command = plan

  variables {
    vnet_id = "not-a-resource-id"
  }

  expect_failures = [
    var.vnet_id,
  ]
}

run "rejects_malformed_aks_subnet_id" {
  command = plan

  variables {
    aks_subnet_id = "not-a-subnet-id"
  }

  expect_failures = [
    var.aks_subnet_id,
  ]
}

run "rejects_malformed_postgres_subnet_id" {
  command = plan

  variables {
    postgres_subnet_id = "not-a-subnet-id"
  }

  expect_failures = [
    var.postgres_subnet_id,
  ]
}

run "rejects_malformed_redis_subnet_id" {
  command = plan

  variables {
    redis_subnet_id = "not-a-subnet-id"
  }

  expect_failures = [
    var.redis_subnet_id,
  ]
}

run "rejects_malformed_appgw_subnet_id" {
  command = plan

  variables {
    appgw_subnet_id = "not-a-subnet-id"
  }

  expect_failures = [
    var.appgw_subnet_id,
  ]
}

run "rejects_malformed_private_endpoint_subnet_id" {
  command = plan

  variables {
    private_endpoint_subnet_id = "not-a-subnet-id"
  }

  expect_failures = [
    var.private_endpoint_subnet_id,
  ]
}

# ── Domain, certificate, and license inputs ─────────────────────────────────

run "rejects_malformed_n8n_domain" {
  command = plan

  variables {
    n8n_domain = "not a domain"
  }

  expect_failures = [
    var.n8n_domain,
  ]
}

run "rejects_malformed_app_gateway_tls_cert_secret_id" {
  command = plan

  variables {
    app_gateway_tls_cert_secret_id = "https://example.com/not-a-key-vault-secret"
  }

  expect_failures = [
    var.app_gateway_tls_cert_secret_id,
  ]
}

run "rejects_keyvault_role_assignment_without_keyvault_id" {
  command = plan

  variables {
    app_gateway_keyvault_role_assignment_enabled = true
  }

  expect_failures = [
    var.app_gateway_keyvault_id,
  ]
}

run "rejects_malformed_app_gateway_keyvault_id" {
  command = plan

  variables {
    app_gateway_keyvault_id = "not-a-keyvault-id"
  }

  expect_failures = [
    var.app_gateway_keyvault_id,
  ]
}

run "rejects_empty_n8n_license_key" {
  command = plan

  variables {
    n8n_license_key = ""
  }

  expect_failures = [
    var.n8n_license_key,
  ]
}

run "rejects_placeholder_n8n_license_key" {
  command = plan

  variables {
    n8n_license_key = "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
  }

  expect_failures = [
    var.n8n_license_key,
  ]
}

# ── AKS and identity foundation (align-azure-with-aws-capabilities section 2) ─

run "aks_cluster_resources_in_plan" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].name == local.cluster_name
    error_message = "AKS cluster name must equal local.cluster_name."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].oidc_issuer_enabled == true
    error_message = "AKS cluster must have the OIDC issuer enabled (required for n8n workload identity federation)."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].workload_identity_enabled == true
    error_message = "AKS cluster must have workload identity enabled."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].identity[0].type == "SystemAssigned"
    error_message = "AKS cluster identity must be SystemAssigned."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].vm_size == var.aks_node_vm_size
    error_message = "default_node_pool.vm_size must equal var.aks_node_vm_size."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].vnet_subnet_id == var.aks_subnet_id
    error_message = "default_node_pool.vnet_subnet_id must equal var.aks_subnet_id."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].min_count == var.aks_node_count_min
    error_message = "default_node_pool.min_count must equal var.aks_node_count_min."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].max_count == var.aks_node_count_max
    error_message = "default_node_pool.max_count must equal var.aks_node_count_max."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].zones == toset(var.aks_availability_zones)
    error_message = "default_node_pool.zones must equal var.aks_availability_zones (default [\"1\", \"2\", \"3\"])."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].temporary_name_for_rotation == "systemtemp"
    error_message = "The default AKS pool must declare a temporary rotation name so callers can update VM size, zones, or other rotation-required properties."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].default_node_pool[0].upgrade_settings[0].max_surge == var.aks_node_upgrade_max_surge
    error_message = "default_node_pool.upgrade_settings.max_surge must equal var.aks_node_upgrade_max_surge (default \"10%\")."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.n8n[0].api_server_access_profile) == 0
    error_message = "api_server_access_profile block must be omitted when var.aks_api_authorized_ip_ranges is empty (the default) so the AKS API server keeps its default access profile."
  }

  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.n8n_user[0].name == "n8nuser"
    error_message = "n8n_user node pool name must be 'n8nuser'."
  }

  assert {
    condition     = azurerm_user_assigned_identity.n8n_workload.name == "${var.friendly_name_prefix}-n8n-workload"
    error_message = "n8n_workload UAMI name must embed friendly_name_prefix."
  }

  assert {
    condition     = azurerm_federated_identity_credential.n8n_workload.subject == "system:serviceaccount:${local.n8n_namespace}:n8n-enterprise"
    error_message = "n8n_workload federated identity credential subject must target the n8n namespace + chart service-account name."
  }

  # ── time_sleep.aks_api_warmup ──────────────────────────────────────────
  assert {
    condition     = time_sleep.aks_api_warmup[0].create_duration == "${var.aks_api_warmup_seconds}s"
    error_message = "time_sleep.aks_api_warmup[0].create_duration must equal '${var.aks_api_warmup_seconds}s' (the var.aks_api_warmup_seconds knob)."
  }

  assert {
    condition     = time_sleep.aks_api_warmup[0].create_duration == "90s"
    error_message = "time_sleep.aks_api_warmup[0].create_duration default must be 90s."
  }
}

run "aks_api_authorized_ranges_render_when_supplied" {
  command = plan

  variables {
    aks_api_authorized_ip_ranges = ["203.0.113.0/24"]
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n[0].api_server_access_profile[0].authorized_ip_ranges == toset(["203.0.113.0/24"])
    error_message = "api_server_access_profile.authorized_ip_ranges must render the supplied CIDR list when non-empty."
  }
}

run "rejects_malformed_aks_kubernetes_version" {
  command = plan

  variables {
    aks_kubernetes_version = "v1.30"
  }

  expect_failures = [
    var.aks_kubernetes_version,
  ]
}

run "rejects_malformed_aks_node_vm_size" {
  command = plan

  variables {
    aks_node_vm_size = "not-a-sku"
  }

  expect_failures = [
    var.aks_node_vm_size,
  ]
}

run "rejects_malformed_aks_availability_zones" {
  command = plan

  variables {
    aks_availability_zones = ["europe"]
  }

  expect_failures = [
    var.aks_availability_zones,
  ]
}

run "rejects_malformed_aks_api_authorized_ip_ranges" {
  command = plan

  variables {
    aks_api_authorized_ip_ranges = ["not-a-cidr"]
  }

  expect_failures = [
    var.aks_api_authorized_ip_ranges,
  ]
}

run "rejects_malformed_aks_node_upgrade_max_surge" {
  command = plan

  variables {
    aks_node_upgrade_max_surge = "a lot"
  }

  expect_failures = [
    var.aks_node_upgrade_max_surge,
  ]
}

run "rejects_aks_api_warmup_seconds_below_floor" {
  command = plan

  variables {
    aks_api_warmup_seconds = 10
  }

  expect_failures = [
    var.aks_api_warmup_seconds,
  ]
}

# ── PostgreSQL topologies (align-azure-with-aws-capabilities section 3) ──────

run "managed_postgres_resources_in_plan" {
  command = plan

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].name == local.postgres_server_name
    error_message = "Managed PostgreSQL Flexible Server name must equal local.postgres_server_name."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].public_network_access_enabled == false
    error_message = "Managed PostgreSQL Flexible Server must have public network access disabled."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].delegated_subnet_id == var.postgres_subnet_id
    error_message = "Managed PostgreSQL Flexible Server must be delegated to var.postgres_subnet_id."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].sku_name == var.pg_sku_name
    error_message = "Managed PostgreSQL Flexible Server sku_name must equal var.pg_sku_name."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].backup_retention_days == var.pg_backup_retention_days
    error_message = "Managed PostgreSQL Flexible Server backup_retention_days must equal var.pg_backup_retention_days (default 7)."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].geo_redundant_backup_enabled == var.pg_geo_redundant_backup_enabled
    error_message = "Managed PostgreSQL Flexible Server geo_redundant_backup_enabled must equal var.pg_geo_redundant_backup_enabled (default false)."
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.n8n[0].high_availability) == 0
    error_message = "high_availability block must be omitted when var.pg_enable_high_availability is false (the default)."
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.n8n[0].maintenance_window) == 0
    error_message = "maintenance_window block must be omitted when var.pg_maintenance_window is null (the default)."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server_database.n8n[0].name == "n8n"
    error_message = "Managed PostgreSQL database name must be 'n8n'."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server_configuration.uuid_ossp[0].value == "UUID-OSSP"
    error_message = "azure.extensions allowlist must include UUID-OSSP."
  }

  assert {
    condition     = azurerm_private_dns_zone.postgres[0].name == "privatelink.postgres.database.azure.com"
    error_message = "PostgreSQL private DNS zone name must be exactly 'privatelink.postgres.database.azure.com'."
  }

  assert {
    condition     = local.postgres_connection.port == 5432
    error_message = "local.postgres_connection.port must be 5432 when create_database = true."
  }

  assert {
    condition     = local.postgres_connection.database == "n8n"
    error_message = "local.postgres_connection.database must be 'n8n' when create_database = true."
  }
}

run "managed_postgres_high_availability_and_maintenance_window_render" {
  command = plan

  variables {
    pg_enable_high_availability = true
    pg_primary_zone             = "1"
    pg_standby_zone             = "2"
    pg_maintenance_window = {
      day_of_week  = 0
      start_hour   = 2
      start_minute = 30
    }
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].high_availability[0].mode == "ZoneRedundant"
    error_message = "high_availability.mode must be ZoneRedundant when var.pg_enable_high_availability is true."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].high_availability[0].standby_availability_zone == "2"
    error_message = "high_availability.standby_availability_zone must equal var.pg_standby_zone."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].zone == "1"
    error_message = "zone must equal var.pg_primary_zone."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n[0].maintenance_window[0].day_of_week == 0
    error_message = "maintenance_window.day_of_week must equal the supplied var.pg_maintenance_window.day_of_week."
  }
}

run "rejects_high_availability_with_burstable_sku" {
  command = plan

  variables {
    pg_enable_high_availability = true
    pg_sku_name                 = "B_Standard_B1ms"
  }

  expect_failures = [
    var.pg_enable_high_availability,
  ]
}

run "rejects_high_availability_with_identical_zones" {
  command = plan

  variables {
    pg_enable_high_availability = true
    pg_primary_zone             = "1"
    pg_standby_zone             = "1"
  }

  expect_failures = [
    var.pg_standby_zone,
  ]
}

run "rejects_malformed_pg_maintenance_window" {
  command = plan

  variables {
    pg_maintenance_window = {
      day_of_week  = 7
      start_hour   = 2
      start_minute = 30
    }
  }

  expect_failures = [
    var.pg_maintenance_window,
  ]
}

run "rejects_pg_backup_retention_days_below_floor" {
  command = plan

  variables {
    pg_backup_retention_days = 3
  }

  expect_failures = [
    var.pg_backup_retention_days,
  ]
}

# ── External PostgreSQL path ─────────────────────────────────────────────────

run "external_postgres_plan_creates_no_server_resources" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "external-pg.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "super-secret-external-password"
    postgres_external_database = "n8n_external"
    postgres_external_port     = 5433
    postgres_external_ssl_mode = "verify-full"
  }

  assert {
    condition     = length(azurerm_postgresql_flexible_server.n8n) == 0
    error_message = "No managed PostgreSQL Flexible Server must be created when create_database = false."
  }

  assert {
    condition     = length(azurerm_private_dns_zone.postgres) == 0
    error_message = "No PostgreSQL private DNS zone must be created when create_database = false."
  }

  assert {
    condition     = length(random_password.postgres_admin) == 0
    error_message = "No admin password must be generated when create_database = false."
  }

  assert {
    condition     = local.postgres_connection.host == "external-pg.example.com"
    error_message = "local.postgres_connection.host must equal postgres_external_host when create_database = false."
  }

  assert {
    condition     = local.postgres_connection.port == 5433
    error_message = "local.postgres_connection.port must equal postgres_external_port when create_database = false."
  }

  assert {
    condition     = local.postgres_connection.database == "n8n_external"
    error_message = "local.postgres_connection.database must equal postgres_external_database when create_database = false."
  }

  assert {
    condition     = local.postgres_connection.username == "n8n_app"
    error_message = "local.postgres_connection.username must equal postgres_external_username when create_database = false."
  }

  assert {
    condition     = local.postgres_connection.password == "super-secret-external-password"
    error_message = "local.postgres_connection.password must equal postgres_external_password when create_database = false."
  }

  assert {
    condition     = local.postgres_connection.ssl_mode == "verify-full"
    error_message = "local.postgres_connection.ssl_mode must equal postgres_external_ssl_mode when create_database = false."
  }
}

run "rejects_external_postgres_without_host" {
  command = plan

  variables {
    create_database = false
  }

  expect_failures = [
    var.postgres_external_host,
    var.postgres_external_username,
    var.postgres_external_password,
  ]
}

run "rejects_malformed_postgres_external_ssl_mode" {
  command = plan

  variables {
    postgres_external_ssl_mode = "maybe"
  }

  expect_failures = [
    var.postgres_external_ssl_mode,
  ]
}

run "rejects_malformed_pg_admin_username" {
  command = plan

  variables {
    pg_admin_username = "admin"
  }

  expect_failures = [
    var.pg_admin_username,
  ]
}

run "rejects_postgres_pool_size_below_floor" {
  command = plan

  variables {
    postgres_pool_size = 0
  }

  expect_failures = [
    var.postgres_pool_size,
  ]
}

# ── Section 4: Azure Managed Redis topologies ───────────────────────────────

run "managed_redis_resources_in_plan" {
  command = plan

  assert {
    condition     = azurerm_managed_redis.n8n[0].name == local.redis_name
    error_message = "Managed Azure Managed Redis instance name must equal local.redis_name."
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].sku_name == var.redis_sku_name
    error_message = "Managed Azure Managed Redis sku_name must equal var.redis_sku_name (default Balanced_B1)."
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].public_network_access == "Disabled"
    error_message = "Managed Azure Managed Redis instance must have public network access disabled."
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].high_availability_enabled == var.redis_high_availability_enabled
    error_message = "Managed Azure Managed Redis high_availability_enabled must equal var.redis_high_availability_enabled (default false)."
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].default_database[0].clustering_policy == "NoCluster"
    error_message = "Managed Azure Managed Redis default_database.clustering_policy must always be NoCluster."
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].default_database[0].client_protocol == "Encrypted"
    error_message = "Managed Azure Managed Redis default_database.client_protocol must always be Encrypted (TLS-only)."
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].default_database[0].access_keys_authentication_enabled == true
    error_message = "Managed Azure Managed Redis default_database.access_keys_authentication_enabled must always be true."
  }

  assert {
    condition     = azurerm_private_dns_zone.redis[0].name == "privatelink.redis.azure.net"
    error_message = "Azure Managed Redis private DNS zone name must be exactly 'privatelink.redis.azure.net'."
  }

  assert {
    condition     = azurerm_private_endpoint.redis[0].subnet_id == var.redis_subnet_id
    error_message = "Redis private endpoint must attach to var.redis_subnet_id."
  }

  assert {
    condition     = azurerm_private_endpoint.redis[0].private_service_connection[0].subresource_names[0] == "redisEnterprise"
    error_message = "Redis private endpoint must target the redisEnterprise subresource."
  }

  assert {
    condition     = local.redis_connection.tls_enabled == true
    error_message = "local.redis_connection.tls_enabled must be true when create_redis = true."
  }

  assert {
    condition     = local.redis_connection.username == null
    error_message = "local.redis_connection.username must be null when create_redis = true (access-key auth has no username)."
  }
}

run "managed_redis_high_availability_renders" {
  command = plan

  variables {
    redis_high_availability_enabled = true
  }

  assert {
    condition     = azurerm_managed_redis.n8n[0].high_availability_enabled == true
    error_message = "high_availability_enabled must render true when var.redis_high_availability_enabled is true."
  }
}

run "rejects_malformed_redis_sku_name" {
  command = plan

  variables {
    redis_sku_name = "Balanced_B50"
  }

  expect_failures = [
    var.redis_sku_name,
  ]
}

run "external_redis_plan_creates_no_managed_resources" {
  command = plan

  variables {
    create_redis               = false
    redis_external_host        = "external-redis.example.com"
    redis_external_password    = "super-secret-external-password"
    redis_external_port        = 6379
    redis_external_tls_enabled = false
    redis_external_username    = "n8n_app"
  }

  assert {
    condition     = length(azurerm_managed_redis.n8n) == 0
    error_message = "No managed Azure Managed Redis instance must be created when create_redis = false."
  }

  assert {
    condition     = length(azurerm_private_dns_zone.redis) == 0
    error_message = "No Redis private DNS zone must be created when create_redis = false."
  }

  assert {
    condition     = length(azurerm_private_endpoint.redis) == 0
    error_message = "No Redis private endpoint must be created when create_redis = false."
  }

  assert {
    condition     = local.redis_connection.host == "external-redis.example.com"
    error_message = "local.redis_connection.host must equal redis_external_host when create_redis = false."
  }

  assert {
    condition     = local.redis_connection.port == 6379
    error_message = "local.redis_connection.port must equal redis_external_port when create_redis = false."
  }

  assert {
    condition     = local.redis_connection.tls_enabled == false
    error_message = "local.redis_connection.tls_enabled must equal redis_external_tls_enabled when create_redis = false."
  }

  assert {
    condition     = local.redis_connection.username == "n8n_app"
    error_message = "local.redis_connection.username must equal redis_external_username when create_redis = false."
  }

  assert {
    condition     = local.redis_connection.password == "super-secret-external-password"
    error_message = "local.redis_connection.password must equal redis_external_password when create_redis = false."
  }
}

run "rejects_external_redis_without_host" {
  command = plan

  variables {
    create_redis = false
  }

  expect_failures = [
    var.redis_external_host,
  ]
}

run "external_redis_plan_supports_unauthenticated_endpoint" {
  command = plan

  variables {
    create_redis        = false
    redis_external_host = "external-redis.example.com"
  }

  assert {
    condition     = local.redis_connection.username == null
    error_message = "local.redis_connection.username must be null for an unauthenticated external Redis endpoint."
  }

  assert {
    condition     = local.redis_connection.password == null
    error_message = "local.redis_connection.password must be null for an unauthenticated external Redis endpoint."
  }
}

# ── Section 5: Private Azure Blob storage ───────────────────────────────────

run "private_blob_storage_resources_in_plan" {
  command = plan

  override_resource {
    target          = azurerm_storage_container.n8n[0]
    override_during = plan
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles/blobServices/default/containers/n8n-data"
    }
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].name == local.storage_account_name
    error_message = "Storage account name must equal local.storage_account_name."
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].public_network_access_enabled == false
    error_message = "Storage account public network access must be disabled."
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].allow_nested_items_to_be_public == false
    error_message = "Storage account must prohibit public nested items."
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].https_traffic_only_enabled == true && azurerm_storage_account.n8n[0].min_tls_version == "TLS1_2"
    error_message = "Storage account must require HTTPS and TLS 1.2 or later."
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].shared_access_key_enabled == false
    error_message = "Storage shared-key access must be disabled on the default managed-identity-only path."
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].account_replication_type == var.storage_account_replication_type
    error_message = "Storage account replication must equal var.storage_account_replication_type."
  }

  assert {
    condition     = azurerm_storage_container.n8n[0].name == var.azure_blob_container_name && azurerm_storage_container.n8n[0].container_access_type == "private"
    error_message = "The managed Blob container must use the configured name and private access."
  }

  assert {
    condition     = azurerm_private_dns_zone.blob[0].name == "privatelink.blob.core.windows.net"
    error_message = "Blob private DNS zone must be privatelink.blob.core.windows.net."
  }

  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.blob[0].virtual_network_id == var.vnet_id
    error_message = "Blob private DNS zone must link to var.vnet_id."
  }

  assert {
    condition     = azurerm_private_endpoint.blob[0].subnet_id == var.private_endpoint_subnet_id
    error_message = "Blob private endpoint must attach to var.private_endpoint_subnet_id."
  }

  assert {
    condition     = azurerm_private_endpoint.blob[0].private_service_connection[0].subresource_names[0] == "blob"
    error_message = "Blob private endpoint must target the blob subresource."
  }

  assert {
    condition     = azurerm_role_assignment.n8n_blob_data_contributor[0].role_definition_name == "Storage Blob Data Contributor"
    error_message = "The n8n workload identity must receive Storage Blob Data Contributor for list, read, write, properties, copy, and delete operations."
  }

  assert {
    condition     = azurerm_role_assignment.n8n_blob_data_contributor[0].scope == azurerm_storage_container.n8n[0].id
    error_message = "The Blob data role assignment must be scoped to the managed container rather than the whole storage account."
  }

  assert {
    condition     = length(azurerm_storage_management_policy.n8n_binary) == 0
    error_message = "No Blob lifecycle policy must exist unless a binary retention period is explicitly supplied."
  }

  assert {
    condition     = nonsensitive(local.azure_blob_connection).auth_auto_detect == true
    error_message = "Managed identity and DefaultAzureCredential auto-detection must be the default Blob authentication path."
  }

}

run "binary_only_blob_retention_creates_scoped_policy" {
  command = plan

  variables {
    azure_blob_binary_retention_days = 30
  }

  assert {
    condition     = length(azurerm_storage_management_policy.n8n_binary) == 1
    error_message = "A binary-only container with a retention period must create one storage management policy."
  }

  assert {
    condition     = azurerm_storage_management_policy.n8n_binary[0].rule[0].filters[0].prefix_match == toset(["${var.azure_blob_container_name}/"])
    error_message = "Binary expiry must be scoped to the managed container prefix."
  }

  assert {
    condition     = azurerm_storage_management_policy.n8n_binary[0].rule[0].actions[0].base_blob[0].delete_after_days_since_modification_greater_than == 30
    error_message = "Binary expiry must use azure_blob_binary_retention_days."
  }
}

run "shared_execution_container_omits_blob_retention" {
  command = plan

  variables {
    azure_blob_binary_retention_days           = 30
    azure_blob_container_stores_execution_data = true
  }

  expect_failures = [
    check.azure_blob_lifecycle_requires_binary_only_container,
  ]

  assert {
    condition     = length(azurerm_storage_management_policy.n8n_binary) == 0
    error_message = "Lifecycle expiry must be omitted when execution data shares the Blob container, even when binary retention is configured."
  }
}

run "blob_connection_string_compatibility_path" {
  command = plan

  variables {
    azure_blob_connection_string = "DefaultEndpointsProtocol=https;AccountName=n8ntestn8nfiles;AccountKey=synthetic;EndpointSuffix=core.windows.net"
    azure_blob_endpoint          = "https://n8ntestn8nfiles.blob.core.usgovcloudapi.net/"
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].shared_access_key_enabled == true
    error_message = "Supplying a connection string must enable shared-key access on the managed account."
  }

  assert {
    condition     = nonsensitive(local.azure_blob_connection).auth_auto_detect == false
    error_message = "Supplying a connection string must disable DefaultAzureCredential auto-detection."
  }

  assert {
    condition     = nonsensitive(local.azure_blob_connection).endpoint == "https://n8ntestn8nfiles.blob.core.usgovcloudapi.net/"
    error_message = "The custom Blob endpoint must pass through verbatim."
  }
}

run "blob_account_key_compatibility_path" {
  command = plan

  variables {
    azure_blob_account_key = "synthetic-storage-account-key"
  }

  assert {
    condition     = azurerm_storage_account.n8n[0].shared_access_key_enabled == true
    error_message = "Supplying an account key must enable shared-key access on the managed account."
  }

  assert {
    condition     = nonsensitive(local.azure_blob_connection).auth_auto_detect == false
    error_message = "Supplying an account key must disable DefaultAzureCredential auto-detection."
  }
}

run "rejects_malformed_azure_blob_container_name" {
  command = plan

  variables {
    azure_blob_container_name = "Upper_Case"
  }

  expect_failures = [var.azure_blob_container_name]
}

run "rejects_blank_azure_blob_connection_string" {
  command = plan

  variables {
    azure_blob_connection_string = ""
  }

  expect_failures = [var.azure_blob_connection_string]
}

run "rejects_blank_azure_blob_account_key" {
  command = plan

  variables {
    azure_blob_account_key = ""
  }

  expect_failures = [var.azure_blob_account_key]
}

run "rejects_multiple_azure_blob_credentials" {
  command = plan

  variables {
    azure_blob_connection_string = "DefaultEndpointsProtocol=https;AccountName=n8ntestn8nfiles;AccountKey=synthetic"
    azure_blob_account_key       = "synthetic-storage-account-key"
  }

  expect_failures = [var.azure_blob_account_key]
}

run "rejects_malformed_azure_blob_endpoint" {
  command = plan

  variables {
    azure_blob_endpoint = "http://insecure.example.com"
  }

  expect_failures = [var.azure_blob_endpoint]
}

run "rejects_fractional_azure_blob_retention" {
  command = plan

  variables {
    azure_blob_binary_retention_days = 1.5
  }

  expect_failures = [var.azure_blob_binary_retention_days]
}

run "rejects_invalid_storage_account_replication_type" {
  command = plan

  variables {
    storage_account_replication_type = "INVALID"
  }

  expect_failures = [var.storage_account_replication_type]
}

# ── Section 6: Controllers and base n8n release ─────────────────────────────

run "controllers_and_base_n8n_release_in_plan" {
  command = plan

  assert {
    condition     = module.controllers.keda_namespace == local.keda_namespace && module.controllers.keda_installed == true
    error_message = "The root must call modules/controllers with local.keda_namespace and install KEDA by default."
  }

  assert {
    condition     = module.controllers.keda_release_name == "keda"
    error_message = "The default root plan must install the KEDA Helm release through modules/controllers."
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].name == local.n8n_namespace && kubernetes_namespace.n8n[0].timeouts.delete == "5m"
    error_message = "The n8n namespace must use the root namespace local and preserve its bounded delete timeout."
  }

  assert {
    condition     = kubernetes_secret.n8n_db[0].metadata[0].namespace == local.n8n_namespace
    error_message = "n8n Secrets must derive their namespace from local.n8n_namespace."
  }

  assert {
    condition     = kubernetes_secret.n8n_redis[0].metadata[0].name == local.n8n_redis_secret_name
    error_message = "The Redis Secret name must match the KEDA TriggerAuthentication reference local."
  }

  assert {
    condition     = contains(keys(kubernetes_secret.n8n_license[0].data), "license-key")
    error_message = "The license Secret must expose the key used by license.existingSecret."
  }

  # The generated-fallback path (var.n8n_encryption_key = null → the random
  # password feeds the Secret) cannot be asserted at plan time: the mocked
  # random_password result is apply-time-unknown. The caller-supplied path is
  # asserted in run "caller_supplied_encryption_key_reaches_the_encryption_secret".
  assert {
    condition     = random_password.n8n_encryption_key[0].length == 48 && random_password.n8n_encryption_key[0].special
    error_message = "The n8n encryption key must retain 48 characters with special-character entropy."
  }

  assert {
    condition     = random_password.n8n_task_runners_token.length == 48 && !random_password.n8n_task_runners_token.special
    error_message = "The task-runner token must retain 48 base62 characters."
  }

  assert {
    condition     = helm_release.n8n.version == "1.10.0" && var.n8n_image_tag == "2.35.0"
    error_message = "The base release must pin chart 1.10.0 and n8n 2.35.0."
  }

  assert {
    condition     = kubernetes_secret.n8n_encryption_key[0].data.N8N_PROTOCOL == "http"
    error_message = "n8n must listen over HTTP behind the TLS-terminating Application Gateway."
  }

  assert {
    condition     = helm_release.n8n.wait && helm_release.n8n.atomic && helm_release.n8n.cleanup_on_fail && helm_release.n8n.timeout == 600
    error_message = "The n8n release must preserve wait, atomic, cleanup-on-fail, and the 600-second timeout."
  }

  assert {
    condition     = time_sleep.n8n_helm_settle.create_duration == "60s"
    error_message = "The Helm settle gate must retain its safe default."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"kind\": \"TriggerAuthentication\"")
    error_message = "The root must render a KEDA TriggerAuthentication manifest."
  }
}

run "external_authenticated_redis_is_shared_by_n8n_and_keda" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"
    redis_external_port        = 6379
    redis_external_tls_enabled = false
    redis_external_username    = "n8n_app"
    redis_external_password    = "synthetic-external-redis-password"
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition     = kubernetes_secret.n8n_redis[0].data.username == "n8n_app" && kubernetes_secret.n8n_redis[0].data.password == "synthetic-external-redis-password"
    error_message = "The Redis Secret must hold the complete external authentication contract."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"parameter\": \"username\"") && strcontains(local.keda_trigger_authentication_yaml, "\"parameter\": \"password\"")
    error_message = "KEDA TriggerAuthentication must reference both username and password keys when external ACL authentication is configured."
  }

  assert {
    condition     = !strcontains(local.keda_trigger_authentication_yaml, "synthetic-external-redis-password")
    error_message = "The KEDA manifest must never embed the Redis password value."
  }

  assert {
    condition = (
      strcontains(helm_release.n8n.values[0], "\"host\": \"redis.external.example.com\"") &&
      length(yamldecode(helm_release.n8n.values[0]).keda.worker.triggers) == 2 &&
      alltrue([
        for trigger in yamldecode(helm_release.n8n.values[0]).keda.worker.triggers :
        trigger.metadata.address == "redis.external.example.com:6379" &&
        trigger.metadata.enableTLS == "false" &&
        trigger.authenticationRef.name == local.n8n_redis_keda_auth_name
      ])
    )
    error_message = "n8n and both KEDA queue triggers must use the same canonical external Redis host, port, TLS, and authentication contract."
  }

  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"passwordSecret\":") && !strcontains(helm_release.n8n.values[0], "synthetic-external-redis-password")
    error_message = "The n8n Helm values must reference the Redis Secret without embedding its password."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).image.tag == var.n8n_image_tag &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.image.tag == var.n8n_image_tag
    )
    error_message = "The application and task-runner images must stay on the same pinned n8n version."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).multiMain.setup.keyTtl == 10 &&
      yamldecode(helm_release.n8n.values[0]).multiMain.setup.checkInterval == 3
    )
    error_message = "The chart values must pin the Redis migration-leader timing safeguards."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).license.existingSecret.name == "n8n-license-secret" &&
      !contains(keys(yamldecode(helm_release.n8n.values[0]).license), "activationKey")
    )
    error_message = "The chart must consume the license from a Secret rather than embedding it in Helm values."
  }
}

run "external_unauthenticated_redis_omits_authentication_references" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"
    redis_external_port        = 6379
    redis_external_tls_enabled = false
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis[0].data) == 0 && !local.redis_authentication_enabled
    error_message = "An unauthenticated external Redis endpoint must create no credential data and activate no auth reference."
  }

  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"authenticationRef\":") && strcontains(helm_release.n8n.values[0], "\"name\": \"\"")
    error_message = "The KEDA trigger must leave authenticationRef empty for unauthenticated Redis."
  }
}

run "base_release_outputs_match_chart_service_contract" {
  command = plan

  assert {
    condition     = output.n8n_namespace == local.n8n_namespace
    error_message = "n8n_namespace must derive from the effective namespace local."
  }

  assert {
    condition     = output.n8n_service_name == "n8n-main" && output.n8n_webhook_service_name == "n8n-webhook-processor" && output.n8n_service_port == 5678
    error_message = "Service discovery outputs must match the pinned chart's rendered Service contract."
  }

  assert {
    condition     = toset(output.n8n_webhook_path_prefixes) == toset(["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"])
    error_message = "The webhook path output must include every endpoint family disabled on main pods."
  }

  assert {
    condition     = output.n8n_url == "https://${var.n8n_domain}"
    error_message = "n8n_url must expose the canonical HTTPS domain."
  }

}

run "caller_supplied_encryption_key_reaches_the_encryption_secret" {
  command = plan

  variables {
    n8n_encryption_key = "restored-v3-encryption-key-0123456789"
  }

  assert {
    condition     = local.n8n_encryption_key == var.n8n_encryption_key
    error_message = "When var.n8n_encryption_key is set, the effective key must be the caller-supplied value, not the generated one."
  }

  assert {
    condition     = kubernetes_secret.n8n_encryption_key[0].data.N8N_ENCRYPTION_KEY == var.n8n_encryption_key
    error_message = "The encryption Secret must carry the caller-supplied key so a database restore decrypts with the original key."
  }
}

run "rejects_too_short_n8n_encryption_key" {
  command = plan

  variables {
    n8n_encryption_key = "short"
  }

  expect_failures = [var.n8n_encryption_key]
}

run "rejects_n8n_application_version_below_azure_floor" {
  command = plan

  variables {
    n8n_image_tag = "2.28.9"
  }

  expect_failures = [var.n8n_image_tag]
}

run "rejects_malformed_n8n_chart_version" {
  command = plan

  variables {
    n8n_chart_version = "latest"
  }

  expect_failures = [var.n8n_chart_version]
}

run "rejects_malformed_keda_chart_version" {
  command = plan

  variables {
    keda_chart_version = "latest"
  }

  expect_failures = [var.keda_chart_version]
}

run "rejects_helm_settle_duration_below_floor" {
  command = plan

  variables {
    n8n_helm_post_install_settle_seconds = 10
  }

  expect_failures = [var.n8n_helm_post_install_settle_seconds]
}

# ── Section 7: n8n runtime and resource controls ─────────────────────────────

run "runtime_controls_defaults_render_in_helm_values" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition = (
      var.n8n_timezone == "UTC" &&
      var.n8n_log_level == "info" &&
      var.n8n_log_output == "console"
    )
    error_message = "Timezone and logging defaults must match the AWS sibling: UTC, info, and console."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).config.timezone == "UTC" &&
      one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == "N8N_LOG_LEVEL"]) == "info" &&
      one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == "N8N_LOG_OUTPUT"]) == "console"
    )
    error_message = "Timezone and logging defaults must render into the shared chart configuration."
  }

  assert {
    condition = (
      var.n8n_main_cpu_request == "1000m" && var.n8n_main_cpu_limit == "2000m" &&
      var.n8n_main_memory_request == "2Gi" && var.n8n_main_memory_limit == "4Gi" &&
      var.n8n_worker_cpu_request == "500m" && var.n8n_worker_cpu_limit == "1000m" &&
      var.n8n_worker_memory_request == "1Gi" && var.n8n_worker_memory_limit == "2Gi" &&
      var.n8n_webhook_cpu_request == "300m" && var.n8n_webhook_cpu_limit == "800m" &&
      var.n8n_webhook_memory_request == "512Mi" && var.n8n_webhook_memory_limit == "1Gi"
    )
    error_message = "All main, worker, and webhook resource defaults must match the AWS sibling."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).resources.main.requests.cpu == "1000m" &&
      yamldecode(helm_release.n8n.values[0]).resources.main.requests.memory == "2Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.main.limits.cpu == "2000m" &&
      yamldecode(helm_release.n8n.values[0]).resources.main.limits.memory == "4Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.requests.cpu == "500m" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.requests.memory == "1Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.limits.cpu == "1000m" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.limits.memory == "2Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.requests.cpu == "300m" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.requests.memory == "512Mi" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.limits.cpu == "800m" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.limits.memory == "1Gi"
    )
    error_message = "Every per-pod CPU and memory default must render for all three n8n pod families."
  }

  assert {
    condition = (
      var.n8n_worker_concurrency == 10 &&
      var.n8n_execution_timeout == 7200 &&
      var.n8n_execution_timeout_max == 7200 &&
      var.n8n_execution_concurrency_limit == 100 &&
      var.n8n_pruning_max_age == 336 &&
      var.n8n_pruning_max_count == 10000
    )
    error_message = "Worker concurrency, execution, and pruning defaults must match the AWS sibling."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).queueMode.workerConcurrency == 10 &&
      yamldecode(helm_release.n8n.values[0]).executions.timeout == 7200 &&
      yamldecode(helm_release.n8n.values[0]).executions.timeoutMax == 7200 &&
      yamldecode(helm_release.n8n.values[0]).executions.concurrency.productionLimit == 100 &&
      yamldecode(helm_release.n8n.values[0]).executions.pruning.enabled &&
      yamldecode(helm_release.n8n.values[0]).executions.pruning.maxAge == 336 &&
      yamldecode(helm_release.n8n.values[0]).executions.pruning.maxCount == 10000 &&
      yamldecode(helm_release.n8n.values[0]).executions.data.saveOnError == "all" &&
      yamldecode(helm_release.n8n.values[0]).executions.data.saveOnSuccess == "all" &&
      !yamldecode(helm_release.n8n.values[0]).executions.data.saveOnProgress &&
      yamldecode(helm_release.n8n.values[0]).executions.data.saveManualExecutions
    )
    error_message = "Worker concurrency, execution limits, and pruning controls must render into chart-native values."
  }

  assert {
    condition = (
      var.n8n_termination_grace_period == 60 &&
      var.n8n_prestop_sleep == 10 &&
      yamldecode(helm_release.n8n.values[0]).lifecycle.main.terminationGracePeriodSeconds == 60 &&
      yamldecode(helm_release.n8n.values[0]).lifecycle.worker.terminationGracePeriodSeconds == 60 &&
      yamldecode(helm_release.n8n.values[0]).lifecycle.webhookProcessor.terminationGracePeriodSeconds == 60 &&
      yamldecode(helm_release.n8n.values[0]).lifecycle.main.preStop.command[2] == "sleep 10" &&
      yamldecode(helm_release.n8n.values[0]).lifecycle.worker.preStop.command[2] == "sleep 10" &&
      yamldecode(helm_release.n8n.values[0]).lifecycle.webhookProcessor.preStop.command[2] == "sleep 10"
    )
    error_message = "All pod families must receive the default 60-second termination grace and 10-second preStop drain."
  }

  assert {
    condition = (
      var.n8n_task_runners_enabled &&
      var.n8n_task_runner_image_tag == null &&
      var.n8n_task_runner_cpu_request == "200m" &&
      var.n8n_task_runner_cpu_limit == "1" &&
      var.n8n_task_runner_memory_request == "512Mi" &&
      var.n8n_task_runner_memory_limit == "1Gi" &&
      var.n8n_task_runner_auto_shutdown_timeout == 15 &&
      var.n8n_task_runner_request_timeout == 300 &&
      var.n8n_task_runner_python_enabled
    )
    error_message = "Every task-runner default must match the AWS sibling."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).taskRunners.enabled &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.image.tag == var.n8n_image_tag &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.nativePythonRunner &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.launcher.autoShutdownTimeout == 15 &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.requests.cpu == "200m" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.requests.memory == "512Mi" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.limits.cpu == "1" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.limits.memory == "1Gi" &&
      one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == "N8N_RUNNERS_TASK_REQUEST_TIMEOUT"]) == "300"
    )
    error_message = "Task-runner enablement, derived image, Python support, resources, and timeouts must render into Helm values."
  }

  assert {
    condition = (
      var.n8n_templates_enabled &&
      var.n8n_personalization_enabled &&
      !var.n8n_reinstall_missing_packages &&
      !var.n8n_community_packages_prevent_loading &&
      var.n8n_community_packages_registry == null &&
      !var.n8n_license_detach_floating_on_shutdown
    )
    error_message = "Template, personalization, community-package, and floating-license defaults must remain safe and non-disruptive."
  }

  assert {
    condition = (
      one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN"]) == "false" &&
      length([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env if contains([
        "N8N_TEMPLATES_ENABLED",
        "N8N_PERSONALIZATION_ENABLED",
        "N8N_REINSTALL_MISSING_PACKAGES",
        "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING",
        "N8N_COMMUNITY_PACKAGES_REGISTRY",
      ], env.name)]) == 0
    )
    error_message = "The floating-license safeguard must always render false while default-on or default-off feature variables remain omitted."
  }
}

run "runtime_control_overrides_render_in_helm_values" {
  command = plan

  variables {
    create_database                         = false
    postgres_external_host                  = "postgres.external.example.com"
    postgres_external_username              = "n8n_app"
    postgres_external_password              = "synthetic-external-postgres-password"
    create_redis                            = false
    redis_external_host                     = "redis.external.example.com"
    n8n_timezone                            = "Europe/Berlin"
    n8n_log_level                           = "debug"
    n8n_log_output                          = "console,file"
    n8n_main_cpu_request                    = "1100m"
    n8n_main_cpu_limit                      = "2100m"
    n8n_main_memory_request                 = "3Gi"
    n8n_main_memory_limit                   = "5Gi"
    n8n_worker_cpu_request                  = "600m"
    n8n_worker_cpu_limit                    = "1100m"
    n8n_worker_memory_request               = "1536Mi"
    n8n_worker_memory_limit                 = "3Gi"
    n8n_webhook_cpu_request                 = "400m"
    n8n_webhook_cpu_limit                   = "900m"
    n8n_webhook_memory_request              = "768Mi"
    n8n_webhook_memory_limit                = "1536Mi"
    n8n_worker_concurrency                  = 25
    n8n_execution_timeout                   = -1
    n8n_execution_timeout_max               = 14400
    n8n_execution_concurrency_limit         = -1
    n8n_pruning_max_age                     = 24
    n8n_pruning_max_count                   = 0
    n8n_termination_grace_period            = 120
    n8n_prestop_sleep                       = 20
    n8n_task_runners_enabled                = false
    n8n_task_runner_cpu_request             = "250m"
    n8n_task_runner_cpu_limit               = "1200m"
    n8n_task_runner_memory_request          = "640Mi"
    n8n_task_runner_memory_limit            = "1280Mi"
    n8n_task_runner_auto_shutdown_timeout   = 0
    n8n_task_runner_request_timeout         = 600
    n8n_task_runner_python_enabled          = false
    n8n_templates_enabled                   = false
    n8n_personalization_enabled             = false
    n8n_reinstall_missing_packages          = true
    n8n_community_packages_prevent_loading  = true
    n8n_community_packages_registry         = "https://npm.internal.example.com:4873/repository/npm"
    n8n_license_detach_floating_on_shutdown = true
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).config.timezone == "Europe/Berlin" &&
      yamldecode(helm_release.n8n.values[0]).queueMode.workerConcurrency == 25 &&
      yamldecode(helm_release.n8n.values[0]).executions.timeout == -1 &&
      yamldecode(helm_release.n8n.values[0]).executions.concurrency.productionLimit == -1 &&
      yamldecode(helm_release.n8n.values[0]).executions.pruning.maxCount == 0
    )
    error_message = "Runtime overrides must flow through chart-native timezone, queue, execution, and pruning values."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).resources.main.requests.cpu == "1100m" &&
      yamldecode(helm_release.n8n.values[0]).resources.main.requests.memory == "3Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.main.limits.cpu == "2100m" &&
      yamldecode(helm_release.n8n.values[0]).resources.main.limits.memory == "5Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.requests.cpu == "600m" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.requests.memory == "1536Mi" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.limits.cpu == "1100m" &&
      yamldecode(helm_release.n8n.values[0]).resources.worker.limits.memory == "3Gi" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.requests.cpu == "400m" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.requests.memory == "768Mi" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.limits.cpu == "900m" &&
      yamldecode(helm_release.n8n.values[0]).resources.webhookProcessor.limits.memory == "1536Mi"
    )
    error_message = "Every main, worker, and webhook resource override must flow into Helm values."
  }

  assert {
    condition = (
      !yamldecode(helm_release.n8n.values[0]).taskRunners.enabled &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.image.tag == "2.35.0" &&
      !yamldecode(helm_release.n8n.values[0]).taskRunners.nativePythonRunner &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.launcher.autoShutdownTimeout == 0 &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.requests.cpu == "250m" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.requests.memory == "640Mi" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.limits.cpu == "1200m" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.resources.limits.memory == "1280Mi"
    )
    error_message = "Task-runner enablement, explicit image tag, Python toggle, and auto-shutdown override must render."
  }

  assert {
    condition = alltrue([
      for name, value in {
        N8N_LOG_LEVEL                           = "debug"
        N8N_LOG_OUTPUT                          = "console,file"
        N8N_RUNNERS_TASK_REQUEST_TIMEOUT        = "600"
        N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN = "true"
        N8N_TEMPLATES_ENABLED                   = "false"
        N8N_PERSONALIZATION_ENABLED             = "false"
        N8N_REINSTALL_MISSING_PACKAGES          = "true"
        N8N_COMMUNITY_PACKAGES_PREVENT_LOADING  = "true"
        N8N_COMMUNITY_PACKAGES_REGISTRY         = "https://npm.internal.example.com:4873/repository/npm"
      } : one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == name]) == value
    ])
    error_message = "Every environment-backed runtime override must render on all n8n pod families through config.extraEnv."
  }
}

run "rejects_invalid_runtime_string_formats" {
  command = plan

  variables {
    n8n_timezone                    = "Europe Berlin"
    n8n_log_level                   = "trace"
    n8n_log_output                  = "json"
    n8n_task_runner_image_tag       = " 2.35.0 "
    n8n_community_packages_registry = "npm.internal.example.com"
  }

  expect_failures = [
    var.n8n_timezone,
    var.n8n_log_level,
    var.n8n_log_output,
    var.n8n_task_runner_image_tag,
    var.n8n_community_packages_registry,
  ]
}

run "rejects_invalid_pod_resource_quantities" {
  command = plan

  variables {
    n8n_main_cpu_request           = "one core"
    n8n_main_cpu_limit             = "0"
    n8n_main_memory_request        = "two gigs"
    n8n_main_memory_limit          = "0Gi"
    n8n_worker_cpu_request         = "one core"
    n8n_worker_cpu_limit           = "0m"
    n8n_worker_memory_request      = "two gigs"
    n8n_worker_memory_limit        = "-1Gi"
    n8n_webhook_cpu_request        = "one core"
    n8n_webhook_cpu_limit          = "0"
    n8n_webhook_memory_request     = "two gigs"
    n8n_webhook_memory_limit       = "0Mi"
    n8n_task_runner_cpu_request    = "one core"
    n8n_task_runner_cpu_limit      = "0"
    n8n_task_runner_memory_request = "two gigs"
    n8n_task_runner_memory_limit   = "0Gi"
  }

  expect_failures = [
    var.n8n_main_cpu_request,
    var.n8n_main_cpu_limit,
    var.n8n_main_memory_request,
    var.n8n_main_memory_limit,
    var.n8n_worker_cpu_request,
    var.n8n_worker_cpu_limit,
    var.n8n_worker_memory_request,
    var.n8n_worker_memory_limit,
    var.n8n_webhook_cpu_request,
    var.n8n_webhook_cpu_limit,
    var.n8n_webhook_memory_request,
    var.n8n_webhook_memory_limit,
    var.n8n_task_runner_cpu_request,
    var.n8n_task_runner_cpu_limit,
    var.n8n_task_runner_memory_request,
    var.n8n_task_runner_memory_limit,
  ]
}

run "rejects_runtime_values_outside_supported_ranges" {
  command = plan

  variables {
    n8n_worker_concurrency                = 0
    n8n_execution_timeout                 = 0
    n8n_execution_timeout_max             = 0
    n8n_execution_concurrency_limit       = 0
    n8n_pruning_max_age                   = 0
    n8n_pruning_max_count                 = -1
    n8n_termination_grace_period          = 59
    n8n_prestop_sleep                     = 9
    n8n_task_runner_auto_shutdown_timeout = -1
    n8n_task_runner_request_timeout       = 0
  }

  expect_failures = [
    var.n8n_worker_concurrency,
    var.n8n_execution_timeout,
    var.n8n_execution_timeout_max,
    var.n8n_execution_concurrency_limit,
    var.n8n_pruning_max_age,
    var.n8n_pruning_max_count,
    var.n8n_termination_grace_period,
    var.n8n_prestop_sleep,
    var.n8n_task_runner_auto_shutdown_timeout,
    var.n8n_task_runner_request_timeout,
  ]
}

run "rejects_fractional_runtime_counts_and_durations" {
  command = plan

  variables {
    n8n_worker_concurrency                = 1.5
    n8n_execution_timeout                 = 1.5
    n8n_execution_timeout_max             = 1.5
    n8n_execution_concurrency_limit       = 1.5
    n8n_pruning_max_age                   = 1.5
    n8n_pruning_max_count                 = 1.5
    n8n_termination_grace_period          = 60.5
    n8n_prestop_sleep                     = 10.5
    n8n_task_runner_auto_shutdown_timeout = 1.5
    n8n_task_runner_request_timeout       = 1.5
  }

  expect_failures = [
    var.n8n_worker_concurrency,
    var.n8n_execution_timeout,
    var.n8n_execution_timeout_max,
    var.n8n_execution_concurrency_limit,
    var.n8n_pruning_max_age,
    var.n8n_pruning_max_count,
    var.n8n_termination_grace_period,
    var.n8n_prestop_sleep,
    var.n8n_task_runner_auto_shutdown_timeout,
    var.n8n_task_runner_request_timeout,
  ]
}

# ── Section 8: Custom images, extensions, and arbitrary configuration ────────

run "custom_image_volumes_and_environment_render_on_all_pods" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"

    n8n_image_repository       = "registry.internal:5000/n8n/custom"
    n8n_image_tag              = "2.35.0-custom"
    n8n_task_runner_image_tag  = "2.35.0"
    n8n_image_pull_secrets     = ["registry-creds", "registry-fallback"]
    n8n_helm_timeout           = 900
    n8n_custom_extensions_path = "/opt/n8n-nodes"
    n8n_extra_volumes = [
      {
        name = "custom-nodes"
        config_map = {
          name         = "n8n-custom-nodes"
          default_mode = "0644"
        }
      },
      {
        name = "ca-bundle"
        secret = {
          secret_name  = "internal-ca"
          default_mode = "0444"
        }
      },
      {
        name = "shared-content"
        persistent_volume_claim = {
          claim_name = "shared-content"
          read_only  = true
        }
      },
    ]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/opt/n8n-nodes" },
      { name = "ca-bundle", mount_path = "/etc/internal-ca", sub_path = "ca.pem" },
      { name = "shared-content", mount_path = "/mnt/shared", read_only = false },
    ]
    n8n_extra_env = [
      { name = "N8N_DEFAULT_LOCALE", value = "de" },
      { name = "NODE_OPTIONS", value = "--max-old-space-size=4096" },
    ]
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition = (
      local.n8n_manages_service_account &&
      local.n8n_service_account_name == "n8n-enterprise-pull" &&
      length(kubernetes_service_account_v1.n8n) == 1
    )
    error_message = "Image pull Secret names must switch the release to the module-managed, collision-free ServiceAccount."
  }

  assert {
    condition = (
      kubernetes_service_account_v1.n8n[0].metadata[0].annotations["azure.workload.identity/client-id"] == "33333333-3333-3333-3333-333333333333" &&
      toset([for secret in kubernetes_service_account_v1.n8n[0].image_pull_secret : secret.name]) == toset(var.n8n_image_pull_secrets)
    )
    error_message = "The module-managed ServiceAccount must preserve workload identity and reference every existing registry Secret by name."
  }

  assert {
    condition     = azurerm_federated_identity_credential.n8n_workload.subject == "system:serviceaccount:n8n:n8n-enterprise-pull"
    error_message = "The workload identity federated subject must follow the active module-managed ServiceAccount."
  }

  assert {
    condition = (
      helm_release.n8n.timeout == 900 &&
      yamldecode(helm_release.n8n.values[0]).image.repository == "registry.internal:5000/n8n/custom" &&
      yamldecode(helm_release.n8n.values[0]).image.tag == "2.35.0-custom" &&
      yamldecode(helm_release.n8n.values[0]).taskRunners.image.tag == "2.35.0" &&
      !yamldecode(helm_release.n8n.values[0]).serviceAccount.create &&
      yamldecode(helm_release.n8n.values[0]).serviceAccount.name == "n8n-enterprise-pull"
    )
    error_message = "Custom application and runner images, Helm timeout, and external ServiceAccount selection must render into Helm values."
  }

  assert {
    condition = (
      local.n8n_extra_volumes[0].configMap.name == "n8n-custom-nodes" &&
      local.n8n_extra_volumes[0].configMap.defaultMode == 420 &&
      local.n8n_extra_volumes[1].secret.secretName == "internal-ca" &&
      local.n8n_extra_volumes[1].secret.defaultMode == 292 &&
      local.n8n_extra_volumes[2].persistentVolumeClaim.claimName == "shared-content" &&
      local.n8n_extra_volume_mounts[1].subPath == "ca.pem"
    )
    error_message = "Typed ConfigMap, Secret, PVC, mode, and sub-path inputs must translate to chart-compatible Kubernetes values."
  }

  assert {
    condition = (
      length(yamldecode(helm_release.n8n.values[0]).extraVolumes) == 3 &&
      length(yamldecode(helm_release.n8n.values[0]).extraVolumeMounts) == 3 &&
      one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == "N8N_CUSTOM_EXTENSIONS"]) == "/opt/n8n-nodes" &&
      one([for env in yamldecode(helm_release.n8n.values[0]).config.extraEnv : env.value if env.name == "N8N_DEFAULT_LOCALE"]) == "de"
    )
    error_message = "Top-level all-pod volumes, the extension path, and safe additional environment values must render once in the shared chart contract."
  }
}

run "rejects_invalid_custom_image_and_volume_inputs" {
  command = plan

  variables {
    n8n_image_repository   = "https://registry.example.com/n8n"
    n8n_image_pull_secrets = ["registry-creds", "registry-creds"]
    n8n_helm_timeout       = 59.5
    n8n_extra_volumes = [
      {
        name       = "custom-nodes"
        config_map = { name = "custom-nodes" }
        secret     = { secret_name = "custom-nodes" }
      },
    ]
  }

  expect_failures = [
    var.n8n_image_repository,
    var.n8n_image_pull_secrets,
    var.n8n_helm_timeout,
    var.n8n_extra_volumes,
  ]
}

run "rejects_extra_mount_without_declared_volume" {
  command = plan

  variables {
    n8n_extra_volume_mounts = [
      { name = "missing-volume", mount_path = "/opt/n8n-nodes" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "rejects_multiple_custom_extension_paths" {
  command = plan

  variables {
    n8n_image_repository       = "registry.example.com/n8n"
    n8n_task_runner_image_tag  = "2.35.0"
    n8n_custom_extensions_path = "/opt/nodes;/opt/more-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "rejects_unsafe_custom_extension_path" {
  command = plan

  variables {
    n8n_image_repository       = "registry.example.com/n8n"
    n8n_task_runner_image_tag  = "2.35.0"
    n8n_custom_extensions_path = "/home/node/.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "rejects_duplicate_additional_environment_names" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_LOCALE", value = "de" },
      { name = "N8N_DEFAULT_LOCALE", value = "en" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "rejects_reserved_additional_environment_names" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_HOST", value = "override" },
      { name = "QUEUE_BULL_REDIS_HOST", value = "override" },
      { name = "N8N_ENCRYPTION_KEY", value = "override" },
      { name = "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME", value = "override" },
      { name = "AZURE_CLIENT_ID", value = "override" },
      { name = "N8N_LICENSE_ACTIVATION_KEY", value = "override" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "warns_when_custom_extensions_have_no_backing_content" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  expect_failures = [check.custom_extensions_path_requires_a_source]
}

run "warns_when_custom_image_has_no_explicit_runner_tag" {
  command = plan

  variables {
    n8n_image_repository = "registry.example.com/n8n"
  }

  expect_failures = [check.custom_image_tag_needs_a_task_runner_tag]
}

run "warns_when_runner_tag_mismatches_application_version" {
  command = plan

  variables {
    n8n_image_repository      = "registry.example.com/n8n"
    n8n_image_tag             = "2.35.0-custom"
    n8n_task_runner_image_tag = "2.34.0"
  }

  expect_failures = [check.task_runner_image_tag_matches_application_version]
}

run "warns_when_image_pull_secrets_are_inert" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["registry-creds"]
  }

  expect_failures = [check.image_pull_secrets_need_a_custom_image]
}

run "warns_when_extra_volume_is_not_mounted" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "unused-config", config_map = { name = "unused-config" } },
    ]
  }

  expect_failures = [check.extra_volumes_should_be_mounted]
}

run "warns_when_runner_tag_is_inert" {
  command = plan

  variables {
    n8n_task_runners_enabled  = false
    n8n_task_runner_image_tag = "2.35.0"
  }

  expect_failures = [check.task_runner_image_tag_requires_task_runners]
}

# ── Section 9: Binary data, execution data, and observability ────────────────

run "azure_binary_defaults_and_disabled_observability_render" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  override_resource {
    target          = azurerm_storage_account.n8n[0]
    override_during = plan
    values = {
      id                    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles"
      name                  = "n8ntestn8nfiles"
      primary_blob_endpoint = "https://n8ntestn8nfiles.blob.core.windows.net/"
    }
  }

  override_resource {
    target          = azurerm_storage_container.n8n[0]
    override_during = plan
    values = {
      id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles/blobServices/default/containers/n8n-data"
      name = "n8n-data"
    }
  }

  assert {
    condition = (
      var.n8n_binary_data_storage_mode == "azure" &&
      toset(var.n8n_available_binary_data_modes) == toset(["azure"]) &&
      var.n8n_execution_data_storage_mode == "database" &&
      local.n8n_azure_storage_enabled
    )
    error_message = "The default must write binary data to Azure, retain Azure reads, and keep execution data in PostgreSQL."
  }

  assert {
    condition = alltrue([
      for name, value in {
        N8N_DEFAULT_BINARY_DATA_MODE                = "azure"
        N8N_AVAILABLE_BINARY_DATA_MODES             = "azure"
        N8N_EXECUTION_DATA_STORAGE_MODE             = "database"
        N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME     = "n8ntestn8nfiles"
        N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME   = "n8n-data"
        N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT = "true"
      } : one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == name]) == value
    ])
    error_message = "Azure binary defaults and DefaultAzureCredential settings must render through the all-pod environment contract."
  }

  assert {
    condition = length([
      for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env
      if env.name == "N8N_METRICS" || startswith(env.name, "N8N_OTEL_") || startswith(env.name, "N8N_LOG_STREAMING_")
    ]) == 0
    error_message = "Metrics, OpenTelemetry, and log-streaming variables must be absent at their disabled defaults."
  }

  assert {
    condition = one([
      for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value
      if env.name == "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS"
    ]) == "true"
    error_message = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS must always render true now that no shared-filesystem mode exists."
  }
}

run "azure_execution_mode_is_independent_from_binary_mode" {
  command = plan

  variables {
    create_database                            = false
    postgres_external_host                     = "postgres.external.example.com"
    postgres_external_username                 = "n8n_app"
    postgres_external_password                 = "synthetic-external-postgres-password"
    create_redis                               = false
    redis_external_host                        = "redis.external.example.com"
    n8n_binary_data_storage_mode               = "database"
    n8n_available_binary_data_modes            = ["database"]
    n8n_execution_data_storage_mode            = "azure"
    azure_blob_container_stores_execution_data = true
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  override_resource {
    target          = azurerm_storage_account.n8n[0]
    override_during = plan
    values = {
      id                    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles"
      name                  = "n8ntestn8nfiles"
      primary_blob_endpoint = "https://n8ntestn8nfiles.blob.core.windows.net/"
    }
  }

  override_resource {
    target          = azurerm_storage_container.n8n[0]
    override_during = plan
    values = {
      id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles/blobServices/default/containers/n8n-data"
      name = "n8n-data"
    }
  }

  assert {
    condition = (
      one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == "N8N_DEFAULT_BINARY_DATA_MODE"]) == "database" &&
      one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == "N8N_EXECUTION_DATA_STORAGE_MODE"]) == "azure" &&
      local.n8n_azure_storage_enabled &&
      length(azurerm_storage_management_policy.n8n_binary) == 0
    )
    error_message = "Azure execution offload must work independently from the database binary backend and must suppress broad Blob expiry."
  }
}

run "connection_string_auth_takes_precedence" {
  command = plan

  variables {
    create_database              = false
    postgres_external_host       = "postgres.external.example.com"
    postgres_external_username   = "n8n_app"
    postgres_external_password   = "synthetic-external-postgres-password"
    create_redis                 = false
    redis_external_host          = "redis.external.example.com"
    azure_blob_connection_string = "DefaultEndpointsProtocol=https;AccountName=n8ntestn8nfiles;AccountKey=synthetic"
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  override_resource {
    target          = azurerm_storage_account.n8n[0]
    override_during = plan
    values = {
      id                    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles"
      name                  = "n8ntestn8nfiles"
      primary_blob_endpoint = "https://n8ntestn8nfiles.blob.core.windows.net/"
    }
  }

  override_resource {
    target          = azurerm_storage_container.n8n[0]
    override_during = plan
    values = {
      id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles/blobServices/default/containers/n8n-data"
      name = "n8n-data"
    }
  }

  assert {
    condition = (
      one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == "N8N_EXTERNAL_STORAGE_AZURE_CONNECTION_STRING"]) == "DefaultEndpointsProtocol=https;AccountName=n8ntestn8nfiles;AccountKey=synthetic" &&
      length([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env if contains([
        "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME",
        "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_KEY",
        "N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT",
      ], env.name)]) == 0
    )
    error_message = "Connection-string authentication must take precedence and omit account-name, account-key, and auto-detect variables."
  }
}

run "rejects_filesystem_binary_data_storage_mode" {
  command = plan

  variables {
    n8n_binary_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_binary_data_storage_mode]
}

run "rejects_inline_memory_binary_data_storage_mode" {
  command = plan

  variables {
    n8n_binary_data_storage_mode = "default"
  }

  expect_failures = [var.n8n_binary_data_storage_mode]
}

run "rejects_filesystem_available_binary_data_modes" {
  command = plan

  variables {
    n8n_available_binary_data_modes = ["azure", "filesystem"]
  }

  expect_failures = [var.n8n_available_binary_data_modes]
}

run "rejects_inline_memory_available_binary_data_modes" {
  command = plan

  variables {
    n8n_available_binary_data_modes = ["azure", "default"]
  }

  expect_failures = [var.n8n_available_binary_data_modes]
}

run "rejects_filesystem_execution_data_storage_mode" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

run "rejects_azure_execution_mode_without_lifecycle_guard" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "azure"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

run "database_only_modes_allow_pre_azure_n8n_version" {
  command = plan

  variables {
    n8n_binary_data_storage_mode    = "database"
    n8n_available_binary_data_modes = ["database"]
    n8n_execution_data_storage_mode = "database"
    n8n_image_tag                   = "2.28.9"
  }

  assert {
    condition     = var.n8n_image_tag == "2.28.9" && !local.n8n_azure_storage_enabled
    error_message = "The n8n 2.29 floor must apply to Azure modes rather than an unrelated database-only deployment."
  }
}

run "observability_controls_render_on_all_pods" {
  command = plan

  variables {
    create_database                    = false
    postgres_external_host             = "postgres.external.example.com"
    postgres_external_username         = "n8n_app"
    postgres_external_password         = "synthetic-external-postgres-password"
    create_redis                       = false
    redis_external_host                = "redis.external.example.com"
    n8n_metrics_enabled                = true
    n8n_otel_enabled                   = true
    n8n_otel_exporter_otlp_endpoint    = "https://otel.example.com:4318"
    n8n_otel_exporter_otlp_headers     = "authorization=Bearer synthetic-token"
    n8n_otel_exporter_service_name     = "n8n-test"
    n8n_otel_traces_sample_rate        = 0.25
    n8n_otel_traces_include_node_spans = false
    n8n_otel_traces_inject_outbound    = false
    n8n_otel_traces_production_only    = false
    n8n_log_streaming_managed_by_env   = true
    n8n_log_streaming_destinations = [
      {
        type             = "webhook"
        label            = "Audit"
        enabled          = true
        subscribedEvents = ["n8n.audit", "n8n.workflow"]
        url              = "https://logs.example.com/n8n"
        method           = "POST"
        sendHeaders      = true
        specifyHeaders   = "keypair"
        headerParameters = {
          parameters = [{ name = "Authorization", value = "Bearer synthetic-log-token" }]
        }
        circuitBreaker = { maxFailures = 5, failureWindow = 60000 }
      },
      {
        type     = "syslog"
        label    = "SIEM"
        host     = "syslog.example.com"
        port     = 6514
        protocol = "tls"
        facility = 16
      },
      {
        type  = "sentry"
        label = "Sentry"
        dsn   = "https://public@sentry.example.com/1"
      },
    ]
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  override_resource {
    target          = azurerm_storage_account.n8n[0]
    override_during = plan
    values = {
      id                    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles"
      name                  = "n8ntestn8nfiles"
      primary_blob_endpoint = "https://n8ntestn8nfiles.blob.core.windows.net/"
    }
  }

  override_resource {
    target          = azurerm_storage_container.n8n[0]
    override_during = plan
    values = {
      id   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles/blobServices/default/containers/n8n-data"
      name = "n8n-data"
    }
  }

  assert {
    condition = alltrue([
      for name, value in {
        N8N_METRICS                        = "true"
        N8N_OTEL_ENABLED                   = "true"
        N8N_OTEL_EXPORTER_OTLP_ENDPOINT    = "https://otel.example.com:4318"
        N8N_OTEL_EXPORTER_OTLP_HEADERS     = "authorization=Bearer synthetic-token"
        N8N_OTEL_EXPORTER_SERVICE_NAME     = "n8n-test"
        N8N_OTEL_TRACES_SAMPLE_RATE        = "0.25"
        N8N_OTEL_TRACES_INCLUDE_NODE_SPANS = "false"
        N8N_OTEL_TRACES_INJECT_OUTBOUND    = "false"
        N8N_OTEL_TRACES_PRODUCTION_ONLY    = "false"
        N8N_LOG_STREAMING_MANAGED_BY_ENV   = "true"
      } : one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == name]) == value
    ])
    error_message = "Metrics and every OpenTelemetry control must render through the shared all-pod environment list."
  }

  assert {
    condition = (
      issensitive(var.n8n_otel_exporter_otlp_headers) &&
      issensitive(var.n8n_log_streaming_destinations) &&
      length(nonsensitive(local.n8n_log_streaming_destinations)) == 3 &&
      !contains(keys(nonsensitive(local.n8n_log_streaming_destinations)[0]), "dsn")
    )
    error_message = "Observability credentials must remain sensitive and absent optional destination fields must be removed before JSON encoding."
  }

  assert {
    condition = (
      strcontains(one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == "N8N_LOG_STREAMING_DESTINATIONS"]), "\"type\":\"webhook\"") &&
      strcontains(one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == "N8N_LOG_STREAMING_DESTINATIONS"]), "\"type\":\"syslog\"") &&
      strcontains(one([for env in yamldecode(nonsensitive(helm_release.n8n.values[0])).config.extraEnv : env.value if env.name == "N8N_LOG_STREAMING_DESTINATIONS"]), "\"type\":\"sentry\"")
    )
    error_message = "Typed webhook, syslog, and Sentry destinations must be JSON encoded into N8N_LOG_STREAMING_DESTINATIONS."
  }
}

run "rejects_invalid_observability_inputs" {
  command = plan

  variables {
    n8n_otel_exporter_otlp_endpoint = "grpc://otel.example.com"
    n8n_otel_exporter_otlp_headers  = ""
    n8n_otel_exporter_service_name  = ""
    n8n_otel_traces_sample_rate     = 1.5
    n8n_log_streaming_destinations = [
      { type = "webhook" },
      { type = "syslog", host = "syslog.example.com", port = 70000 },
    ]
  }

  expect_failures = [
    var.n8n_otel_exporter_otlp_endpoint,
    var.n8n_otel_exporter_otlp_headers,
    var.n8n_otel_exporter_service_name,
    var.n8n_otel_traces_sample_rate,
    var.n8n_log_streaming_destinations,
  ]
}

run "warns_when_otel_tuning_is_disabled" {
  command = plan

  variables {
    n8n_otel_exporter_otlp_endpoint = "https://otel.example.com:4318"
  }

  expect_failures = [check.otel_tuning_requires_master_switch]
}

run "warns_when_log_streaming_destinations_are_ui_managed" {
  command = plan

  variables {
    n8n_log_streaming_destinations = [
      { type = "sentry", dsn = "https://public@sentry.example.com/1" },
    ]
  }

  expect_failures = [check.log_streaming_destinations_require_managed_by_env]
}

run "rejects_storage_and_observability_environment_overrides" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" },
      { name = "N8N_AVAILABLE_BINARY_DATA_MODES", value = "filesystem" },
      { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = "filesystem" },
      { name = "N8N_METRICS", value = "true" },
      { name = "N8N_OTEL_ENABLED", value = "true" },
      { name = "N8N_LOG_STREAMING_MANAGED_BY_ENV", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── Section 10: Workload autoscaling and capacity checks ────────────────────

run "workload_autoscalers_and_replica_floors_render" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition = (
      var.n8n_main_hpa_min_replicas == 2 &&
      var.n8n_main_hpa_max_replicas == 6 &&
      var.n8n_main_hpa_cpu_threshold == 60 &&
      var.n8n_webhook_hpa_min_replicas == 2 &&
      var.n8n_webhook_hpa_max_replicas == 8 &&
      var.n8n_webhook_hpa_cpu_threshold == 65 &&
      var.n8n_worker_keda_min_replicas == 1 &&
      var.n8n_worker_keda_max_replicas == 10 &&
      var.n8n_worker_keda_jobs_per_replica == 5
    )
    error_message = "Main, webhook, and worker autoscaler defaults must match the AWS sibling."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).hpa.main.enabled &&
      yamldecode(helm_release.n8n.values[0]).hpa.main.minReplicas == 2 &&
      yamldecode(helm_release.n8n.values[0]).hpa.main.maxReplicas == 6 &&
      yamldecode(helm_release.n8n.values[0]).hpa.main.targetCPUUtilizationPercentage == 60
    )
    error_message = "The chart-managed main HPA must use the configured floor, ceiling, and CPU target."
  }

  assert {
    condition = (
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].scale_target_ref[0].name == "n8n-webhook-processor" &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].min_replicas == 2 &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].max_replicas == 8 &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].metric[0].resource[0].target[0].average_utilization == 65
    )
    error_message = "The module-managed webhook HPA must target only the webhook Deployment with the configured scaling bounds."
  }

  assert {
    condition = (
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 0 &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].select_policy == "Max" &&
      length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].policy) == 2
    )
    error_message = "The webhook HPA must preserve immediate default scale-up and Kubernetes' default scale-up policies."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).multiMain.replicas == 2 &&
      yamldecode(helm_release.n8n.values[0]).queueMode.workerReplicaCount == 1 &&
      yamldecode(helm_release.n8n.values[0]).webhookProcessor.replicaCount == 2
    )
    error_message = "Every Helm deployment replica count must equal its matching autoscaler floor."
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).keda.worker.minReplicaCount == 1 &&
      yamldecode(helm_release.n8n.values[0]).keda.worker.maxReplicaCount == 10 &&
      length(yamldecode(helm_release.n8n.values[0]).keda.worker.triggers) == 2 &&
      toset([for trigger in yamldecode(helm_release.n8n.values[0]).keda.worker.triggers : trigger.metadata.listName]) == toset(["bull:jobs:wait", "bull:jobs:active"]) &&
      alltrue([for trigger in yamldecode(helm_release.n8n.values[0]).keda.worker.triggers : trigger.metadata.listLength == "5"])
    )
    error_message = "Worker KEDA must own only the worker Deployment and scale from both queue lists using the configured jobs-per-replica target."
  }
}

run "raised_autoscaler_floors_drive_helm_replica_counts" {
  command = plan

  variables {
    create_database                                       = false
    postgres_external_host                                = "postgres.external.example.com"
    postgres_external_username                            = "n8n_app"
    postgres_external_password                            = "synthetic-external-postgres-password"
    create_redis                                          = false
    redis_external_host                                   = "redis.external.example.com"
    n8n_main_hpa_min_replicas                             = 3
    n8n_webhook_hpa_min_replicas                          = 4
    n8n_worker_keda_min_replicas                          = 5
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 300
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.n8n.values[0]).multiMain.replicas == 3 &&
      yamldecode(helm_release.n8n.values[0]).queueMode.workerReplicaCount == 5 &&
      yamldecode(helm_release.n8n.values[0]).webhookProcessor.replicaCount == 4 &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].min_replicas == 4 &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 300
    )
    error_message = "Raised floors and the webhook stabilization window must reach both Helm and the module-owned HPA."
  }
}

run "rejects_inverted_main_autoscaler_range" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 8
    n8n_main_hpa_max_replicas = 6
  }

  expect_failures = [var.n8n_main_hpa_min_replicas]
}

run "rejects_inverted_webhook_autoscaler_range" {
  command = plan

  variables {
    n8n_webhook_hpa_min_replicas = 10
    n8n_webhook_hpa_max_replicas = 8
  }

  expect_failures = [var.n8n_webhook_hpa_min_replicas]
}

run "rejects_inverted_worker_autoscaler_range" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 20
    n8n_worker_keda_max_replicas = 10
  }

  expect_failures = [var.n8n_worker_keda_min_replicas]
}

run "rejects_invalid_autoscaler_tuning_values" {
  command = plan

  variables {
    n8n_main_hpa_cpu_threshold                            = 0
    n8n_webhook_hpa_cpu_threshold                         = 101
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 3601
    n8n_worker_keda_jobs_per_replica                      = 0
  }

  expect_failures = [
    var.n8n_main_hpa_cpu_threshold,
    var.n8n_webhook_hpa_cpu_threshold,
    var.n8n_webhook_hpa_scale_up_stabilization_window_seconds,
    var.n8n_worker_keda_jobs_per_replica,
  ]
}

run "rejects_fractional_autoscaler_counts" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas    = 2.5
    n8n_webhook_hpa_max_replicas = 8.5
    n8n_worker_keda_max_replicas = 10.5
  }

  expect_failures = [
    var.n8n_main_hpa_min_replicas,
    var.n8n_webhook_hpa_max_replicas,
    var.n8n_worker_keda_max_replicas,
  ]
}

run "known_sku_warns_when_autoscaler_maxima_exceed_capacity" {
  command = plan

  variables {
    n8n_main_hpa_max_replicas = 100
  }

  expect_failures = [check.autoscaling_maxima_fit_aks_capacity]

  assert {
    condition = (
      local.aks_node_vcpus == 4 &&
      local.aks_modeled_node_count == 12 &&
      local.n8n_peak_cpu_request_millis > local.n8n_schedulable_cpu_millis
    )
    error_message = "The default Standard_D4s_v4 map and both AKS pool ceilings must drive an objective over-capacity warning."
  }
}

run "known_larger_sku_capacity_fit_stays_clean" {
  command = plan

  variables {
    aks_node_vm_size             = "Standard_D8s_v4"
    aks_node_count_max           = 2
    n8n_main_hpa_max_replicas    = 10
    n8n_webhook_hpa_max_replicas = 20
    n8n_worker_keda_max_replicas = 15
  }

  assert {
    condition = (
      local.aks_node_vcpus == 8 &&
      local.aks_modeled_node_count == 4 &&
      local.n8n_peak_cpu_request_millis <= local.n8n_schedulable_cpu_millis
    )
    error_message = "A known 8-vCPU SKU with internally consistent maxima must fit without a capacity warning."
  }
}

run "unknown_vm_sku_silences_advisory_capacity_check" {
  command = plan

  variables {
    aks_node_vm_size          = "Standard_CustomMonster_v1"
    n8n_main_hpa_max_replicas = 200
  }

  assert {
    condition = (
      local.aks_node_vcpus_derived == null &&
      !local.n8n_capacity_model_readable &&
      kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].max_replicas == 8
    )
    error_message = "A syntactically valid VM SKU outside the reviewed map must suppress only the advisory check and leave the plan intact."
  }
}

# ── Section 11: Default Application Gateway ingress ─────────────────────────

run "public_application_gateway_ingress_renders_by_default" {
  command = plan

  assert {
    condition = (
      length(azurerm_application_gateway.n8n) == 1 &&
      length(azurerm_public_ip.appgw) == 1 &&
      length(azurerm_user_assigned_identity.appgw_tls_cert) == 1 &&
      length(azurerm_user_assigned_identity.agic) == 1 &&
      length(azurerm_kubernetes_cluster.n8n[0].ingress_application_gateway) == 1 &&
      length(kubernetes_ingress_v1.n8n) == 1
    )
    error_message = "Managed ingress defaults must create the public gateway, identities, AKS AGIC addon, and Kubernetes Ingress."
  }

  assert {
    condition = (
      azurerm_public_ip.appgw[0].allocation_method == "Static" &&
      azurerm_public_ip.appgw[0].sku == "Standard" &&
      length(azurerm_application_gateway.n8n[0].frontend_ip_configuration) == 1
    )
    error_message = "Public mode must use one static Standard public IP as the only Application Gateway frontend."
  }

  assert {
    condition = (
      azurerm_application_gateway.n8n[0].sku[0].name == "WAF_v2" &&
      azurerm_application_gateway.n8n[0].sku[0].capacity == 2 &&
      length(azurerm_application_gateway.n8n[0].autoscale_configuration) == 0 &&
      azurerm_application_gateway.n8n[0].ssl_policy[0].policy_name == "AppGwSslPolicy20220101S" &&
      one([for listener in azurerm_application_gateway.n8n[0].http_listener : listener.protocol if listener.name == "default-listener"]) == "Https"
    )
    error_message = "The default gateway must use fixed two-instance WAF_v2 capacity and the explicit modern TLS policy."
  }

  assert {
    condition = (
      length(azurerm_web_application_firewall_policy.appgw) == 1 &&
      azurerm_web_application_firewall_policy.appgw[0].policy_settings[0].mode == "Detection" &&
      azurerm_web_application_firewall_policy.appgw[0].managed_rules[0].managed_rule_set[0].version == "3.2"
    )
    error_message = "WAF_v2 must create an OWASP 3.2 policy in Detection mode by default."
  }

  assert {
    condition = (
      azurerm_network_security_group.appgw[0].name == local.appgw_nsg_name &&
      azurerm_subnet_network_security_group_association.appgw[0].subnet_id == var.appgw_subnet_id &&
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.source_address_prefix if rule.name == "AllowN8nFrontend"]) == "Internet"
    )
    error_message = "The gateway subnet NSG must allow public frontend traffic by default and attach to appgw_subnet_id."
  }

  assert {
    condition = (
      azurerm_role_assignment.agic_addon_appgw_contributor[0].role_definition_name == "Contributor" &&
      azurerm_role_assignment.agic_addon_appgw_tls_uami_operator[0].role_definition_name == "Managed Identity Operator" &&
      azurerm_role_assignment.agic_addon_appgw_subnet_network_contributor[0].role_definition_name == "Network Contributor" &&
      azurerm_role_assignment.agic_addon_rg_reader[0].role_definition_name == "Reader"
    )
    error_message = "The AGIC addon identity must receive its gateway, TLS identity, subnet, and resource-group permissions."
  }

  assert {
    condition = (
      kubernetes_ingress_v1.n8n[0].metadata[0].annotations["appgw.ingress.kubernetes.io/ssl-redirect"] == "true" &&
      kubernetes_ingress_v1.n8n[0].metadata[0].annotations["appgw.ingress.kubernetes.io/cookie-based-affinity"] == "true" &&
      !contains(keys(kubernetes_ingress_v1.n8n[0].metadata[0].annotations), "appgw.ingress.kubernetes.io/use-private-ip")
    )
    error_message = "The public AGIC Ingress must preserve TLS redirect, main-session affinity, and public frontend selection."
  }
}

run "internal_application_gateway_omits_public_frontend" {
  command = plan

  variables {
    appgw_frontend_mode = "internal"
  }

  assert {
    condition     = length(azurerm_public_ip.appgw) == 0
    error_message = "Internal mode must create no public IP resource."
  }

  assert {
    condition = (
      azurerm_application_gateway.n8n[0].frontend_ip_configuration[0].private_ip_address_allocation == "Dynamic" &&
      azurerm_application_gateway.n8n[0].frontend_ip_configuration[0].subnet_id == var.appgw_subnet_id &&
      azurerm_application_gateway.n8n[0].frontend_ip_configuration[0].public_ip_address_id == null
    )
    error_message = "Internal mode must use one dynamically allocated private frontend in appgw_subnet_id."
  }

  assert {
    condition = (
      kubernetes_ingress_v1.n8n[0].metadata[0].annotations["appgw.ingress.kubernetes.io/use-private-ip"] == "true" &&
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.source_address_prefix if rule.name == "AllowN8nFrontend"]) == "VirtualNetwork"
    )
    error_message = "Internal mode must direct AGIC to the private frontend and allow routable VNet sources when no CIDR restriction is set."
  }

  assert {
    condition     = output.appgw_public_ip_address == null && output.appgw_fqdn == null
    error_message = "Public ingress outputs must be null in internal mode."
  }
}

run "disabled_ingress_creates_no_gateway_or_controller_resources" {
  command = plan

  variables {
    create_ingress = false
  }

  assert {
    condition = (
      length(azurerm_application_gateway.n8n) == 0 &&
      length(azurerm_public_ip.appgw) == 0 &&
      length(azurerm_network_security_group.appgw) == 0 &&
      length(azurerm_subnet_network_security_group_association.appgw) == 0 &&
      length(azurerm_web_application_firewall_policy.appgw) == 0 &&
      length(azurerm_user_assigned_identity.appgw_tls_cert) == 0 &&
      length(azurerm_user_assigned_identity.agic) == 0 &&
      length(azurerm_kubernetes_cluster.n8n[0].ingress_application_gateway) == 0 &&
      length(kubernetes_ingress_v1.n8n) == 0
    )
    error_message = "create_ingress = false must omit Application Gateway, public IP, NSG, identities, AGIC integration, and Ingress."
  }

  assert {
    condition = (
      output.app_gateway_id == null &&
      output.appgw_public_ip_address == null &&
      output.appgw_private_ip_address == null &&
      output.appgw_fqdn == null &&
      output.n8n_service_name == "n8n-main" &&
      output.n8n_webhook_service_name == "n8n-webhook-processor" &&
      output.n8n_service_port == 5678
    )
    error_message = "Disabled ingress must return null gateway outputs while preserving caller-owned routing service metadata."
  }
}

run "application_gateway_autoscaling_waf_and_annotations_render" {
  command = plan

  variables {
    appgw_autoscaling_enabled    = true
    appgw_autoscale_min_capacity = 3
    appgw_autoscale_max_capacity = 20
    appgw_waf_mode               = "Prevention"
    ingress_annotations = {
      "appgw.ingress.kubernetes.io/rewrite-rule-set" = "n8n-rewrites"
    }
  }

  assert {
    condition = (
      azurerm_application_gateway.n8n[0].autoscale_configuration[0].min_capacity == 3 &&
      azurerm_application_gateway.n8n[0].autoscale_configuration[0].max_capacity == 20
    )
    error_message = "Autoscaling mode must render the configured minimum and maximum capacity."
  }

  assert {
    condition     = azurerm_web_application_firewall_policy.appgw[0].policy_settings[0].mode == "Prevention"
    error_message = "The module-managed WAF policy must honor Prevention mode."
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["appgw.ingress.kubernetes.io/rewrite-rule-set"] == "n8n-rewrites"
    error_message = "Caller AGIC annotations must merge over module defaults."
  }
}

run "caller_managed_waf_policy_is_attached_without_duplicate_policy" {
  command = plan

  variables {
    appgw_waf_policy_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/shared-waf"
  }

  assert {
    condition = (
      length(azurerm_web_application_firewall_policy.appgw) == 0 &&
      azurerm_application_gateway.n8n[0].firewall_policy_id == var.appgw_waf_policy_id
    )
    error_message = "A caller-managed WAF policy ID must attach directly without creating a competing module policy."
  }
}

run "source_restricted_gateway_preserves_azure_control_traffic" {
  command = plan

  variables {
    appgw_allowed_inbound_cidrs = ["203.0.113.0/24", "198.51.100.7/32"]
  }

  assert {
    condition = (
      toset(one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.source_address_prefixes if rule.name == "AllowN8nFrontend"])) == toset(var.appgw_allowed_inbound_cidrs) &&
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.destination_port_ranges if rule.name == "AllowN8nFrontend"]) == toset(["80", "443"])
    )
    error_message = "Frontend NSG access must be limited to the configured IPv4 CIDRs on ports 80 and 443."
  }

  assert {
    condition = (
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.destination_port_range if rule.name == "AllowGatewayManager"]) == "65200-65535" &&
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.source_address_prefix if rule.name == "AllowGatewayManager"]) == "GatewayManager" &&
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.source_address_prefix if rule.name == "AllowAzureLoadBalancer"]) == "AzureLoadBalancer" &&
      one([for rule in azurerm_network_security_group.appgw[0].security_rule : rule.access if rule.name == "DenyOtherInbound"]) == "Deny"
    )
    error_message = "Source restrictions must preserve GatewayManager and AzureLoadBalancer traffic before denying all other inbound connections."
  }
}

run "every_ingress_host_routes_all_webhook_prefixes_before_main" {
  command = plan

  variables {
    n8n_additional_domains = ["AUTOMATION.EXAMPLE.COM", "hooks.example.net"]
  }

  assert {
    condition     = tolist(local.n8n_ingress_domains) == tolist(["n8n.example.com", "automation.example.com", "hooks.example.net"])
    error_message = "Ingress domains must keep the canonical host first and normalize additional domains to lowercase."
  }

  assert {
    condition = alltrue([
      for rule in kubernetes_ingress_v1.n8n[0].spec[0].rule :
      [for path in rule.http[0].path : path.path] == concat(local.n8n_webhook_path_prefixes, ["/"])
    ])
    error_message = "Every host must declare all five webhook prefixes before the main-service catch-all."
  }

  assert {
    condition = alltrue(flatten([
      for rule in kubernetes_ingress_v1.n8n[0].spec[0].rule : [
        for path in slice(rule.http[0].path, 0, length(local.n8n_webhook_path_prefixes)) :
        path.backend[0].service[0].name == "n8n-webhook-processor" && path.backend[0].service[0].port[0].number == 5678
      ]
    ]))
    error_message = "Every webhook prefix on every host must target the webhook-processor Service on port 5678."
  }

  assert {
    condition = alltrue([
      for rule in kubernetes_ingress_v1.n8n[0].spec[0].rule :
      rule.http[0].path[length(local.n8n_webhook_path_prefixes)].backend[0].service[0].name == "n8n-main"
    ])
    error_message = "The final catch-all path on every host must target the main Service."
  }
}

run "warns_when_ingress_annotations_override_module_controls" {
  command = plan

  variables {
    ingress_annotations = {
      "appgw.ingress.kubernetes.io/request-timeout" = "60"
    }
  }

  expect_failures = [check.ingress_annotations_override_module_controls]
}

run "warns_when_ingress_tuning_is_inert" {
  command = plan

  variables {
    create_ingress      = false
    appgw_frontend_mode = "internal"
  }

  expect_failures = [check.ingress_tuning_requires_module_managed_ingress]
}

run "rejects_invalid_application_gateway_inputs" {
  command = plan

  variables {
    appgw_frontend_mode          = "private"
    appgw_sku_name               = "Basic"
    appgw_capacity               = 0
    appgw_autoscale_min_capacity = 20
    appgw_autoscale_max_capacity = 10
    appgw_ssl_policy             = "latest"
    appgw_waf_mode               = "Block"
    appgw_allowed_inbound_cidrs  = ["2001:db8::/64"]
    ingress_annotations          = { "" = "" }
    n8n_additional_domains       = ["duplicate.example.com", "DUPLICATE.EXAMPLE.COM"]
  }

  expect_failures = [
    var.appgw_frontend_mode,
    var.appgw_sku_name,
    var.appgw_capacity,
    var.appgw_autoscale_min_capacity,
    var.appgw_ssl_policy,
    var.appgw_waf_mode,
    var.appgw_allowed_inbound_cidrs,
    var.ingress_annotations,
    var.n8n_additional_domains,
  ]
}

run "rejects_malformed_application_gateway_waf_policy_id" {
  command = plan

  variables {
    appgw_waf_policy_id = "not-a-policy-id"
  }

  expect_failures = [var.appgw_waf_policy_id]
}

# ── Section 12: DNS and certificate integration ─────────────────────────────

run "public_azure_dns_routes_every_normalized_domain" {
  command = plan

  variables {
    create_public_dns_record = true
    public_dns_zone_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/dnsZones/example.com"
    n8n_additional_domains   = ["AUTOMATION.EXAMPLE.COM", "hooks.example.com"]
  }

  override_resource {
    target          = azurerm_public_ip.appgw[0]
    override_during = plan
    values = {
      ip_address = "203.0.113.10"
    }
  }

  assert {
    condition = (
      local.public_dns_records_managed &&
      !local.private_dns_records_managed &&
      toset(keys(azurerm_dns_a_record.n8n)) == toset(["n8n.example.com", "automation.example.com", "hooks.example.com"])
    )
    error_message = "The public Azure DNS path must create one record for every normalized managed-ingress host."
  }

  assert {
    condition = alltrue([
      for domain, record in azurerm_dns_a_record.n8n :
      record.zone_name == "example.com" &&
      record.resource_group_name == "n8ntest-dns-rg" &&
      record.name == trimsuffix(domain, ".example.com") &&
      record.records == toset(["203.0.113.10"])
    ])
    error_message = "Every public DNS record must use the caller-owned zone and target the managed Application Gateway public IP."
  }
}

run "private_azure_dns_routes_internal_frontend" {
  command = plan

  variables {
    appgw_frontend_mode       = "internal"
    create_private_dns_record = true
    private_dns_zone_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/privateDnsZones/internal.example.com"
    n8n_domain                = "n8n.internal.example.com"
    n8n_additional_domains    = ["hooks.internal.example.com"]
  }

  override_resource {
    target          = azurerm_application_gateway.n8n[0]
    override_during = plan
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGateways/n8ntest-appgw"
      frontend_ip_configuration = {
        private_ip_address = "10.0.4.10"
      }
    }
  }

  assert {
    condition = (
      local.private_dns_records_managed &&
      !local.public_dns_records_managed &&
      toset(keys(azurerm_private_dns_a_record.n8n)) == toset(["n8n.internal.example.com", "hooks.internal.example.com"])
    )
    error_message = "The private Azure DNS path must create one record for every internal managed-ingress host."
  }

  assert {
    condition = alltrue([
      for domain, record in azurerm_private_dns_a_record.n8n :
      record.zone_name == "internal.example.com" &&
      record.resource_group_name == "n8ntest-dns-rg" &&
      record.name == trimsuffix(domain, ".internal.example.com") &&
      record.records == toset(["10.0.4.10"])
    ])
    error_message = "Every private DNS record must use the caller-owned private zone and target the internal Application Gateway frontend."
  }
}

run "application_gateway_certificate_role_uses_minimum_scope" {
  command = plan

  variables {
    app_gateway_keyvault_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-shared-rg/providers/Microsoft.KeyVault/vaults/n8ntest-shared-kv"
    app_gateway_keyvault_role_assignment_enabled = true
  }

  override_resource {
    target          = azurerm_user_assigned_identity.appgw_tls_cert[0]
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-appgw-tls"
      client_id    = "55555555-5555-5555-5555-555555555555"
      principal_id = "66666666-6666-6666-6666-666666666666"
    }
  }

  assert {
    condition = (
      length(azurerm_role_assignment.appgw_kv_secrets_user) == 1 &&
      azurerm_role_assignment.appgw_kv_secrets_user[0].scope == var.app_gateway_keyvault_id &&
      azurerm_role_assignment.appgw_kv_secrets_user[0].role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.appgw_kv_secrets_user[0].principal_id == "66666666-6666-6666-6666-666666666666"
    )
    error_message = "The App Gateway TLS identity must receive only Key Vault Secrets User at the supplied vault scope."
  }

  assert {
    condition = (
      length(time_sleep.appgw_kv_secrets_user_rbac_propagation) == 1 &&
      time_sleep.appgw_kv_secrets_user_rbac_propagation[0].create_duration == "120s" &&
      one([for cert in azurerm_application_gateway.n8n[0].ssl_certificate : cert.key_vault_secret_id if cert.name == "appgw-ssl-cert"]) == var.app_gateway_tls_cert_secret_id
    )
    error_message = "The gateway must preserve the caller-supplied certificate Secret URI and the Key Vault RBAC propagation gate."
  }
}

run "caller_owned_ingress_omits_dns_and_certificate_roles" {
  command = plan

  variables {
    create_ingress                               = false
    create_public_dns_record                     = true
    public_dns_zone_id                           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/dnsZones/example.com"
    app_gateway_keyvault_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-shared-rg/providers/Microsoft.KeyVault/vaults/n8ntest-shared-kv"
    app_gateway_keyvault_role_assignment_enabled = true
  }

  expect_failures = [
    check.dns_requires_module_managed_ingress,
    check.keyvault_role_assignment_requires_module_managed_ingress,
  ]

  assert {
    condition = (
      length(azurerm_dns_a_record.n8n) == 0 &&
      length(azurerm_private_dns_a_record.n8n) == 0 &&
      length(azurerm_role_assignment.appgw_kv_secrets_user) == 0 &&
      length(time_sleep.appgw_kv_secrets_user_rbac_propagation) == 0
    )
    error_message = "Caller-owned ingress must create no application DNS records or module-gateway certificate role assignments."
  }
}

run "rejects_dns_zone_and_frontend_mismatches" {
  command = plan

  variables {
    appgw_frontend_mode      = "internal"
    create_public_dns_record = true
    public_dns_zone_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/dnsZones/example.com"
  }

  expect_failures = [var.public_dns_zone_id]
}

run "rejects_both_public_and_private_dns_zones" {
  command = plan

  variables {
    create_public_dns_record  = true
    create_private_dns_record = true
    public_dns_zone_id        = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/dnsZones/example.com"
    private_dns_zone_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/privateDnsZones/example.com"
  }

  expect_failures = [
    var.create_public_dns_record,
    var.private_dns_zone_id,
  ]
}

run "rejects_domain_outside_selected_dns_zone" {
  command = plan

  variables {
    create_public_dns_record = true
    public_dns_zone_id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/dnsZones/example.com"
    n8n_additional_domains   = ["hooks.other.example.net"]
  }

  expect_failures = [var.public_dns_zone_id]
}

run "rejects_public_dns_toggle_without_zone_id" {
  command = plan

  variables {
    create_public_dns_record = true
  }

  expect_failures = [var.public_dns_zone_id]
}

run "rejects_public_dns_zone_id_without_toggle" {
  command = plan

  variables {
    public_dns_zone_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-dns-rg/providers/Microsoft.Network/dnsZones/example.com"
  }

  expect_failures = [var.public_dns_zone_id]
}

run "rejects_malformed_public_dns_zone_id" {
  command = plan

  variables {
    create_public_dns_record = true
    public_dns_zone_id       = "not-a-public-zone-id"
  }

  expect_failures = [var.public_dns_zone_id]
}

run "rejects_malformed_private_dns_zone_id" {
  command = plan

  variables {
    appgw_frontend_mode       = "internal"
    create_private_dns_record = true
    private_dns_zone_id       = "not-a-private-zone-id"
  }

  expect_failures = [var.private_dns_zone_id]
}

run "rejects_malformed_canonical_host" {
  command = plan

  variables {
    n8n_domain = "bad..example.com"
  }

  expect_failures = [var.n8n_domain]
}

run "rejects_malformed_additional_host" {
  command = plan

  variables {
    n8n_additional_domains = ["-hooks.example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

# ── Section 1 (add-customer-managed-modularity): ownership contracts ───────
# Every new create_*/install_* switch defaults to module ownership, every
# existing-resource reference is required only when its switch is false,
# every credential source pair is mutually exclusive, and every ignored
# reference on the module-managed path warns without failing the plan.

run "customer_managed_ownership_switches_default_to_module_managed" {
  command = plan

  assert {
    condition     = var.create_aks == true
    error_message = "create_aks must default to true."
  }

  assert {
    condition     = var.create_blob_storage == true
    error_message = "create_blob_storage must default to true."
  }

  assert {
    condition     = var.create_namespace == true
    error_message = "create_namespace must default to true."
  }

  assert {
    condition     = var.install_keda == true
    error_message = "install_keda must default to true."
  }

  assert {
    condition     = var.n8n_webhook_hpa_enabled == true
    error_message = "n8n_webhook_hpa_enabled must default to true."
  }

  assert {
    condition     = var.n8n_namespace == "n8n"
    error_message = "n8n_namespace must default to 'n8n'."
  }

  assert {
    condition     = var.keda_namespace == "keda"
    error_message = "keda_namespace must default to 'keda'."
  }

  assert {
    condition     = var.keda_chart_repository == "https://kedacore.github.io/charts"
    error_message = "keda_chart_repository must default to the public kedacore charts repository."
  }

  assert {
    condition     = local.effective_aks_cluster_name == azurerm_kubernetes_cluster.n8n[0].name
    error_message = "local.effective_aks_cluster_name must resolve to the module-managed cluster name by default."
  }

  assert {
    condition     = local.effective_blob_container_name == azurerm_storage_container.n8n[0].name
    error_message = "local.effective_blob_container_name must resolve to the module-managed container name by default."
  }

  assert {
    condition     = local.n8n_license_key_uses_secret_ref == false
    error_message = "local.n8n_license_key_uses_secret_ref must be false when n8n_license_key_secret_ref is not set."
  }

  assert {
    condition     = local.n8n_encryption_key_uses_secret_ref == false
    error_message = "local.n8n_encryption_key_uses_secret_ref must be false when n8n_encryption_key_secret_ref is not set."
  }
}

run "rejects_malformed_n8n_namespace" {
  command = plan

  variables {
    n8n_namespace = "Not_Valid"
  }

  expect_failures = [var.n8n_namespace]
}

run "rejects_malformed_keda_namespace" {
  command = plan

  variables {
    keda_namespace = "Not_Valid"
  }

  expect_failures = [var.keda_namespace]
}

run "rejects_malformed_keda_chart_repository" {
  command = plan

  variables {
    keda_chart_repository = "not-a-url"
  }

  expect_failures = [var.keda_chart_repository]
}

# ── Existing AKS contract ───────────────────────────────────────────────────

run "rejects_existing_aks_missing_cluster_name" {
  command = plan

  variables {
    create_aks                                   = false
    create_ingress                               = false
    existing_aks_resource_group_name             = "shared-aks-rg"
    existing_aks_cluster_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_aks_cluster_name]
}

run "rejects_existing_aks_missing_resource_group_name" {
  command = plan

  variables {
    create_aks                                   = false
    create_ingress                               = false
    existing_aks_cluster_name                    = "shared-aks"
    existing_aks_cluster_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_aks_resource_group_name]
}

run "rejects_existing_aks_unconfirmed_prerequisites" {
  command = plan

  variables {
    create_aks                       = false
    create_ingress                   = false
    existing_aks_cluster_name        = "shared-aks"
    existing_aks_resource_group_name = "shared-aks-rg"
  }

  expect_failures = [var.existing_aks_cluster_prerequisites_confirmed]
}

run "warns_when_existing_aks_reference_is_ignored" {
  command = plan

  variables {
    existing_aks_cluster_name = "shared-aks"
  }

  expect_failures = [check.existing_aks_reference_ignored_when_module_managed]
}

run "existing_aks_plan_creates_no_managed_resources" {
  command = plan

  variables {
    create_aks                                   = false
    create_ingress                               = false
    existing_aks_cluster_name                    = "shared-aks"
    existing_aks_resource_group_name             = "shared-aks-rg"
    existing_aks_cluster_prerequisites_confirmed = true
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.n8n) == 0
    error_message = "No azurerm_kubernetes_cluster.n8n instance must be created when create_aks = false."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.n8n_user) == 0
    error_message = "No azurerm_kubernetes_cluster_node_pool.n8n_user instance must be created when create_aks = false."
  }

  assert {
    condition     = length(time_sleep.aks_api_warmup) == 0
    error_message = "No time_sleep.aks_api_warmup instance must be created when create_aks = false; the existing cluster's API is assumed already warm."
  }

  assert {
    condition     = length(data.azurerm_kubernetes_cluster.existing) == 1
    error_message = "data.azurerm_kubernetes_cluster.existing must be read exactly once when create_aks = false."
  }

  assert {
    condition     = local.effective_aks_cluster_name == var.existing_aks_cluster_name
    error_message = "local.effective_aks_cluster_name must resolve to the supplied existing_aks_cluster_name when create_aks = false."
  }

  assert {
    condition     = local.effective_aks_resource_group_name == var.existing_aks_resource_group_name
    error_message = "local.effective_aks_resource_group_name must resolve to the supplied existing_aks_resource_group_name when create_aks = false."
  }

  assert {
    condition     = local.effective_aks_oidc_issuer_url == data.azurerm_kubernetes_cluster.existing[0].oidc_issuer_url
    error_message = "local.effective_aks_oidc_issuer_url must resolve to the existing cluster data source's oidc_issuer_url when create_aks = false."
  }

  assert {
    condition     = azurerm_federated_identity_credential.n8n_workload.issuer == local.effective_aks_oidc_issuer_url
    error_message = "The n8n workload federated identity credential must use the effective AKS OIDC issuer URL regardless of create_aks."
  }

  assert {
    condition     = local.n8n_capacity_model_readable == false
    error_message = "The advisory AKS capacity model must stay silent (unreadable) when create_aks = false; the existing cluster's capacity is caller-owned."
  }
}

run "rejects_managed_ingress_on_existing_aks" {
  command = plan

  variables {
    create_aks                                   = false
    existing_aks_cluster_name                    = "shared-aks"
    existing_aks_resource_group_name             = "shared-aks-rg"
    existing_aks_cluster_prerequisites_confirmed = true
  }

  expect_failures = [var.create_ingress]
}

run "warns_when_aks_tuning_is_inert_on_existing_cluster" {
  command = plan

  variables {
    create_aks                                   = false
    create_ingress                               = false
    existing_aks_cluster_name                    = "shared-aks"
    existing_aks_resource_group_name             = "shared-aks-rg"
    existing_aks_cluster_prerequisites_confirmed = true
    aks_node_vm_size                             = "Standard_D8s_v4"
  }

  expect_failures = [check.aks_tuning_requires_module_managed_aks]
}

# ── Customer-managed Blob contract ──────────────────────────────────────────

run "rejects_existing_blob_missing_account_name" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_storage_account_name]
}

run "rejects_existing_blob_missing_container_name" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_container_name]
}

run "rejects_existing_blob_missing_container_id" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_container_id]
}

run "rejects_malformed_existing_blob_container_id" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "not-a-container-id"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_container_id]
}

run "rejects_existing_blob_container_id_for_different_account" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/othern8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_container_id]
}

run "rejects_existing_blob_container_id_for_different_container" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/other-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_container_id]
}

run "rejects_existing_blob_missing_endpoint" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_prerequisites_confirmed = true
  }

  expect_failures = [var.existing_blob_endpoint]
}

run "rejects_existing_blob_unconfirmed_prerequisites" {
  command = plan

  variables {
    create_blob_storage                = false
    existing_blob_storage_account_name = "sharedn8nfiles"
    existing_blob_container_name       = "n8n-data"
    existing_blob_container_id         = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint             = "https://sharedn8nfiles.blob.core.windows.net/"
  }

  expect_failures = [var.existing_blob_prerequisites_confirmed]
}

run "warns_when_existing_blob_reference_is_ignored" {
  command = plan

  variables {
    existing_blob_storage_account_name = "sharedn8nfiles"
  }

  expect_failures = [check.existing_blob_reference_ignored_when_module_managed]
}

run "accepts_full_customer_managed_blob_contract" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  assert {
    condition     = local.effective_blob_storage_account_name == "sharedn8nfiles"
    error_message = "local.effective_blob_storage_account_name must use the caller-supplied account name when create_blob_storage is false."
  }

  assert {
    condition     = local.effective_blob_container_id == var.existing_blob_container_id
    error_message = "local.effective_blob_container_id must use the caller-supplied container ID when create_blob_storage is false."
  }
}

run "existing_blob_plan_creates_no_managed_resources" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
  }

  assert {
    condition     = length(azurerm_storage_account.n8n) == 0
    error_message = "No azurerm_storage_account.n8n instance must be created when create_blob_storage = false."
  }

  assert {
    condition     = length(azurerm_storage_container.n8n) == 0
    error_message = "No azurerm_storage_container.n8n instance must be created when create_blob_storage = false."
  }

  assert {
    condition     = length(azurerm_private_dns_zone.blob) == 0
    error_message = "No azurerm_private_dns_zone.blob instance must be created when create_blob_storage = false."
  }

  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.blob) == 0
    error_message = "No azurerm_private_dns_zone_virtual_network_link.blob instance must be created when create_blob_storage = false."
  }

  assert {
    condition     = length(azurerm_private_endpoint.blob) == 0
    error_message = "No azurerm_private_endpoint.blob instance must be created when create_blob_storage = false."
  }

  assert {
    condition     = length(azurerm_storage_management_policy.n8n_binary) == 0
    error_message = "No azurerm_storage_management_policy.n8n_binary instance must be created when create_blob_storage = false."
  }

  assert {
    condition     = length(azurerm_role_assignment.n8n_blob_data_contributor) == 1
    error_message = "The n8n workload identity's role assignment must still be created, scoped to the supplied existing_blob_container_id, because automatic authentication is selected by default."
  }

  assert {
    condition     = azurerm_role_assignment.n8n_blob_data_contributor[0].scope == var.existing_blob_container_id
    error_message = "The Blob data role assignment must be scoped to local.effective_blob_container_id, not a module-managed container, on the customer-managed path."
  }

  assert {
    condition     = nonsensitive(local.azure_blob_connection).account_name == var.existing_blob_storage_account_name
    error_message = "local.azure_blob_connection must render the supplied existing_blob_storage_account_name into every n8n pod environment."
  }

  assert {
    condition     = nonsensitive(local.azure_blob_connection).endpoint == var.existing_blob_endpoint
    error_message = "local.azure_blob_connection must render the supplied existing_blob_endpoint into every n8n pod environment."
  }

  assert {
    condition = (
      length(local.azure_blob_endpoint_env) == 1 &&
      nonsensitive(local.azure_blob_endpoint_env[0].name) == "N8N_EXTERNAL_STORAGE_AZURE_ENDPOINT" &&
      nonsensitive(local.azure_blob_endpoint_env[0].value) == var.existing_blob_endpoint
    )
    error_message = "The n8n Helm environment must render existing_blob_endpoint as N8N_EXTERNAL_STORAGE_AZURE_ENDPOINT on the customer-managed Blob path."
  }
}

run "existing_blob_with_compatibility_credential_omits_role_assignment" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
    azure_blob_account_key                = "synthetic-storage-account-key"
  }

  assert {
    condition     = length(azurerm_role_assignment.n8n_blob_data_contributor) == 0
    error_message = "The n8n workload identity's role assignment must be omitted when a compatibility credential is supplied, because n8n does not use workload identity for Blob access in that mode."
  }
}

run "warns_when_blob_tuning_is_inert_on_existing_storage" {
  command = plan

  variables {
    create_blob_storage                   = false
    existing_blob_storage_account_name    = "sharedn8nfiles"
    existing_blob_container_name          = "n8n-data"
    existing_blob_container_id            = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/shared-rg/providers/Microsoft.Storage/storageAccounts/sharedn8nfiles/blobServices/default/containers/n8n-data"
    existing_blob_endpoint                = "https://sharedn8nfiles.blob.core.windows.net/"
    existing_blob_prerequisites_confirmed = true
    storage_account_replication_type      = "ZRS"
  }

  expect_failures = [check.blob_tuning_requires_module_managed_blob_storage]
}

run "module_managed_blob_storage_is_unchanged_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_storage_account.n8n) == 1
    error_message = "Exactly one azurerm_storage_account.n8n instance must be created by default (create_blob_storage = true)."
  }

  assert {
    condition     = length(azurerm_storage_container.n8n) == 1
    error_message = "Exactly one azurerm_storage_container.n8n instance must be created by default."
  }

  assert {
    condition     = length(azurerm_role_assignment.n8n_blob_data_contributor) == 1
    error_message = "The n8n workload identity's role assignment must still be created by default."
  }

  assert {
    condition     = local.effective_blob_container_name == azurerm_storage_container.n8n[0].name
    error_message = "local.effective_blob_container_name must resolve to the module-managed container's name by default."
  }
}

# ── KEDA installation contract ──────────────────────────────────────────────

run "rejects_install_keda_false_unconfirmed_prerequisites" {
  command = plan

  variables {
    install_keda = false
  }

  expect_failures = [var.existing_keda_prerequisites_confirmed]
}

run "warns_when_existing_keda_prerequisites_are_ignored" {
  command = plan

  variables {
    existing_keda_prerequisites_confirmed = true
  }

  expect_failures = [check.existing_keda_prerequisites_ignored_when_module_managed]
}

run "accepts_install_keda_false_with_confirmed_prerequisites" {
  command = plan

  variables {
    install_keda                          = false
    existing_keda_prerequisites_confirmed = true
  }

  assert {
    condition     = var.install_keda == false
    error_message = "install_keda must be settable to false when prerequisites are confirmed."
  }

  assert {
    condition     = module.controllers.keda_installed == false && module.controllers.keda_release_name == null
    error_message = "modules/controllers must create no KEDA release when install_keda = false, and its release output must be null."
  }

  # The chart-rendered worker ScaledObject and the root TriggerAuthentication
  # are unaffected by install_keda — only the controller installation itself
  # is skipped (design.md decision 7).
  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"kind\": \"TriggerAuthentication\"")
    error_message = "The root TriggerAuthentication manifest must still render when install_keda = false."
  }
}

run "passes_custom_keda_chart_settings_through_to_controllers" {
  command = plan

  variables {
    keda_chart_repository = "https://mirror.example.com/keda-charts"
    keda_chart_version    = "2.16.1"
  }

  assert {
    condition     = module.controllers.keda_release_name == "keda"
    error_message = "modules/controllers must still install KEDA when only the chart repository and version are overridden."
  }
}

# ── Caller-managed namespace and webhook HPA ────────────────────────────────

run "rejects_malformed_namespace_when_caller_managed" {
  command = plan

  variables {
    create_namespace = false
    n8n_namespace    = "Not_Valid"
  }

  expect_failures = [var.n8n_namespace]
}

run "caller_managed_namespace_creates_no_namespace_resource" {
  command = plan

  variables {
    create_namespace = false
    n8n_namespace    = "platform-n8n"
  }

  assert {
    condition     = length(kubernetes_namespace.n8n) == 0
    error_message = "No kubernetes_namespace.n8n instance must be created when create_namespace = false."
  }

  assert {
    condition     = local.n8n_namespace == "platform-n8n"
    error_message = "local.n8n_namespace must resolve to the caller-supplied n8n_namespace regardless of create_namespace."
  }

  assert {
    condition     = kubernetes_secret.n8n_db[0].metadata[0].namespace == "platform-n8n"
    error_message = "n8n Secrets must target the caller-managed namespace when create_namespace = false."
  }

  assert {
    condition     = helm_release.n8n.namespace == "platform-n8n"
    error_message = "The n8n Helm release must target the caller-managed namespace when create_namespace = false."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].metadata[0].namespace == "platform-n8n"
    error_message = "The webhook HPA must target the caller-managed namespace when create_namespace = false."
  }

  assert {
    condition     = output.n8n_namespace == "platform-n8n"
    error_message = "n8n_namespace output must reflect the caller-managed namespace when create_namespace = false."
  }
}

run "module_managed_namespace_is_unchanged_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_namespace.n8n) == 1
    error_message = "Exactly one kubernetes_namespace.n8n instance must be created by default (create_namespace = true)."
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].name == "n8n"
    error_message = "The module-managed namespace must default to 'n8n'."
  }
}

run "disabled_webhook_hpa_creates_no_hpa_resource" {
  command = plan

  variables {
    n8n_webhook_hpa_enabled    = false
    create_database            = false
    postgres_external_host     = "postgres.external.example.com"
    postgres_external_username = "n8n_app"
    postgres_external_password = "synthetic-external-postgres-password"
    create_redis               = false
    redis_external_host        = "redis.external.example.com"
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
      client_id    = "33333333-3333-3333-3333-333333333333"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0
    error_message = "No kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook instance must be created when n8n_webhook_hpa_enabled = false."
  }

  assert {
    condition     = yamldecode(helm_release.n8n.values[0]).webhookProcessor.replicaCount == var.n8n_webhook_hpa_min_replicas
    error_message = "The chart-rendered webhook replica floor must still be set to n8n_webhook_hpa_min_replicas when the module-managed HPA is disabled."
  }
}

run "warns_when_webhook_hpa_tuning_is_ignored" {
  command = plan

  variables {
    n8n_webhook_hpa_enabled      = false
    n8n_webhook_hpa_max_replicas = 20
  }

  expect_failures = [check.webhook_hpa_tuning_requires_module_managed_webhook_hpa]
}

run "module_managed_webhook_hpa_is_unchanged_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 1
    error_message = "Exactly one kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook instance must be created by default (n8n_webhook_hpa_enabled = true)."
  }
}

# ── Caller-managed Kubernetes Secret credential references ─────────────────

run "rejects_neither_license_key_nor_secret_ref" {
  command = plan

  variables {
    n8n_license_key = null
  }

  expect_failures = [var.n8n_license_key]
}

run "rejects_both_license_key_and_secret_ref" {
  command = plan

  variables {
    n8n_license_key            = "test-license-key-value"
    n8n_license_key_secret_ref = { name = "n8n-license", key = "license-key" }
  }

  expect_failures = [var.n8n_license_key]
}

run "accepts_license_key_secret_ref_alone" {
  command = plan

  variables {
    n8n_license_key            = null
    n8n_license_key_secret_ref = { name = "n8n-license", key = "license-key" }
  }

  assert {
    condition     = local.n8n_license_key_uses_secret_ref == true
    error_message = "local.n8n_license_key_uses_secret_ref must be true when n8n_license_key_secret_ref is set."
  }
}

run "rejects_empty_license_key_secret_ref_fields" {
  command = plan

  variables {
    n8n_license_key            = null
    n8n_license_key_secret_ref = { name = "", key = "license-key" }
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

run "rejects_both_encryption_key_and_secret_ref" {
  command = plan

  variables {
    n8n_encryption_key            = "supplied-encryption-key-value"
    n8n_encryption_key_secret_ref = { name = "n8n-encryption", key = "N8N_ENCRYPTION_KEY" }
  }

  expect_failures = [var.n8n_encryption_key]
}

run "accepts_encryption_key_secret_ref_alone" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "n8n-encryption", key = "N8N_ENCRYPTION_KEY" }
  }

  assert {
    condition     = local.n8n_encryption_key_uses_secret_ref == true
    error_message = "local.n8n_encryption_key_uses_secret_ref must be true when n8n_encryption_key_secret_ref is set."
  }
}

run "rejects_postgres_password_secret_ref_with_managed_database" {
  command = plan

  variables {
    postgres_password_secret_ref = { name = "postgres-password", key = "password" }
  }

  expect_failures = [var.postgres_password_secret_ref]
}

run "rejects_postgres_external_neither_password_nor_secret_ref" {
  command = plan

  variables {
    create_database            = false
    postgres_external_host     = "external-pg.example.com"
    postgres_external_username = "n8n"
    postgres_external_password = null
  }

  expect_failures = [var.postgres_external_password]
}

run "rejects_postgres_external_both_password_and_secret_ref" {
  command = plan

  variables {
    create_database              = false
    postgres_external_host       = "external-pg.example.com"
    postgres_external_username   = "n8n"
    postgres_external_password   = "external-password-value"
    postgres_password_secret_ref = { name = "postgres-password", key = "password" }
  }

  expect_failures = [var.postgres_external_password]
}

run "accepts_postgres_external_secret_ref_alone" {
  command = plan

  variables {
    create_database              = false
    postgres_external_host       = "external-pg.example.com"
    postgres_external_username   = "n8n"
    postgres_external_password   = null
    postgres_password_secret_ref = { name = "postgres-password", key = "password" }
  }

  assert {
    condition     = local.postgres_password_uses_secret_ref == true
    error_message = "local.postgres_password_uses_secret_ref must be true when postgres_password_secret_ref is set on the external database path."
  }
}

run "rejects_redis_password_secret_ref_with_managed_redis" {
  command = plan

  variables {
    redis_password_secret_ref = { name = "redis-password", key = "password" }
  }

  expect_failures = [var.redis_password_secret_ref]
}

run "rejects_redis_external_both_password_and_secret_ref" {
  command = plan

  variables {
    create_redis              = false
    redis_external_host       = "external-redis.example.com"
    redis_external_password   = "external-password-value"
    redis_password_secret_ref = { name = "redis-password", key = "password" }
  }

  expect_failures = [var.redis_external_password]
}

run "accepts_redis_external_secret_ref_alone" {
  command = plan

  variables {
    create_redis              = false
    redis_external_host       = "external-redis.example.com"
    redis_password_secret_ref = { name = "redis-password", key = "password" }
  }

  assert {
    condition     = local.redis_password_uses_secret_ref == true
    error_message = "local.redis_password_uses_secret_ref must be true when redis_password_secret_ref is set on the external Redis path."
  }
}

# ── Caller-managed workload Secret rendering (section 5) ────────────────────
# Complements the local-selection assertions above with resource-count and
# chart-rendering proof for every generated, literal, and caller-managed
# Secret branch — the module never creates a Secret it does not own, and the
# chart always points at whichever Secret currently backs each credential.

run "rejects_encryption_key_secret_ref_wrong_key" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "n8n-encryption", key = "some-other-key" }
  }

  expect_failures = [var.n8n_encryption_key_secret_ref]
}

run "rejects_empty_encryption_key_secret_ref_name" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "", key = "N8N_ENCRYPTION_KEY" }
  }

  expect_failures = [var.n8n_encryption_key_secret_ref]
}

run "license_key_secret_ref_creates_no_managed_secret" {
  command = plan

  variables {
    n8n_license_key            = null
    n8n_license_key_secret_ref = { name = "platform-n8n-license", key = "license-key" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_license) == 0
    error_message = "kubernetes_secret.n8n_license must not exist when n8n_license_key_secret_ref is set."
  }

  assert {
    condition     = local.n8n_license_secret_name == "platform-n8n-license" && local.n8n_license_secret_key == "license-key"
    error_message = "local.n8n_license_secret_name/_key must reflect n8n_license_key_secret_ref when set."
  }
}

run "encryption_key_secret_ref_creates_no_managed_secret_or_random_password" {
  command = plan

  variables {
    n8n_encryption_key_secret_ref = { name = "platform-n8n-encryption", key = "N8N_ENCRYPTION_KEY" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_encryption_key) == 0
    error_message = "kubernetes_secret.n8n_encryption_key must not exist when n8n_encryption_key_secret_ref is set."
  }

  assert {
    condition     = length(random_password.n8n_encryption_key) == 0
    error_message = "random_password.n8n_encryption_key must not be generated when n8n_encryption_key_secret_ref is set."
  }

  assert {
    condition     = local.n8n_encryption_key == null
    error_message = "local.n8n_encryption_key must be null when n8n_encryption_key_secret_ref is set — Terraform never reads the caller-managed Secret's value."
  }

  assert {
    condition     = local.n8n_encryption_secret_name == "platform-n8n-encryption"
    error_message = "local.n8n_encryption_secret_name must reflect n8n_encryption_key_secret_ref when set."
  }
}

run "postgres_password_secret_ref_creates_no_managed_secret_and_helm_matches" {
  command = plan

  variables {
    create_database              = false
    postgres_external_host       = "external-pg.example.com"
    postgres_external_username   = "n8n"
    postgres_external_password   = null
    postgres_password_secret_ref = { name = "platform-n8n-db-password", key = "pgpass" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 0
    error_message = "kubernetes_secret.n8n_db must not exist when postgres_password_secret_ref is set."
  }

  assert {
    condition     = local.postgres_password_secret_name == "platform-n8n-db-password" && local.postgres_password_secret_key == "pgpass"
    error_message = "local.postgres_password_secret_name/_key must reflect postgres_password_secret_ref when set."
  }

  assert {
    condition     = local.postgres_connection.password == null
    error_message = "local.postgres_connection.password must be null when postgres_password_secret_ref is set — Terraform never reads the caller-managed Secret's value."
  }
}

run "redis_password_secret_ref_creates_no_managed_secret_and_helm_matches" {
  command = plan

  variables {
    create_redis              = false
    redis_external_host       = "external-redis.example.com"
    redis_password_secret_ref = { name = "platform-n8n-redis-password", key = "redispass" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "kubernetes_secret.n8n_redis must not exist when redis_password_secret_ref is set and no username is configured."
  }

  assert {
    condition     = local.redis_password_secret_name == "platform-n8n-redis-password" && local.redis_password_secret_key == "redispass"
    error_message = "local.redis_password_secret_name/_key must reflect redis_password_secret_ref when set."
  }

  assert {
    condition     = local.redis_connection.password == null
    error_message = "local.redis_connection.password must be null when redis_password_secret_ref is set — Terraform never reads the caller-managed Secret's value."
  }

  assert {
    condition     = local.redis_password_present == true
    error_message = "local.redis_password_present must stay true when redis_password_secret_ref is set, so the TriggerAuthentication and Helm redis.passwordSecret block still render."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "platform-n8n-redis-password") && strcontains(local.keda_trigger_authentication_yaml, "redispass")
    error_message = "The KEDA TriggerAuthentication manifest must reference the caller-managed Redis Secret's name and key when redis_password_secret_ref is set."
  }
}

run "redis_password_secret_ref_with_username_still_creates_secret_for_username" {
  command = plan

  variables {
    create_redis              = false
    redis_external_host       = "external-redis.example.com"
    redis_external_username   = "n8n_app"
    redis_password_secret_ref = { name = "platform-n8n-redis-password", key = "redispass" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 1
    error_message = "kubernetes_secret.n8n_redis must still exist to carry the username when redis_password_secret_ref is set alongside redis_external_username."
  }

  assert {
    condition     = kubernetes_secret.n8n_redis[0].data.username == "n8n_app" && !contains(keys(kubernetes_secret.n8n_redis[0].data), "password")
    error_message = "kubernetes_secret.n8n_redis must carry only the username when the password comes from a caller-managed Secret reference."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "platform-n8n-redis-password")
    error_message = "The KEDA TriggerAuthentication manifest's password entry must still reference the caller-managed Redis Secret even when a module-managed Secret exists for the username."
  }
}
