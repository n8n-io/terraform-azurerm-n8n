# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── KEDA TriggerAuthentication (Redis password auth) ─────────────────────────
# Wires the n8n worker ScaledObject (rendered by the n8n Helm chart in
# US-023) to the Redis primary access key so KEDA can poll the queue depth
# and scale workers. Azure Redis enforces TLS + password auth; KEDA's Redis
# scaler reads the password from a `TriggerAuthentication` CR that points
# at a Kubernetes Secret in the same namespace as the ScaledObject.
#
# Why `gavinbunney/kubectl_manifest` instead of `hashicorp/kubernetes_manifest`:
#   The TriggerAuthentication CRD only exists AFTER `helm_release.keda`
#   (controllers.tf, US-022) installs it. `hashicorp/kubernetes_manifest`
#   needs the CRD's OpenAPI schema available AT PLAN TIME, so the very first
#   `terraform plan` against a fresh module fails with
#   `no matches for kind "TriggerAuthentication"` — forcing a two-pass apply.
#   `gavinbunney/kubectl_manifest` defers schema resolution to apply time
#   (it uses the dynamic kubectl client rather than the typed openapi
#   client), so a single-pass apply works against a fresh cluster. Same
#   pattern documented in the gavinbunney/kubectl provider README for
#   "CRD-aware manifests" and replaces the legacy
#   `null_resource` + shell-out `kubectl apply` workaround retired in
#   registry-hardening US-007 (Phase 3 R3.2). The R3.1 chart-native path
#   was investigated and rejected: the n8n-io chart at
#   `var.n8n_chart_version` does not expose `keda.triggerAuthentication.*`
#   values nor `extraManifests` / `extraObjects` hooks (verified upstream
#   values.yaml).
#
# Why the TriggerAuthentication lives in the `n8n` namespace (and not in
# `keda` where the operator runs): TriggerAuthentication is a *namespaced*
# CR — KEDA looks up the CR in the SAME namespace as the ScaledObject that
# references it. The n8n Helm chart's worker ScaledObject is rendered into
# the n8n namespace, so the TriggerAuthentication must be there too. (KEDA
# also offers `ClusterTriggerAuthentication` for cross-namespace use, but
# the n8n chart's ScaledObject template references
# `kind: TriggerAuthentication`, so we follow suit.)
#
# `depends_on` orders this resource AFTER `helm_release.keda` (CRDs
# installed) AND `kubernetes_secret.n8n_redis` (secret the body's
# `secretTargetRef.name` resolves against — keeping the secret ahead of
# the CR avoids a transient apply-order race where KEDA reconciles the
# CR before the secret exists). The `kubernetes_namespace.n8n` reference
# is implicit through `kubernetes_secret.n8n_redis.metadata[0].namespace`.
# Codebase pattern (registry-hardening US-022 → US-023): `depends_on` is
# a floor extended as new resources land in this submodule, not a ceiling.
#
# Re-apply behaviour: `kubectl_manifest` reconciles by group/version/kind +
# namespace + name. The body is rendered from the secret RESOURCE (not its
# value), so a Redis primary-key rotation does not change the CR body and
# the resource is correctly idempotent. A KEDA chart upgrade that does not
# touch the TriggerAuthentication shape (i.e. group/version still
# `keda.sh/v1alpha1`) is also a no-op. If a future KEDA upgrade rev's the
# CRD's apiVersion, the YAML body string changes and the manifest is
# re-applied automatically.

resource "kubectl_manifest" "keda_trigger_authentication" {
  yaml_body = local.keda_trigger_authentication_yaml

  depends_on = [
    helm_release.keda,
    kubernetes_secret.n8n_redis,
  ]
}
