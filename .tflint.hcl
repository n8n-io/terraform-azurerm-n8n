# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# tflint config for the terraform-azurerm-n8n module.
#
# Pinned at module root and reused by examples/complete via the
# TFLINT_CONFIG_FILE env var in `.github/workflows/terraform-tests.yml`,
# so both targets share the same ruleset and plugin pin.

config {
  call_module_type = "local"
}

# Built-in Terraform language ruleset (recommended preset).
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Azure provider ruleset. Bump together with the azurerm provider pin in
# `versions.tf` (currently `>= 4.39.0, < 5.0.0`); the azurerm ruleset tracks azurerm
# resource argument changes.
plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
