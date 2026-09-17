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
    id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8nsplit-n8n-rg"
  }
}

variables {
  friendly_name_prefix = "n8nsplit"
  n8n_domain           = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "split_ingress_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed_admin.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplita-tls-test.vault.azure.net/secrets/n8nsplita-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = module.tls_self_signed_webhook.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplitw-tls-test.vault.azure.net/secrets/n8nsplitw-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.webhook
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8nsplit-n8n-rg/providers/Microsoft.Network/applicationGateways/n8nsplit-webhook-appgw"
    }
  }

  override_resource {
    target          = azurerm_application_gateway.admin
    override_during = plan
    values = {
      id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/n8nsplit-n8n-rg/providers/Microsoft.Network/applicationGateways/n8nsplit-admin-appgw"
    }
  }

  # The whole point of this example: module ingress disabled, two gateways
  # with opposite frontend modes, each serving a disjoint slice of traffic.

  assert {
    condition     = module.n8n.aks_cluster_name != null
    error_message = "The root module must still create AKS even though create_ingress is false."
  }

  assert {
    condition     = azurerm_application_gateway.webhook.frontend_ip_configuration[0].name == "webhook-frontend-ip"
    error_message = "The webhook Application Gateway must declare its public frontend."
  }

  assert {
    condition     = azurerm_application_gateway.admin.frontend_ip_configuration[0].name == "admin-frontend-ip"
    error_message = "The admin Application Gateway must declare its private, subnet-bound frontend."
  }

  # Every prefix n8n disables on the main pods must be on the public gateway,
  # and there must be no catch-all rule.
  assert {
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      contains([for p in kubernetes_ingress_v1.webhook_public.spec[0].rule[0].http[0].path : p.path], prefix)
    ])
    error_message = "The public Ingress must route all five webhook prefixes."
  }

  assert {
    condition = alltrue([
      for p in kubernetes_ingress_v1.webhook_public.spec[0].rule[0].http[0].path :
      p.backend[0].service[0].name == "n8n-webhook-processor"
    ])
    error_message = "Every path on the public Ingress must target the webhook processor Service."
  }

  assert {
    condition = !contains(
      [for p in kubernetes_ingress_v1.webhook_public.spec[0].rule[0].http[0].path : p.path],
      "/"
    )
    error_message = "The public Ingress must NOT have a catch-all / rule, which would expose the editor UI."
  }

  # The internal Ingress carries the webhook prefixes too, not just the
  # catch-all, or an in-VNet webhook delivery silently hits the editor SPA.
  assert {
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      length([
        for p in kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path :
        p if p.path == prefix && p.backend[0].service[0].name == "n8n-webhook-processor"
      ]) == 1
    ])
    error_message = "The internal Ingress must route the webhook prefixes to the webhook processor."
  }

  # Test-mode prefixes must precede the production prefixes and target main:
  # Application Gateway evaluates string-prefix rules in declared order.
  assert {
    condition = (
      slice([for p in kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path : p.path], 0, 3) == ["/webhook-test", "/form-test", "/mcp-test"] &&
      alltrue([for p in slice(kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path, 0, 3) : p.backend[0].service[0].name == "n8n-main"])
    )
    error_message = "The Ingress must route the three editor test-mode prefixes to the main Service ahead of the production webhook prefixes."
  }

  assert {
    condition = one([
      for p in kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path :
      p.backend[0].service[0].name if p.path == "/"
    ]) == "n8n-main"
    error_message = "The internal Ingress must send the catch-all to the main Service."
  }

  assert {
    condition     = kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path[length(kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path) - 1].path == "/"
    error_message = "The catch-all must be declared after the webhook prefixes."
  }

  # Hostnames are split and each Ingress carries the class annotation that
  # routes it to the matching AGIC install, not the other one.
  assert {
    condition     = kubernetes_ingress_v1.webhook_public.spec[0].rule[0].host == "hooks.n8n.test.example.com"
    error_message = "The public Ingress must answer on the webhook hostname."
  }

  assert {
    condition     = kubernetes_ingress_v1.admin_internal.spec[0].rule[0].host == "n8n.test.example.com"
    error_message = "The internal Ingress must answer on the admin hostname."
  }

  # n8n must advertise webhooks on the public hostname while the editor
  # identity (OAuth2 credential callbacks) stays on the admin hostname.
  assert {
    condition = (
      module.n8n.n8n_webhook_url == "https://hooks.n8n.test.example.com" &&
      module.n8n.n8n_url == "https://n8n.test.example.com"
    )
    error_message = "n8n must advertise N8N_WEBHOOK_URL on the public webhook host while N8N_EDITOR_BASE_URL stays on the admin host."
  }

  assert {
    condition     = kubernetes_ingress_v1.webhook_public.metadata[0].annotations["kubernetes.io/ingress.class"] != kubernetes_ingress_v1.admin_internal.metadata[0].annotations["kubernetes.io/ingress.class"]
    error_message = "The two Ingress objects must carry distinct ingress-class annotations so each AGIC install reconciles only its own gateway."
  }

  # Each AGIC identity is scoped to only its own Application Gateway.
  assert {
    condition     = azurerm_role_assignment.agic_webhook_appgw_contributor.scope == azurerm_application_gateway.webhook.id
    error_message = "The webhook AGIC identity must be Contributor on the webhook gateway only."
  }

  assert {
    condition     = azurerm_role_assignment.agic_admin_appgw_contributor.scope == azurerm_application_gateway.admin.id
    error_message = "The admin AGIC identity must be Contributor on the admin gateway only."
  }

  # WAF attaches to the public gateway only, and only when requested.
  assert {
    condition     = azurerm_application_gateway.webhook.sku[0].name == "WAF_v2"
    error_message = "The webhook gateway must use WAF_v2 when create_webhook_waf_policy is true (the default)."
  }

  assert {
    condition     = azurerm_application_gateway.admin.sku[0].name == "Standard_v2"
    error_message = "The admin gateway must never carry a WAF policy: it is already private."
  }
}

