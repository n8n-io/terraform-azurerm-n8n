# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Terraform & provider requirements ──────────────────────────────────────
# This submodule owns the Azure IaaS layer: AKS, PostgreSQL Flexible Server,
# Redis Cache, Storage Account / Azure Files share, Application Gateway +
# Public IP, and the user-assigned identities + role assignments that bind
# them. It MUST stay IaaS-only — no kubernetes / helm / kubectl providers
# are declared here. The Kubernetes-side workload (KEDA + n8n Helm release +
# manifests) lives in `modules/workload/`.
#
# Posture mirrors `terraform-azurerm-terraform-enterprise-hvd/` (a HashiCorp
# Validated Design) which pins a single provider — `azurerm` — for its IaaS
# scope. We add `random` because some resource names embed a short random
# suffix (e.g. the storage account when `friendly_name_prefix` collides with
# an existing Azure-namespace neighbour) and `time` because the AKS API
# warm-up gate (`time_sleep.aks_api_warmup`, registry-hardening US-003) and
# the Azure Files destroy-time pod-drain gate (`time_sleep.wait_for_aks_drain`,
# US-005) sit in this submodule — both replace `null_resource` + shell-out
# workarounds the prototype shipped with.
#
# Provider configuration (subscription, auth) is the caller's job — the
# submodule does not include any `provider {}` blocks.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
