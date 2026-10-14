# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Azure Customer Usage Attribution (CUA) ──────────────────────────────────
# Microsoft associates usage in a customer subscription with a partner when a
# deployment named `pid-<guid>` (type Microsoft.Resources/deployments) exists
# in the scope. The module configures no providers, so the azurerm provider's
# `partner_id` is the caller's to set; this empty template is the route the
# module can own. See openspec/changes/add-azure-partner-attribution/design.md.

locals {
  azure_partner_attribution_name = var.azure_partner_attribution_id == "" ? null : (
    startswith(lower(var.azure_partner_attribution_id), "pid-") ? var.azure_partner_attribution_id : "pid-${var.azure_partner_attribution_id}"
  )
}

resource "azurerm_resource_group_template_deployment" "partner_attribution" {
  count = local.azure_partner_attribution_name == null ? 0 : 1

  name                = local.azure_partner_attribution_name
  resource_group_name = var.resource_group_name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources      = []
  })

  tags = local.common_tags
}
