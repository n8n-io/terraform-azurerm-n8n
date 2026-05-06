# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── IAM (cross-resource UAMIs + role assignments) ────────────────────────────
# Identities and role assignments that don't logically belong to a single
# resource live here. Per the project convention, identities used by exactly
# one resource (e.g. AKS kubelet, n8n workload) live in the same file as that
# resource — see `aks.tf`. This file holds the pieces that span concerns:
#
#   - The explicit `agic` UAMI — the AKS `ingress_application_gateway` addon
#     auto-creates ITS OWN identity for AGIC (see `aks.tf`), and that
#     auto-created identity is what holds the runtime Contributor / Reader
#     role assignments below. The explicit `agic` UAMI is unused at runtime
#     today — kept in place as a forward reference for a future story that
#     switches off the AKS addon and binds AGIC to this UAMI directly. (Same
#     shape decision the root `iam.tf` documented per the US-008 deferral.)
#
#   - The AGIC role assignments scoped to the BYO resource group
#     (`Reader` on the RG enumerates sibling resources during reconcile;
#     the matching `Contributor` on the App Gateway itself lives in
#     `ingress.tf` because the scope is the App Gateway resource).
#
# The resource group is BYO via `var.resource_group_name`. We need the RG's
# resource ID for the `Reader` role assignment scopes — Azure RBAC scopes
# are full resource IDs, not names — so this file looks the RG up via a data
# source. Under `mock_provider "azurerm"` the data source resolves to a
# synthetic `id` value, so plan-time tests still pass without Azure
# credentials.

data "azurerm_resource_group" "n8n" {
  name = var.resource_group_name
}

# ── User-Assigned Identities ──
# AGIC explicit identity — unused at runtime because the AKS
# `ingress_application_gateway` addon auto-creates its own identity. Kept as
# a forward reference for future stories that may disable the addon and
# attach AGIC to this UAMI directly. The matching role assignments below
# (`agic_rg_reader`) bind THIS explicit UAMI to the resource group; the
# parallel `agic_addon_*` role assignments bind the auto-created addon
# identity instead.
resource "azurerm_user_assigned_identity" "agic" {
  name                = "${var.friendly_name_prefix}-agic"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-agic" })
}

# ── Role Assignments ──
# AGIC explicit-UAMI: Reader on the BYO resource group. Forward reference
# alongside the `agic` UAMI above — see comment on the UAMI for the deferred
# binding rationale.
resource "azurerm_role_assignment" "agic_rg_reader" {
  scope                = data.azurerm_resource_group.n8n.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# AGIC addon's auto-created identity: Reader on the BYO resource group so it
# can enumerate sibling resources during AGIC's reconcile loop. The matching
# Contributor scope on the App Gateway itself lives in `ingress.tf`. The
# principal_id is read off the AKS cluster's `ingress_application_gateway`
# computed attribute (the addon block in `aks.tf`).
resource "azurerm_role_assignment" "agic_addon_rg_reader" {
  scope                = data.azurerm_resource_group.n8n.id
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.n8n.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# ── Federated identity credential (AKS workload identity → n8n SA) ───────────
# Wires the n8n_workload UAMI (defined in aks.tf) to the chart-created service
# account "n8n-enterprise" in the n8n namespace via the AKS cluster's OIDC
# issuer URL.
#
# Lives in modules/infra/ rather than modules/workload/ — the credential is
# an azurerm-tier resource (it federates an Azure UAMI to an external IDP),
# so it naturally belongs alongside the UAMI in the IaaS submodule. Moving
# it here (rather than into modules/workload/iam.tf as the PRD US-023 AC's
# literal text suggested) preserves the chart-only consumer posture
# documented in modules/workload/AGENTS.md ("Don't add an `azurerm` provider
# here") and keeps modules/workload/'s five-provider count
# (kubernetes / helm / random / time / kubectl) on track for the US-026
# final-state KPI of four. The credential's only Kubernetes-side metadata
# is two literal strings (the namespace and the chart-rendered service
# account name) — it has no actual cross-tier resource dependency, so
# either submodule can host it without resource-graph contortions. The
# matched literals must stay in lockstep with modules/workload/locals.tf
# (`local.n8n_namespace = "n8n"`) and the n8n Helm chart's hardcoded
# service-account name ("n8n-enterprise"); a rename on either side
# requires an edit here.
#
# Subject string format is fixed by the AKS workload identity contract:
#   system:serviceaccount:<namespace>:<serviceaccount-name>
#
# Two azurerm v5 forward-compat tweaks vs the prototype shape:
#   1. `resource_group_name` is OMITTED — deprecated in azurerm 4.x with
#      "This field is no longer used and will be removed in the next
#      major version of the Azure Provider". The credential is scoped to
#      its parent UAMI (via `user_assigned_identity_id`), which itself
#      carries the RG; Terraform / azurerm derive the RG from the parent.
#   2. `parent_id` was renamed to `user_assigned_identity_id` in azurerm
#      4.x with "`parent_id` has been renamed to
#      `user_assigned_identity_id` and will be removed in v5.0 of the
#      AzureRM Provider". Both names accept the same
#      `azurerm_user_assigned_identity.<name>.id` value; the v5-stable
#      name is `user_assigned_identity_id`.
resource "azurerm_federated_identity_credential" "n8n_workload" {
  name                      = "${var.friendly_name_prefix}-n8n-workload-fed"
  user_assigned_identity_id = azurerm_user_assigned_identity.n8n_workload.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.n8n.oidc_issuer_url
  subject                   = "system:serviceaccount:n8n:n8n-enterprise"
}
