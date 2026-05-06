# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform requirement ──────────────────────────────────────────────────
# After registry-hardening US-025 (Phase 5 R5.3), the root module owns no
# resources of its own — every Azure / Kubernetes resource n8n needs has
# moved into one of the two-tier submodules:
#
#   modules/infra/    — Azure IaaS (AKS, Postgres, Redis, Storage, App Gateway,
#                       IAM, BYO-KV role assignment).
#                       required_providers: azurerm, random, time.
#   modules/workload/ — Kubernetes (KEDA, n8n Helm release, Ingress, HPAs,
#                       federated identity wiring's Kubernetes side, KEDA
#                       TriggerAuthentication CR).
#                       required_providers: kubernetes, helm, random, time, kubectl.
#
# Consumers wire both tiers in their own root module — see `examples/complete/`
# for the canonical two-tier composition. The root retains only this file
# (Terraform CLI floor) plus README.md / LICENSE / AGENTS.md / .copywrite.hcl
# so the directory remains a valid Terraform module folder for the Registry's
# layout audit, without declaring any providers of its own.
#
# `required_version` matches both submodules to keep the floor consistent —
# 1.9 is the minimum that supports cross-variable validation (used by both
# submodules' validation blocks).

terraform {
  required_version = ">= 1.9"
}
