# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── AKS and identity foundation ──────────────────────────────────────────
# Moved from `modules/infra/aks.tf` + `modules/infra/iam.tf` into this root
# concern file per align-azure-with-aws-capabilities section 2. Mirrors the
# AWS sibling's `eks.tf` shape (cluster + node group + identity + the
# autoscaler-owned-node-count guard) with the Azure-specific additions
# design.md decision 2 calls out: availability zones, API authorized
# ranges, explicit upgrade surge, OIDC + workload identity, and the AKS API
# warm-up gate (a proven Azure provider timing fix — see the comment on
# `time_sleep.aks_api_warmup` below).
#
# Section 11 conditionally enables the AKS-managed AGIC addon below. The addon
# receives the module-managed gateway ID only when create_ingress is true, so
# caller-owned ingress creates no controller identity or Azure integration.
#
# Identity shape:
#   - Cluster identity = SystemAssigned — the simplest viable path; no
#     pre-create role-assignment dance with a kubelet UAMI.
#   - Kubelet identity is left to Azure (auto-created at cluster create).
#     A future story that needs a stable kubelet identity (e.g. private-ACR
#     image pulls via AcrPull, or CMK Disk Encryption Set wiring) adds a
#     bound UAMI plus its subnet role assignment then — an internal pre-release
#     iteration removed the dormant `aks_kubelet` UAMI so no unbound identity holds Network
#     Contributor on the caller's subnet in the meantime.
#   - `n8n_workload` UAMI is federated to the n8n chart's Kubernetes service
#     account below so n8n pods can authenticate to Azure services (Blob
#     Storage in section 5) without static credentials.

resource "azurerm_kubernetes_cluster" "n8n" {
  count = var.create_aks ? 1 : 0

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
    name                        = "system"
    temporary_name_for_rotation = "systemtemp"
    vm_size                     = local.aks_system_node_vm_size_effective
    vnet_subnet_id              = var.aks_subnet_id
    zones                       = var.aks_availability_zones
    os_disk_size_gb             = var.aks_node_os_disk_size_gb

    node_count           = local.aks_system_node_count_min_effective
    auto_scaling_enabled = true
    min_count            = local.aks_system_node_count_min_effective
    max_count            = local.aks_system_node_count_max_effective

    upgrade_settings {
      max_surge = var.aks_node_upgrade_max_surge
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

  # API authorized ranges (HVD-inspired addition — see design.md decision
  # 2 and the autoscaling-and-capacity spec's "Restrict the control plane"
  # scenario). Omit the block entirely when the list is empty so the API
  # server stays on its default (publicly reachable) access profile; Azure
  # rejects an `api_server_access_profile` block with an empty
  # `authorized_ip_ranges` list differently than omitting the block, so the
  # dynamic block (not a static block with a conditional list) is required.
  dynamic "api_server_access_profile" {
    for_each = length(var.aks_api_authorized_ip_ranges) > 0 ? [1] : []

    content {
      authorized_ip_ranges = var.aks_api_authorized_ip_ranges
    }
  }

  dynamic "ingress_application_gateway" {
    for_each = var.create_ingress ? [1] : []

    content {
      gateway_id = azurerm_application_gateway.n8n[0].id
    }
  }

  tags = merge(local.common_tags, { Name = local.cluster_name })

  # The cluster autoscaler owns default_node_pool[0].node_count after
  # creation (min_count/max_count above bound its range). Without this,
  # every plan after a scale-out event proposes resetting node_count back
  # to var.aks_node_count_min, and applying that drains live nodes — see
  # the autoscaling-and-capacity spec's "Autoscaler-owned node count"
  # requirement and the AWS sibling's aws_eks_node_group.n8n equivalent in
  # eks.tf.
  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# ── Optional user node pool ──
# Second pool for n8n workloads, mode = "User" by default. Sized from
# aks_node_vm_size/aks_node_count_min/aks_node_count_max, matching the system
# pool's sizing unless aks_system_node_* overrides it (locals.tf); split out
# explicitly so a future story can taint it for n8n-only scheduling.
resource "azurerm_kubernetes_cluster_node_pool" "n8n_user" {
  count = var.create_aks ? 1 : 0

  name                        = "n8nuser"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.n8n[0].id
  vm_size                     = var.aks_node_vm_size
  vnet_subnet_id              = var.aks_subnet_id
  zones                       = var.aks_availability_zones
  os_disk_size_gb             = var.aks_node_os_disk_size_gb
  temporary_name_for_rotation = "n8nusrtemp"

  node_count           = var.aks_node_count_min
  auto_scaling_enabled = true
  min_count            = var.aks_node_count_min
  max_count            = var.aks_node_count_max

  upgrade_settings {
    max_surge = var.aks_node_upgrade_max_surge
  }

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-user" })

  lifecycle {
    ignore_changes = [node_count]
  }
}

# ── User-Assigned Identities ──

resource "azurerm_user_assigned_identity" "n8n_workload" {
  name                = "${var.friendly_name_prefix}-n8n-workload"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-n8n-workload" })
}

# ── AKS API warm-up gate ──────────────────────────────────────────────────
# Azure reports the AKS resource as `Succeeded` before `/healthz` is
# consistently green; the kubernetes and helm providers fire 503s (`EOF`,
# `the server is currently unable to handle the request`) against the
# control plane until it finishes warming.
#
#   1. A small fixed warm-up window (`var.aks_api_warmup_seconds`, default
#      90 s, range 30..600) gated on this `time_sleep`. Long enough to
#      cover the typical AKS post-provision warm-up; short enough that a
#      transient burst of 503s after the gate is left to:
#   2. The kubernetes/helm providers' built-in retry on transient API
#      errors (configured via certificate-based provider auth in the
#      caller's providers.tf — no kubelogin/exec dependency).
#
# Every downstream Kubernetes-/Helm-provider resource this module creates
# (controllers.tf, keda.tf, n8n.tf — sections 6+) must depend on this gate,
# directly or transitively. The `triggers` map re-fires the gate when the
# cluster is recreated.
resource "time_sleep" "aks_api_warmup" {
  count = var.create_aks ? 1 : 0

  create_duration = "${var.aks_api_warmup_seconds}s"

  triggers = {
    cluster_id = azurerm_kubernetes_cluster.n8n[0].id
  }

  depends_on = [azurerm_kubernetes_cluster.n8n]
}

# ── Existing AKS lookup ────────────────────────────────────────────────────
# The only exception to the rule against inspecting customer-managed Azure
# resources (design.md decision 2): workload federation needs the existing
# cluster's OIDC issuer, and the root's stable outputs need connection
# material. This reads identity/connection coordinates, not a security audit
# of the cluster's configuration — that is what
# existing_aks_cluster_prerequisites_confirmed attests to instead.
data "azurerm_kubernetes_cluster" "existing" {
  count = var.create_aks ? 0 : 1

  name                = var.existing_aks_cluster_name
  resource_group_name = var.existing_aks_resource_group_name
}
