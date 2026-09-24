# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Offline fixtures for tests/scripts/check-n8n-chart.sh. The script reads the
# planned helm_release.n8n.values attribute from Terraform's verbose JSON test
# output, so these runs exercise the exact value assembled in n8n.tf.

mock_provider "azurerm" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "kubectl" {}

override_data {
  target = data.azurerm_resource_group.n8n
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg"
  }
}

override_data {
  target = data.azurerm_kubernetes_cluster.existing[0]
  values = {
    id              = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.ContainerService/managedClusters/n8ntest-aks"
    oidc_issuer_url = "https://oidc.example.invalid/"
    kube_config = [{
      host                   = "https://aks.example.invalid"
      client_certificate     = "test-certificate"
      client_key             = "test-key"
      cluster_ca_certificate = "test-ca"
      password               = "test-password"
      username               = "test-user"
    }]
  }
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

variables {
  location                                     = "eastus"
  resource_group_name                          = "n8ntest-rg"
  friendly_name_prefix                         = "n8ntest"
  vnet_id                                      = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet"
  aks_subnet_id                                = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/aks"
  postgres_subnet_id                           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/postgres"
  redis_subnet_id                              = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/redis"
  appgw_subnet_id                              = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/appgw"
  private_endpoint_subnet_id                   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/pe"
  n8n_domain                                   = "n8n.test.example.com"
  app_gateway_tls_cert_secret_id               = "https://n8ntest-shared-kv.vault.azure.net/secrets/n8n-tls-cert/abc123"
  n8n_license_key                              = null
  n8n_license_key_secret_ref                   = { name = "test-license", key = "license-key" }
  n8n_encryption_key_secret_ref                = { name = "test-core", key = "N8N_ENCRYPTION_KEY" }
  create_aks                                   = false
  existing_aks_cluster_name                    = "n8ntest-aks"
  existing_aks_resource_group_name             = "n8ntest-rg"
  existing_aks_cluster_prerequisites_confirmed = true
  create_ingress                               = false
  create_database                              = false
  postgres_external_host                       = "test-db.example.invalid"
  postgres_external_username                   = "n8n"
  postgres_external_password                   = null
  postgres_password_secret_ref                 = { name = "test-db", key = "password" }
  create_redis                                 = false
  redis_external_host                          = "test-redis.example.invalid"
  create_blob_storage                          = false
  existing_blob_storage_account_name           = "n8nteststorage"
  existing_blob_container_name                 = "n8n-data"
  existing_blob_container_id                   = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Storage/storageAccounts/n8nteststorage/blobServices/default/containers/n8n-data"
  existing_blob_endpoint                       = "https://n8nteststorage.blob.core.windows.net/"
  existing_blob_prerequisites_confirmed        = true
}

run "multi_main" {
  command = plan

  assert {
    condition = { for env in yamldecode(helm_release.n8n.values[0]).webhookProcessor.extraEnv : env.name => env.value } == {
      EXECUTIONS_DATA_SAVE_ON_SUCCESS        = "all"
      EXECUTIONS_DATA_SAVE_ON_ERROR          = "all"
      EXECUTIONS_DATA_SAVE_ON_PROGRESS       = "false"
      EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS = "true"
    }
    error_message = "Webhook processors must receive the default execution-save policies."
  }
}

run "single_main" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
    n8n_main_hpa_max_replicas = 20
  }
}

run "pg_runtime" {
  command = plan

  variables {
    postgres_connection_timeout_ms             = 45000
    postgres_ping_timeout_ms                   = 15000
    postgres_ping_interval_seconds             = 5
    postgres_ping_max_failures_before_recovery = 6
  }
}

run "worker_timing" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration    = 90000
    n8n_queue_worker_lock_renew_time  = 15000
    n8n_queue_worker_stalled_interval = 45000
  }
}

run "save_policy" {
  command = plan

  variables {
    n8n_executions_data_save_on_success        = "none"
    n8n_executions_data_save_on_error          = "all"
    n8n_executions_data_save_on_progress       = true
    n8n_executions_data_save_manual_executions = false
  }

  assert {
    condition = { for env in yamldecode(helm_release.n8n.values[0]).webhookProcessor.extraEnv : env.name => env.value } == {
      EXECUTIONS_DATA_SAVE_ON_SUCCESS        = "none"
      EXECUTIONS_DATA_SAVE_ON_ERROR          = "all"
      EXECUTIONS_DATA_SAVE_ON_PROGRESS       = "true"
      EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS = "false"
    }
    error_message = "Webhook processors must receive independent save policies and stringified booleans."
  }
}

