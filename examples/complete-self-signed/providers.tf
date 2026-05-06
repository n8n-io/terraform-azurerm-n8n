# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  features {}
}

# `hashicorp/tls` is used by `modules/tls-self-signed/` (registry-hardening
# US-010) to generate the App Gateway listener cert. Neither modules/infra/
# nor modules/workload/ requires `tls`; the submodule owns it locally and
# the example declares it here for the submodule's call. No special
# configuration required; `hashicorp/tls` is local-only (no upstream API
# calls).
provider "tls" {}

# The kubernetes / helm / kubectl providers are configured against the AKS
# cluster `module.infra` creates. They can't be resolved until after the
# cluster exists — on the first apply, Terraform creates the AKS cluster
# inside `module.infra` before any kubernetes_* / helm_release / kubectl_*
# resource inside `module.workload` is evaluated. The kube_config output is
# sensitive; the sensitive marker passes through to the provider config
# (every provider below accepts sensitive values for these arguments).
#
# Auth shape: certificate-based (client_certificate + client_key + CA), not
# kubelogin/exec. See `examples/complete/providers.tf` for the canonical
# commentary.

provider "kubernetes" {
  host                   = module.infra.aks_kube_config[0].host
  client_certificate     = base64decode(module.infra.aks_kube_config[0].client_certificate)
  client_key             = base64decode(module.infra.aks_kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.infra.aks_kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.infra.aks_kube_config[0].host
    client_certificate     = base64decode(module.infra.aks_kube_config[0].client_certificate)
    client_key             = base64decode(module.infra.aks_kube_config[0].client_key)
    cluster_ca_certificate = base64decode(module.infra.aks_kube_config[0].cluster_ca_certificate)
  }
}

# `gavinbunney/kubectl` provider — `modules/workload/keda.tf` installs a
# single CRD-aware manifest (the KEDA `TriggerAuthentication`) via
# `kubectl_manifest`. Same certificate-based auth as `kubernetes` / `helm`.
# `load_config_file = false` keeps credentials exclusively from the explicit
# fields below.
provider "kubectl" {
  host                   = module.infra.aks_kube_config[0].host
  client_certificate     = base64decode(module.infra.aks_kube_config[0].client_certificate)
  client_key             = base64decode(module.infra.aks_kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.infra.aks_kube_config[0].cluster_ca_certificate)
  load_config_file       = false
}
