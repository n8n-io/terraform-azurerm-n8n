# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── KEDA controller ───────────────────────────────────────────────────────────
# AKS provides its own cluster autoscaler and AGIC remains an AKS addon when the
# ingress resources move to root in section 11. KEDA is the only controller the
# root installs with Helm. Its explicit namespace and release both sit behind
# the AKS API warm-up gate so a cold create does not race Azure's delayed API
# readiness.
resource "kubernetes_namespace" "keda" {
  metadata {
    name = local.keda_namespace
  }

  timeouts {
    delete = "2m"
  }

  depends_on = [time_sleep.aks_api_warmup]
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
