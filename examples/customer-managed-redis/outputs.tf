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

output "pg_backup_retention_days" {
  description = "Effective PostgreSQL backup retention window, in days, passed to the root module's pg_backup_retention_days."
  value       = var.pg_backup_retention_days
}

output "blob_delete_retention_days" {
  description = "Effective Blob soft-delete retention window, in days, passed to the root module's blob_delete_retention_days. Null leaves soft delete disabled."
  value       = var.blob_delete_retention_days
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
  description = "Hostname of the caller-owned Redis stand-in n8n and KEDA connect to."
  value       = module.n8n.redis_hostname
}

output "redis_password_secret_name" {
  description = "Name of the caller-managed Kubernetes Secret holding the Redis password, referenced by redis_password_secret_ref on the module call. The module never reads this Secret's value."
  value       = kubernetes_secret.redis_password.metadata[0].name
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
