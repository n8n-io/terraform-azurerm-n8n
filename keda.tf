# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── KEDA TriggerAuthentication ────────────────────────────────────────────────
# The TriggerAuthentication CRD is installed by module.controllers' KEDA Helm
# release during this same apply. hashicorp/kubernetes_manifest validates CRDs at plan time and
# therefore forces a two-pass apply on a fresh cluster. kubectl_manifest defers
# schema resolution to apply time. The manifest contains only references to the
# Redis Secret, never a credential value.
#
# TriggerAuthentication is namespaced and must live beside the chart-rendered
# worker ScaledObject in the n8n namespace. The resource is retained on the
# unauthenticated external Redis path with an empty secretTargetRef list, but the
# ScaledObject leaves authenticationRef empty and does not use it. Keeping one
# stable resource address avoids a count expression derived from a sensitive or
# same-plan-computed external password.
resource "kubectl_manifest" "keda_trigger_authentication" {
  yaml_body = local.keda_trigger_authentication_yaml

  depends_on = [
    module.controllers,
    kubernetes_secret.n8n_redis,
  ]
}
