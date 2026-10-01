# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Caller-owned ingress ──────────────────────────────────────────────────────
# create_ingress = false on the module call (existing AKS requires it) means
# this example owns the Application Gateway and AGIC install, the same
# single-gateway pattern examples/customer-managed-cluster uses.

resource "azurerm_public_ip" "n8n" {
  name                = "${var.friendly_name_prefix}-appgw-pip"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.friendly_name_prefix

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-appgw-pip" })
}

resource "azurerm_user_assigned_identity" "n8n_tls_cert" {
  name                = "${var.friendly_name_prefix}-appgw-tls"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-appgw-tls" })
}

resource "azurerm_role_assignment" "n8n_tls_cert_kv_reader" {
  scope                = azurerm_key_vault.tls.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.n8n_tls_cert.principal_id

  depends_on = [time_sleep.key_vault_rbac]
}

resource "time_sleep" "n8n_tls_cert_kv_rbac" {
  depends_on      = [azurerm_role_assignment.n8n_tls_cert_kv_reader]
  create_duration = "120s"
}

resource "azurerm_application_gateway" "n8n" {
  # checkov:skip=CKV_AZURE_218:Policy tracks the same Azure TLS 1.2-or-later 2022 predefined policy the root module defaults to.
  name                = "${var.friendly_name_prefix}-appgw"
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
    identity_ids = [azurerm_user_assigned_identity.n8n_tls_cert.id]
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
    name                 = "n8n-frontend-ip"
    public_ip_address_id = azurerm_public_ip.n8n.id
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
    frontend_ip_configuration_name = "n8n-frontend-ip"
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
    key_vault_secret_id = module.tls_self_signed.app_gateway_tls_cert_secret_id
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-appgw" })

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

  depends_on = [time_sleep.n8n_tls_cert_kv_rbac]
}

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
    name                       = "AllowFrontend"
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

data "azurerm_resource_group" "n8n" {
  name = azurerm_resource_group.n8n.name
}

resource "azurerm_user_assigned_identity" "agic" {
  name                = "${var.friendly_name_prefix}-agic"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = azurerm_resource_group.n8n.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-agic" })
}

resource "azurerm_role_assignment" "agic_appgw_contributor" {
  scope                = azurerm_application_gateway.n8n.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_rg_reader" {
  scope                = data.azurerm_resource_group.n8n.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_subnet_network_contributor" {
  scope                = azurerm_subnet.appgw.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_tls_identity_operator" {
  scope                = azurerm_user_assigned_identity.n8n_tls_cert.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_federated_identity_credential" "agic" {
  name                      = "${var.friendly_name_prefix}-agic-fed"
  user_assigned_identity_id = azurerm_user_assigned_identity.agic.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.existing.oidc_issuer_url
  subject                   = "system:serviceaccount:agic:agic-sa-ingress-azure"
}

resource "kubernetes_namespace" "agic" {
  metadata {
    name = "agic"
  }

  depends_on = [module.n8n]
}

resource "helm_release" "agic" {
  name       = "agic"
  repository = "oci://mcr.microsoft.com/azure-application-gateway/charts"
  chart      = "ingress-azure"
  version    = "1.7.5"
  namespace  = kubernetes_namespace.agic.metadata[0].name

  set {
    name  = "appgw.applicationGatewayID"
    value = azurerm_application_gateway.n8n.id
  }

  set {
    name  = "armAuth.type"
    value = "workloadIdentity"
  }

  set {
    name  = "armAuth.identityClientID"
    value = azurerm_user_assigned_identity.agic.client_id
  }

  set {
    name  = "kubernetes.watchNamespace"
    value = module.n8n.n8n_namespace
  }

  set {
    name  = "rbac.enabled"
    value = "true"
  }

  depends_on = [
    azurerm_role_assignment.agic_appgw_contributor,
    azurerm_role_assignment.agic_rg_reader,
    azurerm_role_assignment.agic_subnet_network_contributor,
    azurerm_role_assignment.agic_tls_identity_operator,
    azurerm_federated_identity_credential.agic,
  ]
}

resource "kubernetes_ingress_v1" "n8n" {
  metadata {
    name      = "n8n"
    namespace = module.n8n.n8n_namespace
    annotations = {
      "appgw.ingress.kubernetes.io/ssl-redirect"          = "true"
      "appgw.ingress.kubernetes.io/backend-protocol"      = "http"
      "appgw.ingress.kubernetes.io/appgw-ssl-certificate" = "appgw-ssl-cert"
      # Matches the root module's default annotation (locals.tf): pins each
      # multi-main client to one main pod so its session state stays on the
      # same backend. Without this, Application Gateway load-balances across
      # mains per request and users see intermittent 401s as auth state
      # diverges between mains.
      "appgw.ingress.kubernetes.io/cookie-based-affinity" = "true"
    }
  }

  spec {
    ingress_class_name = "azure-application-gateway"

    rule {
      host = var.n8n_domain

      http {
        # Editor test-mode prefixes first: Application Gateway matches string
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

  depends_on = [helm_release.agic]
}
