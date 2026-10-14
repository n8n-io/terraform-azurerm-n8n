# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  storage_use_azuread = true

  features {
    # Write a resource's ID to state before polling its create to completion.
    # A resource whose create fails on the Azure side (for example an
    # Application Gateway that ends in provisioningState Failed) is then kept
    # as tainted and replaced or destroyed by the next run, instead of being
    # orphaned outside state, where it blocks the next create, the subnet
    # delete, and the resource-group delete. Needs azurerm 4.75.0 or later.
    persist_id_on_create_before_polling_for_completion = true
  }
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
  kubernetes = {
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
