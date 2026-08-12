# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# align-azure-with-aws-capabilities flattens the two-tier `modules/infra` +
# `modules/workload` composition into one resource-bearing root module,
# mirroring `terraform-aws-n8n`'s single-module shape (see that repo's
# `versions.tf`). The root now directly owns every provider both former
# submodules declared:
#
#   azurerm    — AKS, PostgreSQL Flexible Server, Azure Managed Redis,
#                Storage Account / Blob, Application Gateway,
#                IAM (UAMIs + role assignments).
#   kubernetes — namespaces, Secrets, the federated-identity Kubernetes
#                side, and any manifests the Helm chart does not render.
#   helm       — the KEDA and n8n Helm releases.
#   random     — generated passwords / suffixes (Postgres admin password,
#                storage-account name collision avoidance).
#   time       — the AKS API warm-up gate, the Key Vault RBAC-propagation
#                gate, and the post-install Helm settle gate.
#   kubectl    — the CRD-aware `kubectl_manifest.keda_trigger_authentication`
#                resource (`hashicorp/kubernetes_manifest` cannot resolve a
#                CRD Helm installs in the same apply — see AGENTS.md).
#
# Sections 2–6 of the align-azure-with-aws-capabilities change move each
# provider's resources from the two submodules into root concern files
# (aks.tf, database.tf, redis.tf, storage.tf, controllers.tf, keda.tf,
# n8n.tf, ingress.tf, dns.tf, iam.tf, scaling.tf, cleanup.tf). Until that
# migration completes, this file only declares the combined requirement —
# see `openspec/changes/align-azure-with-aws-capabilities/tasks.md`.
#
# `required_version >= 1.9` is required by every cross-variable `validation`
# block this module and its predecessors use (stabilized in Terraform
# 1.9.0). No `provider {}` blocks — provider configuration (subscription,
# auth, kube/helm wiring against the AKS cluster this module creates) is
# the caller's job. See `examples/small/providers.tf` (added in section 13)
# for the canonical wiring, mirroring `terraform-aws-n8n`'s
# `examples/small/providers.tf`.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
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
