# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Two Application Gateways, two standalone AGIC installs ──────────────────
# The root module's own AGIC path (ingress.tf) is a single AKS `ingress_
# application_gateway` addon, which binds to exactly one Application Gateway
# per cluster. Serving two gateways from one AKS cluster instead needs two
# standalone `ingress-azure` Helm releases (the addon is disabled entirely by
# create_ingress = false in main.tf), each with its own AKS workload-identity
# federation, ARM role assignments, and `kubernetes.ingressClass` value so
# they do not fight over the same Ingress objects. See
# https://azure.github.io/application-gateway-kubernetes-ingress/how-tos/deploy-AGIC-with-Workload-Identity-using-helm/.

locals {
  # Legacy annotation-based class matching (kubernetes.ingressClass Helm
  # value), not a Kubernetes IngressClass resource: AGIC 1.7's chart still
  # keys multi-controller matching off the kubernetes.io/ingress.class
  # annotation, so both Ingress objects below use annotations, not
  # spec.ingressClassName.
  webhook_ingress_class = "azure/application-gateway-webhook"
  admin_ingress_class   = "azure/application-gateway-admin"
}

# ── Webhook Application Gateway (public) ─────────────────────────────────────

resource "azurerm_public_ip" "webhook" {
  name                = "${var.friendly_name_prefix}-webhook-pip"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.friendly_name_prefix}-webhook"

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-webhook-pip" })
}

resource "azurerm_user_assigned_identity" "webhook_tls_cert" {
  name                = "${var.friendly_name_prefix}-webhook-tls"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-webhook-tls" })
}

resource "azurerm_role_assignment" "webhook_tls_cert_kv_reader" {
  scope                = azurerm_key_vault.tls.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.webhook_tls_cert.principal_id

  depends_on = [time_sleep.key_vault_rbac]
}

resource "time_sleep" "webhook_tls_cert_kv_rbac" {
  depends_on      = [azurerm_role_assignment.webhook_tls_cert_kv_reader]
  create_duration = "120s"
}

resource "azurerm_web_application_firewall_policy" "webhook" {
  count = var.create_webhook_waf_policy ? 1 : 0

  name                = "${var.friendly_name_prefix}-webhook-waf"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

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

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-webhook-waf" })
}

resource "azurerm_application_gateway" "webhook" {
  # checkov:skip=CKV_AZURE_218:Policy tracks the same Azure TLS 1.2-or-later 2022 predefined policy the root module defaults to.
  name                = "${var.friendly_name_prefix}-webhook-appgw"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  http2_enabled       = true

  sku {
    name     = var.create_webhook_waf_policy ? "WAF_v2" : "Standard_v2"
    tier     = var.create_webhook_waf_policy ? "WAF_v2" : "Standard_v2"
    capacity = 2
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.webhook_tls_cert.id]
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "https"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "webhook-frontend-ip"
    public_ip_address_id = azurerm_public_ip.webhook.id
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
    frontend_ip_configuration_name = "webhook-frontend-ip"
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
    key_vault_secret_id = module.tls_self_signed_webhook.app_gateway_tls_cert_secret_id
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  firewall_policy_id = var.create_webhook_waf_policy ? azurerm_web_application_firewall_policy.webhook[0].id : null

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-webhook-appgw" })

  # AGIC reconciles listeners, routing rules, and backend settings against
  # the live Ingress once its Helm release is up; these mirror the module's
  # own ignore_changes so a plan does not fight the controller.
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
      # ssl_certificate is deliberately not ignored: AGIC references the
      # gateway certificate by name only, and ignoring it would silently drop
      # every rotation of the Key Vault secret URI on an existing gateway.
      url_path_map,
      tags["ingress-for-aks-cluster-id"],
      tags["managed-by-k8s-ingress"],
    ]
  }

  depends_on = [time_sleep.webhook_tls_cert_kv_rbac]
}

# ── Admin Application Gateway (private) ──────────────────────────────────────
# No public IP: the frontend_ip_configuration below binds a dynamic private
# address inside the appgw subnet instead, so this gateway is reachable only
# from inside the VNet or whatever is peered/VPN-attached to it.

resource "azurerm_user_assigned_identity" "admin_tls_cert" {
  name                = "${var.friendly_name_prefix}-admin-tls"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-admin-tls" })
}

resource "azurerm_role_assignment" "admin_tls_cert_kv_reader" {
  scope                = azurerm_key_vault.tls.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.admin_tls_cert.principal_id

  depends_on = [time_sleep.key_vault_rbac]
}

resource "time_sleep" "admin_tls_cert_kv_rbac" {
  depends_on      = [azurerm_role_assignment.admin_tls_cert_kv_reader]
  create_duration = "120s"
}

