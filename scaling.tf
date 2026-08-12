# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── HPA: n8n webhook processor pods ─────────────────────────────────────────
# The chart suppresses its webhook HPA whenever KEDA is enabled for workers.
# This module therefore owns the webhook HPA directly while the chart renders
# the independent main HPA. Workers remain queue-depth driven through KEDA.
resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook" {
  metadata {
    name      = "n8n-webhook-processor"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "n8n-webhook-processor"
    }

    min_replicas = var.n8n_webhook_hpa_min_replicas
    max_replicas = var.n8n_webhook_hpa_max_replicas

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = var.n8n_webhook_hpa_cpu_threshold
        }
      }
    }

    # Once behavior is present, the provider requires at least one policy. The
    # two policies and Max selection reproduce Kubernetes' default scale-up
    # behavior while exposing only the stabilization window.
    behavior {
      scale_up {
        stabilization_window_seconds = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }

        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}

# ── Advisory AKS CPU capacity model ──────────────────────────────────────────
# Workload autoscaler ceilings and AKS node-pool ceilings are independent. If
# all pod families can request more CPU than the cluster can ever schedule,
# pods remain Pending after both node pools reach aks_node_count_max.
#
# The model uses a reviewed, explicit VM SKU map rather than an Azure data
# source. A data source can remain unknown during planning, which would turn an
# advisory check into an error. Azure VM SKUs outside this map remain valid and
# simply suppress the diagnostic. The Dsv4, Dsv5, and Dsv7 values come from Microsoft's
# VM size tables:
# https://learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dsv4-series
# https://learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dsv5-series
# https://learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dsv7-series
locals {
  aks_vm_sku_vcpus = {
    Standard_D2s_v4  = 2
    Standard_D4s_v4  = 4
    Standard_D8s_v4  = 8
    Standard_D16s_v4 = 16
    Standard_D32s_v4 = 32
    Standard_D48s_v4 = 48
    Standard_D64s_v4 = 64
    Standard_D2s_v5  = 2
    Standard_D4s_v5  = 4
    Standard_D8s_v5  = 8
    Standard_D16s_v5 = 16
    Standard_D32s_v5 = 32
    Standard_D48s_v5 = 48
    Standard_D64s_v5 = 64
    Standard_D96s_v5 = 96
    Standard_D2s_v7  = 2
    Standard_D4s_v7  = 4
    Standard_D8s_v7  = 8
    Standard_D16s_v7 = 16
    Standard_D32s_v7 = 32
    Standard_D48s_v7 = 48
    Standard_D64s_v7 = 64
    Standard_D96s_v7 = 96
  }

  aks_node_vcpus_derived = lookup(local.aks_vm_sku_vcpus, var.aks_node_vm_size, null)
  aks_node_vcpus         = coalesce(local.aks_node_vcpus_derived, 0)

  # Microsoft documents these AKS kube-reserved CPU values in millicores. The
  # 48 and 96 vCPU entries continue the documented 10m-per-core increment above
  # 4 vCPU. These reservations are unavailable to pods before any DaemonSet or
  # application request is considered.
  # https://learn.microsoft.com/azure/aks/node-resource-reservations
  aks_kube_reserved_cpu_by_vcpu = {
    "2"  = 100
    "4"  = 140
    "8"  = 180
    "16" = 260
    "32" = 420
    "48" = 580
    "64" = 740
    "96" = 1060
  }
  aks_node_kube_reserved_cpu_millis = lookup(
    local.aks_kube_reserved_cpu_by_vcpu,
    tostring(local.aks_node_vcpus),
    0,
  )

  # Fixed request allowances for node-local AKS agents. They cover Azure CNI,
  # kube-proxy, and the Azure Disk or Files CSI node containers. Exact requests
  # can move with AKS and add-on versions, so this remains an advisory model.
  aks_node_daemon_cpu_requests_millis = {
    azure_network_agents = 100
    kube_proxy           = 100
    csi_node_agents      = 60
  }
  aks_node_daemon_cpu_millis = sum(values(local.aks_node_daemon_cpu_requests_millis))

  # Cluster-wide control workload allowances are subtracted once. They cover
  # two CoreDNS replicas, metrics-server, KEDA's operator, metrics server and
  # admission webhook, CSI controllers, and the Application Gateway ingress
  # controller added by the module's managed-ingress path.
  aks_cluster_control_cpu_requests_millis = {
    coredns                  = 200
    metrics_server           = 100
    keda                     = 300
    csi_controllers          = 120
    application_gateway_agic = 100
  }
  aks_cluster_control_cpu_millis = sum(values(local.aks_cluster_control_cpu_requests_millis))

  # The root creates one system pool and one untainted user pool, both with the
  # same maximum. n8n pods may schedule on either, so both contribute capacity.
  aks_modeled_node_count = var.aks_node_count_max * 2

  aks_node_schedulable_cpu_millis = max(
    local.aks_node_vcpus * 1000 - local.aks_node_kube_reserved_cpu_millis - local.aks_node_daemon_cpu_millis,
    0,
  )
  n8n_schedulable_cpu_millis = max(
    local.aks_modeled_node_count * local.aks_node_schedulable_cpu_millis - local.aks_cluster_control_cpu_millis,
    0,
  )

  # Kubernetes CPU quantities accepted by variables.tf are decimal cores or
  # millicores. Normalize both forms before multiplying by autoscaler maxima.
  n8n_cpu_requests = {
    main        = var.n8n_main_cpu_request
    worker      = var.n8n_worker_cpu_request
    webhook     = var.n8n_webhook_cpu_request
    task_runner = var.n8n_task_runners_enabled ? var.n8n_task_runner_cpu_request : "0"
  }
  n8n_cpu_request_millis = {
    for name, quantity in local.n8n_cpu_requests : name => (
      endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000
    )
  }

  n8n_peak_cpu_request_millis = (
    var.n8n_main_hpa_max_replicas * (local.n8n_cpu_request_millis.main + local.n8n_cpu_request_millis.task_runner) +
    var.n8n_worker_keda_max_replicas * (local.n8n_cpu_request_millis.worker + local.n8n_cpu_request_millis.task_runner) +
    var.n8n_webhook_hpa_max_replicas * local.n8n_cpu_request_millis.webhook
  )

  n8n_capacity_model_readable = local.aks_node_vcpus_derived != null
}

