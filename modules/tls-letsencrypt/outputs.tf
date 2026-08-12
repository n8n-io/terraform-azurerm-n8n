# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Outputs ──────────────────────────────────────────────────────────────────
# The versioned Key Vault Secret URI is the Application Gateway integration
# contract. The domain-name set lets callers verify which canonical and alias
# hosts the imported certificate covers before attaching it to other gateways.

output "app_gateway_tls_cert_secret_id" {
  description = "Versioned Key Vault Secret URI for the imported PFX bundle. Pass this to the root module's `app_gateway_tls_cert_secret_id` input. Sensitive because it embeds the certificate's secret-version segment, which a holder of read access to the vault can use to fetch the private key."
  value       = azurerm_key_vault_certificate.letsencrypt.secret_id
  sensitive   = true
}

output "certificate_domain_names" {
  description = "Normalized set of domain names covered by the issued certificate, including domain_name and every subject_alternative_names entry."
  value = toset(concat(
    [acme_certificate.n8n.common_name],
    [for domain in var.subject_alternative_names : lower(domain)],
  ))
}
