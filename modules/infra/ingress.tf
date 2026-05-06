# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Application Gateway + AGIC ───────────────────────────────────────────────
# Public ingress for n8n, moved into modules/infra/ as part of Phase 5 R5.1f
# (registry-hardening US-019). The Application Gateway is the public-facing
# entry point (TLS termination, WAF); AGIC (the AKS Application Gateway
# Ingress Controller addon, enabled in `aks.tf`) translates Kubernetes
# Ingress objects into App Gateway routing rules at runtime.
#
# TLS is wired in `keyvault.tf` (this submodule) — that file holds the
# count-gated `Key Vault Secrets User` role assignment that lets the App
# Gateway UAMI fetch `var.app_gateway_tls_cert_secret_id` from the
# caller-supplied Key Vault. The legacy module-owned `azurerm_key_vault.n8n`
# was removed in registry-hardening US-012 (Phase 4 R4.3); this submodule
# does NOT create a Key Vault.
#
# Identity wiring:
#   - `azurerm_user_assigned_identity.appgw_tls_cert` (below) is attached to
#     the App Gateway so it can pull the TLS cert from Key Vault. The
#     matching `Key Vault Secrets User` role assignment lives in
#     `keyvault.tf` (count-gated on `var.app_gateway_keyvault_id`).
#   - The AKS `ingress_application_gateway` addon (enabled in `aks.tf`)
#     auto-creates its own UAMI for AGIC — this is a fundamental
#     azurerm/AKS limitation: the addon does not accept a caller-supplied
#     identity. We grant the auto-created identity the runtime permissions
#     AGIC needs: Contributor on this App Gateway (below) + Reader on the
#     BYO resource group (`iam.tf`). The explicit `agic` UAMI in `iam.tf`
#     is unused at runtime today; kept as a forward reference for a future
#     story that disables the addon.
#
# AGIC-mutated fields are listed in `lifecycle.ignore_changes` so that
# `terraform plan` after a reconcile is a no-op. `ssl_certificate` is
# included because the n8n Ingress (`modules/workload/`, US-023) will use
# AGIC's `appgw-ssl-certificate` annotation pointing at a Key Vault cert
# URL — AGIC fetches the cert and writes it onto the App Gateway, and
# Terraform must not revert that.

# ── User-Assigned Identity ──
# App Gateway TLS-cert reader — assigned to the Application Gateway so it
# can fetch the TLS cert from Key Vault at runtime. The matching role
# assignment lives in `keyvault.tf` (count-gated on
# `var.app_gateway_keyvault_id`).
resource "azurerm_user_assigned_identity" "appgw_tls_cert" {
  name                = "${var.friendly_name_prefix}-appgw-tls"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-appgw-tls" })
}

# ── Public IP ────────────────────────────────────────────────────────────────
# Static Standard SKU public IP — required for Application Gateway v2. The
# DNS label is `<friendly_name_prefix>-n8n.<region>.cloudapp.azure.com`
# (Azure-assigned hostname); callers wire their own DNS (CNAME pointing at
# either this auto-hostname or the IP) onto `var.n8n_domain` separately
# (the optional automated DNS path lives outside this submodule today —
# Phase 2 work in the umbrella example, US-025).
resource "azurerm_public_ip" "appgw" {
  name                = local.appgw_pip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.friendly_name_prefix}-n8n"

  tags = merge(local.common_tags, { Name = local.appgw_pip_name })
}

# ── WAF Policy (WAF_v2 SKU only) ──────────────────────────────────────
# Azure deprecated the inline `waf_configuration` block on the App Gateway
# resource itself: any `terraform apply` against a fresh (or post-deprecation)
# subscription returns the synchronous 400
#
#   ApplicationGatewayWafConfigurationDeprecated: Direct WAF configuration on
#   Application Gateway has been retired. To continue, attach an existing WAF
#   policy or create a new one and associate it with your gateway.
#
# The replacement is a separate `azurerm_web_application_firewall_policy`
# referenced via `firewall_policy_id` on the App Gateway. The policy below
# matches the legacy inline block 1:1 (OWASP-3.2 ruleset, Detection mode
# = log only / no shadow-blocking on first rollout). Phase 2 work will
# expose `policy_settings.mode` (Detection vs Prevention) and the
# `managed_rule_set.version` to callers; today we keep the legacy posture
# unchanged.
#
# The policy is count-gated on the SKU — Standard_v2 callers don't need
# (and Azure rejects) a WAF policy attachment.
resource "azurerm_web_application_firewall_policy" "appgw" {
  count = var.appgw_sku_name == "WAF_v2" ? 1 : 0

  name                = "${local.app_gateway_name}-waf-policy"
  resource_group_name = var.resource_group_name
  location            = var.location

  policy_settings {
    enabled                     = true
    mode                        = "Detection"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }

  tags = merge(local.common_tags, { Name = "${local.app_gateway_name}-waf-policy" })
}

