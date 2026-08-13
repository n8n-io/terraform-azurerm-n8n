# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# This submodule owns the only infrastructure controller the Azure module
# installs with Helm: KEDA. Extracting it lets an advanced caller install
# KEDA once and compose it into more than one workload root, or install KEDA
# through a separate process entirely and point this repository's root module
# at it with `install_keda = false`.
#
# Provider configuration (kube/helm wiring against the target cluster) is the
# caller's job — the root module configures both providers from its own AKS
# outputs and passes them into this submodule implicitly via Terraform's
# provider inheritance. A direct caller must configure `kubernetes` and
# `helm` itself before calling this module.

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
  }
}
