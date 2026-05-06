# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# This submodule owns the Kubernetes-side workload: the KEDA Helm release,
# the n8n Helm release, the n8n + KEDA namespaces, the chart-side Secrets
# (database / Redis / Azure Files credentials), the n8n Ingress, the HPAs
# the chart does not own (webhook-processor), the federated identity
# credential binding the n8n service account to the AKS OIDC issuer, and
# the KEDA TriggerAuthentication CR. The Azure IaaS layer (AKS, Postgres,
# Redis, Storage, App Gateway, IAM) lives in `modules/infra/`. **No
# `azurerm` provider is declared here** — every cross-tier value flows in
# through this submodule's typed inputs (see variables.tf) which the
# umbrella example (US-025) wires to `modules/infra/`'s outputs.
#
# Provider count: 5 — `kubernetes`, `helm`, `random` (chart-side
# random_password / random_id usage that may surface as we move
# resources in, US-022 / US-023), `time` (the `time_sleep.n8n_helm_settle`
# gate the chart-native multi-main migration absorption pattern relies
# on, registry-hardening US-002), and `kubectl` (the gavinbunney/kubectl
# provider hosting `kubectl_manifest.keda_trigger_authentication` —
# registry-hardening US-007 took the R3.2 fall-back because the n8n-io
# chart at `var.n8n_chart_version` does not expose first-class
# `keda.triggerAuthentication.*` values nor `extraManifests` /
# `extraObjects` hooks). This is the chart-only consumer's posture per
# the Phase 5 PRD R5.2 AC #1.
#
# Provider configuration (kubeconfig / OIDC / cluster CA) is the caller's
# job — the submodule does not include any `provider {}` blocks. The
# umbrella example wires the kubernetes / helm / kubectl providers from
# `module.infra.aks_kube_config` so the same certificate-based auth shape
# the root module uses today carries through to this submodule.

terraform {
  required_version = ">= 1.9"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}
