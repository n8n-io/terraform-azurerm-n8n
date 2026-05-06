# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values: the common tag set merged onto every taggable resource and
# deterministic resource names derived from `var.friendly_name_prefix`. Every
# name embeds the prefix so sibling deployments in the same subscription /
# region don't collide on the globally-unique Azure namespaces (storage
# account, Key Vault, App Gateway public-IP DNS label).
#
# Mirrored from the root module's `locals.tf` — the resource-name shape stays
# stable as resources move out of the root and into this submodule per
# US-015..US-019. `key_vault_name` is included for consumers that want to
# create their own Key Vault for the App Gateway TLS secret; the root module
# itself no longer owns a Key Vault (registry-hardening US-012 collapsed the
# legacy `var.tls_mode` surface into a single BYO-secret contract).
#
# Azure name-length limits the names below must respect:
#   - Storage Account   3–24 chars (lowercase alnum only — no hyphens)
#   - PostgreSQL FS     3–63 chars (lowercase + digits + hyphens)
#   - AKS cluster       1–63 chars (alnum + hyphens)
#   - Redis Cache       1–63 chars (alnum + hyphens)
#   - Key Vault         3–24 chars (alnum + hyphens)
#
# `friendly_name_prefix` is validated as ^[a-z0-9]{2,12}$ in variables.tf, so
# every suffix below fits within the tightest 24-char Storage Account / Key
# Vault limit. `substr()` is defensive truncation in case that validation is
# ever loosened.

locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.common_tags,
  )

  cluster_name         = "${var.friendly_name_prefix}-aks"
  postgres_server_name = "${var.friendly_name_prefix}-postgres"
  redis_cache_name     = "${var.friendly_name_prefix}-redis"
  # Reserved as a name-shape reference for callers that want to provision
  # their own Key Vault for the App Gateway TLS secret with the same prefix
  # convention this module uses. This module no longer owns a Key Vault
  # (registry-hardening US-012 collapsed `var.tls_mode` into a BYO-secret
  # contract) so no resource consumes it directly.
  # tflint-ignore: terraform_unused_declarations
  key_vault_name       = substr("${var.friendly_name_prefix}-n8n-kv", 0, 24)
  storage_account_name = substr("${var.friendly_name_prefix}n8nfiles", 0, 24)
  app_gateway_name     = "${var.friendly_name_prefix}-appgw"
  appgw_pip_name       = "${var.friendly_name_prefix}-appgw-pip"
}
