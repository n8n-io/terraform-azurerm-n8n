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

override_data {
  target = data.azurerm_resource_group.n8n
  values = {
    id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg"
  }
}

variables {
  friendly_name_prefix    = "n8ncme"
  n8n_domain              = "n8n.test.example.com"
  n8n_license_key         = "test-license-key-not-real"
  postgres_admin_password = "test-password-not-real-12345"
}

run "customer_managed_everything_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncme-tls-test.vault.azure.net/secrets/n8ncme-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.n8n
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Network/applicationGateways/n8ncme-appgw"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_tls_cert
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncme-appgw-tls"
    }
  }

  override_resource {
    target          = azurerm_kubernetes_cluster.existing
    override_during = plan
    values = {
      oidc_issuer_url = "https://oidc.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/"
      kube_config = [{
        host                   = "https://n8ncme-shared-aks.hcp.eastus.azmk8s.io:443"
        client_certificate     = "ZmFrZS1jZXJ0"
        client_key             = "ZmFrZS1rZXk="
        cluster_ca_certificate = "ZmFrZS1jYQ=="
        password               = "fake-password"
        username               = "fake-username"
      }]
    }
  }

  override_resource {
    target          = azurerm_postgresql_flexible_server.existing
    override_during = plan
    values = {
      id   = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/n8ncme-shared-pg"
      fqdn = "n8ncme-shared-pg.postgres.database.azure.com"
    }
  }

  override_resource {
    target          = azurerm_managed_redis.existing
    override_during = plan
    values = {
      id       = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Cache/redisEnterprise/n8ncme-shared-redis"
      hostname = "n8ncme-shared-redis.eastus.redis.azure.net"
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

  override_resource {
    target          = random_string.storage_suffix
    override_during = plan
    values = {
      result = "abcdef"
    }
  }

  override_resource {
    target          = azurerm_storage_account.existing
    override_during = plan
    values = {
      id                    = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmestabcdef"
      primary_blob_endpoint = "https://n8ncmestabcdef.blob.core.windows.net/"
    }
  }

  override_resource {
    target          = azurerm_storage_container.existing
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmestabcdef/blobServices/default/containers/n8n-data"
    }
  }

  override_resource {
    target          = module.n8n.azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncme-workload"
      client_id    = "44444444-4444-4444-4444-444444444444"
      principal_id = "55555555-5555-5555-5555-555555555555"
    }
  }

  # Every ownership boundary resolves to the caller-owned stand-in, not a
  # module-created resource.
  assert {
    condition     = module.n8n.aks_cluster_name == azurerm_kubernetes_cluster.existing.name
    error_message = "The module's effective AKS cluster must resolve to the caller-owned stand-in."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.existing.default_node_pool[0].upgrade_settings[0].max_surge == "10%"
    error_message = "The caller-owned AKS stand-in must declare Azure's default upgrade surge to remain idempotent after creation."
  }

  assert {
    condition     = module.n8n.postgres_fqdn == azurerm_postgresql_flexible_server.existing.fqdn
    error_message = "The module's effective PostgreSQL host must resolve to the caller-owned external server."
  }

  assert {
    condition     = module.n8n.redis_hostname == azurerm_managed_redis.existing.hostname
    error_message = "The module's effective Redis hostname must resolve to the caller-owned external instance."
  }

  assert {
    condition     = module.n8n.storage_account_name == azurerm_storage_account.existing.name
    error_message = "The module's effective storage account must resolve to the caller-owned account."
  }

  assert {
    condition     = module.n8n.n8n_namespace == kubernetes_namespace.n8n.metadata[0].name
    error_message = "The module's effective namespace must resolve to the caller-created namespace."
  }

  assert {
    condition     = module.n8n.postgres_admin_password == null
    error_message = "The module must never surface a PostgreSQL password value on the external + Secret-reference path."
  }

  assert {
    condition     = module.n8n.redis_primary_access_key == null
    error_message = "The module must never surface a Redis password value on the external + Secret-reference path."
  }

  assert {
    condition     = module.n8n.n8n_encryption_key == null
    error_message = "The module must never surface an encryption key value when n8n_encryption_key_secret_ref selects a caller-managed Secret."
  }

  # Direct modules/controllers composition and ordering.
  assert {
    condition     = module.controllers.keda_namespace == local.keda_namespace
    error_message = "The direct modules/controllers call must install KEDA into the configured namespace."
  }

  # Caller-owned ingress and webhook HPA exist; the module creates neither.
  assert {
    condition     = azurerm_application_gateway.n8n.frontend_ip_configuration[0].name == "n8n-frontend-ip"
    error_message = "This example's own standalone Application Gateway must declare its public frontend, since create_ingress = false leaves the module with no gateway of its own."
  }

  assert {
    condition     = azurerm_federated_identity_credential.agic.subject == "system:serviceaccount:agic:agic-sa-ingress-azure"
    error_message = "The standalone AGIC identity must federate the service account created by ingress-azure chart 1.7.5."
  }

  assert {
    condition     = azurerm_role_assignment.agic_tls_identity_operator.scope == azurerm_user_assigned_identity.n8n_tls_cert.id && azurerm_role_assignment.agic_tls_identity_operator.role_definition_name == "Managed Identity Operator"
    error_message = "AGIC must be able to reattach the gateway TLS identity when it reconciles the caller-owned Application Gateway."
  }

  assert {
    condition = (
      kubernetes_ingress_v1.n8n.spec[0].ingress_class_name == "azure-application-gateway" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/appgw-ssl-certificate"] == "appgw-ssl-cert" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/ssl-redirect"] == "true" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/backend-protocol"] == "http" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/request-timeout"] == "300" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/connection-draining"] == "true" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/connection-draining-timeout"] == "30" &&
      kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/cookie-based-affinity"] == "true"
    )
    error_message = "The caller-owned Ingress must select AGIC, preserve the gateway TLS and HTTP-backend contract, and match the root module's request timeout, connection draining, and cookie-based affinity defaults."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook.spec[0].max_replicas == 8
    error_message = "The caller-owned webhook HPA must exist and target the webhook-processor Deployment, since n8n_webhook_hpa_enabled = false leaves the module without one of its own."
  }

  assert {
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      length([
        for p in kubernetes_ingress_v1.n8n.spec[0].rule[0].http[0].path :
        p if p.path == prefix && p.backend[0].service[0].name == "n8n-webhook-processor"
      ]) == 1
    ])
    error_message = "The caller-owned Ingress must route every webhook prefix to the webhook processor Service."
  }

  # Test-mode prefixes must precede the production prefixes and target main:
  # Application Gateway evaluates string-prefix rules in declared order.
  assert {
    condition = (
      slice([for p in kubernetes_ingress_v1.n8n.spec[0].rule[0].http[0].path : p.path], 0, 3) == ["/webhook-test", "/form-test", "/mcp-test"] &&
      alltrue([for p in slice(kubernetes_ingress_v1.n8n.spec[0].rule[0].http[0].path, 0, 3) : p.backend[0].service[0].name == "n8n-main"])
    )
    error_message = "The Ingress must route the three editor test-mode prefixes to the main Service ahead of the production webhook prefixes."
  }
}

