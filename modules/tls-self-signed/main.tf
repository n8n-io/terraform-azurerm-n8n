# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Self-signed cert via Key Vault native Self issuer ─────────────────────────
# Azure Key Vault's `Self` issuer generates the keypair INSIDE the vault,
# self-signs an X.509 cert against the supplied policy, and stores the
# resulting bundle as an unencrypted PFX (PKCS#12) under the cert's secret
# URI. This is the canonical AGW-compatible shape: Application Gateway v2
# expects `keyVaultSecretId` to point at a base-64 unencrypted PFX, and the
# Self-issuer path is the only one that satisfies that without an external
# openssl conversion step.
#
# WHY NOT hashicorp/tls + import:
# Earlier revisions of this submodule generated the keypair + cert via
# `tls_private_key` / `tls_self_signed_cert` and imported the resulting
# PEM bundle into Key Vault with `secret_properties.content_type =
# application/x-pem-file`. Live-apply rehearsals against a real Azure
# subscription showed that Application Gateway v2's KV-integration code
# path silently rejects PEM-typed secrets (the deploy fails with the
# generic `InternalServerError` / "An error occurred." message — no useful
# detail in the activity log). PFX is the only format AGW reliably
# accepts. KV's Self issuer always stores PFX, so this rewrite removes the
# format-mismatch failure mode entirely. As a bonus the submodule no
# longer pulls the `hashicorp/tls` provider, halving its provider count.
#
# Self-signed mode is intended for lab / internal-only use; browsers will
# warn on the cert. Production deployments should use the sibling
# `modules/tls-letsencrypt/` submodule.
#
# Renewal: KV's `lifetime_action` / `AutoRenew` re-issues the cert
# `lifetime_percentage = 80` of the way through the validity window. The
# Application Gateway picks up the new versioned secret URI on its next
# `azurerm_application_gateway` apply.

resource "azurerm_key_vault_certificate" "self_signed" {
  name         = "${var.friendly_name_prefix}-n8n-tls"
  key_vault_id = var.key_vault_id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = false
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        # Re-issue when 80% of the validity window has elapsed (e.g. ~73d
        # before expiry on a 1y cert). Mirrors the legacy
        # `early_renewal_hours = 720` behaviour without needing a second
        # input on the contract.
        lifetime_percentage = 80
      }
    }

    secret_properties {
      # PFX is what AGW reliably consumes — see the file-level comment
      # for the rationale.
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${var.domain_name}"
      validity_in_months = floor(var.validity_period_hours / 730)

      # serverAuth EKU — required for AGW listener termination.
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"]

      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]

      subject_alternative_names {
        dns_names = [var.domain_name]
      }
    }
  }
}
