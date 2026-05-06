# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# This submodule's required_providers list is the reason it exists: pulling
# the `vancluever/acme` and `hashicorp/tls` providers OUT of the root module
# is the structural change Phase 4 R4.3 (US-012) is preparing for. Consumers
# who already have a PFX (the production-majority `custom_pfx` path) avoid
# initialising this submodule entirely, so terraform init no longer pulls
# the acme provider tree on the apply host.
#
# Provider configuration (subscription, ACME server URL, AZURE_* env-var
# resolution for the lego DNS-01 challenge against Azure DNS) is the
# caller's job — see examples/complete-letsencrypt/providers.tf (US-011).

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