# A check emits a warning without blocking plan or apply. The model is
# intentionally approximate because callers can add workloads and AKS add-on
# requests can change. Unknown VM SKUs stay silent rather than warning from a
# guessed vCPU count.
check "autoscaling_maxima_fit_aks_capacity" {
  assert {
    condition = local.n8n_capacity_model_readable ? (
      local.n8n_peak_cpu_request_millis <= local.n8n_schedulable_cpu_millis
    ) : true
    error_message = join("", [
      "Autoscaler maxima request ${local.n8n_peak_cpu_request_millis}m CPU, but the modeled AKS supply leaves only ",
      "${local.n8n_schedulable_cpu_millis}m schedulable for n8n. Demand is main ",
      "${var.n8n_main_hpa_max_replicas} x ${local.n8n_cpu_request_millis.main + local.n8n_cpu_request_millis.task_runner}m, worker ",
      "${var.n8n_worker_keda_max_replicas} x ${local.n8n_cpu_request_millis.worker + local.n8n_cpu_request_millis.task_runner}m, and webhook ",
      "${var.n8n_webhook_hpa_max_replicas} x ${local.n8n_cpu_request_millis.webhook}m. Supply models two pools at ",
      "aks_node_count_max=${var.aks_node_count_max}, VM size ${var.aks_node_vm_size} (${local.aks_node_vcpus} vCPU per node), ",
      "less ${local.aks_node_kube_reserved_cpu_millis}m AKS reservation and ${local.aks_node_daemon_cpu_millis}m daemon requests per node, ",
      "plus ${local.aks_cluster_control_cpu_millis}m cluster control requests. Lower autoscaler maxima or CPU requests, or raise ",
      "aks_node_count_max or aks_node_vm_size. This diagnostic is advisory and does not fail the plan.",
    ])
  }
}
