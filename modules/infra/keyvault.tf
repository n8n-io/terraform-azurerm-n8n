# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Key Vault wiring ─────────────────────────────────────────────────────────
# This submodule does NOT create a Key Vault — registry-hardening US-012
# (Phase 4 R4.3) collapsed the legacy module-owned `azurerm_key_vault.n8n`
# resource into a single BYO-secret contract. Callers either:
#   - Use one of the two TLS-mode submodules (`modules/tls-letsencrypt/` or
#     `modules/tls-self-signed/`) which both provision a caller-owned Key
#     Vault as part of their cert workflow, OR
#   - Bring an existing Key Vault holding the App Gateway listener cert.
#
# When `var.app_gateway_keyvault_role_assignment_enabled = true`, this
# submodule:
#   1. Looks up the vault via `data.azurerm_key_vault.byo` so its `vault_uri`
#      flows out of the submodule's `key_vault_uri` output (per US-019 AC#5).
#   2. Grants the `appgw_tls_cert` UAMI (created in `ingress.tf`) `Key Vault
#      Secrets User` on the supplied vault — the minimum role needed for the
#      gateway to fetch the cert at runtime.
#
# When the toggle is false (default), the caller is responsible for
# granting the `appgw_tls_cert` UAMI access on the cert's vault out-of-band
# (e.g. via an `access_policy` block on a vault in legacy access-policy mode,
# or an out-of-band role assignment they manage themselves). Both the data
# source and the role assignment below are count-gated on the toggle so the
# off-path is a clean no-op.
#
# Why a separate boolean toggle (vs the legacy `count = ... == null ? 0 : 1`):
# Terraform requires `count` arguments to be plan-time-known. When a
# caller passes a same-plan-built vault attribute (e.g.
# `azurerm_key_vault.shared.id`), `var.app_gateway_keyvault_id` is unknown
# until apply and the legacy null-check could not resolve, breaking the
# documented single-apply path. The explicit boolean toggle is plan-time
# known regardless of how the ID is wired — see
# `examples/complete*/main.tf` for the canonical caller-side wiring
# (set the toggle to `true` and pass the vault ID as before).
#
# Key-Vault NAME parsing:
# `data.azurerm_key_vault` requires a name + resource_group_name (it will not
# accept a fully qualified resource ID). The Azure resource-ID shape
# `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>`
# means `split("/", id)[4]` is the resource group and the last segment is
# the vault name — both reliably parseable. When the vault is built in the
# same plan, both `var.app_gateway_keyvault_id` and the `split()` results
# are unknown until apply, but data-source arguments tolerate unknown
# values (the read is deferred to apply). Only `count` cared about
# plan-time resolvability, which is why the explicit bool toggle above
# isolates the count signal from the (possibly unknown) ID value.

data "azurerm_key_vault" "byo" {
  count = var.app_gateway_keyvault_role_assignment_enabled ? 1 : 0

  name                = reverse(split("/", var.app_gateway_keyvault_id))[0]
  resource_group_name = split("/", var.app_gateway_keyvault_id)[4]
}

resource "azurerm_role_assignment" "appgw_kv_secrets_user" {
  count = var.app_gateway_keyvault_role_assignment_enabled ? 1 : 0

  scope                = var.app_gateway_keyvault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw_tls_cert.principal_id
}

# Absorb Azure RBAC propagation lag (typically 30–120 s for vault-scope
# role assignments) before the App Gateway is created. Without this gate,
# the App Gateway create races the role assignment and the cert-fetch
# step inside AGW provisioning fails with the generic
# `InternalServerError` after a 9-minute internal retry loop — with no
# specific cause surfaced in the activity log. Live-apply rehearsals
# against a fresh subscription consistently reproduced this race even
# when the role assignment had completed apparently-cleanly several
# seconds before the AGW began provisioning. Mirrors the kv_operator
# RBAC-propagation gate in `examples/complete*/main.tf`.
resource "time_sleep" "appgw_kv_secrets_user_rbac_propagation" {
  count = var.app_gateway_keyvault_role_assignment_enabled ? 1 : 0

  depends_on      = [azurerm_role_assignment.appgw_kv_secrets_user]
  create_duration = "120s"
}
