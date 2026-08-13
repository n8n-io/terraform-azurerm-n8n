# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── KEDA controller ───────────────────────────────────────────────────────────
# Azure has no root-installed equivalents of the AWS Load Balancer Controller,
# Cluster Autoscaler, metrics-server, or EBS CSI stack — AKS provides its own
# cluster autoscaler and AGIC remains an AKS addon. KEDA is the only controller
# this repository installs with Helm, so it is the only one extracted into a
# directly callable submodule.
#
# `install_keda = false` skips both resources below. A direct caller is then
# responsible for KEDA and its CRDs (including TriggerAuthentication) being
# ready before any resource that depends on this module applies. See this
# submodule's README for the depends_on contract root callers and direct
# callers must both honor, and the destroy-time ScaledObject finalizer hazard
# of changing install_keda on an already-applied stack.
resource "kubernetes_namespace" "keda" {
  count = var.install_keda ? 1 : 0

  metadata {
    name = var.keda_namespace
  }

  timeouts {
    delete = "2m"
  }
}

resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name            = "keda"
  repository      = var.keda_chart_repository
  chart           = "keda"
  version         = var.keda_chart_version
  namespace       = kubernetes_namespace.keda[0].metadata[0].name
  wait            = var.keda_helm_wait
  timeout         = var.keda_helm_timeout_seconds
  atomic          = var.keda_helm_atomic
  cleanup_on_fail = var.keda_helm_cleanup_on_fail
}
