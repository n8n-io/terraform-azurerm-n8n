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
  friendly_name_prefix = "n8nsmall"
  n8n_domain           = "n8n.test.example.com"
  public_dns_zone_name = "test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "small_tier_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsmall-tls-test.vault.azure.net/secrets/n8nsmall-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = azurerm_subnet.aks.address_prefixes[0] == "10.0.0.0/21"
    error_message = "The small AKS subnet must preserve its documented /21 address space."
  }

  assert {
    condition     = azurerm_subnet.postgres.delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "The PostgreSQL subnet must carry the Flexible Server delegation."
  }

  assert {
    condition     = azurerm_subnet.redis.private_endpoint_network_policies == "Disabled" && azurerm_subnet.private_endpoints.private_endpoint_network_policies == "Disabled"
    error_message = "Both private-endpoint subnets must disable private endpoint network policies."
  }

  assert {
    condition = output.tier_configuration == {
      aks_node_vm_size         = "Standard_D2s_v5"
      aks_availability_zones   = tolist(["1", "2", "3"])
      aks_node_count_min       = 2
      aks_node_count_max       = 6
      pg_sku_name              = "GP_Standard_D2s_v3"
      pg_storage_mb            = 32768
      redis_sku_name           = "Balanced_B0"
      storage_replication_type = "LRS"
      webhook_max_replicas     = 8
      main_min_replicas        = 2
    }
    error_message = "The small example must preserve its documented root-module sizing decisions."
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "The root module URL output must preserve the canonical domain."
  }
}

run "small_tier_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsmall-tls-test.vault.azure.net/secrets/n8nsmall-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = output.tier_configuration.main_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "Unrelated example settings must remain unchanged when selecting single-main."
  }
}
