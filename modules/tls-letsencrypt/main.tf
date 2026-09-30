# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Let's Encrypt ACME → Key Vault ────────────────────────────────────────────
# vancluever/acme registers an account with Let's Encrypt and issues a cert
# via the DNS-01 challenge against an Azure DNS zone authoritative for
# `var.domain_name` and every `var.subject_alternative_names` entry. The
# `acme_certificate` resource exposes a PKCS#12 bundle
# (`certificate_p12` + `certificate_p12_password`) that imports directly into
# Azure Key Vault — no openssl conversion step needed.
#
# DNS-01 challenge requirements (caller-side):
#   - An Azure DNS zone (`var.dns_zone_name`) authoritative for `var.domain_name`
#     in `var.dns_zone_resource_group_name`.
#   - Azure credentials supported by lego's azuredns provider on the apply
#     host so the lego library can write the validation TXT record.
#   - The principal those creds resolve to must have `DNS Zone Contributor`
#     on the zone.
#
# The submodule passes AZURE_RESOURCE_GROUP + AZURE_ZONE_NAME into the lego
# config map so the principal is scoped to the correct zone — without this,
# lego enumerates every zone in the subscription on each challenge.

resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "n8n" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

resource "acme_certificate" "n8n" {
  account_key_pem = acme_registration.n8n.account_key_pem
  common_name     = lower(var.domain_name)
  subject_alternative_names = length(var.subject_alternative_names) == 0 ? null : toset([
    for domain in var.subject_alternative_names : lower(domain)
  ])

  dns_challenge {
    provider = "azuredns"

    config = {
      AZURE_RESOURCE_GROUP = var.dns_zone_resource_group_name
      AZURE_ZONE_NAME      = var.dns_zone_name
    }
  }
}

# ── Key Vault Certificate import ──────────────────────────────────────────────
# The PFX bundle from acme_certificate.n8n is imported into the caller-
# supplied Key Vault as a single certificate object. The vault's secret_id
# (a versioned URI under https://<vault>.vault.azure.net/secrets/<name>/<v>)
# is what the App Gateway listener references in
# `ssl_certificate.key_vault_secret_id` — exposed via the
# `app_gateway_tls_cert_secret_id` output.

resource "azurerm_key_vault_certificate" "letsencrypt" {
  name         = local.certificate_name
  key_vault_id = var.key_vault_id

  certificate {
    contents = acme_certificate.n8n.certificate_p12
    password = acme_certificate.n8n.certificate_p12_password
  }

  tags = merge(local.common_tags, { Name = local.certificate_name })
}
