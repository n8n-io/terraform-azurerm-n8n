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
# `required_version >= 1.9` was required by every cross-variable `validation`
# block this module and its predecessors use (stabilized in Terraform
# 1.9.0). Raised to `>= 1.11` by the `postgres_password_write_only` opt-in
# (issue #26): an `ephemeral = true` variable (`postgres_admin_password_wo`)
# needs Terraform 1.10's ephemeral-value support, and feeding it into
# `azurerm_postgresql_flexible_server.n8n`'s `administrator_password_wo`
# argument needs 1.11's write-only-argument support for managed resources.
# Both are parsed unconditionally from this module's HCL regardless of
# whether any caller sets `postgres_password_write_only`, so the floor is
# module-wide.
#
# Raised again to `>= 1.12`: the `var.x == null || var.x.attr` guards in
# variables.tf need 1.12, the first release that short-circuits `||` and
# `&&`. On 1.11 and earlier both sides are evaluated, so those guards fail
# with "Attempt to get attribute from null value" on every plan that
# leaves such an input null (for example `pg_maintenance_window`, which
# defaults to null). CI tests this floor alongside its newer runtime.
#
# No `provider {}` blocks — provider configuration (subscription, auth,
# kube/helm wiring against the AKS cluster this module creates) is the
# caller's job. See `examples/small/providers.tf` (added in section 13)
# for the canonical wiring, mirroring `terraform-aws-n8n`'s
# `examples/small/providers.tf`.

terraform {
  required_version = ">= 1.12"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 5.x only: the private DNS VNet links and A record address their zone
      # by `private_dns_zone_id`, and AKS needs `node_provisioning_profile`,
      # neither of which 4.x accepts. The floor is 5.5.0, the first release
      # with `azurerm_storage_account.public_network_access`; it also
      # carries the 5.1.0 storage container state migration from 4.x.
      # docs/upgrading-azurerm-5.md covers moving an existing deployment.
      version = ">= 5.5.0, < 6.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}
