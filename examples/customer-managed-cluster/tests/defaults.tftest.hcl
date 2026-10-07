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
    id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg"
  }
}

variables {
  friendly_name_prefix = "n8ncmc"
  n8n_domain           = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "customer_managed_cluster_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncmc-tls-test.vault.azure.net/secrets/n8ncmc-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.n8n
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.Network/applicationGateways/n8ncmc-appgw"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_tls_cert
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncmc-appgw-tls"
    }
  }

  override_resource {
    target          = azurerm_kubernetes_cluster.existing
    override_during = plan
    values = {
      id              = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.ContainerService/managedClusters/n8ncmc-shared-aks"
      oidc_issuer_url = "https://oidc.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/"
      kube_config = [{
        host                   = "https://n8ncmc-shared-aks.hcp.eastus.azmk8s.io:443"
        client_certificate     = "ZmFrZS1jZXJ0"
        client_key             = "ZmFrZS1rZXk="
        cluster_ca_certificate = "ZmFrZS1jYQ=="
        password               = "fake-password"
        username               = "fake-username"
      }]
    }
  }

  # The whole point of this example: the module targets the caller-owned
  # stand-in cluster instead of creating its own AKS.
  assert {
    condition     = module.n8n.aks_cluster_name == azurerm_kubernetes_cluster.existing.name
    error_message = "The module's effective AKS cluster must resolve to the caller-owned stand-in, not a module-created cluster."
  }

  # module.n8n.aks_oidc_issuer_url itself is not asserted here: it flows
  # from the module's own data.azurerm_kubernetes_cluster.existing lookup,
  # which Terraform defers to apply time whenever it depends on a resource
  # with pending changes (this example's own stand-in cluster) — the same
  # "will be read during apply" behavior a real first apply against a
  # brand-new stand-in would show. The federation assertion below proves
  # the same effective-issuer wiring using a value this test CAN observe
  # at plan time: the override on azurerm_kubernetes_cluster.existing
  # itself.
  assert {
    condition     = azurerm_kubernetes_cluster.existing.oidc_issuer_enabled == true && azurerm_kubernetes_cluster.existing.workload_identity_enabled == true
    error_message = "The caller-owned stand-in cluster must enable OIDC issuer and workload identity, matching this example's existing_aks_cluster_prerequisites_confirmed attestation."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.existing.default_node_pool[0].upgrade_settings[0].max_surge == "10%"
    error_message = "The caller-owned AKS stand-in must declare Azure's default upgrade surge to remain idempotent after creation."
  }

  assert {
    condition     = azurerm_application_gateway.n8n.frontend_ip_configuration[0].name == "n8n-frontend-ip"
    error_message = "This example's own standalone Application Gateway must declare its public frontend, since create_ingress = false leaves the module with no gateway of its own."
  }

  assert {
    condition     = azurerm_federated_identity_credential.agic.issuer == azurerm_kubernetes_cluster.existing.oidc_issuer_url
    error_message = "The standalone AGIC identity must federate against the caller-owned cluster's own OIDC issuer."
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
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      length([
        for p in kubernetes_ingress_v1.n8n.spec[0].rule[0].http[0].path :
        p if p.path == prefix && p.backend[0].service[0].name == "n8n-webhook-processor"
      ]) == 1
    ])
    error_message = "The Ingress must route every webhook prefix to the webhook processor Service."
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

  assert {
    condition = one([
      for p in kubernetes_ingress_v1.n8n.spec[0].rule[0].http[0].path :
      p.backend[0].service[0].name if p.path == "/"
    ]) == "n8n-main"
    error_message = "The Ingress catch-all must route to the main Service."
  }

  assert {
    condition     = output.pg_backup_retention_days == 7
    error_message = "The default pg_backup_retention_days (7) must pass through to the root module unchanged."
  }

  assert {
    condition     = output.blob_delete_retention_days == null
    error_message = "The default blob_delete_retention_days (null) must pass through to the root module unchanged."
  }

  # PostgreSQL, Redis, and Blob remain module-managed in this example — the
  # module call in main.tf sets no create_database, create_redis, or
  # create_blob_storage override, so all three keep their true defaults.
}

run "customer_managed_cluster_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncmc-tls-test.vault.azure.net/secrets/n8ncmc-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.n8n
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.Network/applicationGateways/n8ncmc-appgw"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_tls_cert
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncmc-appgw-tls"
    }
  }

  override_resource {
    target          = azurerm_kubernetes_cluster.existing
    override_during = plan
    values = {
      id              = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.ContainerService/managedClusters/n8ncmc-shared-aks"
      oidc_issuer_url = "https://oidc.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/"
      kube_config = [{
        host                   = "https://n8ncmc-shared-aks.hcp.eastus.azmk8s.io:443"
        client_certificate     = "ZmFrZS1jZXJ0"
        client_key             = "ZmFrZS1rZXk="
        cluster_ca_certificate = "ZmFrZS1jYQ=="
        password               = "fake-password"
        username               = "fake-username"
      }]
    }
  }

  assert {
    condition     = output.main_hpa_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition     = module.n8n.aks_cluster_name == azurerm_kubernetes_cluster.existing.name
    error_message = "Selecting single-main must not change the caller-owned AKS targeting."
  }
}

run "customer_managed_cluster_retention_overrides" {
  command = plan

  variables {
    pg_backup_retention_days   = 14
    blob_delete_retention_days = 30
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8ncmc-tls-test.vault.azure.net/secrets/n8ncmc-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.n8n
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.Network/applicationGateways/n8ncmc-appgw"
    }
  }

  override_resource {
    target          = azurerm_user_assigned_identity.n8n_tls_cert
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/n8ncmc-appgw-tls"
    }
  }

  override_resource {
    target          = azurerm_kubernetes_cluster.existing
    override_during = plan
    values = {
      id              = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8ncmc-n8n-rg/providers/Microsoft.ContainerService/managedClusters/n8ncmc-shared-aks"
      oidc_issuer_url = "https://oidc.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/"
      kube_config = [{
        host                   = "https://n8ncmc-shared-aks.hcp.eastus.azmk8s.io:443"
        client_certificate     = "ZmFrZS1jZXJ0"
        client_key             = "ZmFrZS1rZXk="
        cluster_ca_certificate = "ZmFrZS1jYQ=="
        password               = "fake-password"
        username               = "fake-username"
      }]
    }
  }

  assert {
    condition     = output.pg_backup_retention_days == 14
    error_message = "An explicit pg_backup_retention_days override must pass through to the root module unchanged."
  }

  assert {
    condition     = output.blob_delete_retention_days == 30
    error_message = "An explicit blob_delete_retention_days override must pass through to the root module unchanged."
  }
}