resource "azurerm_application_gateway" "admin" {
  name                = "${var.friendly_name_prefix}-admin-appgw"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  # Application Gateway HTTP/2 intermittently resets the editor's large
  # initial asset burst, leaving the UI blank on otherwise healthy backends.
  http2_enabled = false

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.admin_tls_cert.id]
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "https"
    port = 443
  }

  frontend_ip_configuration {
    name                          = "admin-frontend-ip"
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address_allocation = "Dynamic"
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
    frontend_ip_configuration_name = "admin-frontend-ip"
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
    key_vault_secret_id = module.tls_self_signed_admin.app_gateway_tls_cert_secret_id
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-admin-appgw" })

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
      # ssl_certificate is deliberately not ignored: AGIC references the
      # gateway certificate by name only, and ignoring it would silently drop
      # every rotation of the Key Vault secret URI on an existing gateway.
      url_path_map,
      tags["ingress-for-aks-cluster-id"],
      tags["managed-by-k8s-ingress"],
    ]
  }

  depends_on = [time_sleep.admin_tls_cert_kv_rbac]
}

# ── Application Gateway subnet NSG ───────────────────────────────────────────
# Shared by both gateways since they share the appgw subnet. The admin
# gateway is already private; admin_allowed_cidr_blocks narrows it further
# for defense in depth. The webhook gateway accepts any source, since
# webhook senders are arbitrary internet hosts by design.

# checkov:skip=CKV_AZURE_160:AllowWebhookFrontend intentionally opens 80/443 from Internet: the webhook Application Gateway exists to accept unauthenticated internet webhook traffic. The admin frontend on the same NSG stays VirtualNetwork-only (or admin_allowed_cidr_blocks-restricted) by design, which is the isolation this example exists to demonstrate.
resource "azurerm_network_security_group" "appgw" {
  name                = "${var.friendly_name_prefix}-appgw-nsg"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

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
    name                       = "AllowWebhookFrontend"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAdminFrontend"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = length(var.admin_allowed_cidr_blocks) == 0 ? "VirtualNetwork" : null
    source_address_prefixes    = length(var.admin_allowed_cidr_blocks) > 0 ? var.admin_allowed_cidr_blocks : null
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

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-appgw-nsg" })
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

# ── Standalone AGIC identities and permissions ───────────────────────────────
# Each AGIC install gets its own workload-identity UAMI, federated to its own
# namespace + the chart's fixed "ingress-azure" service account name, and
# Contributor on only its own Application Gateway (never both — crossing
# these would let the webhook controller reconfigure the admin gateway).

data "azurerm_resource_group" "n8n" {
  name = azurerm_resource_group.n8n.name
}

resource "azurerm_user_assigned_identity" "agic_webhook" {
  name                = "${var.friendly_name_prefix}-agic-webhook"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-agic-webhook" })
}

resource "azurerm_role_assignment" "agic_webhook_appgw_contributor" {
  scope                = azurerm_application_gateway.webhook.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_webhook.principal_id
}

resource "azurerm_role_assignment" "agic_webhook_rg_reader" {
  scope                = data.azurerm_resource_group.n8n.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic_webhook.principal_id
}

resource "azurerm_role_assignment" "agic_webhook_subnet_network_contributor" {
  scope                = azurerm_subnet.appgw.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_webhook.principal_id
}

resource "azurerm_federated_identity_credential" "agic_webhook" {
  name                      = "${var.friendly_name_prefix}-agic-webhook-fed"
  user_assigned_identity_id = azurerm_user_assigned_identity.agic_webhook.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.n8n.aks_oidc_issuer_url
  subject                   = "system:serviceaccount:agic-webhook:ingress-azure"
}

resource "azurerm_user_assigned_identity" "agic_admin" {
  name                = "${var.friendly_name_prefix}-agic-admin"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-agic-admin" })
}

resource "azurerm_role_assignment" "agic_admin_appgw_contributor" {
  scope                = azurerm_application_gateway.admin.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_admin.principal_id
}

resource "azurerm_role_assignment" "agic_admin_rg_reader" {
  scope                = data.azurerm_resource_group.n8n.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic_admin.principal_id
}

resource "azurerm_role_assignment" "agic_admin_subnet_network_contributor" {
  scope                = azurerm_subnet.appgw.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_admin.principal_id
}

resource "azurerm_federated_identity_credential" "agic_admin" {
  name                      = "${var.friendly_name_prefix}-agic-admin-fed"
  user_assigned_identity_id = azurerm_user_assigned_identity.agic_admin.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.n8n.aks_oidc_issuer_url
  subject                   = "system:serviceaccount:agic-admin:ingress-azure"
}

# ── Standalone AGIC Helm releases ─────────────────────────────────────────────
# Each release lives in its own namespace so both can use the chart's fixed
# "ingress-azure" service account name without colliding, but both watch the
# shared n8n namespace for Ingress objects carrying their own
# kubernetes.io/ingress.class value.

resource "kubernetes_namespace" "agic_webhook" {
  metadata {
    name = "agic-webhook"
  }

  depends_on = [module.n8n]
}

resource "helm_release" "agic_webhook" {
  name       = "agic-webhook"
  repository = "oci://mcr.microsoft.com/azure-application-gateway/charts"
  chart      = "ingress-azure"
  version    = "1.7.5"
  namespace  = kubernetes_namespace.agic_webhook.metadata[0].name

  set {
    name  = "appgw.applicationGatewayID"
    value = azurerm_application_gateway.webhook.id
  }

  set {
    name  = "armAuth.type"
    value = "workloadIdentity"
  }

  set {
    name  = "armAuth.identityClientID"
    value = azurerm_user_assigned_identity.agic_webhook.client_id
  }

  set {
    name  = "kubernetes.watchNamespace"
    value = module.n8n.n8n_namespace
  }

  set {
    name  = "kubernetes.ingressClass"
    value = local.webhook_ingress_class
  }

  set {
    name  = "rbac.enabled"
    value = "true"
  }

  depends_on = [
    azurerm_role_assignment.agic_webhook_appgw_contributor,
    azurerm_role_assignment.agic_webhook_rg_reader,
    azurerm_role_assignment.agic_webhook_subnet_network_contributor,
    azurerm_federated_identity_credential.agic_webhook,
  ]
}

resource "kubernetes_namespace" "agic_admin" {
  metadata {
    name = "agic-admin"
  }

  depends_on = [module.n8n]
}

resource "helm_release" "agic_admin" {
  name       = "agic-admin"
  repository = "oci://mcr.microsoft.com/azure-application-gateway/charts"
  chart      = "ingress-azure"
  version    = "1.7.5"
  namespace  = kubernetes_namespace.agic_admin.metadata[0].name

  set {
    name  = "appgw.applicationGatewayID"
    value = azurerm_application_gateway.admin.id
  }

  set {
    name  = "armAuth.type"
    value = "workloadIdentity"
  }

  set {
    name  = "armAuth.identityClientID"
    value = azurerm_user_assigned_identity.agic_admin.client_id
  }

  set {
    name  = "kubernetes.watchNamespace"
    value = module.n8n.n8n_namespace
  }

  set {
    name  = "kubernetes.ingressClass"
    value = local.admin_ingress_class
  }

  set {
    name  = "rbac.enabled"
    value = "true"
  }

  depends_on = [
    azurerm_role_assignment.agic_admin_appgw_contributor,
    azurerm_role_assignment.agic_admin_rg_reader,
    azurerm_role_assignment.agic_admin_subnet_network_contributor,
    azurerm_federated_identity_credential.agic_admin,
  ]
}

# ── Kubernetes Ingress objects ────────────────────────────────────────────────
# Routes exactly the prefixes n8n disables on the main pods, taken from the
# module output rather than hardcoded so this example cannot drift as n8n
# adds endpoints.

resource "kubernetes_ingress_v1" "webhook_public" {
  metadata {
    name      = "n8n-webhook-public"
    namespace = module.n8n.n8n_namespace

    annotations = {
      "kubernetes.io/ingress.class" = local.webhook_ingress_class
    }
  }

  spec {
    rule {
      host = local.webhook_domain

      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"

            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port {
                  number = module.n8n.n8n_service_port
                }
              }
            }
          }
        }

        # Deliberately no catch-all "/" rule: a request to any other path
        # gets the gateway's default 404 and never reaches the editor UI.
      }
    }
  }

  timeouts {
    create = "10m"
    delete = "10m"
  }

  depends_on = [helm_release.agic_webhook]
}

