# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

mock_provider "azurerm" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

override_data {
  target = data.azurerm_client_config.current
  values = {
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    object_id       = "11111111-1111-1111-1111-111111111111"
    subscription_id = "22222222-2222-2222-2222-222222222222"
    client_id       = "33333333-3333-3333-3333-333333333333"
  }
}

variables {
  friendly_name_prefix = "n8nlarge"
  n8n_domain           = "n8n.test.example.com"
  public_dns_zone_name = "test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "large_tier_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nlarge-tls-test.vault.azure.net/secrets/n8nlarge-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = azurerm_virtual_network.n8n.address_space == toset(["10.0.0.0/15"]) && azurerm_subnet.aks.address_prefixes[0] == "10.0.0.0/18"
    error_message = "The large tier must retain its larger VNet and AKS subnet ranges."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.sku_name == "GP_Standard_D8s_v3" && azurerm_postgresql_flexible_server.n8n.storage_mb == 524288
    error_message = "The large PostgreSQL server must retain its documented compute and storage."
  }

  assert {
    condition     = azurerm_postgresql_flexible_server.n8n.high_availability[0].mode == "ZoneRedundant" && azurerm_postgresql_flexible_server.n8n.high_availability[0].standby_availability_zone == "2"
    error_message = "The large PostgreSQL server must use a zone-redundant standby in zone 2."
  }

  assert {
    condition     = module.n8n.postgres_fqdn == "pgbouncer.pgbouncer.svc.cluster.local"
    error_message = "The root module must use the external PostgreSQL contract through PgBouncer."
  }

  assert {
    condition     = kubernetes_deployment.pgbouncer.spec[0].replicas == "2"
    error_message = "PgBouncer must run two replicas."
  }

  assert {
    condition     = length(kubernetes_deployment.pgbouncer.spec[0].template[0].spec[0].affinity[0].pod_anti_affinity[0].required_during_scheduling_ignored_during_execution) == 1
    error_message = "PgBouncer replicas must use required node anti-affinity."
  }

  assert {
    condition     = kubernetes_pod_disruption_budget_v1.pgbouncer.spec[0].min_available == "1"
    error_message = "PgBouncer must keep one replica available during voluntary disruption."
  }

  assert {
    condition = output.tier_configuration == {
      aks_node_vm_size             = "Standard_D16s_v5"
      aks_node_count_min           = 5
      aks_node_count_max           = 20
      postgres_sku_name            = "GP_Standard_D8s_v3"
      postgres_storage_mb          = 524288
      postgres_zone_redundant      = true
      pgbouncer_replicas           = 2
      redis_sku_name               = "MemoryOptimized_M20"
      redis_high_availability      = true
      storage_replication_type     = "ZRS"
      private_blob_enabled         = true
      binary_data_storage_mode     = "azure"
      execution_data_storage_mode  = "azure"
      main_min_replicas            = 6
      main_max_replicas            = 60
      webhook_min_replicas         = 20
      webhook_max_replicas         = 80
      worker_min_replicas          = 20
      worker_max_replicas          = 160
      worker_concurrency           = 40
      appgw_autoscale_min_capacity = 2
      appgw_autoscale_max_capacity = 30
    }
    error_message = "The large example must preserve its documented root-module sizing and availability decisions."
  }
}
