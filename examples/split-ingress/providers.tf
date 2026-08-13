# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  storage_use_azuread = true

  features {}
}

# These providers use the AKS local-account certificate returned by the
# module call. Terraform can create Azure resources first, then configure
# the Kubernetes-facing providers once the cluster output is known. This
# example's own ingress.tf then installs two standalone AGIC Helm releases
# and two Kubernetes Ingress objects against the same cluster, since
# create_ingress = false leaves the module's own AGIC addon and Ingress
# unused.
provider "kubernetes" {
  host                   = module.n8n.aks_kube_config[0].host
  client_certificate     = base64decode(module.n8n.aks_kube_config[0].client_certificate)
  client_key             = base64decode(module.n8n.aks_kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.n8n.aks_kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.n8n.aks_kube_config[0].host
    client_certificate     = base64decode(module.n8n.aks_kube_config[0].client_certificate)
    client_key             = base64decode(module.n8n.aks_kube_config[0].client_key)
    cluster_ca_certificate = base64decode(module.n8n.aks_kube_config[0].cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = module.n8n.aks_kube_config[0].host
  client_certificate     = base64decode(module.n8n.aks_kube_config[0].client_certificate)
  client_key             = base64decode(module.n8n.aks_kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.n8n.aks_kube_config[0].cluster_ca_certificate)
  load_config_file       = false
}
