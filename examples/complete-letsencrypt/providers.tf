# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  features {}
}

# `hashicorp/tls` and `vancluever/acme` are used by `modules/tls-letsencrypt/`
# (registry-hardening US-009) to generate the App Gateway listener cert.
# Neither modules/infra/ nor modules/workload/ requires either provider; the
# submodule owns them locally and the example declares them here for the
# submodule's call.

provider "tls" {}

# ── ACME provider for Let's Encrypt ───────────────────────────────────────────
# The `vancluever/acme` provider drives certificate issuance from Let's
# Encrypt's ACME service. The `server_url` defaults to production
# (https://acme-v02.api.letsencrypt.org/directory) when omitted; switch to
# staging for first-apply rehearsals to avoid the production endpoint's
# 5-certs-per-7-days-per-FQDN rate limit.
#
# DNS-01 challenge against Azure DNS reads `AZURE_TENANT_ID` /
# `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_SUBSCRIPTION_ID` directly
# from the apply host's environment via the lego library — independent of how
# the `azurerm` provider is configured. The principal those env vars resolve
# to must hold `DNS Zone Contributor` on `var.public_dns_zone_name`.
provider "acme" {
  # Production (default — uncomment to confirm explicitly):
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
  # Staging — recommended for first-apply rehearsals:
  # server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

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
