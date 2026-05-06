# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Outputs ───────────────────────────────────────────────────────────────────
# The outputs contract finalised in registry-hardening US-024 (Phase 5 R5.2d).
# Re-exports the few values worth surfacing to the umbrella example (US-025)
# and to operators wiring post-apply tooling (smoke tests, kubectl scripts,
# helm CLI runbooks). Mirrors the per-output shape modules/infra/'s outputs.tf
# uses (US-014..US-020): each output carries a `description`, sensitive
# attributes are explicitly marked, and the corresponding
# `output_contract_complete` apply-mode run in tests/defaults.tftest.hcl
# locks in the contract surface against regressions.

output "n8n_url" {
  description = "Public HTTPS URL of the n8n web UI, computed from var.n8n_domain. Convenience for callers that wire post-apply smoke tests / curl gates against the deployment without re-deriving the scheme + hostname themselves."
  value       = "https://${var.n8n_domain}"
}

output "n8n_namespace" {
  description = "Name of the Kubernetes namespace the n8n chart runs in (mirrors local.n8n_namespace). Surfaced for operators wiring post-apply tooling (kubectl scripts, smoke tests, helm CLI runbooks) that need to scope queries to the n8n namespace without hardcoding the literal."
  value       = local.n8n_namespace
}

output "n8n_helm_release_name" {
  description = "Name of the n8n Helm release (always 'n8n' under the current chart pin). Surfaced for parity with operator runbooks that reference `helm status n8n -n n8n` / `helm history n8n -n n8n`."
  value       = helm_release.n8n.name
}

output "n8n_helm_release_revision" {
  description = "Revision number of the most recent successful `helm_release.n8n` install/upgrade. Increments on every chart upgrade; useful for callers that gate post-apply reconciliation steps on the release having actually rolled forward."
  value       = helm_release.n8n.metadata[0].revision
}
