# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Inputs ───────────────────────────────────────────────────────────────────
# Submodule contract. The caller supplies:
#   - the FQDN the cert is issued for (`domain_name`),
#   - the Key Vault that issues and stores the certificate (`key_vault_id`),
#   - the standard naming/tagging pair (`friendly_name_prefix`, `common_tags`),
#   - the cert validity window (`validity_in_months`, default 12).
#
# Provider configuration (subscription, auth shape for azurerm) is the
# caller's responsibility — see the README in this directory.

variable "domain_name" {
  description = "Fully-qualified domain name the issued cert is valid for (e.g. n8n.example.com). Becomes the cert's CN and the sole entry in its SAN list. The App Gateway listener presents this CN to clients — a mismatch with the ingress hostname is an immediate browser cert-name error."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }

  validation {
    condition     = length(var.domain_name) <= 64
    error_message = "domain_name must be 64 characters or fewer: it becomes the certificate's Common Name, and RFC 5280 caps a certificate Common Name at 64 octets."
  }
}

variable "key_vault_id" {
  description = "Azure resource ID of the Key Vault that issues the certificate with its `Self` issuer and stores it as a PFX secret. The principal running `terraform apply` must hold certificate create and update rights on this vault (Key Vault Certificates Officer in RBAC mode, or Create/Get/Import/Update on certificates plus Get/Set on secrets in legacy access-policy mode). The App Gateway's user-assigned identity that consumes the cert at runtime needs Get on certificates+secrets — granted by the caller out-of-band (this submodule does not touch access policies / RBAC)."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.KeyVault/vaults/.+$", var.key_vault_id))
    error_message = "key_vault_id must be a fully qualified Azure Key Vault resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>)."
  }
}

variable "friendly_name_prefix" {
  description = "Short, lowercase name prefix used in the issued certificate's name, `<friendly_name_prefix>-n8n-tls`, which is also its `Name` tag (e.g. `n8nprod`, `n8ndev`). Mirrors the root module's variable to keep naming/tagging consistent across the IaaS + TLS surfaces. 2–12 chars, lowercase alphanumeric only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must be 2–12 characters of lowercase letters and digits."
  }
}

variable "common_tags" {
  description = "Tags merged onto the Key Vault certificate this submodule creates, on top of the baseline `ManagedBy = terraform` and `Project = n8n` tags (caller values win). The `Name` tag is always set to the certificate name."
  type        = map(string)
  default     = {}

  # no validation: arbitrary string→string tag map; Azure's per-tag length and
  # per-resource tag-count limits are enforced by the platform at apply.
}

variable "validity_in_months" {
  description = "Lifetime of the self-signed certificate, in whole months (1 to 120). Defaults to 12. Passed straight to the Key Vault certificate policy's validity_in_months, which only accepts whole months. Key Vault's AutoRenew lifetime action issues a new certificate version once 80% of the validity window has elapsed; the App Gateway listener picks up the new versioned URI on the next terraform apply. Self-signed mode is intended for lab / internal-only use; production deployments should use the sibling `modules/tls-letsencrypt/` submodule or pass an existing Key Vault certificate's Secret URI to the root module's app_gateway_tls_cert_secret_id."
  type        = number
  default     = 12
  nullable    = false

  validation {
    condition     = var.validity_in_months >= 1 && var.validity_in_months <= 120 && floor(var.validity_in_months) == var.validity_in_months
    error_message = "validity_in_months must be a whole number between 1 and 120 (10 years); Key Vault's certificate policy takes validity in whole months."
  }
}
