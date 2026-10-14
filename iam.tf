# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── IAM (cross-resource identities and role assignments) ────────────────
# Moved from `modules/infra/iam.tf` into this root concern file per
# align-azure-with-aws-capabilities sections 2 and 11. The n8n workload
# federation is always present. AGIC's explicit forward-reference identity and
# both resource-group Reader grants are gated with create_ingress; the addon's
# gateway-, TLS-identity-, and subnet-scoped permissions live in ingress.tf.

# ── AGIC identities and resource-group permissions ──────────────────────

# The resource group scope comes from the AGIC identity's resource ID rather
# than a `data "azurerm_resource_group"` lookup. A caller's module-level
# `depends_on` with any pending change defers every data source inside the
# module to apply time, which made the scope unknown at plan time and planned
# a destroy-and-recreate of both Reader assignments (scope forces
# replacement) even though the resource group never changed. A managed
# resource's ID already in state stays known at plan time, and the UAMI lives
# in var.resource_group_name, so its ID carries the same
# /subscriptions/<sub>/resourceGroups/<rg> prefix the lookup returned (on
# azurerm before 4.54.0 the lookup used Azure's stored name casing instead
# of var.resource_group_name's; see CHANGELOG.md for that upgrade case). On the
# first apply the UAMI does not exist yet, so the scope is unknown exactly as
# long as the assignments themselves are being created.
locals {
  agic_resource_group_scope = var.create_ingress ? regex("^/subscriptions/[^/]+/resourceGroups/[^/]+", azurerm_user_assigned_identity.agic[0].id) : null
}

# The AKS ingress_application_gateway addon currently creates and uses its own
# identity. Keep this explicit UAMI as the stable identity contract for a future
# switch to a separately installed AGIC controller without changing its Azure
# name or resource-group Reader scope.
resource "azurerm_user_assigned_identity" "agic" {
  count = var.create_ingress ? 1 : 0

  name                = "${var.friendly_name_prefix}-agic"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-agic" })
}

resource "azurerm_role_assignment" "agic_rg_reader" {
  count = var.create_ingress ? 1 : 0

  scope                = local.agic_resource_group_scope
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic[0].principal_id
}

resource "azurerm_role_assignment" "agic_addon_rg_reader" {
  count = var.create_ingress ? 1 : 0

  scope                = local.agic_resource_group_scope
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.n8n[0].ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# ── Federated identity credential (AKS workload identity → n8n SA) ──────
# Wires the n8n_workload UAMI (aks.tf) to the active workload service account
# in the n8n namespace through the AKS cluster's OIDC issuer URL. The chart owns
# that account by default. When image pull Secrets are configured, Terraform
# owns a distinct account instead, and local.n8n_service_account_name keeps the
# federated subject and Helm values aligned without accepting registry
# credentials through module inputs.
#
# Subject string format is fixed by the AKS workload identity contract:
#   system:serviceaccount:<namespace>:<serviceaccount-name>
#
# Two azurerm notes carried over from modules/infra/iam.tf:
#   1. `resource_group_name` is OMITTED: deprecated in azurerm 4.x and
#      removed in 5.0; the credential is scoped to its parent UAMI
#      (`user_assigned_identity_id`), which itself carries the RG.
#   2. `parent_id` was renamed to `user_assigned_identity_id` in azurerm
#      4.x and removed in 5.0, where `user_assigned_identity_id` is required.
resource "azurerm_federated_identity_credential" "n8n_workload" {
  name                      = "${var.friendly_name_prefix}-n8n-workload-fed"
  user_assigned_identity_id = azurerm_user_assigned_identity.n8n_workload.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.effective_aks_oidc_issuer_url
  subject                   = "system:serviceaccount:${local.n8n_namespace}:${local.n8n_service_account_name}"
}
