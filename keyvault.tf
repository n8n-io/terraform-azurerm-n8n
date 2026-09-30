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

# ── Key Vault Secrets Provider add-on access ────────────────────────────────
# The add-on (aks.tf) creates and manages its own identity; this grants that
# identity read access to a caller-named vault so SecretProviderClass objects
# in that vault can sync into the Secrets the *_secret_ref inputs read (see
# docs/customer-managed-infrastructure.md for the full pattern).
resource "azurerm_role_assignment" "aks_key_vault_secrets_provider_kv_secrets_user" {
  count = var.create_aks && var.aks_key_vault_secrets_provider_role_assignment_enabled ? 1 : 0

  scope                = var.aks_key_vault_secrets_provider_keyvault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.n8n[0].key_vault_secrets_provider[0].secret_identity[0].object_id
}

# ── AKS KMS etcd encryption access ──────────────────────────────────────────
# Azure requires the cluster's own identity to already hold this role on the
# key vault before key_management_service (aks.tf) can be enabled — see the
# two-apply sequencing note above var.aks_kms_key_vault_key_id in
# variables.tf. The cluster's identity is always the UserAssigned
# aks_cluster identity here (local.aks_needs_user_assigned_identity in
# locals.tf is true whenever this role assignment is requested), since
# AKS's KMS feature rejects a SystemAssigned identity outright.
#
# Role choice: "Key Vault Crypto Service Encryption User" (the role this
# resource granted before this fix) only carries the wrap/unwrap data
# actions — it does NOT include keys/encrypt/action or keys/decrypt/action.
# AKS's KMS identity-permission validation checks specifically for
# encrypt/decrypt, so every apply enabling aks_kms_key_vault_key_id under
# that role failed with
# AzureKeyVaultKmsValidateIdentityPermissionCustomerError ("The identity
# does not have keys encrypt/decrypt permission on key vault ..."), live-
# reproduced on a brand-new cluster with no identity-type switch involved,
# confirming the failure is this wrong role, not RBAC propagation lag.
# "Key Vault Crypto User" carries encrypt/decrypt
# (plus wrap/unwrap/sign/verify), matching the role Microsoft's own AKS KMS
# documentation grants for this exact scenario.
resource "azurerm_role_assignment" "aks_kms_kv_crypto_user" {
  count = var.create_aks && var.aks_kms_role_assignment_enabled ? 1 : 0

  scope                = var.aks_kms_key_vault_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.aks_cluster[0].principal_id
}
