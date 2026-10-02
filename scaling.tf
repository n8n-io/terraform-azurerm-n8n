# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── HPA: n8n webhook processor pods ─────────────────────────────────────────
# The chart suppresses its webhook HPA whenever KEDA is enabled for workers.
# This module therefore owns the webhook HPA directly while the chart renders
# the independent main HPA. Workers remain queue-depth driven through KEDA.
resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook" {
  count = var.n8n_webhook_hpa_enabled ? 1 : 0

  metadata {
    name      = "n8n-webhook-processor"
    namespace = local.n8n_namespace
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

# n8n_webhook_hpa_enabled = false leaves the caller responsible for scaling
# the webhook-processor Deployment. Helm still renders it at
# n8n_webhook_hpa_min_replicas (see webhookProcessor.replicaCount in
# n8n.tf), so a platform-managed HPA has a stable Deployment to target.
check "webhook_hpa_tuning_requires_module_managed_webhook_hpa" {
  assert {
    condition = var.n8n_webhook_hpa_enabled ? true : (
      var.n8n_webhook_hpa_max_replicas == 8 &&
      var.n8n_webhook_hpa_cpu_threshold == 65 &&
      var.n8n_webhook_hpa_scale_up_stabilization_window_seconds == 0
    )
    error_message = join("", [
      "An n8n_webhook_hpa_max_replicas, n8n_webhook_hpa_cpu_threshold, or ",
      "n8n_webhook_hpa_scale_up_stabilization_window_seconds override is set while ",
      "n8n_webhook_hpa_enabled = false. The module creates no webhook HPA in that mode, so ",
      "none of these apply — n8n_webhook_hpa_min_replicas still sets the chart-rendered floor. ",
      "Scaling above that floor is the caller-managed autoscaler's responsibility.",
    ])
  }
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

  # The system pool's effective VM size (locals.tf) is looked up the same
  # way, and stays independently silent when only its SKU is unmapped.
  aks_system_node_vcpus_derived = lookup(local.aks_vm_sku_vcpus, local.aks_system_node_vm_size_effective, null)
  aks_system_node_vcpus         = coalesce(local.aks_system_node_vcpus_derived, 0)

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
  aks_system_node_kube_reserved_cpu_millis = lookup(
    local.aks_kube_reserved_cpu_by_vcpu,
    tostring(local.aks_system_node_vcpus),
    0,
  )

  # Fixed request allowances for node-local AKS agents. They cover Azure CNI,
  # kube-proxy, and the Azure Disk or Files CSI node containers. Exact requests
  # can move with AKS and add-on versions, so this remains an advisory model.
  # The same fixed allowance applies to both pools regardless of VM size.
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

  # The root creates one system pool and one untainted user pool. n8n pods may
  # schedule on either, so both contribute capacity, each modeled at its own
  # effective maximum and VM size (locals.tf) — identical by default, and only
  # different when aks_system_node_* overrides the system pool.
  aks_modeled_user_node_count   = var.aks_node_count_max
  aks_modeled_system_node_count = local.aks_system_node_count_max_effective

  aks_node_schedulable_cpu_millis = max(
    local.aks_node_vcpus * 1000 - local.aks_node_kube_reserved_cpu_millis - local.aks_node_daemon_cpu_millis,
    0,
  )
  aks_system_node_schedulable_cpu_millis = max(
    local.aks_system_node_vcpus * 1000 - local.aks_system_node_kube_reserved_cpu_millis - local.aks_node_daemon_cpu_millis,
    0,
  )
  n8n_schedulable_cpu_millis = max(
    local.aks_modeled_user_node_count * local.aks_node_schedulable_cpu_millis +
    local.aks_modeled_system_node_count * local.aks_system_node_schedulable_cpu_millis -
    local.aks_cluster_control_cpu_millis,
    0,
  )

  # Kubernetes CPU quantities accepted by variables.tf are decimal cores or
  # millicores. Normalize both forms before multiplying by autoscaler maxima.
  n8n_cpu_requests = {
    main        = var.n8n_main_cpu_request
    worker      = var.n8n_worker_cpu_request
    webhook     = var.n8n_webhook_cpu_request
    task_runner = var.n8n_task_runners_enabled ? var.n8n_task_runner_cpu_request : "0"
    # Matches the exporter Deployment's single hardcoded CPU request
    # (observability.tf). One replica regardless of any autoscaler maximum,
    # so this contributes a flat amount rather than scaling with a ceiling.
    redis_exporter = var.redis_exporter_enabled ? "10m" : "0"
  }
  n8n_cpu_request_millis = {
    for name, quantity in local.n8n_cpu_requests : name => (
      endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000
    )
  }

  # Verified upstream 1.12.0 (n8n-hosting #179) removes task-runner sidecars
  # from queue-mode mains, unchanged through 1.14.0 (1.13.0 only reworks
  # worker/webhook-processor replica ownership; 1.14.0 only renames the
  # chart's WEBHOOK_URL key, drops an S3-only env var, and aggregates
  # validation errors; deployment-main.yaml's runner placement is untouched).
  # Previews, older or future releases and any chart this list has not been
  # checked against keep the conservative main-sidecar allowance until their
  # topology is verified.
  # Same shape as terraform-aws-n8n's n8n_chart_has_worker_only_runners, minus
  # its repository check (helm_release.n8n hardcodes the upstream OCI
  # repository here) and its build-metadata strip (n8n_chart_version's
  # validation never admits a "+build" suffix).
  n8n_chart_has_worker_only_runners = contains(["1.12.0", "1.13.0", "1.14.0"], var.n8n_chart_version)
  n8n_main_task_runner_cpu_millis   = local.n8n_chart_has_worker_only_runners ? 0 : local.n8n_cpu_request_millis.task_runner

  # keda.worker.pause/pausedReplicaCount shipped in chart 1.12.0
  # (n8n-hosting #177), but 1.12.0 still renders the worker's spec.replicas on
  # every upgrade, which overrides a held count (see
  # check.worker_keda_pause_requires_a_supported_chart in n8n.tf). 1.13.0
  # (n8n-hosting #201) stops rendering it, so "1.13.0 or later" is the test.
  # A version floor, not an allowlist like the one above: this is a
  # feature-presence check with nothing to re-verify per release. The
  # prerelease suffix is stripped and major.minor compared as numbers, so a
  # preview off an older line (examples/worker-pools'
  # "1.11.0-preview.workerpools.1") does not pass. Same shape as
  # terraform-aws-n8n's local of the same name, minus its repository check and
  # build-metadata strip (see n8n_chart_has_worker_only_runners above).
  n8n_worker_keda_pause_chart_version_core = split(".", split("-", var.n8n_chart_version)[0])
  n8n_worker_keda_pause_supported = (
    tonumber(local.n8n_worker_keda_pause_chart_version_core[0]) > 1 ||
    (
      tonumber(local.n8n_worker_keda_pause_chart_version_core[0]) == 1 &&
      tonumber(local.n8n_worker_keda_pause_chart_version_core[1]) >= 13
    )
  )

  # Each n8n_worker_pools entry (worker-pools.tf) autoscales through its own
  # KEDA ScaledObject and can reach its own max_replicas independently of the
  # default worker deployment, and a pool that overrides nothing inherits
  # n8n_worker_cpu_request, so its per-pod cost is the same coalesce the Helm
  # values use. Left out of the model, the check below would go quiet exactly
  # as pools were added, which is when the arithmetic starts to matter.
  n8n_pool_cpu_requests = {
    for p in var.n8n_worker_pools :
    p.name => coalesce(p.cpu_request, var.n8n_worker_cpu_request)
  }
  n8n_pool_cpu_request_millis = {
    for name, quantity in local.n8n_pool_cpu_requests : name => (
      endswith(quantity, "m") ? tonumber(trimsuffix(quantity, "m")) : tonumber(quantity) * 1000
    )
  }

  # Pool pods render from the chart's shared worker pod template, so they
  # carry the task-runner sidecar too. sum() rejects an empty list, hence the
  # [0] seed for the no-pools default, which keeps this at 0 and the totals
  # below unchanged.
  n8n_pool_peak_cpu_request_millis = sum(concat([0], [
    for p in var.n8n_worker_pools :
    p.max_replicas * (local.n8n_pool_cpu_request_millis[p.name] + local.n8n_cpu_request_millis.task_runner)
  ]))

  # Use the effective main ceiling (locals.tf) rather than the raw configured
  # maximum so a higher unused main maximum in single-main mode does not
  # inflate modeled demand, since the chart never schedules more than one main
  # replica in that mode regardless of the configured HPA maximum. The main
  # sidecar allowance is chart-dependent (n8n_main_task_runner_cpu_millis).
  n8n_peak_cpu_request_millis = (
    local.n8n_main_hpa_effective_max_replicas * (local.n8n_cpu_request_millis.main + local.n8n_main_task_runner_cpu_millis) +
    var.n8n_worker_keda_max_replicas * (local.n8n_cpu_request_millis.worker + local.n8n_cpu_request_millis.task_runner) +
    var.n8n_webhook_hpa_max_replicas * local.n8n_cpu_request_millis.webhook +
    local.n8n_cpu_request_millis.redis_exporter +
    local.n8n_pool_peak_cpu_request_millis
  )

  # The capacity model assumes it owns both AKS node pools and their maximum
  # counts (design.md decision 8). That assumption is only true when
  # create_aks = true; an existing cluster's capacity is the caller's to size
  # and monitor, so the diagnostic below stays silent in that mode. Either
  # pool's VM size being outside the reviewed SKU map also keeps it silent,
  # since a guessed vCPU count for either pool would make the model no
  # better than a coin flip.
  n8n_capacity_model_readable = var.create_aks && local.aks_node_vcpus_derived != null && local.aks_system_node_vcpus_derived != null
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
      "${local.n8n_main_hpa_effective_max_replicas} x ${local.n8n_cpu_request_millis.main + local.n8n_main_task_runner_cpu_millis}m, worker ",
      "${var.n8n_worker_keda_max_replicas} x ${local.n8n_cpu_request_millis.worker + local.n8n_cpu_request_millis.task_runner}m, and webhook ",
      "${var.n8n_webhook_hpa_max_replicas} x ${local.n8n_cpu_request_millis.webhook}m, plus ${local.n8n_cpu_request_millis.redis_exporter}m ",
      "for the optional Redis exporter when enabled",
      length(var.n8n_worker_pools) > 0 ? join("", [
        ", plus worker pools ${local.n8n_pool_peak_cpu_request_millis}m across ",
        "${length(var.n8n_worker_pools)} pool(s) at their ceilings",
      ]) : "",
      ". Supply models the user pool at ",
      "aks_node_count_max=${var.aks_node_count_max}, VM size ${var.aks_node_vm_size} (${local.aks_node_vcpus} vCPU per node), and the system pool at ",
      "aks_system_node_count_max(effective)=${local.aks_system_node_count_max_effective}, VM size ${local.aks_system_node_vm_size_effective} (${local.aks_system_node_vcpus} vCPU per node), ",
      "less ${local.aks_node_kube_reserved_cpu_millis}m/${local.aks_system_node_kube_reserved_cpu_millis}m AKS reservation and ${local.aks_node_daemon_cpu_millis}m daemon requests per node (user/system), ",
      "plus ${local.aks_cluster_control_cpu_millis}m cluster control requests. Lower autoscaler maxima (including any n8n_worker_pools max_replicas) or CPU requests, or raise ",
      "aks_node_count_max, aks_node_vm_size, aks_system_node_count_max, or aks_system_node_vm_size. This diagnostic is advisory and does not fail the plan.",
    ])
  }
}