run "waf_policy_omitted_uses_standard_v2" {
  command = plan

  variables {
    create_webhook_waf_policy = false
  }

  override_resource {
    target          = module.tls_self_signed_admin.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplita-tls-test.vault.azure.net/secrets/n8nsplita-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = module.tls_self_signed_webhook.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplitw-tls-test.vault.azure.net/secrets/n8nsplitw-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = azurerm_application_gateway.webhook.sku[0].name == "Standard_v2"
    error_message = "create_webhook_waf_policy = false must drop the webhook gateway to Standard_v2."
  }

  assert {
    condition     = length(azurerm_web_application_firewall_policy.webhook) == 0
    error_message = "create_webhook_waf_policy = false must omit the WAF policy resource."
  }
}

run "webhook_subdomain_flows_through_to_every_consumer" {
  command = plan

  variables {
    webhook_subdomain = "callbacks"
  }

  override_resource {
    target          = module.tls_self_signed_admin.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplita-tls-test.vault.azure.net/secrets/n8nsplita-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = module.tls_self_signed_webhook.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplitw-tls-test.vault.azure.net/secrets/n8nsplitw-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = kubernetes_ingress_v1.webhook_public.spec[0].rule[0].host == "callbacks.n8n.test.example.com"
    error_message = "webhook_subdomain must drive the public Ingress host."
  }

  assert {
    condition     = output.webhook_base_url == "https://callbacks.n8n.test.example.com"
    error_message = "webhook_base_url must track webhook_subdomain."
  }
}

run "split_ingress_single_main_override" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  override_resource {
    target          = module.tls_self_signed_admin.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplita-tls-test.vault.azure.net/secrets/n8nsplita-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  override_resource {
    target          = module.tls_self_signed_webhook.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nsplitw-tls-test.vault.azure.net/secrets/n8nsplitw-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = output.main_hpa_min_replicas == 1
    error_message = "Setting main minimum to 1 must pass 1 through to the root module."
  }

  assert {
    condition = (
      module.n8n.n8n_webhook_url == "https://hooks.n8n.test.example.com" &&
      module.n8n.n8n_url == "https://n8n.test.example.com"
    )
    error_message = "Selecting single-main must not change the split editor/webhook URLs."
  }
}

run "admin_cidr_validation_rejects_ipv6" {
  command = plan

  variables {
    admin_allowed_cidr_blocks = ["2001:db8::/32"]
  }

  expect_failures = [var.admin_allowed_cidr_blocks]
}

run "webhook_subdomain_validation_rejects_non_dns_label" {
  command = plan

  variables {
    webhook_subdomain = "not_a_label"
  }

  expect_failures = [var.webhook_subdomain]
}

run "n8n_license_key_rejects_the_example_placeholder" {
  command = plan

  variables {
    n8n_license_key = "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
  }

  expect_failures = [var.n8n_license_key]
}
