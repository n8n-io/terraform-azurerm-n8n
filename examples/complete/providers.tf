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
# kubelogin/exec. The cluster is created without AAD-RBAC integration
# (`azure_active_directory_role_based_access_control` block is absent in
# `modules/infra/aks.tf`), so `aks_kube_config` is the cluster's local-account
# admin credential — equivalent in trust shape to `kube_admin_config` on
# AAD-enabled clusters but populated unconditionally here. This avoids a
# `kubelogin` CLI dependency on the apply host. The cert + key are stable
# for the cluster's lifetime; every kube-targeted provider transparently
# retries transient `503` / `EOF` errors against the AKS API server after
# the `time_sleep.aks_api_warmup` gate (registry-hardening US-003) inside
# `module.infra` hands off, so no probe loop is needed.

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
# `kubectl_manifest`. Auth shape mirrors `kubernetes` / `helm` above: same
# certificate-based credentials from `module.infra.aks_kube_config`. Setting
# `load_config_file = false` prevents the provider from picking up
# `~/.kube/config` on the apply host — credentials come exclusively from
# the explicit fields below, matching the trust shape of the other two
# kube-targeted providers.
provider "kubectl" {
  host                   = module.infra.aks_kube_config[0].host
  client_certificate     = base64decode(module.infra.aks_kube_config[0].client_certificate)
  client_key             = base64decode(module.infra.aks_kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.infra.aks_kube_config[0].cluster_ca_certificate)
  load_config_file       = false
}
