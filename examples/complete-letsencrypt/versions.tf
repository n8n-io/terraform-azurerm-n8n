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
    # `gavinbunney/kubectl` is needed because the called root module installs a
    # single CRD-aware manifest (the KEDA `TriggerAuthentication` in
    # `keda.tf`).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    # `acme` + `tls` are required by `modules/tls-letsencrypt/`. Registry-
    # hardening US-012 retired the root module's inline `tls_mode =
    # letsencrypt` branch; both providers are now scoped to the submodule
    # only.
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
