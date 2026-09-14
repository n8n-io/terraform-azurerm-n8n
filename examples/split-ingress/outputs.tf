# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

output "n8n_url" {
  description = "URL for the n8n editor UI. Resolves to the internal (admin) Application Gateway, so it is reachable only from inside the VNet or over VPN/peering."
  value       = "https://${var.n8n_domain}"
}

output "webhook_base_url" {
  description = "Public base URL for webhooks, forms, and MCP. Passed to the root module as n8n_webhook_url, so n8n's own N8N_WEBHOOK_URL matches this value — see module.n8n.n8n_webhook_url for the module's own confirmation of the effective value."
  value       = "https://${local.webhook_domain}"
}

output "main_hpa_min_replicas" {
  description = "Effective main-topology floor passed to the root module's n8n_main_hpa_min_replicas. See module.n8n.n8n_url for confirmation the module accepted it."
  value       = var.n8n_main_hpa_min_replicas
}

output "webhook_appgw_fqdn" {
  description = "FQDN of the public webhook Application Gateway."
  value       = azurerm_public_ip.webhook.fqdn
}

output "admin_appgw_private_ip" {
  description = "Private IPv4 address of the internal admin Application Gateway's frontend, once AGIC provisions it. Null until then."
  value       = try([for c in azurerm_application_gateway.admin.frontend_ip_configuration : c.private_ip_address if c.name == "admin-frontend-ip"][0], null)
}

output "webhook_path_prefixes" {
  description = "Path prefixes routed to the webhook processors on the public gateway. Sourced from the module so this example cannot drift from what n8n actually serves."
  value       = module.n8n.n8n_webhook_path_prefixes
}

output "kubectl_config_command" {
  description = "Command that writes the AKS context into the local kubeconfig."
  value       = "az aks get-credentials --name ${module.n8n.aks_cluster_name} --resource-group ${azurerm_resource_group.n8n.name} --overwrite-existing"
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  value       = module.n8n.n8n_namespace
}

output "postgres_password" {
  description = "Generated PostgreSQL administrator password. Back it up in a secret manager."
  value       = module.n8n.postgres_admin_password
  sensitive   = true
}
