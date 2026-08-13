# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Caller-owned webhook HPA ──────────────────────────────────────────────────
# n8n_webhook_hpa_enabled = false on the module call means the module creates
# no webhook-processor HPA of its own — the chart still renders the
# Deployment at n8n_webhook_hpa_min_replicas, so this HPA has a stable target.
# Mirrors the module's own scaling.tf shape for the resource this example
# takes ownership of.
resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook" {
  metadata {
    name      = "n8n-webhook-processor"
    namespace = module.n8n.n8n_namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "n8n-webhook-processor"
    }

    min_replicas = 2
    max_replicas = 8

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = 65
        }
      }
    }
  }

  depends_on = [module.n8n]
}
