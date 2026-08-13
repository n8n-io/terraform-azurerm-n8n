# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  storage_use_azuread = true

  features {}
}

# These providers use the AKS local-account certificate returned by the same
# module call. AKS remains module-managed in this example (only Blob storage
# moves outside the module), so provider wiring follows examples/small's
# pattern.
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
