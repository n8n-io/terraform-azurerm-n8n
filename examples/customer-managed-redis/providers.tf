# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

provider "azurerm" {
  storage_use_azuread = true

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

  features {}
}

# These providers use the AKS local-account certificate returned by the same
# module call. AKS remains module-managed in this example (only Redis moves
# outside the module), so provider wiring follows examples/small's pattern.
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
