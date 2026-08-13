# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

output "n8n_url" {
  description = "Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings."
  value       = module.n8n.n8n_url
}

output "appgw_public_ip" {
  description = "Public IPv4 address of the caller-owned Application Gateway (ingress.tf)."
  value       = azurerm_public_ip.n8n.ip_address
}

output "aks_cluster_name" {
  description = "Name of the caller-owned AKS stand-in cluster the module targets via create_aks = false."
  value       = azurerm_kubernetes_cluster.existing.name
}

output "aks_resource_group" {
  description = "Resource group containing the caller-owned AKS cluster and the n8n managed services."
  value       = azurerm_resource_group.n8n.name
}

output "kubectl_config_command" {
  description = "Command that writes the AKS context into the local kubeconfig."
  value       = "az aks get-credentials --name ${azurerm_kubernetes_cluster.existing.name} --resource-group ${azurerm_resource_group.n8n.name} --overwrite-existing"
}

output "namespace" {
  description = "Kubernetes namespace containing n8n."
  value       = module.n8n.n8n_namespace
}

output "postgres_password" {
  description = "Generated PostgreSQL administrator password. Back it up in a secret manager."
  value       = module.n8n.postgres_admin_password
  sensitive   = true
}

output "postgres_fqdn" {
  description = "Private FQDN n8n connects to for PostgreSQL."
  value       = module.n8n.postgres_fqdn
}

output "redis_hostname" {
  description = "Private hostname n8n and KEDA connect to for Redis."
  value       = module.n8n.redis_hostname
}

output "n8n_encryption_key" {
  description = "Generated n8n encryption key. Back it up to a password manager immediately after the first apply."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "storage_account_name" {
  description = "Name of the private StorageV2 account holding the module-managed Azure Blob container."
  value       = module.n8n.storage_account_name
}

output "azure_blob_container_name" {
  description = "Name of the private Azure Blob container used for n8n binary and execution data."
  value       = module.n8n.azure_blob_container_name
}
