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
  description = "Public IPv4 address of the caller-owned Application Gateway (ingress.tf)."
  value       = azurerm_public_ip.n8n.ip_address
}

output "aks_cluster_name" {
  description = "Name of the caller-owned AKS stand-in cluster the module targets via create_aks = false."
  value       = azurerm_kubernetes_cluster.existing.name
}

output "kubectl_config_command" {
  description = "Command that writes the AKS context into the local kubeconfig."
  value       = "az aks get-credentials --name ${azurerm_kubernetes_cluster.existing.name} --resource-group ${azurerm_resource_group.n8n.name} --overwrite-existing"
}

output "namespace" {
  description = "Kubernetes namespace containing n8n, created directly by this example (create_namespace = false)."
  value       = module.n8n.n8n_namespace
}

output "postgres_fqdn" {
  description = "Private FQDN of the caller-owned external PostgreSQL Flexible Server stand-in."
  value       = azurerm_postgresql_flexible_server.existing.fqdn
}

output "redis_hostname" {
  description = "Private hostname of the caller-owned external Redis stand-in."
  value       = azurerm_managed_redis.existing.hostname
}

output "storage_account_name" {
  description = "Name of the caller-owned StorageV2 account the module targets via create_blob_storage = false."
  value       = azurerm_storage_account.existing.name
}

output "azure_blob_container_name" {
  description = "Name of the caller-owned private Blob container used for n8n binary and execution data."
  value       = azurerm_storage_container.existing.name
}

output "keda_release_name" {
  description = "Name of the KEDA Helm release installed by the direct modules/controllers call in main.tf."
  value       = module.controllers.keda_release_name
}

output "n8n_workload_uami_client_id" {
  description = "Client ID of the module-owned n8n workload identity granted Storage Blob Data Contributor on the caller-owned container above."
  value       = module.n8n.n8n_workload_uami_client_id
  sensitive   = true
}
