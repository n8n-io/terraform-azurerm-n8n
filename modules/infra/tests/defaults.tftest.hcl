# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for the modules/infra/ submodule using mocked providers.
# Asserts on the locals/variables surface that the R5.1a (US-014) skeleton
# exposes; subsequent Phase 5 stories (US-015..US-019) layer in resource-
# specific assertions as resources are moved into this submodule.
#
# Run: terraform test
#   (from this directory's parent — modules/infra/. No Azure credentials
#    needed; both providers are mocked.)

mock_provider "azurerm" {}
mock_provider "random" {}
mock_provider "time" {}

# `azurerm_role_assignment.scope` is validated as a resource ID by the
# azurerm provider at plan time. Under `mock_provider "azurerm"`, the
# synthetic `id` of `data.azurerm_resource_group.n8n` does NOT match the
# `/subscriptions/.../resourceGroups/...` shape, so the role-assignment
# scope validation fails. The fix mirrors the codebase pattern documented
# for `azurerm_key_vault.tenant_id` UUID validation: pin a synthetic
# resource-ID-shaped value via `override_data` so the role-assignment
# validation passes. Goes alongside `override_resource` blocks for any
# computed-at-apply attributes the test needs to read (US-019 needs the
# AGIC-addon's `ingress_application_gateway_identity` block on the cluster
# to be plan-known so the agic_addon_rg_reader / agic_addon_appgw_contributor
# role assignments compile).
override_data {
  target = data.azurerm_resource_group.n8n
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg"
  }
}

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
}

