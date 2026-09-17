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
  friendly_name_prefix = "n8ncms"
  n8n_domain           = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "customer_managed_storage_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncms-tls-test.vault.azure.net/secrets/n8ncms-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = random_string.storage_suffix
    override_during = plan
    values = {
      result = "abcdef"
    }
  }

  override_resource {
    target          = azurerm_storage_container.existing
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncms-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmsstabcdef/blobServices/default/containers/n8n-data"
    }
  }

  override_resource {
    target          = azurerm_storage_account.existing
    override_during = plan
    values = {
      id                    = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncms-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmsstabcdef"
      primary_blob_endpoint = "https://n8ncmsstabcdef.blob.core.windows.net/"
    }
  }

  # The whole point of this example: the module targets the caller-owned
  # storage account and container instead of creating its own.
  assert {
    condition     = module.n8n.storage_account_name == azurerm_storage_account.existing.name
    error_message = "The module's effective storage account must resolve to the caller-owned account, not a module-created one."
  }

  assert {
    condition     = module.n8n.azure_blob_container_name == azurerm_storage_container.existing.name
    error_message = "The module's effective Blob container must resolve to the caller-owned container, not a module-created one."
  }
}

run "customer_managed_storage_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncms-tls-test.vault.azure.net/secrets/n8ncms-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = random_string.storage_suffix
    override_during = plan
    values = {
      result = "abcdef"
    }
  }

  override_resource {
    target          = azurerm_storage_container.existing
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncms-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmsstabcdef/blobServices/default/containers/n8n-data"
    }
  }

  override_resource {
    target          = azurerm_storage_account.existing
    override_during = plan
    values = {
      id                    = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncms-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmsstabcdef"
      primary_blob_endpoint = "https://n8ncmsstabcdef.blob.core.windows.net/"
    }
  }

  assert {
    condition     = output.main_hpa_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition     = module.n8n.storage_account_name == azurerm_storage_account.existing.name
    error_message = "Selecting single-main must not change the caller-owned storage targeting."
  }
}
