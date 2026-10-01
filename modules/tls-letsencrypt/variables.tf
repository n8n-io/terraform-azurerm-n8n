# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Inputs ───────────────────────────────────────────────────────────────────
# Submodule contract. The caller supplies:
#   - the Key Vault to import the issued PFX into (`key_vault_id`),
#   - the primary FQDN and optional subject alternative names the cert covers
#     (`domain_name` + `subject_alternative_names`),
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
  description = "Canonical fully-qualified domain name for the issued certificate (e.g. n8n.example.com). Becomes the certificate common name. It must be the Azure DNS zone apex or a subdomain of dns_zone_name so DNS-01 validation can write the challenge record."
  type        = string

  validation {
    condition     = length(var.domain_name) <= 253 && can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", var.domain_name))
    error_message = "domain_name must be a valid fully qualified domain name with no empty labels or leading or trailing hyphens (e.g. n8n.example.com)."
  }

  validation {
    condition     = length(var.domain_name) <= 64
    error_message = "domain_name must be 64 characters or fewer: it becomes the certificate's Common Name, and RFC 5280 caps a certificate Common Name at 64 octets (tighter than the 253-octet DNS limit above). Add extra names to subject_alternative_names instead, which is not bound by this limit."
  }

  validation {
    condition = (
      lower(var.domain_name) == lower(var.dns_zone_name) ||
      endswith(lower(var.domain_name), ".${lower(var.dns_zone_name)}")
    )
    error_message = "domain_name must be the dns_zone_name apex or a subdomain of dns_zone_name."
  }
}

variable "subject_alternative_names" {
  description = "Additional fully-qualified domain names included on the certificate. Names are normalized to lowercase before issuance, must be unique without repeating domain_name, and must live in dns_zone_name because the Azure DNS challenge uses that one authoritative zone."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for domain in var.subject_alternative_names :
      length(domain) <= 253 && can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", domain))
    ])
    error_message = "Every subject_alternative_names entry must be a valid fully qualified domain name with no empty labels or leading or trailing hyphens."
  }

  validation {
    condition     = !contains([for domain in var.subject_alternative_names : lower(domain)], lower(var.domain_name))
    error_message = "domain_name must not be repeated in subject_alternative_names."
  }

  validation {
    condition     = length(distinct([for domain in var.subject_alternative_names : lower(domain)])) == length(var.subject_alternative_names)
    error_message = "subject_alternative_names must not contain case-insensitive duplicates."
  }

  validation {
    condition = alltrue([
      for domain in var.subject_alternative_names :
      lower(domain) == lower(var.dns_zone_name) ||
      endswith(lower(domain), ".${lower(var.dns_zone_name)}")
    ])
    error_message = "Every subject_alternative_names entry must be the dns_zone_name apex or a subdomain of dns_zone_name."
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
  description = "Azure resource ID of the Key Vault the issued PFX is imported into. The principal running `terraform apply` must hold certificate import and update rights on this vault (Key Vault Certificates Officer in RBAC mode, or Get/Import/Update on certificates in legacy access-policy mode; Update applies tag changes to an existing certificate; destroy also needs Delete, plus Purge when the azurerm provider purges soft-deleted certificates, and re-creating a soft-deleted certificate needs Recover). The App Gateway's user-assigned identity that consumes the cert at runtime needs read access to the vault's secrets (Key Vault Secrets User in RBAC mode, or Get on secrets in legacy access-policy mode), which this submodule does not grant: set the root module's app_gateway_keyvault_id with app_gateway_keyvault_role_assignment_enabled = true, or grant it out-of-band."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.KeyVault/vaults/.+$", var.key_vault_id))
    error_message = "key_vault_id must be a fully qualified Azure Key Vault resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>)."
  }
}

variable "friendly_name_prefix" {
  description = "Short, lowercase name prefix used in the imported certificate's name, `<friendly_name_prefix>-n8n-tls`, which is also its `Name` tag (e.g. `n8nprod`, `n8ndev`). Mirrors the root module's variable to keep naming/tagging consistent across the IaaS + TLS surfaces. 2–12 chars, lowercase alphanumeric only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must be 2–12 characters of lowercase letters and digits."
  }
}

variable "common_tags" {
  description = "Tags merged onto the Key Vault certificate this submodule imports, on top of the baseline `ManagedBy = terraform` and `Project = n8n` tags (caller values win). The `Name` tag is always set to the certificate name. Key Vault allows at most 15 tags per certificate, so the merged map must not exceed 15 keys."
  type        = map(string)
  default     = {}

  # Key Vault caps certificates at 15 tags. Count the merged map the module
  # actually sends (baseline + caller + Name) so the limit fails at plan,
  # not at apply. Azure still enforces per-tag name/value lengths at apply.
  validation {
    condition     = length(merge({ ManagedBy = "", Project = "", Name = "" }, var.common_tags)) <= 15
    error_message = "common_tags plus the module's ManagedBy, Project, and Name tags must total at most 15 keys: Key Vault allows at most 15 tags per certificate."
  }
}