resource "kubernetes_ingress_v1" "admin_internal" {
  metadata {
    name      = "n8n-admin-internal"
    namespace = module.n8n.n8n_namespace

    annotations = {
      "kubernetes.io/ingress.class" = local.admin_ingress_class
      # Matches the root module's default annotation (locals.tf): pins each
      # multi-main client to one main pod so its session state stays on the
      # same backend. n8n_main_hpa_min_replicas defaults to 2 in this example,
      # so without this, Application Gateway load-balances across mains per
      # request and users see intermittent 401s as auth state diverges
      # between mains.
      "appgw.ingress.kubernetes.io/cookie-based-affinity" = "true"
    }
  }

  spec {
    rule {
      host = var.n8n_domain

      http {
        # Editor test-mode prefixes first (served by mains only): Application Gateway matches string
        # prefixes in declared order, so /webhook* would otherwise capture
        # /webhook-test and send it to webhook processors that return 404.
        dynamic "path" {
          for_each = module.n8n.n8n_test_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"

            backend {
              service {
                name = module.n8n.n8n_service_name
                port {
                  number = module.n8n.n8n_service_port
                }
              }
            }
          }
        }

        # Same prefixes as the public gateway, same reason: mains serve none
        # of them. Declared before the catch-all so the specific paths win.
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"

            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port {
                  number = module.n8n.n8n_service_port
                }
              }
            }
          }
        }

        # Editor UI and REST API.
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = module.n8n.n8n_service_name
              port {
                number = module.n8n.n8n_service_port
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

  depends_on = [helm_release.agic_admin]
}
