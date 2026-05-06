# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Inputs ───────────────────────────────────────────────────────────────────
# Submodule contract. The caller supplies:
#   - the Key Vault to import the issued PFX into (`key_vault_id`),
#   - the FQDN the cert is issued for (`domain_name`),
#   - the ACME registration email (`acme_email`),
#   - the Azure DNS zone backing the DNS-01 challenge
#     (`dns_zone_resource_group_name` + `dns_zone_name`),
#   - the standard naming/tagging pair (`friendly_name_prefix`, `common_tags`).
#
# Provider configuration (AZURE_* env vars / DefaultAzureCredential the lego
# library uses to write the validation TXT record) is the caller's
# responsibility — see the README in this directory.

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for ACME issuance and renewal notifications. Required — Let's Encrypt rejects ACME registrations without a contact email."
  type        = string

  validation {
    condition     = length(var.acme_email) > 0 && can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.acme_email))
    error_message = "acme_email must be a non-empty email-shaped string (e.g. ops@example.com)."
  }
}

variable "domain_name" {
  description = "Fully-qualified domain name the issued cert is valid for (e.g. n8n.example.com). Becomes the cert's CN and the sole entry in its SAN list. Must be a name covered by `var.dns_zone_name` so the DNS-01 challenge can write the validation TXT record."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }
}

variable "dns_zone_name" {
  description = "Name of the Azure DNS zone authoritative for `var.domain_name` (e.g. `example.com` when domain_name is `n8n.example.com`). Wired into the lego DNS-01 challenge config so the validation TXT record lands in the correct zone. The zone itself must exist before this submodule runs — it is not module-managed."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.dns_zone_name))
    error_message = "dns_zone_name must be a valid DNS zone name (lowercase, dot-separated labels of [a-z0-9-], not starting/ending with a hyphen)."
  }
}

variable "dns_zone_resource_group_name" {
  description = "Resource group name containing `var.dns_zone_name`. Wired into the lego DNS-01 challenge config (AZURE_RESOURCE_GROUP) so the principal resolved from AZURE_* env vars is scoped to the correct zone when writing the validation TXT record."
  type        = string

  validation {
    condition     = length(var.dns_zone_resource_group_name) > 0 && length(var.dns_zone_resource_group_name) <= 90
    error_message = "dns_zone_resource_group_name must be a non-empty Azure resource group name (1–90 chars)."
  }
}

variable "key_vault_id" {
  description = "Azure resource ID of the Key Vault the issued PFX is imported into. The principal running `terraform apply` must hold cert-import rights on this vault (Key Vault Certificates Officer in RBAC mode, or Create/Import on certificates in legacy access-policy mode). The App Gateway's user-assigned identity that consumes the cert at runtime needs Get on certificates+secrets — granted by the caller out-of-band (this submodule does not touch access policies / RBAC)."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.KeyVault/vaults/.+$", var.key_vault_id))
    error_message = "key_vault_id must be a fully qualified Azure Key Vault resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>)."
  }
}

variable "friendly_name_prefix" {
  description = "Short, lowercase name prefix used in the imported certificate's name and as the value of the `Name` tag (e.g. `n8nprod`, `n8ndev`). Mirrors the root module's variable to keep naming/tagging consistent across the IaaS + TLS surfaces. 2–12 chars, lowercase alphanumeric only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must be 2–12 characters of lowercase letters and digits."
  }
}

# No taggable Azure resource lives in this submodule (azurerm_key_vault_certificate
# does not carry tags — tags live on the parent vault, which is caller-owned).
# Kept on the contract so umbrella examples can pass the same `common_tags`
# they pass to other submodules without bookkeeping divergence; will be
# consumed automatically if a future Azure resource gains tag support inside
# this submodule.
# tflint-ignore: terraform_unused_declarations
variable "common_tags" {
  description = "Tags merged onto every taggable resource this submodule creates. The Key Vault Certificate resource itself is not directly taggable on Azure (tags live on the parent vault), so today this only flows into the `Name` tag the caller will see in azurerm_key_vault_certificate plan output. Kept on the contract so a future taggable ACME resource picks the value up automatically."
  type        = map(string)
  default     = {}

  # no validation: arbitrary string→string tag map; Azure's per-tag length and
  # per-resource tag-count limits are enforced by the platform at apply.
}