run "skeleton_plans_clean_with_defaults" {
  command = plan

  # ── Resource-name locals (mirrored from the root locals.tf) ────────────────
  # Every resource-name local must embed `friendly_name_prefix` so sibling
  # deployments in the same subscription / region don't collide on the
  # globally-unique Azure namespaces. Subsequent stories (US-015..US-019)
  # will reference these locals from the resources they move in; pinning
  # the shape here means a future rename is a single-local edit.
  assert {
    condition     = local.cluster_name == "${var.friendly_name_prefix}-aks"
    error_message = "local.cluster_name must be '<friendly_name_prefix>-aks' (mirrors the root locals.tf naming convention)."
  }

  assert {
    condition     = local.postgres_server_name == "${var.friendly_name_prefix}-postgres"
    error_message = "local.postgres_server_name must be '<friendly_name_prefix>-postgres'."
  }

  assert {
    condition     = local.redis_cache_name == "${var.friendly_name_prefix}-redis"
    error_message = "local.redis_cache_name must be '<friendly_name_prefix>-redis'."
  }

  assert {
    condition     = local.key_vault_name == substr("${var.friendly_name_prefix}-n8n-kv", 0, 24)
    error_message = "local.key_vault_name must be the substr-truncated '<friendly_name_prefix>-n8n-kv' (Key Vault names cap at 24 chars)."
  }

  assert {
    condition     = local.storage_account_name == substr("${var.friendly_name_prefix}n8nfiles", 0, 24)
    error_message = "local.storage_account_name must be the substr-truncated '<friendly_name_prefix>n8nfiles' (Storage Account names cap at 24 chars, alnum-lowercase)."
  }

  # ── common_tags shape ──────────────────────────────────────────────────────
  # The submodule-built-in `ManagedBy = terraform` and `Project = n8n` tags
  # must always be present, with caller-supplied tags merged on top. A
  # regression here would silently strip ownership tags from every resource
  # this submodule creates.
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

run "aks_cluster_resources_in_plan" {
  command = plan

  # ── azurerm_kubernetes_cluster.n8n shape ───────────────────────────────────
  # Cluster name comes from local.cluster_name; embed the friendly_name_prefix
  # so the resource is plan-known under mock_provider.
  assert {
    condition     = azurerm_kubernetes_cluster.n8n.name == local.cluster_name
    error_message = "azurerm_kubernetes_cluster.n8n.name must equal local.cluster_name (single source of truth)."
  }

  # OIDC issuer + workload identity must both be on — modules/workload/
  # (US-023) federates the n8n_workload UAMI to the chart-created service
  # account via the AKS OIDC issuer URL; without these flags the federation
  # fails silently at apply.
  assert {
    condition     = azurerm_kubernetes_cluster.n8n.oidc_issuer_enabled == true
    error_message = "oidc_issuer_enabled must be true — workload identity federation depends on it."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n.workload_identity_enabled == true
    error_message = "workload_identity_enabled must be true — n8n pods authenticate to Azure via federated tokens."
  }

  # Default node pool: vm_size, autoscaler bounds, and subnet are caller-driven.
  assert {
    condition     = azurerm_kubernetes_cluster.n8n.default_node_pool[0].vm_size == var.aks_node_vm_size
    error_message = "default_node_pool.vm_size must equal var.aks_node_vm_size."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n.default_node_pool[0].vnet_subnet_id == var.aks_subnet_id
    error_message = "default_node_pool.vnet_subnet_id must equal var.aks_subnet_id."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n.default_node_pool[0].min_count == var.aks_node_count_min
    error_message = "default_node_pool.min_count must equal var.aks_node_count_min."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.n8n.default_node_pool[0].max_count == var.aks_node_count_max
    error_message = "default_node_pool.max_count must equal var.aks_node_count_max."
  }

  # Azure CNI on the deliberately non-default service_cidr (avoids 10.0.0.0/16
  # collisions that the Azure default frequently hits in enterprise VNets).
  assert {
    condition     = azurerm_kubernetes_cluster.n8n.network_profile[0].service_cidr == "172.16.0.0/16"
    error_message = "network_profile.service_cidr must be 172.16.0.0/16 to avoid 10.0.0.0/16 enterprise-VNet collisions."
  }

  # ── Optional user node pool ────────────────────────────────────────────────
  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.n8n_user.name == "n8nuser"
    error_message = "n8n_user node pool name must be 'n8nuser' (matches the legacy root aks.tf shape)."
  }

  # ── User-Assigned Identities ───────────────────────────────────────────────
  # Names embed friendly_name_prefix so sibling deployments don't collide.
  assert {
    condition     = azurerm_user_assigned_identity.aks_kubelet.name == "${var.friendly_name_prefix}-aks-kubelet"
    error_message = "aks_kubelet UAMI name must embed friendly_name_prefix."
  }

  assert {
    condition     = azurerm_user_assigned_identity.n8n_workload.name == "${var.friendly_name_prefix}-n8n-workload"
    error_message = "n8n_workload UAMI name must embed friendly_name_prefix."
  }

  # ── Role Assignment ────────────────────────────────────────────────────────
  assert {
    condition     = azurerm_role_assignment.aks_kubelet_subnet_network_contributor.role_definition_name == "Network Contributor"
    error_message = "aks_kubelet must hold Network Contributor on the AKS subnet (Azure CNI pod-IP attach)."
  }

  assert {
    condition     = azurerm_role_assignment.aks_kubelet_subnet_network_contributor.scope == var.aks_subnet_id
    error_message = "aks_kubelet Network Contributor role assignment must be scoped to var.aks_subnet_id."
  }

  # ── time_sleep.aks_api_warmup ──────────────────────────────────────────────
  # Replaces null_resource.wait_for_aks_api (registry-hardening US-003).
  # create_duration is configured (plan-known under mock_provider "time").
  assert {
    condition     = time_sleep.aks_api_warmup.create_duration == "${var.aks_api_warmup_seconds}s"
    error_message = "time_sleep.aks_api_warmup.create_duration must equal '${var.aks_api_warmup_seconds}s' (the var.aks_api_warmup_seconds knob)."
  }

  # 90 s default — covers the typical AKS post-provision warm-up window.
  assert {
    condition     = time_sleep.aks_api_warmup.create_duration == "90s"
    error_message = "time_sleep.aks_api_warmup.create_duration default must be 90s."
  }

  # ── azurerm_federated_identity_credential.n8n_workload (US-023) ────────────
  # Wires the n8n_workload UAMI to the chart-created service account
  # "n8n-enterprise" in the n8n namespace. Lives in this submodule rather
  # than modules/workload/ to preserve the chart-only consumer posture
  # (modules/workload/AGENTS.md "Don't add an `azurerm` provider here").
  # Only the configured (plan-known) attributes are asserted here:
  # `parent_id` and `issuer` reference computed-at-apply attributes
  # (azurerm_user_assigned_identity.n8n_workload.id and
  # azurerm_kubernetes_cluster.n8n.oidc_issuer_url) which are unknown
  # under mock_provider in plan mode; the wiring on those references is
  # enforced by the resource declaration in iam.tf and verified
  # transitively by the output_contract_complete apply-mode run below.
  assert {
    condition     = azurerm_federated_identity_credential.n8n_workload.name == "${var.friendly_name_prefix}-n8n-workload-fed"
    error_message = "federated_identity_credential.n8n_workload.name must embed friendly_name_prefix."
  }

  # `resource_group_name` was removed from the resource in iam.tf because it
  # was deprecated in azurerm 4.x ("This field is no longer used and will be
  # removed in the next major version"). The credential is now scoped via
  # `parent_id` only — azurerm derives the RG from the parent UAMI.

  # subject must be `system:serviceaccount:<namespace>:<sa>` per the AKS
  # workload identity contract. The `n8n` namespace + `n8n-enterprise` SA
  # name are literals here that must stay in lockstep with
  # modules/workload/locals.tf (`local.n8n_namespace = "n8n"`) and the
  # chart's hardcoded SA name. A drift on either side silently breaks
  # workload identity.
  assert {
    condition     = azurerm_federated_identity_credential.n8n_workload.subject == "system:serviceaccount:n8n:n8n-enterprise"
    error_message = "federated_identity_credential.n8n_workload.subject must be 'system:serviceaccount:n8n:n8n-enterprise' (matches modules/workload/locals.tf local.n8n_namespace + the n8n chart's hardcoded service-account name)."
  }

  assert {
    condition     = azurerm_federated_identity_credential.n8n_workload.audience[0] == "api://AzureADTokenExchange"
    error_message = "federated_identity_credential.n8n_workload.audience must be ['api://AzureADTokenExchange'] (the AKS workload identity contract)."
  }
}

# ── Variable validation rejects bad input ─────────────────────────────────────
# One contract per validation rule. Each scenario sets one bad value, leaves
# the rest at the defaults block above, and asserts terraform plan is
# rejected before any provider call. Mirrors the `invalid_inputs_fail_fast_*`
# convention from the root module's tests.

