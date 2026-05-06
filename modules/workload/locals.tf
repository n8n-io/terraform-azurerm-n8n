# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values consumed by the workload-tier resources subsequent Phase 5
# sub-stories (US-022 / US-023) move in. Two namespace literals are pinned
# here per the registry-hardening US-008 outcome (the root module's
# `locals.tf` declared the same two locals and replaced every literal
# namespace string with `local.<name>`). Pinning the names in a local
# means a future rename is a single-local edit; pinning them in this
# submodule means the renaming is local to the workload tier and does not
# leak into `modules/infra/`.
#
# Why the TriggerAuthentication CR lives in the n8n namespace, not the keda
# namespace: KEDA resolves a `TriggerAuthentication` (a namespaced kind) in
# the SAME namespace as the ScaledObject that references it. The chart's
# ScaledObject for the n8n worker queue is rendered into the n8n namespace
# (the chart only knows about its own namespace), so the
# TriggerAuthentication must follow it there. `local.keda_namespace` is
# only the home of the KEDA operator itself (the `helm_release.keda`
# US-022 will move in).

locals {
  # No taggable Azure resource lives in this submodule (every resource here
  # is a chart / Kubernetes / kubectl_manifest object — none of which carry
  # Azure tags). The local is preserved so this submodule's tag-merge shape
  # mirrors `modules/infra/locals.tf` and any future Azure-tier resource the
  # workload tier might pick up has a ready place to plug in.
  # tflint-ignore: terraform_unused_declarations
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.common_tags,
  )

  n8n_namespace  = "n8n"
  keda_namespace = "keda"

  # Name of the Kubernetes Secret holding the Redis primary access key — the
  # bearer credential the KEDA Redis-list scaler uses to poll queue depth.
  # The secret resource itself (`kubernetes_secret.n8n_redis`) is created in
  # US-023 alongside the rest of the n8n chart-side Secrets; the
  # TriggerAuthentication body (keda.tf, US-022) references the secret by
  # name via this local so a future rename is a single-local edit. Pinning
  # the name in a local also lets US-022's `kubectl_manifest` body render
  # cleanly today even though the secret resource is a forward reference —
  # the body needs the *name*, not a resource attribute. The literal string
  # is the same name registry-hardening US-008's root keda.tf uses (and the
  # legacy umbrella module before that), so a caller migrating from v1.x
  # never sees the secret renamed.
  n8n_redis_secret_name = "n8n-redis-secret"

  # Name of the Kubernetes Secret holding the task-runner shared auth token.
  # Mounted by the chart's task-runner sidecar via the `taskRunners.
  # authToken.existingSecret` value when `var.n8n_task_runners_enabled =
  # true`. The literal lives in a local so the secret resource
  # (`kubernetes_secret.n8n_task_runners`) and the chart-values reference
  # in `n8n.tf` cannot drift; a future rename is a single-local edit.
  n8n_task_runners_secret_name = "n8n-task-runners-secret"

  # Name of the KEDA TriggerAuthentication CR the n8n chart's worker
  # ScaledObject references. Both the CR
  # (`kubectl_manifest.keda_trigger_authentication` in keda.tf) and the
  # chart-values `keda.worker.triggers[*].authenticationRef.name` field in
  # n8n.tf must use the same string — promoting it to a local keeps them
  # in lockstep.
  n8n_redis_keda_trigger_auth_name = "n8n-redis-keda-auth"

  # KEDA TriggerAuthentication YAML body — exposed as a local (rather than
  # inlined into the resource's `yaml_body` argument) so plan-time tests can
  # read the rendered string. The `kubectl_manifest` resource attribute
  # itself is sensitive-marked by the gavinbunney/kubectl provider AND
  # replaced with a synthetic placeholder under `mock_provider "kubectl"`,
  # so reading `kubectl_manifest.<name>.yaml_body` in a test condition
  # fails with "(sensitive value)". Locals are plan-known and not sensitive.
  #
  # The `metadata.namespace` reads `local.n8n_namespace` (registry-
  # hardening US-008): KEDA looks up a `TriggerAuthentication` (a namespaced
  # kind) in the SAME namespace as the ScaledObject that references it, and
  # the n8n chart's worker ScaledObject is rendered into the n8n namespace.
  # The keda namespace is only the home of the KEDA operator itself; the
  # CR must follow the ScaledObject. The `secretTargetRef.name` reads
  # `local.n8n_redis_secret_name` so the CR points at US-023's
  # `kubernetes_secret.n8n_redis` once it lands without needing a body
  # rewrite.
  keda_trigger_authentication_yaml = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata = {
      name      = local.n8n_redis_keda_trigger_auth_name
      namespace = local.n8n_namespace
    }
    spec = {
      secretTargetRef = [
        {
          parameter = "password"
          name      = local.n8n_redis_secret_name
          key       = "password"
        }
      ]
    }
  })
}
