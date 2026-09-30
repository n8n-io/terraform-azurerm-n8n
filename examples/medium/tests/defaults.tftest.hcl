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
  friendly_name_prefix = "n8nmedium"
  n8n_domain           = "n8n.test.example.com"
  public_dns_zone_name = "test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "medium_tier_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nmedium-tls-test.vault.azure.net/secrets/n8nmedium-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = azurerm_subnet.aks.address_prefixes[0] == "10.0.0.0/20"
    error_message = "The medium AKS subnet must preserve its documented /20 address space."
  }

  assert {
    condition = output.tier_configuration == {
      aks_node_vm_size             = "Standard_D8s_v5"
      aks_node_count_min           = 3
      aks_node_count_max           = 10
      aks_sku_tier                 = "Standard"
      pg_sku_name                  = "GP_Standard_D4s_v3"
      pg_storage_mb                = 131072
      pg_storage_auto_grow_enabled = true
      pg_backup_retention_days     = 14
      redis_sku_name               = "Balanced_B5"
      storage_replication_type     = "ZRS"
      main_min_replicas            = 3
      main_max_replicas            = 16
      webhook_min_replicas         = 4
      webhook_max_replicas         = 24
      worker_min_replicas          = 4
      worker_max_replicas          = 30
      worker_concurrency           = 20
      appgw_autoscale_min_capacity = 2
      appgw_autoscale_max_capacity = 10
    }
    error_message = "The medium example must preserve its documented root-module sizing decisions."
  }

  assert {
    condition     = output.tier_configuration.pg_backup_retention_days == 14
    error_message = "The default pg_backup_retention_days (14) must reach the module n8n call unchanged."
  }

  assert {
    condition     = output.tier_configuration.pg_storage_auto_grow_enabled == true
    error_message = "pg_storage_auto_grow_enabled (true) must reach the module n8n call unchanged."
  }

  assert {
    condition     = output.blob_delete_retention_days == null
    error_message = "The default blob_delete_retention_days (null) must reach the module n8n call unchanged."
  }

  # A clean plan also proves the root capacity check accepts the 67,700m of
  # requested CPU against about 150,380m of modeled supply.
}

run "medium_tier_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nmedium-tls-test.vault.azure.net/secrets/n8nmedium-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = output.tier_configuration.main_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition     = output.tier_configuration.webhook_max_replicas == 24
    error_message = "Selecting single-main must not change unrelated webhook sizing."
  }
}

run "medium_tier_pg_backup_retention_override" {
  command = plan

  variables {
    pg_backup_retention_days = 21
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nmedium-tls-test.vault.azure.net/secrets/n8nmedium-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = output.tier_configuration.pg_backup_retention_days == 21
    error_message = "Setting pg_backup_retention_days must pass the override through to the module n8n call unchanged."
  }
}

run "medium_tier_blob_delete_retention_override" {
  command = plan

  variables {
    blob_delete_retention_days = 30
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nmedium-tls-test.vault.azure.net/secrets/n8nmedium-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = output.blob_delete_retention_days == 30
    error_message = "Setting blob_delete_retention_days must pass the override through to the module n8n call unchanged."
  }
}
