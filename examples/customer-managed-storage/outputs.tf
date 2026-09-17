# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

output "n8n_url" {
  description = "Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings."
  value       = module.n8n.n8n_url
}

output "main_hpa_min_replicas" {
  description = "Effective main-topology floor passed to the root module's n8n_main_hpa_min_replicas."
  value       = var.n8n_main_hpa_min_replicas
}

output "appgw_public_ip" {
  description = "Public IPv4 address of the module-managed Application Gateway."
  value       = module.n8n.appgw_public_ip_address
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.n8n.aks_cluster_name
}

output "kubectl_config_command" {
  description = "Command that writes the AKS context into the local kubeconfig."
  value       = "az aks get-credentials --name ${module.n8n.aks_cluster_name} --resource-group ${azurerm_resource_group.n8n.name} --overwrite-existing"
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
  description = "Name of the caller-owned StorageV2 account the module targets via create_blob_storage = false."
  value       = azurerm_storage_account.existing.name
}

output "azure_blob_container_name" {
  description = "Name of the caller-owned private Blob container used for n8n binary and execution data."
  value       = azurerm_storage_container.existing.name
}

output "n8n_workload_uami_client_id" {
  description = "Client ID of the module-owned n8n workload identity granted Storage Blob Data Contributor on the caller-owned container above."
  value       = module.n8n.n8n_workload_uami_client_id
  sensitive   = true
}
