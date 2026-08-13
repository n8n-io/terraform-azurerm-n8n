# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

output "tier_configuration" {
  description = "Plan-known sizing and availability decisions used by this example and passed into the root module."
  value       = local.tier
}

output "n8n_url" {
  description = "Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings."
  value       = module.n8n.n8n_url
}

output "appgw_public_ip" {
  description = "Public IPv4 address of the module-managed Application Gateway."
  value       = module.n8n.appgw_public_ip_address
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.n8n.aks_cluster_name
}

output "aks_resource_group" {
  description = "Resource group containing AKS and the n8n managed services."
  value       = azurerm_resource_group.n8n.name
}

output "kubectl_config_command" {
  description = "Command that writes the AKS context into the local kubeconfig."
  value       = "az aks get-credentials --name ${module.n8n.aks_cluster_name} --resource-group ${azurerm_resource_group.n8n.name} --overwrite-existing"
}

output "namespace" {
  description = "Kubernetes namespace containing n8n."
  value       = module.n8n.n8n_namespace
}

output "public_dns_zone_name_servers" {
  description = "Azure DNS name servers to delegate at the registrar."
  value       = azurerm_dns_zone.public.name_servers
}

output "postgres_fqdn" {
  description = "Private FQDN of the example-owned zone-redundant PostgreSQL server behind PgBouncer."
  value       = azurerm_postgresql_flexible_server.n8n.fqdn
}

output "postgres_password" {
  description = "Generated PostgreSQL administrator password. Back it up in a secret manager."
  value       = random_password.postgres.result
  sensitive   = true
}

output "tls_certificate_secret_id" {
  description = "Versioned Key Vault Secret URI consumed by Application Gateway."
  value       = module.tls_self_signed.app_gateway_tls_cert_secret_id
  sensitive   = true
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
  description = "Name of the private StorageV2 account holding the Azure Blob container. Consumed by tests/scripts/smoke-test.sh to verify Azure Blob access."
  value       = module.n8n.storage_account_name
}

output "azure_blob_container_name" {
  description = "Name of the private Azure Blob container used for n8n binary and execution data. Consumed by tests/scripts/smoke-test.sh."
  value       = module.n8n.azure_blob_container_name
}

output "n8n_webhook_path_prefixes" {
  description = "Complete path-prefix set the Ingress routes to the webhook-processor service. Consumed by tests/scripts/smoke-test.sh to verify webhook route ownership."
  value       = module.n8n.n8n_webhook_path_prefixes
}