run "customer_managed_everything_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncme-tls-test.vault.azure.net/secrets/n8ncme-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.n8n
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Network/applicationGateways/n8ncme-appgw"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_tls_cert
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncme-appgw-tls"
    }
  }

  override_resource {
    target          = azurerm_kubernetes_cluster.existing
    override_during = plan
    values = {
      oidc_issuer_url = "https://oidc.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/"
      kube_config = [{
        host                   = "https://n8ncme-shared-aks.hcp.eastus.azmk8s.io:443"
        client_certificate     = "ZmFrZS1jZXJ0"
        client_key             = "ZmFrZS1rZXk="
        cluster_ca_certificate = "ZmFrZS1jYQ=="
        password               = "fake-password"
        username               = "fake-username"
      }]
    }
  }

  override_resource {
    target          = azurerm_postgresql_flexible_server.existing
    override_during = plan
    values = {
      id   = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/n8ncme-shared-pg"
      fqdn = "n8ncme-shared-pg.postgres.database.azure.com"
    }
  }

  override_resource {
    target          = azurerm_managed_redis.existing
    override_during = plan
    values = {
      id       = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Cache/redisEnterprise/n8ncme-shared-redis"
      hostname = "n8ncme-shared-redis.eastus.redis.azure.net"
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

  override_resource {
    target          = random_string.storage_suffix
    override_during = plan
    values = {
      result = "abcdef"
    }
  }

  override_resource {
    target          = azurerm_storage_account.existing
    override_during = plan
    values = {
      id                    = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmestabcdef"
      primary_blob_endpoint = "https://n8ncmestabcdef.blob.core.windows.net/"
    }
  }

  override_resource {
    target          = azurerm_storage_container.existing
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.Storage/storageAccounts/n8ncmestabcdef/blobServices/default/containers/n8n-data"
    }
  }

  override_resource {
    target          = module.n8n.azurerm_user_assigned_identity.n8n_workload
    override_during = plan
    values = {
      id           = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncme-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncme-workload"
      client_id    = "44444444-4444-4444-4444-444444444444"
      principal_id = "55555555-5555-5555-5555-555555555555"
    }
  }

  assert {
    condition     = output.main_hpa_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition     = module.n8n.aks_cluster_name == azurerm_kubernetes_cluster.existing.name
    error_message = "Selecting single-main must not change any caller-owned resource targeting."
  }
}