# Managed-cluster sizing/version/hardening inputs left at anything other than
# their documented defaults while create_aks = false have no effect —
# azurerm_kubernetes_cluster.n8n and its node pool do not exist in that mode,
# and the capacity model above stays silent. The existing cluster's version,
# node sizing, zones, API access, and upgrade surge are owned by whoever
# created it. Mirrors `redis_tuning_requires_module_managed_redis`. KEEP
# THESE LITERALS IN LOCKSTEP WITH variables.tf defaults.
check "aks_tuning_requires_module_managed_aks" {
  assert {
    condition = var.create_aks ? true : (
      var.aks_kubernetes_version == "1.35" &&
      var.aks_node_vm_size == "Standard_D4s_v4" &&
      var.aks_node_count_min == 2 &&
      var.aks_node_count_max == 6 &&
      var.aks_system_node_vm_size == null &&
      var.aks_system_node_count_min == null &&
      var.aks_system_node_count_max == null &&
      var.aks_availability_zones == tolist(["1", "2", "3"]) &&
      length(var.aks_api_authorized_ip_ranges) == 0 &&
      var.aks_node_upgrade_max_surge == "10%" &&
      var.aks_api_warmup_seconds == 90 &&
      var.aks_node_os_disk_size_gb == null
    )
    error_message = join("", [
      "An aks_kubernetes_version, aks_node_vm_size, aks_node_count_min, aks_node_count_max, ",
      "aks_system_node_vm_size, aks_system_node_count_min, aks_system_node_count_max, ",
      "aks_availability_zones, aks_api_authorized_ip_ranges, aks_node_upgrade_max_surge, ",
      "aks_api_warmup_seconds, or aks_node_os_disk_size_gb override is set while create_aks = false. The ",
      "module creates no AKS cluster or node pool in that mode, so none of these apply — sizing, version, ",
      "zones, API access, upgrade behavior, and disk size are properties of the existing cluster you supplied.",
    ])
  }
}
