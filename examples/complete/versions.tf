# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

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
    # `gavinbunney/kubectl` is needed because the called module installs a
    # single CRD-aware manifest (the KEDA `TriggerAuthentication` in
    # `keda.tf`). The example configures it in `providers.tf` with the same
    # certificate-based auth as `kubernetes` / `helm`.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    # `hashicorp/tls` is required by `modules/tls-self-signed/`, which this
    # example calls to issue the App Gateway listener cert. The root n8n
    # module no longer pulls `tls` (registry-hardening US-012); the
    # submodule owns it locally.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # `hashicorp/time` is used at the example root for `time_sleep` gates
    # (e.g. RBAC propagation on the shared Key Vault). Both submodules
    # also depend on `time` for their own gates.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
