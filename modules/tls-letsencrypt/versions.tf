# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# This submodule keeps the `vancluever/acme` and `hashicorp/tls` providers out
# of the root module. Callers that already have a certificate do not initialize
# this submodule, so Terraform does not pull the ACME provider tree.
#
# Provider configuration (subscription, ACME server URL, AZURE_* env-var
# resolution for the lego DNS-01 challenge against Azure DNS) is the
# caller's job — see the provider example in this submodule's README.

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
