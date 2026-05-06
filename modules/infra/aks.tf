# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── AKS ──────────────────────────────────────────────────────────────────────
# AKS cluster + optional user node pool + AKS-side user-assigned identities,
# moved into modules/infra/ as part of Phase 5 R5.1b (registry-hardening
# US-015). The shape mirrors the root aks.tf the previous campaign produced
# in US-009 / US-014:
#
#   - Azure CNI on the caller-supplied subnet (var.aks_subnet_id).
#   - OIDC issuer + workload identity enabled. modules/workload/ wires the
#     n8n service-account federation against `oidc_issuer_url` and
#     `n8n_workload_uami_client_id` (US-021..US-024).
#   - Cluster autoscaler bounded by var.aks_node_count_min /
#     var.aks_node_count_max, auto_scaler_profile tuned for n8n's workload
#     mix (queue workers churn fastest).
#   - Optional second node pool (azurerm_kubernetes_cluster_node_pool.n8n_user)
#     so a future story can taint it for n8n-only scheduling without
#     touching the system pool that runs CoreDNS / AGIC / KEDA.
#
# Deferred wiring (added in later Phase 5 stories so terraform validate stays
# green while modules/infra/ is built up incrementally):
#
#   - postgres_cmk / storage_cmk identities are bound to their owning
#     resources in US-016 / US-018 respectively — they live in
#     modules/infra/iam.tf alongside the postgres / storage resources, not
#     here.
#
# AGIC addon (added in US-019): the `ingress_application_gateway` block below
# enables the AKS Application Gateway Ingress Controller addon and points it
# at `azurerm_application_gateway.n8n` (modules/infra/ingress.tf). The addon
# auto-creates its OWN UAMI for AGIC; the runtime Contributor / Reader role
# assignments that bind that auto-created identity live in `ingress.tf`
# (App-Gateway-scoped Contributor) and `iam.tf` (RG-scoped Reader). The
# explicit `agic` UAMI in `iam.tf` is unused at runtime — kept as a forward
# reference for a future story that disables the addon.
#
# Identity:
#   - Cluster identity = SystemAssigned (the simplest viable path; no
#     pre-create role-assignment dance with the kubelet UAMI).
#   - Kubelet identity is left to Azure (auto-created at cluster create).
#     The `aks_kubelet` UAMI declared below is currently unbound — kept in
#     place as a forward reference for a future story that needs a stable
#     kubelet identity (e.g. private-ACR image pulls via AcrPull, or CMK
#     Disk Encryption Set wiring). The matching Network Contributor role
#     assignment on `var.aks_subnet_id` is similarly dormant until the
#     binding is wired.

resource "azurerm_kubernetes_cluster" "n8n" {
  name                = local.cluster_name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = local.cluster_name
  kubernetes_version  = var.aks_kubernetes_version

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name           = "system"
    vm_size        = var.aks_node_vm_size
    vnet_subnet_id = var.aks_subnet_id

    auto_scaling_enabled = true
    min_count            = var.aks_node_count_min
    max_count            = var.aks_node_count_max

    upgrade_settings {
      max_surge = "10%"
    }
  }

  auto_scaler_profile {
    expander                      = "least-waste"
    scale_down_unneeded           = "10m"
    scale_down_unready            = "20m"
    skip_nodes_with_local_storage = false
    skip_nodes_with_system_pods   = true
  }

  # Azure CNI. service_cidr is set to 172.16.0.0/16 so the cluster Service
  # range will not collide with the common 10.0.0.0/16 enterprise VNet
  # space (the Azure default of 10.0.0.0/16 frequently overlaps).
  network_profile {
    network_plugin    = "azure"
    service_cidr      = "172.16.0.0/16"
    dns_service_ip    = "172.16.0.10"
    load_balancer_sku = "standard"
  }

  # AGIC addon (US-019) — points at the BYO Application Gateway in
  # `ingress.tf`. The addon auto-creates its own UAMI for AGIC; the runtime
  # Contributor (App-Gateway-scoped) / Reader (RG-scoped) role assignments
  # are wired in `ingress.tf` and `iam.tf` respectively.
  ingress_application_gateway {
    gateway_id = azurerm_application_gateway.n8n.id
  }

  tags = merge(local.common_tags, { Name = local.cluster_name })

  # depends_on is redundant with the implicit reference inside
  # `ingress_application_gateway.gateway_id`, but is documented explicitly
  # here so the resource ordering is unambiguous in the file the addon is
  # wired in (mirrors the root aks.tf shape).
  depends_on = [azurerm_application_gateway.n8n]
}

