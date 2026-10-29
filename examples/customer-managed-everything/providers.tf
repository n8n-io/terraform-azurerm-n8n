# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  storage_use_azuread = true
  partner_id          = var.partner_id == null ? null : lower(var.partner_id)

  # azurerm 5.x registers no resource providers by default. Register the ones
  # this deployment uses, so a fresh subscription behaves as it did on 4.x.
  # Registering an unregistered provider needs the
  # Microsoft.Resources/subscriptions/providers/register/action permission.
  resource_providers_to_register = [
    "Microsoft.Authorization",
    "Microsoft.Cache",
    "Microsoft.Compute",
    "Microsoft.ContainerService",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.Storage",
  ]

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

# Provider wiring targets the caller-owned azurerm_kubernetes_cluster.existing
# stand-in directly, not module.n8n.aks_kube_config — design.md decision 2.
# The direct modules/controllers call in main.tf, this example's own
# namespace/Secret/ingress/HPA resources, and module "n8n" itself all share
# this provider configuration.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.existing.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.existing.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
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
