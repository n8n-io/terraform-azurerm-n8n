# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Outputs ───────────────────────────────────────────────────────────────────
# The outputs contract `modules/workload/` (US-021..US-024) and the rewritten
# `examples/complete/` (US-025) consume. Subsequent stories layer in Postgres
# / Redis / Storage / App Gateway outputs as their resources move into this
# submodule:
#
#   - US-015 (AKS):       cluster_id, cluster_name, kube_config (sensitive),
#                         oidc_issuer_url, n8n_workload_uami_client_id
#                         (sensitive), n8n_workload_uami_principal_id
#                         (sensitive — added in US-020) — defined below
#   - US-016 (Postgres):  postgres_fqdn, postgres_admin_username (sensitive),
#                         postgres_admin_password (sensitive),
#                         postgres_database_name — defined below
#   - US-017 (Redis):     redis_hostname, redis_ssl_port, redis_primary_access_key
#                         (sensitive) — defined below
#   - US-018 (Storage):   storage_account_name,
#                         storage_account_primary_access_key (sensitive),
#                         storage_share_name — defined below
#   - US-019 (App GW):    app_gateway_id, appgw_public_ip_address, appgw_fqdn,
#                         key_vault_id, key_vault_uri — defined below
#   - US-020 (contract):  contract finalised. The `output_contract_complete`
#                         run in tests/defaults.tftest.hcl asserts every named
#                         output above resolves to a non-null value in plan,
#                         locking in the contract `modules/workload/` (US-023)
#                         consumes against a frozen surface.

# ── AKS (US-015) ─────────────────────────────────────────────────────────────

output "aks_cluster_id" {
  description = "Resource ID of the AKS cluster. Consumed by example wiring that scopes role assignments to the cluster (e.g. AGIC Contributor)."
  value       = azurerm_kubernetes_cluster.n8n.id
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster. Used by the umbrella example (US-025) when configuring the kubernetes / helm providers (e.g. for `data.azurerm_kubernetes_cluster.n8n` lookups in callers that prefer data-source-based kubeconfig refresh over the `kube_config` output)."
  value       = azurerm_kubernetes_cluster.n8n.name
}

output "aks_kube_config" {
  description = "Local-account kubeconfig block for the AKS cluster. The cluster has no AAD-RBAC integration so this IS the local-account admin credential — equivalent in trust shape to `kube_admin_config` on AAD-enabled clusters. Consumed by `modules/workload/` (and the umbrella example's providers.tf) to configure certificate-based kubernetes / helm provider auth without a kubelogin / exec dependency."
  value       = azurerm_kubernetes_cluster.n8n.kube_config
  sensitive   = true
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster. Consumed by `modules/workload/` (US-023) when it creates the federated-identity-credential binding the n8n Kubernetes service account to `n8n_workload_uami_client_id` so n8n pods can authenticate to Azure services without static credentials."
  value       = azurerm_kubernetes_cluster.n8n.oidc_issuer_url
}

output "n8n_workload_uami_client_id" {
  description = "Client ID of the n8n workload user-assigned identity. Consumed by `modules/workload/` (US-023) to (a) bind a Kubernetes-side federated identity credential to the AKS OIDC issuer + n8n service account, and (b) annotate the n8n service account with `azure.workload.identity/client-id`. Marked sensitive because the identity's client_id is an authentication-relevant value."
  value       = azurerm_user_assigned_identity.n8n_workload.client_id
  sensitive   = true
}

output "n8n_workload_uami_principal_id" {
  description = "Principal (AAD object) ID of the n8n workload user-assigned identity. Distinct from `client_id`: the principal_id is the AAD-side object that Azure RBAC role assignments target, while client_id is the OIDC `sub` claim consumed by federated-identity-credential subject mappings. Consumed by `modules/workload/` (US-023) and the umbrella example (US-025) when scoping role assignments to the n8n_workload identity (e.g. `Storage Blob Data Reader` / `Key Vault Secrets User` extensions on the caller side). Marked sensitive per the same conservative shape as `client_id`."
  value       = azurerm_user_assigned_identity.n8n_workload.principal_id
  sensitive   = true
}

# ── PostgreSQL Flexible Server (US-016) ──────────────────────────────────────

output "postgres_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL Flexible Server. Resolves to the server's private IP from inside `var.vnet_id` via the `privatelink.postgres.database.azure.com` private DNS zone created by this submodule. Consumed by `modules/workload/` (US-023) when it builds the n8n database connection string."
  value       = azurerm_postgresql_flexible_server.n8n.fqdn
}

output "postgres_admin_username" {
  description = "PostgreSQL administrator login name (mirrors `var.pg_admin_username`). Consumed by `modules/workload/` (US-023) when it builds the n8n database-credentials Secret. Marked sensitive because it is part of the database credential pair."
  value       = var.pg_admin_username
  sensitive   = true
}

output "postgres_admin_password" {
  description = "PostgreSQL administrator password generated by `random_password.postgres_admin`. Consumed by `modules/workload/` (US-023) when it builds the n8n database-credentials Secret. Rotating the password is a destructive operation under the current shape — the chart and helm release would have to be reconciled in lockstep; document the rotation recipe in a follow-up runbook story."
  value       = random_password.postgres_admin.result
  sensitive   = true
}

