# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Outputs ──────────────────────────────────────────────────────────────────
# Single contract output: the versioned Key Vault Secret URI that the App
# Gateway listener's `ssl_certificate.key_vault_secret_id` field consumes.
# US-012 (Phase 4 R4.3) wires this output into the root module's
# `var.app_gateway_tls_cert_secret_id` input — this submodule and the
# `tls-letsencrypt` sibling are interchangeable behind that single contract.

output "app_gateway_tls_cert_secret_id" {
  description = "Versioned Key Vault Secret URI for the self-signed certificate Key Vault issued (PFX). Pass this to the root module's `app_gateway_tls_cert_secret_id` input (US-012). Sensitive because it embeds the certificate's secret-version segment, which a holder of read access to the vault can use to fetch the private key."
  value       = azurerm_key_vault_certificate.self_signed.secret_id
  sensitive   = true
}
