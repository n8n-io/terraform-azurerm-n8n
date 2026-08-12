# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Application Gateway certificate access ─────────────────────────────────
# The module never creates a Key Vault or certificate. The caller supplies the
# versioned certificate Secret URI consumed by ingress.tf. When explicitly
# requested, this file grants the gateway TLS identity the minimum built-in
# role needed to read that Secret from the caller-owned vault.
#
# The separate boolean keeps count plan-known when app_gateway_keyvault_id is
# an ID produced by another resource in the same apply. The managed-ingress
# gate prevents an orphan role assignment when the caller owns ingress.

resource "azurerm_role_assignment" "appgw_kv_secrets_user" {
  count = var.create_ingress && var.app_gateway_keyvault_role_assignment_enabled ? 1 : 0

  scope                = var.app_gateway_keyvault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw_tls_cert[0].principal_id
}

# Azure RBAC changes can take up to two minutes to reach the Key Vault data
# plane. Wait before Application Gateway reads the listener certificate or its
# create can fail with an opaque InternalServerError.
resource "time_sleep" "appgw_kv_secrets_user_rbac_propagation" {
  count = var.create_ingress && var.app_gateway_keyvault_role_assignment_enabled ? 1 : 0

  depends_on      = [azurerm_role_assignment.appgw_kv_secrets_user]
  create_duration = "120s"
}

check "keyvault_role_assignment_requires_module_managed_ingress" {
  assert {
    condition     = var.create_ingress ? true : !var.app_gateway_keyvault_role_assignment_enabled
    error_message = "app_gateway_keyvault_role_assignment_enabled is true while create_ingress is false, so there is no module-managed Application Gateway identity to grant access. Manage certificate access on the caller-owned gateway or disable the toggle."
  }
}
