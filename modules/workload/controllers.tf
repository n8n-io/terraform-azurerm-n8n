# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── KEDA controller (US-022) ──────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling — scales n8n workers based on Redis
# queue depth rather than CPU, so workers appear only when there is work to
# do. The TriggerAuthentication that wires n8n's ScaledObject to the Redis
# primary access key is created in keda.tf via `kubectl_manifest` AFTER this
# Helm release succeeds (so the CRDs are present at apply time; the
# `gavinbunney/kubectl` provider defers schema resolution to apply time so
# the very first plan against a fresh cluster does not fail with
# `no matches for kind "TriggerAuthentication"`).
#
# Cluster Autoscaler is NOT installed via Helm here — AKS ships its own
# managed cluster autoscaler controlled by `auto_scaling_enabled` /
# `min_count` / `max_count` on the node pool plus the `auto_scaler_profile`
# block on `azurerm_kubernetes_cluster.n8n` (see `modules/infra/aks.tf`).
# This is the Azure delta vs the AWS sibling, where Cluster Autoscaler is a
# separate Helm release in `controllers.tf`.
#
# AGIC (Application Gateway Ingress Controller) is also NOT installed via
# Helm — it runs as the AKS `ingress_application_gateway` addon (see
# `modules/infra/aks.tf` + `modules/infra/ingress.tf`). Only KEDA needs to
# be installed by this submodule.
#
# Destroy ordering: helm_release.n8n (US-023) depends_on this release, so
# during destroy the n8n release (including its ScaledObjects) is deleted
# FIRST while the KEDA operator is still running. KEDA processes the
# ScaledObject deletions and removes its own `finalizer.keda.sh` finalizer.
# KEDA is uninstalled only after all ScaledObjects are gone — no orphaned
# finalizers blocking namespace deletion.
#
# `kubernetes_namespace.keda` is created explicitly (rather than using the
# chart's `create_namespace = true`) so future stories can attach
# resources to it (e.g. NetworkPolicy, ResourceQuota) referencing the
# `kubernetes_namespace.keda.metadata[0].name` — avoids a chicken-and-egg
# between the namespace and the Helm release. The name reads
# `local.keda_namespace` (US-008 single-source-of-truth pattern).
#
# Cross-tier dependency on `time_sleep.aks_api_warmup`: the gate lives in
# `modules/infra/aks.tf` (US-015) and is NOT exposed as an output. The
# umbrella example (US-025) is responsible for wiring the kubernetes / helm
# providers from `module.infra.aks_kube_config` AFTER the infra module's
# apply has completed; the typical pattern is `depends_on = [module.infra]`
# on the workload module call. This submodule does not pull the gate's id
# in via a variable — keeping the workload tier provider-cardinality at
# 5 (kubernetes / helm / random / time / kubectl) and matching the
# chart-only consumer's posture declared in versions.tf.

resource "kubernetes_namespace" "keda" {
  metadata {
    name = local.keda_namespace
  }

  timeouts {
    delete = "2m"
  }
}

resource "helm_release" "keda" {
  name            = "keda"
  repository      = "https://kedacore.github.io/charts"
  chart           = "keda"
  version         = var.keda_chart_version
  namespace       = kubernetes_namespace.keda.metadata[0].name
  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true
}