run "save_policy_inverse" {
  command = plan

  variables {
    n8n_executions_data_save_on_success        = "all"
    n8n_executions_data_save_on_error          = "none"
    n8n_executions_data_save_on_progress       = false
    n8n_executions_data_save_manual_executions = true
  }

  assert {
    condition = { for env in yamldecode(helm_release.n8n.values[0]).webhookProcessor.extraEnv : env.name => env.value } == {
      EXECUTIONS_DATA_SAVE_ON_SUCCESS        = "all"
      EXECUTIONS_DATA_SAVE_ON_ERROR          = "none"
      EXECUTIONS_DATA_SAVE_ON_PROGRESS       = "false"
      EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS = "true"
    }
    error_message = "Webhook error retention must vary independently from success retention."
  }
}

run "heap" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 768
  }
}

run "task_runner_config" {
  command = plan

  variables {
    n8n_task_runner_custom_config = {
      config_map_name = "n8n-task-runner-launcher"
    }
  }
}

# Rendered by check-n8n-chart.sh as scaledobject-worker: the chart turns these
# into autoscaling.keda.sh/paused and paused-replicas annotations. 0 is the
# scale-to-zero case the chart guards against Go's falsy zero.
run "worker_pause" {
  command = plan

  variables {
    n8n_worker_keda_pause                = true
    n8n_worker_keda_paused_replica_count = 0
  }

  assert {
    condition     = yamldecode(helm_release.n8n.values[0]).keda.worker.pause == true && yamldecode(helm_release.n8n.values[0]).keda.worker.pausedReplicaCount == 0
    error_message = "keda.worker.pause and pausedReplicaCount must carry the module inputs."
  }
}

run "dns" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["10.0.0.10"]
      searches    = ["svc.cluster.local"]
      options     = [{ name = "ndots", value = "1" }, { name = "edns0" }]
    }
  }
}

run "split_url" {
  command = plan

  variables {
    n8n_webhook_url = "https://hooks.test.example.com:8443/n8n/"
  }
}

# Worker-only environment (port-aws-050-enhancements section 2). The chart
# renders queueMode.workerExtraEnv on the worker container only, so
# check-n8n-chart.sh asserts both presence on deployment-worker and absence on
# deployment-main and deployment-webhook-processor.
run "worker_extra_env" {
  command = plan

  variables {
    n8n_worker_extra_env = [
      { name = "N8N_WORKER_ONLY_SETTING", value = "worker-only" },
    ]
  }
}

# Worker pools (port-aws-050-enhancements section 7, early alpha). The
# file-level fixture is already the unauthenticated external-Redis path
# (TLS on, the module default), which is exactly where a pool's keda block must omit
# authenticationRef: the chart schema puts minLength 1 on
# workerGroups[].keda.authenticationRef.name and an empty string fails the
# render. check-n8n-chart.sh renders this against the preview chart build
# (the pinned default chart predates queueMode.workerGroups) and asserts on
# the pool Deployment and ScaledObject.
run "worker_pools" {
  command = plan

  variables {
    n8n_chart_version = "1.11.0-preview.workerpools.1"
    n8n_image_tag     = "2.39.0"
    n8n_worker_pools = [
      { name = "gpu", min_replicas = 0, max_replicas = 3, concurrency = 2 },
    ]
  }
}

# Same pool on an authenticated Redis: the pool's authenticationRef must name
# the module's TriggerAuthentication, matching the default worker's triggers.
run "worker_pools_authenticated" {
  command = plan

  variables {
    n8n_chart_version       = "1.11.0-preview.workerpools.1"
    n8n_image_tag           = "2.39.0"
    redis_external_username = "n8n-queue"
    redis_external_password = "not-a-real-password"
    n8n_worker_pools = [
      { name = "gpu", min_replicas = 0, max_replicas = 3, concurrency = 2 },
    ]
  }
}