output "postgres_database_name" {
  description = "Name of the PostgreSQL database `azurerm_postgresql_flexible_server_database.n8n` provisions. Always `n8n` today (matches the legacy umbrella module's hardcoded database name). Consumed by `modules/workload/` (US-023) when it builds the n8n database connection string."
  value       = azurerm_postgresql_flexible_server_database.n8n.name
}

# ── Redis Cache (US-017) ──────────────────────────────────────────────────────

output "redis_hostname" {
  description = "Hostname of the Azure Cache for Redis instance. Resolves to the cache's private IP from inside `var.vnet_id` via the `privatelink.redis.cache.windows.net` private DNS zone created by this submodule. Consumed by `modules/workload/` (US-023) when it builds the n8n queue-backend connection string and the KEDA TriggerAuthentication Secret."
  value       = azurerm_redis_cache.n8n.hostname
}

output "redis_ssl_port" {
  description = "TLS-only port the Azure Cache for Redis listens on (always 6380 — `non_ssl_port_enabled = false` is hardcoded). Consumed by `modules/workload/` (US-023) when it builds the n8n queue-backend connection string."
  value       = azurerm_redis_cache.n8n.ssl_port
}

output "redis_primary_access_key" {
  description = "Primary access key for the Azure Cache for Redis instance (the bearer credential n8n + KEDA use to authenticate). Consumed by `modules/workload/` (US-023) when it builds the n8n queue-backend Secret and the KEDA TriggerAuthentication Secret. Marked sensitive."
  value       = azurerm_redis_cache.n8n.primary_access_key
  sensitive   = true
}

# ── Storage Account / Azure Files share (US-018) ──────────────────────────────

output "storage_account_name" {
  description = "Name of the Azure storage account that backs the n8n Azure Files share. Consumed by `modules/workload/` (US-023) when it builds the chart-side `azurefiles-credentials` Kubernetes Secret + the static `PersistentVolume` referenced by every n8n pod's binary-data mount. Mirrors `local.storage_account_name`."
  value       = azurerm_storage_account.n8n.name
}

output "storage_account_primary_access_key" {
  description = "Primary access key for the storage account that backs the n8n Azure Files share. Consumed by `modules/workload/` (US-023) when it builds the chart-side `azurefiles-credentials` Kubernetes Secret. The workload tier may instead resolve the key at runtime via the `n8n_workload` UAMI's `Storage Account Key Operator Service Role` role assignment (also created by this submodule, see `storage.tf`); the static-key path stays available for callers that prefer the legacy v1.x wiring. Marked sensitive."
  value       = azurerm_storage_account.n8n.primary_access_key
  sensitive   = true
}

output "storage_share_name" {
  description = "Name of the Azure Files share that backs n8n binary data. Always `n8n-binary-data` today (the resource name is fixed in `storage.tf` because the chart-side wiring in `modules/workload/` references it directly). Consumed by `modules/workload/` (US-023) when it builds the chart-side `PersistentVolume` mount."
  value       = azurerm_storage_share.n8n_binary.name
}

# ── Application Gateway + Key Vault (US-019) ──────────────────────────────────

output "app_gateway_id" {
  description = "Resource ID of the Application Gateway. Consumed by the umbrella example (US-025) for diagnostics and by `modules/workload/` (US-023) when the chart-side n8n Ingress sets the `appgw-ssl-certificate` annotation against this gateway."
  value       = azurerm_application_gateway.n8n.id
}

output "appgw_public_ip_address" {
  description = "Static public IPv4 address of the Application Gateway. Callers wire DNS — manual A-record or one of the Phase-2 automated public/private DNS paths in the umbrella example — to point `var.n8n_domain` at this address."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_fqdn" {
  description = "Azure-assigned cloudapp.azure.com hostname of the Application Gateway public IP (e.g. `<friendly_name_prefix>-n8n.<region>.cloudapp.azure.com`). Always-on Azure-managed alternative to `appgw_public_ip_address` for callers that want to CNAME `var.n8n_domain` at a hostname rather than an IP. Resolves to the same address as `appgw_public_ip_address`."
  value       = azurerm_public_ip.appgw.fqdn
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault holding the App Gateway TLS cert (mirrors `var.app_gateway_keyvault_id`). Null when the caller did NOT supply a vault — in which case the caller is responsible for granting the `appgw_tls_cert` UAMI access on the cert's vault out-of-band. Consumed by the umbrella example (US-025) for diagnostics and by `modules/workload/` (US-023) when the chart-side AGIC annotation references the cert."
  value       = var.app_gateway_keyvault_id
}

output "key_vault_uri" {
  description = "Vault URI of the Key Vault holding the App Gateway TLS cert (e.g. `https://<vault>.vault.azure.net/`). Resolved via `data.azurerm_key_vault.byo` when `var.app_gateway_keyvault_role_assignment_enabled = true`; null otherwise. The legacy module-owned `azurerm_key_vault.n8n` was removed in registry-hardening US-012 — this submodule never owns a vault, only optionally references one supplied by the caller."
  value       = var.app_gateway_keyvault_role_assignment_enabled ? data.azurerm_key_vault.byo[0].vault_uri : null
}
