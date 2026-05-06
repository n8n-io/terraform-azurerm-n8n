# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── DNS delegation ────────────────────────────────────────────────────────────
# The Azure DNS zone the example creates needs upstream NS delegation at the
# registrar before the world can resolve var.n8n_domain to the App Gateway
# public IP. Retrieve the NS records after `terraform apply` and copy them
# into the registrar's DNS settings for var.public_dns_zone_name.

output "public_dns_zone_name" {
  description = "Name of the public Azure DNS zone the example created. Identical to var.public_dns_zone_name — exposed so callers can pipe `terraform output` straight into automation."
  value       = azurerm_dns_zone.public.name
}

output "public_dns_zone_name_servers" {
  description = "Authoritative name servers Azure assigned to the public DNS zone. Configure these at your registrar as the NS records for var.public_dns_zone_name to complete the upstream delegation. Run `terraform output -json public_dns_zone_name_servers` after apply."
  value       = azurerm_dns_zone.public.name_servers
}

# ── Pass-through of module outputs ────────────────────────────────────────────
# Re-export the most useful module outputs at the example level so
# `terraform output` from inside examples/complete-self-signed/ surfaces them
# without `terraform output -module=infra` / `-module=workload`.

output "appgw_public_ip" {
  description = "Static public IP address of the Application Gateway (sourced from `module.infra.appgw_public_ip_address`). The example also writes the A-record automatically — surfaced here for sanity-checking."
  value       = module.infra.appgw_public_ip_address
}

output "n8n_url" {
  description = "URL n8n is reachable at once DNS delegation is in place (sourced from `module.workload.n8n_url`)."
  value       = module.workload.n8n_url
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster — pass to `az aks get-credentials --name <this> --resource-group <aks_resource_group>` (sourced from `module.infra.aks_cluster_name`)."
  value       = module.infra.aks_cluster_name
}

output "aks_resource_group" {
  description = "Name of the workload resource group the AKS cluster (and every other module.infra-owned resource) lives in. Distinct from the example's network resource group, which holds the VNet / DNS zone / shared KV."
  value       = azurerm_resource_group.n8n.name
}

output "n8n_namespace" {
  description = "Kubernetes namespace n8n is deployed into (sourced from `module.workload.n8n_namespace`). Use `kubectl -n <this>` for operational queries."
  value       = module.workload.n8n_namespace
}

output "tls_self_signed_cert_secret_id" {
  description = "Versioned Key Vault Secret URI for the submodule-issued self-signed cert. Sensitive because it embeds the certificate's secret-version segment, which a holder of read access to the vault can use to fetch the private key."
  value       = module.tls_self_signed.app_gateway_tls_cert_secret_id
  sensitive   = true
}