# ── Application Gateway ──────────────────────────────────────────────────────
resource "azurerm_application_gateway" "n8n" {
  name                = local.app_gateway_name
  resource_group_name = var.resource_group_name
  location            = var.location
  http2_enabled       = true

  sku {
    name     = var.appgw_sku_name
    tier     = var.appgw_sku_name
    capacity = var.appgw_capacity
  }

  # UserAssigned so the App Gateway can fetch the TLS cert from Key Vault.
  # The matching `Key Vault Secrets User` role assignment lives in
  # `keyvault.tf` (count-gated on `var.app_gateway_keyvault_id`).
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw_tls_cert.id]
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = var.appgw_subnet_id
  }

  frontend_port {
    name = "http"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Placeholder backend pool — AGIC will populate with n8n Pod IPs once the
  # n8n Ingress is reconciled. Empty-pool create is fine on Application
  # Gateway v2.
  backend_address_pool {
    name = "default-backend-pool"
  }

  backend_http_settings {
    name                  = "default-backend-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
  }

  # Placeholder HTTP listener so the App Gateway is creatable. AGIC will
  # add the real HTTPS listener (port 443) when it processes the n8n
  # Ingress with its TLS annotation; this listener is then ignored via
  # `lifecycle.ignore_changes`.
  http_listener {
    name                           = "default-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "default-rule"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "default-listener"
    backend_address_pool_name  = "default-backend-pool"
    backend_http_settings_name = "default-backend-settings"
  }

  # KV-backed TLS cert reference (registry-hardening US-012 single-pass-
  # through contract). The cert lives in a caller-owned Key Vault; the
  # App Gateway fetches it at runtime via the `appgw_tls_cert` UAMI
  # (granted `Key Vault Secrets User` on the vault by `keyvault.tf` when
  # `var.app_gateway_keyvault_id` is set, or by the caller out-of-band when
  # it isn't). The `var.app_gateway_tls_cert_secret_id` value must be a
  # versioned KV Secret URI of the form
  # `https://<vault>.vault.azure.net/secrets/<cert>/<ver>`. This block is
  # in `lifecycle.ignore_changes` below so AGIC can rotate / replace the
  # cert reference (via the n8n Ingress's `appgw-ssl-certificate`
  # annotation) without Terraform fighting it.
  ssl_certificate {
    name                = "appgw-ssl-cert"
    key_vault_secret_id = var.app_gateway_tls_cert_secret_id
  }

  # WAF_v2 SKU requires a firewall policy attached via `firewall_policy_id`
  # — the inline `waf_configuration` block was retired by Azure (see the
  # `azurerm_web_application_firewall_policy.appgw` resource above for the
  # full rationale). Standard_v2 callers don't need (and Azure rejects)
  # the attachment, so we feed null on that branch.
  firewall_policy_id = var.appgw_sku_name == "WAF_v2" ? azurerm_web_application_firewall_policy.appgw[0].id : null

  tags = merge(local.common_tags, { Name = local.app_gateway_name })

  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      frontend_port,
      http_listener,
      probe,
      redirect_configuration,
      request_routing_rule,
      rewrite_rule_set,
      ssl_certificate,
      url_path_map,
      # AGIC stamps these two book-keeping tags onto the App Gateway on
      # every reconcile (`ingress-for-aks-cluster-id` records the parent
      # cluster's ARM id; `managed-by-k8s-ingress` records the AGIC image
      # tag). Without ignoring them the next `terraform plan` always
      # reports a tag-drift in-place update, which is purely cosmetic
      # but noisy.
      tags["ingress-for-aks-cluster-id"],
      tags["managed-by-k8s-ingress"],
    ]
  }

  # Block the App Gateway create until the BYO Key Vault role assignment
  # has propagated (see `time_sleep.appgw_kv_secrets_user_rbac_propagation`
  # in `keyvault.tf`). Without the explicit dependency the gate would only
  # fire if the AGW happened to land on the right side of the DAG by
  # accident — the cert-fetch race surfaces as a 9-minute opaque
  # `InternalServerError` and is otherwise hard to diagnose.
  depends_on = [
    time_sleep.appgw_kv_secrets_user_rbac_propagation,
  ]
}

# ── AGIC role assignment scoped to the App Gateway ──────────────────────────
# AGIC's auto-created addon identity needs Contributor on the App Gateway
# (to mutate listeners / pools / rules) at reconcile time. The matching
# Reader scope on the BYO resource group lives in `iam.tf`. The
# principal_id is read off the AKS cluster's
# `ingress_application_gateway_identity` computed attribute.
resource "azurerm_role_assignment" "agic_addon_appgw_contributor" {
  scope                = azurerm_application_gateway.n8n.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.n8n.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# AGIC addon identity needs `Managed Identity Operator` on the App Gateway
# TLS-cert UAMI so that, when AGIC writes a Key-Vault-backed HTTPS
# listener onto the App Gateway, ARM accepts the linked
# `userAssignedIdentities/<appgw-tls>` reference. Without this assignment
# AGIC's reconcile fails with `LinkedAuthorizationFailed` (the principal
# has `applicationGateways/write` but lacks
# `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` on the
# linked UAMI). The role grants exactly that single action and nothing
# else.
resource "azurerm_role_assignment" "agic_addon_appgw_tls_uami_operator" {
  scope                = azurerm_user_assigned_identity.appgw_tls_cert.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.n8n.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# AGIC addon identity needs Network Contributor on the App Gateway's
# subnet so that, when AGIC writes the AGW config (frontend IP + listener),
# ARM accepts the implicit subnet-join validation. Without this role the
# reconcile fails with `ApplicationGatewayInsufficientPermissionOnSubnet`
# (`Microsoft.Network/virtualNetworks/subnets/join/action` denied).
# Microsoft documents the requirement at https://aka.ms/agsubnetjoin.
# Mirrors the `aks_kubelet_subnet_network_contributor` pattern in
# `aks.tf` for the AKS kubelet identity on the AKS subnet.
resource "azurerm_role_assignment" "agic_addon_appgw_subnet_network_contributor" {
  scope                = var.appgw_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.n8n.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}