run "rejects_malformed_location" {
  command = plan

  variables {
    location = "East US"
  }

  expect_failures = [
    var.location,
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

run "rejects_malformed_aks_kubernetes_version" {
  command = plan

  variables {
    aks_kubernetes_version = "v1.30"
  }

  expect_failures = [
    var.aks_kubernetes_version,
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

run "postgres_resources_in_plan" {
  command = plan

  # ── azurerm_postgresql_flexible_server.n8n shape ───────────────────────────
  # Server name comes from local.postgres_server_name; sizing/version are
  # caller-driven; private-only posture is hardcoded (no public endpoint
  # ever — the whole point of injecting into a delegated subnet).
  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.name == local.postgres_server_name
    error_message = "azurerm_postgresql_flexible_server.n8n.name must equal local.postgres_server_name (single source of truth)."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.version == var.pg_version
    error_message = "postgresql_flexible_server.n8n.version must equal var.pg_version."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.sku_name == var.pg_sku_name
    error_message = "postgresql_flexible_server.n8n.sku_name must equal var.pg_sku_name."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.storage_mb == var.pg_storage_mb
    error_message = "postgresql_flexible_server.n8n.storage_mb must equal var.pg_storage_mb."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.delegated_subnet_id == var.postgres_subnet_id
    error_message = "postgresql_flexible_server.n8n.delegated_subnet_id must equal var.postgres_subnet_id."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.public_network_access_enabled == false
    error_message = "postgresql_flexible_server.n8n.public_network_access_enabled must be false (private-only posture is hardcoded)."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.administrator_login == var.pg_admin_username
    error_message = "postgresql_flexible_server.n8n.administrator_login must equal var.pg_admin_username."
  }

  # ── azure.extensions allowlist (uuid-ossp safety belt) ─────────────────────
  # Preserved across the Phase 5 split per US-016 AC#4. n8n's own migrations
  # do not issue `CREATE EXTENSION "uuid-ossp"`, but the allowlist costs
  # nothing and gates any operator-side `psql` retry path (registry-hardening
  # US-001 retired the in-cluster bootstrap Job).
  assert {
    condition     = azurerm_postgresql_flexible_server_configuration.uuid_ossp.name == "azure.extensions"
    error_message = "uuid_ossp configuration name must be 'azure.extensions' (the server-level parameter Azure honours)."
  }

  assert {
    condition     = strcontains(upper(azurerm_postgresql_flexible_server_configuration.uuid_ossp.value), "UUID-OSSP")
    error_message = "uuid_ossp configuration value must contain 'UUID-OSSP' (server-level allowlist preserved across Phase 5 split — see US-001 / US-016)."
  }

  # ── Private DNS zone + VNet link ───────────────────────────────────────────
  # The DNS zone name MUST be the literal Azure-mandated string —
  # auto-registration only fires for that exact name.
  assert {
    condition     = azurerm_private_dns_zone.postgres.name == "privatelink.postgres.database.azure.com"
    error_message = "private DNS zone name must be 'privatelink.postgres.database.azure.com' (Azure Flexible Server auto-registration only fires for that exact name)."
  }

  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.postgres.virtual_network_id == var.vnet_id
    error_message = "postgres private DNS VNet link must point at var.vnet_id."
  }

  # ── n8n database ───────────────────────────────────────────────────────────
  assert {
    condition     = azurerm_postgresql_flexible_server_database.n8n.name == "n8n"
    error_message = "postgresql_flexible_server_database.n8n.name must be 'n8n' (matches the legacy umbrella module's hardcoded database name)."
  }
}

run "rejects_malformed_pg_sku_name" {
  command = plan

  variables {
    pg_sku_name = "Standard_D2s_v3"
  }

  expect_failures = [
    var.pg_sku_name,
  ]
}

run "rejects_pg_storage_below_floor" {
  command = plan

  variables {
    pg_storage_mb = 16384
  }

  expect_failures = [
    var.pg_storage_mb,
  ]
}

run "rejects_burstable_with_high_availability" {
  command = plan

  variables {
    pg_sku_name                 = "B_Standard_B1ms"
    pg_enable_high_availability = true
  }

  expect_failures = [
    var.pg_enable_high_availability,
  ]
}

run "rejects_reserved_pg_admin_username" {
  command = plan

  variables {
    pg_admin_username = "azure_superuser"
  }

  expect_failures = [
    var.pg_admin_username,
  ]
}

run "redis_resources_in_plan" {
  command = plan

  # ── azurerm_redis_cache.n8n shape ──────────────────────────────────────────
  # Cache name comes from local.redis_cache_name; sizing is caller-driven;
  # private-only + TLS-only posture is hardcoded (the whole point of attaching
  # the cache to a private endpoint — no caller-tunable knob would re-enable
  # the public endpoint or the non-TLS port without subverting the trust
  # model).
  assert {
    condition     = azurerm_redis_cache.n8n.name == local.redis_cache_name
    error_message = "azurerm_redis_cache.n8n.name must equal local.redis_cache_name (single source of truth)."
  }

  assert {
    condition     = azurerm_redis_cache.n8n.sku_name == var.redis_sku_name
    error_message = "azurerm_redis_cache.n8n.sku_name must equal var.redis_sku_name."
  }

  assert {
    condition     = azurerm_redis_cache.n8n.family == var.redis_family
    error_message = "azurerm_redis_cache.n8n.family must equal var.redis_family."
  }

  assert {
    condition     = azurerm_redis_cache.n8n.capacity == var.redis_capacity
    error_message = "azurerm_redis_cache.n8n.capacity must equal var.redis_capacity."
  }

  assert {
    condition     = azurerm_redis_cache.n8n.public_network_access_enabled == false
    error_message = "azurerm_redis_cache.n8n.public_network_access_enabled must be false (private-only posture is hardcoded)."
  }

  assert {
    condition     = azurerm_redis_cache.n8n.non_ssl_port_enabled == false
    error_message = "azurerm_redis_cache.n8n.non_ssl_port_enabled must be false (TLS-only on 6380 is hardcoded)."
  }

  assert {
    condition     = azurerm_redis_cache.n8n.minimum_tls_version == "1.2"
    error_message = "azurerm_redis_cache.n8n.minimum_tls_version must be 1.2 (hardened default)."
  }

  # ── Private DNS zone + VNet link ───────────────────────────────────────────
  # The DNS zone name MUST be the literal Azure-mandated string —
  # auto-registration only fires for that exact name.
  assert {
    condition     = azurerm_private_dns_zone.redis.name == "privatelink.redis.cache.windows.net"
    error_message = "private DNS zone name must be 'privatelink.redis.cache.windows.net' (Azure Redis private-endpoint auto-registration only fires for that exact name)."
  }

  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.redis.virtual_network_id == var.vnet_id
    error_message = "redis private DNS VNet link must point at var.vnet_id."
  }

  # ── Private Endpoint ───────────────────────────────────────────────────────
  # Lands on the caller-supplied redis_subnet_id; targets the cache itself;
  # wires the auto-registered A record into the private DNS zone above.
  assert {
    condition     = azurerm_private_endpoint.redis.subnet_id == var.redis_subnet_id
    error_message = "azurerm_private_endpoint.redis.subnet_id must equal var.redis_subnet_id."
  }

  assert {
    condition     = azurerm_private_endpoint.redis.private_service_connection[0].subresource_names[0] == "redisCache"
    error_message = "azurerm_private_endpoint.redis.private_service_connection.subresource_names must be ['redisCache']."
  }

  assert {
    condition     = azurerm_private_endpoint.redis.private_service_connection[0].is_manual_connection == false
    error_message = "azurerm_private_endpoint.redis.private_service_connection.is_manual_connection must be false (auto-approved within the same subscription)."
  }
}

run "rejects_invalid_redis_sku_name" {
  command = plan

  variables {
    redis_sku_name = "Basic"
  }

  expect_failures = [
    var.redis_sku_name,
  ]
}

run "rejects_invalid_redis_family" {
  command = plan

  variables {
    redis_family = "X"
  }

  expect_failures = [
    var.redis_family,
  ]
}

run "rejects_redis_capacity_above_ceiling" {
  command = plan

  variables {
    redis_capacity = 7
  }

  expect_failures = [
    var.redis_capacity,
  ]
}

run "storage_resources_in_plan" {
  command = plan

  # ── azurerm_storage_account.n8n shape ──────────────────────────────────────
  # Account name comes from local.storage_account_name; replication type is
  # caller-driven; tier / kind / TLS posture are hardcoded (the security
  # posture is non-negotiable, surfacing trade-offs as a code-review concern
  # instead of a runtime knob — same pattern US-016 / US-017 used).
  assert {
    condition     = azurerm_storage_account.n8n.name == local.storage_account_name
    error_message = "azurerm_storage_account.n8n.name must equal local.storage_account_name (single source of truth)."
  }

  assert {
    condition     = azurerm_storage_account.n8n.account_tier == "Standard"
    error_message = "azurerm_storage_account.n8n.account_tier must be 'Standard' (Premium Files would require account_kind = FileStorage and is out of scope)."
  }

  assert {
    condition     = azurerm_storage_account.n8n.account_replication_type == var.storage_account_replication_type
    error_message = "azurerm_storage_account.n8n.account_replication_type must equal var.storage_account_replication_type."
  }

  assert {
    condition     = azurerm_storage_account.n8n.account_kind == "StorageV2"
    error_message = "azurerm_storage_account.n8n.account_kind must be 'StorageV2'."
  }

  assert {
    condition     = azurerm_storage_account.n8n.https_traffic_only_enabled == true
    error_message = "azurerm_storage_account.n8n.https_traffic_only_enabled must be true (reject plain-HTTP REST calls)."
  }

  assert {
    condition     = azurerm_storage_account.n8n.min_tls_version == "TLS1_2"
    error_message = "azurerm_storage_account.n8n.min_tls_version must be 'TLS1_2' (hardened default)."
  }

  # ── azurerm_storage_share.n8n_binary shape ─────────────────────────────────
  # Share name is fixed at "n8n-binary-data" (chart-side wiring in
  # modules/workload/ US-023 references it directly — a variable here would
  # just shift the coupling without removing it). Quota is caller-tunable.
  assert {
    condition     = azurerm_storage_share.n8n_binary.name == "n8n-binary-data"
    error_message = "azurerm_storage_share.n8n_binary.name must be 'n8n-binary-data' (chart-side wiring in modules/workload/ depends on this fixed name)."
  }

  assert {
    condition     = azurerm_storage_share.n8n_binary.quota == var.storage_share_quota_gb
    error_message = "azurerm_storage_share.n8n_binary.quota must equal var.storage_share_quota_gb."
  }

  # ── Workload identity → storage account access key ─────────────────────────
  # AC#1 third bullet: a role assignment grants the n8n_workload UAMI the
  # `listKeys` API on the storage account so the workload tier can resolve
  # the access key via workload-identity federation rather than embedding it
  # in a long-lived Kubernetes Secret.
  assert {
    condition     = azurerm_role_assignment.n8n_workload_storage_account_key_operator.role_definition_name == "Storage Account Key Operator Service Role"
    error_message = "n8n_workload role assignment must be 'Storage Account Key Operator Service Role' — the canonical Azure role granting listKeys on a storage account."
  }
}

run "rejects_invalid_storage_account_replication_type" {
  command = plan

  variables {
    storage_account_replication_type = "INVALID"
  }

  expect_failures = [
    var.storage_account_replication_type,
  ]
}

run "rejects_storage_share_quota_below_floor" {
  command = plan

  variables {
    storage_share_quota_gb = 0
  }

  expect_failures = [
    var.storage_share_quota_gb,
  ]
}

run "rejects_storage_share_quota_above_ceiling" {
  command = plan

  variables {
    storage_share_quota_gb = 5121
  }

  expect_failures = [
    var.storage_share_quota_gb,
  ]
}

run "appgw_resources_in_plan" {
  command = plan

  # ── azurerm_public_ip.appgw shape ──────────────────────────────────────────
  # Static / Standard SKU is required for App Gateway v2; the DNS label is
  # `<friendly_name_prefix>-n8n` (the auto-FQDN is exposed via the
  # `appgw_fqdn` output).
  assert {
    condition     = azurerm_public_ip.appgw.name == local.appgw_pip_name
    error_message = "azurerm_public_ip.appgw.name must equal local.appgw_pip_name (single source of truth)."
  }

  assert {
    condition     = azurerm_public_ip.appgw.allocation_method == "Static"
    error_message = "azurerm_public_ip.appgw.allocation_method must be 'Static' (Application Gateway v2 requires static allocation)."
  }

  assert {
    condition     = azurerm_public_ip.appgw.sku == "Standard"
    error_message = "azurerm_public_ip.appgw.sku must be 'Standard' (Application Gateway v2 requires the Standard SKU)."
  }

  assert {
    condition     = azurerm_public_ip.appgw.domain_name_label == "${var.friendly_name_prefix}-n8n"
    error_message = "azurerm_public_ip.appgw.domain_name_label must be '<friendly_name_prefix>-n8n' (the auto-FQDN seed)."
  }

  # ── azurerm_application_gateway.n8n shape ──────────────────────────────────
  # Name comes from local.app_gateway_name; sku.name + sku.tier mirror
  # var.appgw_sku_name; capacity is caller-tunable via var.appgw_capacity
  # (NEW input in this story — root hardcoded capacity = 2).
  assert {
    condition     = azurerm_application_gateway.n8n.name == local.app_gateway_name
    error_message = "azurerm_application_gateway.n8n.name must equal local.app_gateway_name (single source of truth)."
  }

  assert {
    condition     = azurerm_application_gateway.n8n.sku[0].name == var.appgw_sku_name
    error_message = "azurerm_application_gateway.n8n.sku.name must equal var.appgw_sku_name."
  }

  assert {
    condition     = azurerm_application_gateway.n8n.sku[0].tier == var.appgw_sku_name
    error_message = "azurerm_application_gateway.n8n.sku.tier must equal var.appgw_sku_name (v2 SKUs use the same string for name + tier)."
  }

  assert {
    condition     = azurerm_application_gateway.n8n.sku[0].capacity == var.appgw_capacity
    error_message = "azurerm_application_gateway.n8n.sku.capacity must equal var.appgw_capacity."
  }

  assert {
    condition     = azurerm_application_gateway.n8n.http2_enabled == true
    error_message = "azurerm_application_gateway.n8n.http2_enabled must be true."
  }

  # gateway_ip_configuration must use the caller-supplied appgw subnet.
  assert {
    condition     = azurerm_application_gateway.n8n.gateway_ip_configuration[0].subnet_id == var.appgw_subnet_id
    error_message = "azurerm_application_gateway.n8n.gateway_ip_configuration.subnet_id must equal var.appgw_subnet_id."
  }

  # frontend_ip_configuration must reference the public IP created above.
  assert {
    condition     = azurerm_application_gateway.n8n.frontend_ip_configuration[0].name == "appgw-frontend-ip"
    error_message = "azurerm_application_gateway.n8n.frontend_ip_configuration.name must be 'appgw-frontend-ip' (referenced by request_routing_rule)."
  }

  # UserAssigned identity attached so the gateway can fetch the TLS cert
  # from Key Vault at runtime.
  assert {
    condition     = azurerm_application_gateway.n8n.identity[0].type == "UserAssigned"
    error_message = "azurerm_application_gateway.n8n.identity.type must be 'UserAssigned' (the appgw_tls_cert UAMI fetches the TLS cert from Key Vault)."
  }

  # ssl_certificate is set(object) on the azurerm 4.x schema, so set elements
  # have no addressable index. The for-expression keyed on `name` is the
  # canonical pattern (codebase patterns / US-012).
  assert {
    condition     = [for cert in azurerm_application_gateway.n8n.ssl_certificate : cert.key_vault_secret_id if cert.name == "appgw-ssl-cert"][0] == var.app_gateway_tls_cert_secret_id
    error_message = "azurerm_application_gateway.n8n.ssl_certificate['appgw-ssl-cert'].key_vault_secret_id must equal var.app_gateway_tls_cert_secret_id (registry-hardening US-012 single-pass-through contract)."
  }

  # ── WAF policy attachment (WAF_v2 SKU, post-deprecation contract) ──────────
  # Azure deprecated the inline `waf_configuration` block on the App Gateway
  # itself; the replacement is a separate `azurerm_web_application_firewall_policy`
  # attached via `firewall_policy_id`. Default SKU is WAF_v2, so we expect
  # the policy to materialise (count = 1) and the App Gateway to point at
  # it. See `ingress.tf` for the deprecation rationale and
  # `appgw_sku_standard_v2_skips_waf_policy` below for the off-branch.
  assert {
    condition     = length(azurerm_web_application_firewall_policy.appgw) == 1
    error_message = "azurerm_web_application_firewall_policy.appgw count must be 1 when var.appgw_sku_name = WAF_v2 (default)."
  }

  assert {
    condition     = azurerm_web_application_firewall_policy.appgw[0].policy_settings[0].mode == "Detection"
    error_message = "WAF policy must default to Detection mode (log only / no shadow-blocking on first rollout)."
  }

  assert {
    condition     = azurerm_web_application_firewall_policy.appgw[0].managed_rules[0].managed_rule_set[0].type == "OWASP" && azurerm_web_application_firewall_policy.appgw[0].managed_rules[0].managed_rule_set[0].version == "3.2"
    error_message = "WAF policy must use OWASP-3.2 ruleset (matches the legacy inline waf_configuration block)."
  }

  # `firewall_policy_id` is a string of an .id attribute that's computed
  # at apply by `mock_provider "azurerm"`, so an equality check is
  # unevaluable at plan time. The structural wiring is enforced by the
  # count + policy-attribute checks above; the equality regression would
  # surface on a real apply (or in the example's apply-mode test under
  # mocks), not here.

  # ── azurerm_user_assigned_identity.appgw_tls_cert ──────────────────────────
  assert {
    condition     = azurerm_user_assigned_identity.appgw_tls_cert.name == "${var.friendly_name_prefix}-appgw-tls"
    error_message = "appgw_tls_cert UAMI name must embed friendly_name_prefix."
  }

  # ── azurerm_user_assigned_identity.agic (forward-reference identity) ───────
  # Currently unused at runtime — the AKS addon auto-creates its own
  # identity. Kept as a forward reference for future stories that disable
  # the addon and bind AGIC to this UAMI directly (mirrors the root iam.tf
  # comment).
  assert {
    condition     = azurerm_user_assigned_identity.agic.name == "${var.friendly_name_prefix}-agic"
    error_message = "agic UAMI name must embed friendly_name_prefix."
  }

  # ── AGIC App Gateway Contributor role assignment ──────────────────────────
  # The AKS-addon-auto-created identity must hold Contributor on the App
  # Gateway so AGIC can mutate listeners / pools / rules at reconcile time.
  assert {
    condition     = azurerm_role_assignment.agic_addon_appgw_contributor.role_definition_name == "Contributor"
    error_message = "agic_addon_appgw_contributor must hold Contributor on the App Gateway."
  }

  # ── AKS AGIC addon block on the cluster ───────────────────────────────────
  # Confirms the addon is enabled and points at THIS App Gateway.
  assert {
    condition     = length(azurerm_kubernetes_cluster.n8n.ingress_application_gateway) == 1
    error_message = "azurerm_kubernetes_cluster.n8n.ingress_application_gateway block must be present (AGIC addon enabled in US-019)."
  }

  # ── Off-branch: role-assignment toggle is false by default ────────────────
  # The `Key Vault Secrets User` role assignment must NOT be created when
  # the caller did not flip the toggle. The data source must also resolve
  # to an empty list. Note: prior versions count-gated on
  # `var.app_gateway_keyvault_id == null`, but that broke `count` resolution
  # when callers passed a same-plan-built vault attribute (e.g.
  # `azurerm_key_vault.shared.id`) whose value is unknown until apply. The
  # explicit boolean toggle is plan-time-known regardless of how the ID is
  # wired — see `rejects_appgw_keyvault_toggle_without_id` below for the
  # cross-variable misuse-detection regression.
  assert {
    condition     = length(azurerm_role_assignment.appgw_kv_secrets_user) == 0
    error_message = "azurerm_role_assignment.appgw_kv_secrets_user count must be 0 when var.app_gateway_keyvault_role_assignment_enabled is false (default)."
  }

  assert {
    condition     = length(data.azurerm_key_vault.byo) == 0
    error_message = "data.azurerm_key_vault.byo count must be 0 when var.app_gateway_keyvault_role_assignment_enabled is false (default)."
  }
}

run "appgw_keyvault_on_branch" {
  command = plan

  variables {
    app_gateway_keyvault_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-shared-rg/providers/Microsoft.KeyVault/vaults/n8ntest-shared-kv"
    app_gateway_keyvault_role_assignment_enabled = true
  }

  # ── On-branch: data lookup + role assignment both materialise ─────────────
  assert {
    condition     = length(data.azurerm_key_vault.byo) == 1
    error_message = "data.azurerm_key_vault.byo count must be 1 when var.app_gateway_keyvault_role_assignment_enabled is true."
  }

  # Vault name + RG must be parsed correctly out of the resource ID.
  assert {
    condition     = data.azurerm_key_vault.byo[0].name == "n8ntest-shared-kv"
    error_message = "data.azurerm_key_vault.byo[0].name must be the last segment of var.app_gateway_keyvault_id."
  }

  assert {
    condition     = data.azurerm_key_vault.byo[0].resource_group_name == "n8ntest-shared-rg"
    error_message = "data.azurerm_key_vault.byo[0].resource_group_name must be the resourceGroups segment of var.app_gateway_keyvault_id."
  }

  assert {
    condition     = length(azurerm_role_assignment.appgw_kv_secrets_user) == 1
    error_message = "azurerm_role_assignment.appgw_kv_secrets_user count must be 1 when var.app_gateway_keyvault_role_assignment_enabled is true."
  }

  # Scope is the caller-supplied KV ID; role is the minimum needed for
  # runtime secret reads (guards against an accidental over-grant like
  # 'Key Vault Administrator').
  assert {
    condition     = azurerm_role_assignment.appgw_kv_secrets_user[0].scope == var.app_gateway_keyvault_id
    error_message = "appgw_kv_secrets_user role assignment scope must equal var.app_gateway_keyvault_id."
  }

  assert {
    condition     = azurerm_role_assignment.appgw_kv_secrets_user[0].role_definition_name == "Key Vault Secrets User"
    error_message = "appgw_kv_secrets_user role_definition_name must be 'Key Vault Secrets User' (the minimum role for runtime secret reads)."
  }
}

run "rejects_invalid_appgw_sku_name" {
  command = plan

  variables {
    appgw_sku_name = "Standard"
  }

  expect_failures = [
    var.appgw_sku_name,
  ]
}

# Off-branch for the WAF policy attachment: Standard_v2 SKU must NOT
# create the policy (Azure rejects the attachment on non-WAF SKUs) and
# the App Gateway's `firewall_policy_id` must be null.
run "appgw_sku_standard_v2_skips_waf_policy" {
  command = plan

  variables {
    appgw_sku_name = "Standard_v2"
  }

  assert {
    condition     = length(azurerm_web_application_firewall_policy.appgw) == 0
    error_message = "azurerm_web_application_firewall_policy.appgw count must be 0 when var.appgw_sku_name = Standard_v2 (Azure rejects WAF policy attachment on non-WAF SKUs)."
  }

  assert {
    condition     = azurerm_application_gateway.n8n.firewall_policy_id == null
    error_message = "azurerm_application_gateway.n8n.firewall_policy_id must be null when SKU is Standard_v2."
  }
}

run "rejects_appgw_capacity_above_ceiling" {
  command = plan

  variables {
    appgw_capacity = 126
  }

  expect_failures = [
    var.appgw_capacity,
  ]
}

run "rejects_invalid_n8n_domain" {
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
    app_gateway_tls_cert_secret_id = "https://example.com/secrets/cert"
  }

  expect_failures = [
    var.app_gateway_tls_cert_secret_id,
  ]
}

