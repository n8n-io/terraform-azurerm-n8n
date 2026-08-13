# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Application Gateway ingress ─────────────────────────────────────────────
# The managed path creates one public or private-only Application Gateway,
# enables the AKS AGIC addon, and installs a host-aware Kubernetes Ingress.
# Setting create_ingress = false omits every resource in this file while the
# n8n namespace, Services, service port, and webhook-prefix outputs remain
# available for caller-owned routing.

# ── Application Gateway identities and frontend ─────────────────────────────

resource "azurerm_user_assigned_identity" "appgw_tls_cert" {
  count = var.create_ingress ? 1 : 0

  name                = "${var.friendly_name_prefix}-appgw-tls"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-appgw-tls" })
}

resource "azurerm_public_ip" "appgw" {
  count = var.create_ingress && var.appgw_frontend_mode == "public" ? 1 : 0

  name                = local.appgw_pip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.friendly_name_prefix}-n8n"

  tags = merge(local.common_tags, { Name = local.appgw_pip_name })
}

# ── Application Gateway subnet NSG ──────────────────────────────────────────
# Source restrictions apply to the whole gateway, including production
# webhook routes. Azure control-plane traffic and load-balancer health probes
# must remain allowed ahead of the explicit deny rule or the gateway becomes
# unhealthy. Application Gateway v2 uses GatewayManager ports 65200-65535.
resource "azurerm_network_security_group" "appgw" {
  count = var.create_ingress ? 1 : 0

  name                = local.appgw_nsg_name
  resource_group_name = var.resource_group_name
  location            = var.location

  security_rule {
    name                       = "AllowGatewayManager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                    = "AllowN8nFrontend"
    priority                = 120
    direction               = "Inbound"
    access                  = "Allow"
    protocol                = "Tcp"
    source_port_range       = "*"
    destination_port_ranges = ["80", "443"]
    source_address_prefix = length(var.appgw_allowed_inbound_cidrs) == 0 ? (
      var.appgw_frontend_mode == "internal" ? "VirtualNetwork" : "Internet"
    ) : null
    source_address_prefixes    = length(var.appgw_allowed_inbound_cidrs) > 0 ? var.appgw_allowed_inbound_cidrs : null
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = merge(local.common_tags, { Name = local.appgw_nsg_name })
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  count = var.create_ingress ? 1 : 0

  subnet_id                 = var.appgw_subnet_id
  network_security_group_id = azurerm_network_security_group.appgw[0].id
}

# ── Web application firewall ─────────────────────────────────────────────────
# Azure retired inline WAF configuration. Create a dedicated OWASP 3.2 policy
# for WAF_v2 unless the caller supplies an existing policy ID. Standard_v2 has
# no WAF policy attachment.
resource "azurerm_web_application_firewall_policy" "appgw" {
  count = var.create_ingress && var.appgw_sku_name == "WAF_v2" && var.appgw_waf_policy_id == null ? 1 : 0

  name                = "${local.app_gateway_name}-waf-policy"
  resource_group_name = var.resource_group_name
  location            = var.location

  policy_settings {
    enabled                     = true
    mode                        = var.appgw_waf_mode
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

# ── Application Gateway ─────────────────────────────────────────────────────

# Checkov cannot resolve a variable-backed predefined policy name. The input
# validation permits only the 2022 TLS 1.2-or-later policies and defaults to
# the stricter AppGwSslPolicy20220101S variant.
resource "azurerm_application_gateway" "n8n" {
  # checkov:skip=CKV_AZURE_218:Policy is constrained by appgw_ssl_policy validation to Azure's TLS 1.2-or-later 2022 policy family.
  count = var.create_ingress ? 1 : 0

  name                = local.app_gateway_name
  resource_group_name = var.resource_group_name
  location            = var.location
  http2_enabled       = true

  sku {
    name     = var.appgw_sku_name
    tier     = var.appgw_sku_name
    capacity = var.appgw_autoscaling_enabled ? null : var.appgw_capacity
  }

  dynamic "autoscale_configuration" {
    for_each = var.appgw_autoscaling_enabled ? [1] : []

    content {
      min_capacity = var.appgw_autoscale_min_capacity
      max_capacity = var.appgw_autoscale_max_capacity
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw_tls_cert[0].id]
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = var.appgw_subnet_id
  }

  # Start from an HTTPS-only placeholder listener. AGIC adds the port 80
  # redirect after it reconciles the Ingress, and that controller-owned
  # frontend-port/listener drift is intentionally ignored below.
  frontend_port {
    name = "https"
    port = 443
  }

  dynamic "frontend_ip_configuration" {
    for_each = var.appgw_frontend_mode == "public" ? [1] : []

    content {
      name                 = local.appgw_frontend_ip_configuration_name
      public_ip_address_id = azurerm_public_ip.appgw[0].id
    }
  }

  dynamic "frontend_ip_configuration" {
    for_each = var.appgw_frontend_mode == "internal" ? [1] : []

    content {
      name                          = local.appgw_frontend_ip_configuration_name
      subnet_id                     = var.appgw_subnet_id
      private_ip_address_allocation = "Dynamic"
    }
  }

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

  http_listener {
    name                           = "default-listener"
    frontend_ip_configuration_name = local.appgw_frontend_ip_configuration_name
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw-ssl-cert"
  }

  request_routing_rule {
    name                       = "default-rule"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "default-listener"
    backend_address_pool_name  = "default-backend-pool"
    backend_http_settings_name = "default-backend-settings"
  }

  ssl_certificate {
    name                = "appgw-ssl-cert"
    key_vault_secret_id = var.app_gateway_tls_cert_secret_id
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = var.appgw_ssl_policy
  }

  firewall_policy_id = var.appgw_sku_name == "WAF_v2" ? (
    var.appgw_waf_policy_id != null ? var.appgw_waf_policy_id : azurerm_web_application_firewall_policy.appgw[0].id
  ) : null

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
      tags["ingress-for-aks-cluster-id"],
      tags["managed-by-k8s-ingress"],
    ]
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.appgw,
    time_sleep.appgw_kv_secrets_user_rbac_propagation,
  ]
}

# ── AGIC runtime permissions ─────────────────────────────────────────────────
# The AKS addon creates its own identity. Grant that identity the minimum
# scopes needed to reconcile this gateway and attach its TLS-reader UAMI.
resource "azurerm_role_assignment" "agic_addon_appgw_contributor" {
  count = var.create_ingress ? 1 : 0

  scope                = azurerm_application_gateway.n8n[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.n8n[0].ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

resource "azurerm_role_assignment" "agic_addon_appgw_tls_uami_operator" {
  count = var.create_ingress ? 1 : 0

  scope                = azurerm_user_assigned_identity.appgw_tls_cert[0].id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.n8n[0].ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

resource "azurerm_role_assignment" "agic_addon_appgw_subnet_network_contributor" {
  count = var.create_ingress ? 1 : 0

  scope                = var.appgw_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.n8n[0].ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# ── AGIC-managed Kubernetes Ingress ──────────────────────────────────────────
# For every host, all five production webhook prefixes are declared before the
# catch-all so AGIC routes waiting webhooks, forms, and MCP traffic to the
# webhook processors instead of mains where production webhooks are disabled.
resource "kubernetes_ingress_v1" "n8n" {
  count = var.create_ingress ? 1 : 0

  metadata {
    name        = "n8n-ingress"
    namespace   = local.n8n_namespace
    annotations = local.appgw_ingress_annotations
  }

  spec {
    ingress_class_name = "azure-application-gateway"

    dynamic "rule" {
      for_each = local.n8n_ingress_domains

      content {
        host = rule.value

        http {
          dynamic "path" {
            for_each = local.n8n_webhook_path_prefixes

            content {
              path      = path.value
              path_type = "Prefix"

              backend {
                service {
                  name = "${helm_release.n8n.name}-webhook-processor"
                  port {
                    number = local.n8n_service_port
                  }
                }
              }
            }
          }

          path {
            path      = "/"
            path_type = "Prefix"

            backend {
              service {
                name = "${helm_release.n8n.name}-main"
                port {
                  number = local.n8n_service_port
                }
              }
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "10m"
    delete = "10m"
  }

  depends_on = [
    kubernetes_namespace.n8n,
    azurerm_role_assignment.agic_addon_appgw_contributor,
    azurerm_role_assignment.agic_addon_appgw_tls_uami_operator,
    azurerm_role_assignment.agic_addon_appgw_subnet_network_contributor,
    azurerm_role_assignment.agic_addon_rg_reader,
    time_sleep.n8n_helm_settle,
  ]
}

# ── Ingress diagnostics ──────────────────────────────────────────────────────

check "ingress_tuning_requires_module_managed_ingress" {
  assert {
    condition = var.create_ingress ? true : (
      var.appgw_frontend_mode == "public" &&
      var.appgw_sku_name == "WAF_v2" &&
      var.appgw_capacity == 2 &&
      !var.appgw_autoscaling_enabled &&
      var.appgw_autoscale_min_capacity == 2 &&
      var.appgw_autoscale_max_capacity == 10 &&
      var.appgw_ssl_policy == "AppGwSslPolicy20220101S" &&
      var.appgw_waf_mode == "Detection" &&
      var.appgw_waf_policy_id == null &&
      length(var.appgw_allowed_inbound_cidrs) == 0 &&
      length(var.ingress_annotations) == 0
    )
    error_message = "Application Gateway mode, SKU, capacity, autoscaling, TLS, WAF, source restrictions, or ingress annotations are customized while create_ingress is false, so those values are inert. Configure equivalent controls on the caller-owned gateways or restore the defaults."
  }
}

check "ingress_annotations_override_module_controls" {
  assert {
    condition = var.create_ingress ? length(setintersection(
      toset(keys(var.ingress_annotations)),
      local.appgw_ingress_control_annotation_names,
    )) == 0 : true
    error_message = "ingress_annotations overrides one or more module-owned AGIC annotations for TLS, frontend selection, backend protocol, timeout, draining, or affinity. Caller annotations are merged last and win; confirm the override preserves the intended dedicated ingress control."
  }
}