# ── Optional user node pool ──
# Second pool for n8n workloads, mode = "User" by default. Sized identically
# to the system pool today (same SKU, same autoscaler bounds); split out
# explicitly so a future story can taint it for n8n-only scheduling.
resource "azurerm_kubernetes_cluster_node_pool" "n8n_user" {
  name                  = "n8nuser"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.n8n.id
  vm_size               = var.aks_node_vm_size
  vnet_subnet_id        = var.aks_subnet_id

  auto_scaling_enabled = true
  min_count            = var.aks_node_count_min
  max_count            = var.aks_node_count_max

  upgrade_settings {
    max_surge = "10%"
  }

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-user" })
}

# ── User-Assigned Identities ──
# AKS kubelet identity — the AKS node pool runs under this identity (e.g.
# for image pulls). Currently unbound (the cluster uses SystemAssigned);
# the resource is kept as a forward reference for future stories that need
# a stable kubelet identity (private-ACR pulls via AcrPull, CMK Disk
# Encryption Set, etc.). The matching Network Contributor role assignment
# on `var.aks_subnet_id` (below) is similarly dormant until binding lands.
resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "${var.friendly_name_prefix}-aks-kubelet"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-aks-kubelet" })
}

# n8n workload identity — federated to the n8n Kubernetes service account so
# n8n pods can authenticate to Azure services without storing static
# credentials. The matching `azurerm_federated_identity_credential.n8n_workload`
# resource is in `iam.tf` (registry-hardening US-023) — it lives in this
# submodule rather than modules/workload/ because the credential is an
# azurerm-tier resource (federates an Azure UAMI to an external IDP) and
# modules/workload/ is a chart-only consumer with no `azurerm` provider.
# The credential's `subject` string carries the n8n namespace + chart
# service-account name as literals; both must stay in lockstep with
# modules/workload/locals.tf (`local.n8n_namespace = "n8n"`) and the n8n
# Helm chart's hardcoded SA name ("n8n-enterprise").
resource "azurerm_user_assigned_identity" "n8n_workload" {
  name                = "${var.friendly_name_prefix}-n8n-workload"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-n8n-workload" })
}

# ── Role Assignments ──
# AKS kubelet: Network Contributor on the caller-supplied AKS subnet, so
# the kubelet identity can attach pod IPs (Azure CNI). Dormant until the
# kubelet UAMI is bound to the cluster (see comment on the UAMI above).
resource "azurerm_role_assignment" "aks_kubelet_subnet_network_contributor" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

# ── AKS API warm-up gate ────────────────────────────────────────────────────
# Replaces the legacy `null_resource.wait_for_aks_api` (registry-hardening
# US-003). Azure reports the AKS resource as `Succeeded` before `/healthz`
# is consistently green; the kubernetes and helm providers fire 503s
# (`EOF`, `the server is currently unable to handle the request`) against
# the control plane until it finishes warming. The legacy probe poll-loop
# (60 attempts × 10 s on /healthz, executed via `az aks get-credentials`
# + `kubectl`) is replaced by:
#
#   1. A small fixed warm-up window (`var.aks_api_warmup_seconds`,
#      default 90 s, range 30..600) gated on this `time_sleep`. Long
#      enough to cover the typical AKS post-provision warm-up; short
#      enough that a transient burst of 503s after the gate is left to:
#   2. The kubernetes/helm providers' built-in retry on transient API
#      errors (configured via certificate-based provider auth in the
#      caller's providers.tf — no kubelogin/exec dependency).
#
# Lives in modules/infra/ rather than modules/workload/ because the
# workload submodule consumes the kubeconfig output downstream of this
# gate; the gate must run before any kubernetes/helm provider call. The
# `triggers` map re-fires the gate when the cluster is recreated.
resource "time_sleep" "aks_api_warmup" {
  create_duration = "${var.aks_api_warmup_seconds}s"

  triggers = {
    cluster_id = azurerm_kubernetes_cluster.n8n.id
  }

  depends_on = [azurerm_kubernetes_cluster.n8n]
}