run "rejects_malformed_app_gateway_keyvault_id" {
  command = plan

  variables {
    app_gateway_keyvault_id = "not-a-resource-id"
  }

  expect_failures = [
    var.app_gateway_keyvault_id,
  ]
}

# Cross-variable validation regression: flipping the toggle on without
# supplying the vault ID must be rejected at plan time. Catches the
# misuse mode where a caller flips
# `var.app_gateway_keyvault_role_assignment_enabled = true` but forgets
# to pass `var.app_gateway_keyvault_id`. The validation lives on the ID
# variable (cross-variable validation, Terraform 1.9+) so the failure
# surfaces against `var.app_gateway_keyvault_id` here.
run "rejects_appgw_keyvault_toggle_without_id" {
  command = plan

  variables {
    app_gateway_keyvault_role_assignment_enabled = true
    app_gateway_keyvault_id                      = null
  }

  expect_failures = [
    var.app_gateway_keyvault_id,
  ]
}

# ── Output contract (US-020) ──────────────────────────────────────────────────
# Lock the modules/infra/ outputs.tf surface that modules/workload/ (US-023)
# and the umbrella example (US-025) consume. Each named output in PRD US-020
# AC#1 must resolve to a non-null value at plan time given non-null inputs.
#
# `app_gateway_keyvault_id` + `app_gateway_keyvault_role_assignment_enabled = true`
# flip the count gates on `data.azurerm_key_vault.byo` and
# `azurerm_role_assignment.appgw_kv_secrets_user` to 1 so the `key_vault_id`
# and `key_vault_uri` outputs resolve to non-null values rather than the
# explicit-null off-branch.
#
# `command = apply` (rather than `command = plan` like the other runs) is the
# canonical pattern for asserting on computed-at-apply output values. Under
# `mock_provider "azurerm"` an apply-mode run materialises every computed
# attribute with a synthesised placeholder (random alphanumeric for strings,
# a numeric value for numbers, etc.) — all of which are non-null by
# construction, exactly the contract this run locks in. Plan-mode runs leave
# computed-at-apply attrs as unknown, which collapses any `output.X != null`
# condition to "could not be evaluated at this time" (per the codebase
# pattern note in progress.txt).
run "output_contract_complete" {
  command = apply

  variables {
    app_gateway_keyvault_id                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-shared-rg/providers/Microsoft.KeyVault/vaults/n8ntest-shared-kv"
    app_gateway_keyvault_role_assignment_enabled = true
  }

  # The azurerm provider validates `scope` (role_assignment), `server_id`
  # (postgres database / configuration), `private_connection_resource_id`
  # (private endpoint), and `gateway_id` (AKS AGIC addon block) as Azure
  # resource IDs at apply time. Under `mock_provider "azurerm"` the
  # synthesised computed `id` is a short random alphanumeric (e.g.
  # `"fvvgs0b3"`) which fails resource-ID parsing. Pin a synthetic-but-
  # resource-ID-shaped `id` on every resource whose `id` is consumed as a
  # validated Azure resource ID elsewhere in the graph. Mirrors the
  # codebase pattern documented for `data.azurerm_resource_group.n8n.id`
  # via `override_data` at file scope.
  # The cluster `id` is consumed by `azurerm_kubernetes_cluster_node_pool.n8n_user`
  # (.kubernetes_cluster_id) and `time_sleep.aks_api_warmup` (.triggers.cluster_id)
  # — the former validates `kubernetes_cluster_id` as an Azure resource ID at
  # apply time, so a synthetic random alphanumeric from `mock_provider` fails.
  # iam.tf and ingress.tf reach into
  # `.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id`
  # for the agic_addon_rg_reader / agic_addon_appgw_contributor role
  # assignments. Under `mock_provider "azurerm"` this deeply-nested computed
  # block is left as an empty list — pin both a resource-ID-shaped cluster
  # `id` AND a synthetic populated AGIC addon block so the role assignments'
  # `principal_id` reads remain known at apply time.
  #
  # `override_resource` shape note (Terraform 1.15.x): nested block lists with
  # `MaxItems = 1` (e.g. azurerm_kubernetes_cluster.ingress_application_gateway)
  # are addressable at runtime as `<resource>.<block>[0].<attr>` (a list value),
  # but `override_resource.values` expects them as a SINGLE OBJECT, not a list
  # — providing `[{...}]` triggers `expected an object type for attribute
  # ".X[0]" but found list of object`. Inner block lists (e.g. nested
  # `ingress_application_gateway_identity`) DO need to be wrapped as
  # `[{...}]`. Mismatch yields `incompatible types; expected list of object,
  # found object` (or vice versa). Net rule: top-level MaxItems=1 lists →
  # single object; nested lists → list of objects.
  override_resource {
    target = azurerm_kubernetes_cluster.n8n
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ContainerService/managedClusters/n8ntest-aks"
      ingress_application_gateway = {
        effective_gateway_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGateways/n8ntest-appgw"
        gateway_id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGateways/n8ntest-appgw"
        gateway_name         = "n8ntest-appgw"
        subnet_cidr          = ""
        subnet_id            = ""
        ingress_application_gateway_identity = [
          {
            client_id                 = "55555555-5555-5555-5555-555555555555"
            object_id                 = "66666666-6666-6666-6666-666666666666"
            user_assigned_identity_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/MC_n8ntest-rg_n8ntest-aks_eastus/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ingressapplicationgateway-n8ntest-aks"
          }
        ]
      }
    }
  }

  override_resource {
    target = azurerm_postgresql_flexible_server.n8n
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/n8ntest-postgres"
    }
  }

  override_resource {
    target = azurerm_redis_cache.n8n
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Cache/redis/n8ntest-redis"
    }
  }

  override_resource {
    target = azurerm_storage_account.n8n
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8ntestn8nfiles"
    }
  }

  override_resource {
    target = azurerm_application_gateway.n8n
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGateways/n8ntest-appgw"
    }
  }

  # WAF policy `id` is consumed by `azurerm_application_gateway.n8n.firewall_policy_id`,
  # which the azurerm provider validates as a fully-qualified Azure
  # resource ID at apply time. Mirrors the App Gateway / Storage Account
  # pattern above.
  override_resource {
    target = azurerm_web_application_firewall_policy.appgw
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/n8ntest-appgw-waf-policy"
    }
  }

  override_resource {
    target = azurerm_private_dns_zone.postgres
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
    }
  }

  override_resource {
    target = azurerm_private_dns_zone.redis
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/privateDnsZones/privatelink.redis.cache.windows.net"
    }
  }

  override_resource {
    target = azurerm_user_assigned_identity.appgw_tls_cert
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-appgw-tls"
    }
  }

  # The n8n_workload UAMI's `id` is consumed by
  # `azurerm_federated_identity_credential.n8n_workload.parent_id`
  # (US-023, declared in iam.tf), which validates `parent_id` as an Azure
  # resource ID at apply time. Pin a synthetic resource-ID-shaped value
  # so the federated credential resource compiles cleanly under
  # `mock_provider "azurerm"`.
  override_resource {
    target = azurerm_user_assigned_identity.n8n_workload
    values = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ntest-n8n-workload"
    }
  }

  # ── AKS contract (US-015) ──────────────────────────────────────────────────
  assert {
    condition     = output.aks_cluster_id != null
    error_message = "output.aks_cluster_id must be non-null."
  }

  assert {
    condition     = output.aks_cluster_name != null
    error_message = "output.aks_cluster_name must be non-null."
  }

  assert {
    condition     = nonsensitive(output.aks_kube_config) != null
    error_message = "output.aks_kube_config must be non-null."
  }

  assert {
    condition     = output.aks_oidc_issuer_url != null
    error_message = "output.aks_oidc_issuer_url must be non-null."
  }

  assert {
    condition     = nonsensitive(output.n8n_workload_uami_client_id) != null
    error_message = "output.n8n_workload_uami_client_id must be non-null."
  }

  assert {
    condition     = nonsensitive(output.n8n_workload_uami_principal_id) != null
    error_message = "output.n8n_workload_uami_principal_id must be non-null."
  }

  # ── Postgres contract (US-016) ─────────────────────────────────────────────
  assert {
    condition     = output.postgres_fqdn != null
    error_message = "output.postgres_fqdn must be non-null."
  }

  assert {
    condition     = nonsensitive(output.postgres_admin_username) != null
    error_message = "output.postgres_admin_username must be non-null."
  }

  assert {
    condition     = nonsensitive(output.postgres_admin_password) != null
    error_message = "output.postgres_admin_password must be non-null."
  }

  assert {
    condition     = output.postgres_database_name != null
    error_message = "output.postgres_database_name must be non-null."
  }

  # ── Redis contract (US-017) ────────────────────────────────────────────────
  assert {
    condition     = output.redis_hostname != null
    error_message = "output.redis_hostname must be non-null."
  }

  assert {
    condition     = output.redis_ssl_port != null
    error_message = "output.redis_ssl_port must be non-null."
  }

  assert {
    condition     = nonsensitive(output.redis_primary_access_key) != null
    error_message = "output.redis_primary_access_key must be non-null."
  }

  # ── Storage contract (US-018) ──────────────────────────────────────────────
  assert {
    condition     = output.storage_account_name != null
    error_message = "output.storage_account_name must be non-null."
  }

  assert {
    condition     = nonsensitive(output.storage_account_primary_access_key) != null
    error_message = "output.storage_account_primary_access_key must be non-null."
  }

  assert {
    condition     = output.storage_share_name != null
    error_message = "output.storage_share_name must be non-null."
  }

  # ── App Gateway + Key Vault contract (US-019) ──────────────────────────────
  assert {
    condition     = output.app_gateway_id != null
    error_message = "output.app_gateway_id must be non-null."
  }

  assert {
    condition     = output.appgw_public_ip_address != null
    error_message = "output.appgw_public_ip_address must be non-null."
  }

  assert {
    condition     = output.appgw_fqdn != null
    error_message = "output.appgw_fqdn must be non-null."
  }

  # `key_vault_id` is a passthrough of var.app_gateway_keyvault_id which is
  # set above; `key_vault_uri` is resolved via the `data.azurerm_key_vault.byo`
  # data source whose `vault_uri` is computed under `mock_provider "azurerm"`
  # — but that's a DATA-source-side computed attribute, and the existing
  # `appgw_keyvault_on_branch` run already exercises this branch and the
  # data source materialises with computed-but-non-null fields under mocks,
  # so no override is needed here.
  assert {
    condition     = output.key_vault_id != null
    error_message = "output.key_vault_id must be non-null when var.app_gateway_keyvault_id is set."
  }

  assert {
    condition     = output.key_vault_uri != null
    error_message = "output.key_vault_uri must be non-null when var.app_gateway_keyvault_id is set."
  }
}
