# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# After the live-apply rehearsal switched this submodule from
# `hashicorp/tls` + `azurerm_key_vault_certificate.contents`-import to
# Key Vault's native Self issuer (KV generates the keypair + signs the
# cert + stores PFX internally), the submodule's only provider is
# `azurerm`. The previous `hashicorp/tls` dependency is gone, which
# matches the PRD goal of keeping the provider tree on the apply host
# minimal.
#
# Provider configuration (subscription, tenant, auth shape) is the caller's
# job — see the provider example in this submodule's README.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # azurerm_key_vault_certificate is unchanged between 4.x and 5.x, so
      # this helper accepts both majors; the root module requires 5.x.
      version = ">= 4.0, < 6.0.0"
    }
  }
}
