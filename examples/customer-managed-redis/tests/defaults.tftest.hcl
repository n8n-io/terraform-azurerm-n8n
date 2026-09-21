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
  friendly_name_prefix = "n8ncmr"
  n8n_domain           = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "customer_managed_redis_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncmr-tls-test.vault.azure.net/secrets/n8ncmr-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_managed_redis.existing
    override_during = plan
    values = {
      id       = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmr-n8n-rg/providers/Microsoft.Cache/redisEnterprise/n8ncmr-shared-redis"
      hostname = "n8ncmr-shared-redis.eastus.redis.azure.net"
      default_database = {
        clustering_policy                  = "NoCluster"
        client_protocol                    = "Encrypted"
        access_keys_authentication_enabled = true
        port                               = 10000
        primary_access_key                 = "fake-primary-access-key"
        secondary_access_key               = "fake-secondary-access-key"
      }
    }
  }

  # The whole point of this example: the module points at the caller-owned
  # Redis stand-in instead of creating its own Azure Managed Redis instance.
  assert {
    condition     = module.n8n.redis_hostname == azurerm_managed_redis.existing.hostname
    error_message = "The module's effective Redis hostname must resolve to the caller-owned stand-in, not a module-created instance."
  }

  assert {
    condition     = module.n8n.redis_primary_access_key == null
    error_message = "The module must never surface a Redis password value for the caller-managed Secret path; Terraform does not read the referenced Secret."
  }

  assert {
    condition     = kubernetes_secret.redis_password.metadata[0].namespace == module.n8n.n8n_namespace
    error_message = "The caller-managed Redis password Secret must live in the module-managed n8n namespace."
  }

  assert {
    condition     = kubernetes_secret.redis_password.data["password"] == azurerm_managed_redis.existing.default_database[0].primary_access_key
    error_message = "The caller-managed Secret must carry the caller-owned Redis instance's own access key, not a value the module generated."
  }

  assert {
    condition     = output.pg_backup_retention_days == 7
    error_message = "The default pg_backup_retention_days (7) must reach the module n8n call unchanged."
  }

  assert {
    condition     = output.blob_delete_retention_days == null
    error_message = "The default blob_delete_retention_days (null) must reach the module n8n call unchanged."
  }
}

run "customer_managed_redis_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncmr-tls-test.vault.azure.net/secrets/n8ncmr-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_managed_redis.existing
    override_during = plan
    values = {
      id       = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmr-n8n-rg/providers/Microsoft.Cache/redisEnterprise/n8ncmr-shared-redis"
      hostname = "n8ncmr-shared-redis.eastus.redis.azure.net"
      default_database = {
        clustering_policy                  = "NoCluster"
        client_protocol                    = "Encrypted"
        access_keys_authentication_enabled = true
        port                               = 10000
        primary_access_key                 = "fake-primary-access-key"
        secondary_access_key               = "fake-secondary-access-key"
      }
    }
  }

  assert {
    condition     = output.main_hpa_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition     = module.n8n.redis_hostname == azurerm_managed_redis.existing.hostname
    error_message = "Selecting single-main must not change the caller-owned Redis targeting."
  }
}

run "customer_managed_redis_retention_overrides" {
  command = plan

  variables {
    pg_backup_retention_days   = 20
    blob_delete_retention_days = 14
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncmr-tls-test.vault.azure.net/secrets/n8ncmr-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_managed_redis.existing
    override_during = plan
    values = {
      id       = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmr-n8n-rg/providers/Microsoft.Cache/redisEnterprise/n8ncmr-shared-redis"
      hostname = "n8ncmr-shared-redis.eastus.redis.azure.net"
      default_database = {
        clustering_policy                  = "NoCluster"
        client_protocol                    = "Encrypted"
        access_keys_authentication_enabled = true
        port                               = 10000
        primary_access_key                 = "fake-primary-access-key"
        secondary_access_key               = "fake-secondary-access-key"
      }
    }
  }

  assert {
    condition     = output.pg_backup_retention_days == 20
    error_message = "Overriding pg_backup_retention_days must pass the new value through to the module n8n call."
  }

  assert {
    condition     = output.blob_delete_retention_days == 14
    error_message = "Overriding blob_delete_retention_days must pass the new value through to the module n8n call."
  }
}
