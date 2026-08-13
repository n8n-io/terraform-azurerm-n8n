# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  storage_use_azuread = true

  features {}
}

# Provider wiring targets the caller-owned azurerm_kubernetes_cluster.existing
# stand-in directly, not module.n8n.aks_kube_config — design.md decision 2:
# "Provider wiring in customer-managed examples targets the stand-in AKS
# resource or data source directly, not module.n8n.aks_kube_config, so
# depends_on edges do not create a cycle." The module reads this same
# cluster's coordinates through data.azurerm_kubernetes_cluster.existing
# internally when create_aks = false.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.existing.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.existing.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.existing.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].cluster_ca_certificate)
  load_config_file       = false
}
