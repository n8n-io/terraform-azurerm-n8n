# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── HPA: n8n webhook processor pods (CPU-based) ───────────────────────────────
# The n8n Helm chart skips creating the webhook-processor HPA when its KEDA
# integration is enabled. Since this submodule always installs KEDA
# (controllers.tf, US-022) and configures the chart's worker ScaledObject
# via KEDA, the chart's bundled webhook-processor HPA is suppressed and we
# own it here instead. Workers scale on Redis queue depth (KEDA);
# webhook processors scale on CPU (this HPA).
#
# `min_replicas = 2` and `metric.resource = cpu utilization 70%` are
# intentional floors for the multi-main topology — the AKS node-pool sizing
# in `modules/infra/aks.tf` (US-015) assumes ≥2 webhook processors at
# minimum, and 70% CPU is the canonical scale-out threshold per the n8n
# production reference architecture. Only `max_replicas` is caller-tunable
# (via `var.n8n_webhook_hpa_max_replicas`) so operators can size the
# headroom for their expected webhook burst rate.
#
# `metadata.namespace` reads `local.n8n_namespace` (locals.tf, US-008) —
# the same source of truth that drives the embedded namespace in the
# kubectl_manifest TriggerAuthentication body in keda.tf and (US-023's)
# `kubernetes_namespace.n8n`, so renaming the namespace is a single-local
# edit.
#
# `depends_on` orders the HPA AFTER `kubernetes_namespace.n8n` (namespace
# must exist before the HPA can be created) and `helm_release.n8n` (the
# n8n-webhook-processor Deployment the HPA's `scale_target_ref` resolves
# against — without this gate, HPA creation race-fails on first apply
# with "no Deployment found"). Codebase pattern (registry-hardening
# US-022 → US-023): `depends_on` is a floor extended as new resources
# land in this submodule.

resource "kubernetes_horizontal_pod_autoscaler_v2" "webhook_processor" {
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

    min_replicas = 2
    max_replicas = var.n8n_webhook_hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.n8n,
    helm_release.n8n,
  ]
}
