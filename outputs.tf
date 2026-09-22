# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Outputs ───────────────────────────────────────────────────────────────
# The single-module-deployment spec requires every output to derive from a
# managed resource attribute (not a bare variable echo) so Terraform
# preserves the dependency edge — see the spec scenario "Consume a workload
# ordering output".
#
# Section 2 (AKS) is the first section with resources to derive outputs
# from; it adds the six AKS/identity outputs below. Later sections add the
# rest, following the shape `modules/infra/outputs.tf` and
# `modules/workload/outputs.tf` used:
#
#   - Section 3 (PostgreSQL):   postgres_fqdn / postgres_database_name (or
#                                the external-connection equivalents),
#                                postgres_admin_username / _password
#                                (sensitive).
#   - Section 4 (Redis):        redis_hostname, redis_port,
#                                redis_primary_access_key (sensitive), or the
#                                external-connection equivalents.
#   - Section 5 (Storage):      storage_account_name, blob_container_name.
#   - Section 6 (Controllers):  n8n namespace, Helm release, URL, and
#                                caller-owned ingress service coordinates.
#   - Section 11 (Ingress):     app_gateway_id, appgw_public_ip_address,
#                                appgw_private_ip_address, appgw_fqdn.
#
# Every secret-bearing output is marked `sensitive = true` when it lands,
# matching the single-module-deployment spec's stable-public-contract
# requirement.

# ── AKS ──────────────────────────────────────────────────────────────────

output "aks_cluster_id" {
  description = "Resource ID of the effective AKS cluster (module-created or existing). Consumed by caller wiring that scopes role assignments to the cluster (e.g. AGIC Contributor)."
  value       = local.effective_aks_cluster_id
}

output "aks_cluster_name" {
  description = "Name of the effective AKS cluster (module-created or existing). Useful for `data.azurerm_kubernetes_cluster.n8n` lookups in callers that prefer data-source-based kubeconfig refresh over the `aks_kube_config` output."
  value       = local.effective_aks_cluster_name
}

output "aks_kube_config" {
  description = "Local-account kubeconfig block for the effective AKS cluster (module-created or existing). The cluster has no AAD-RBAC integration so this IS the local-account admin credential. A calling root uses this to configure the kubernetes / helm providers against this module's cluster (see examples/small/providers.tf, section 13) without a kubelogin / exec dependency. On existing AKS, the caller's own read permissions on the referenced cluster govern whether this local-account kubeconfig is available."
  value       = local.effective_aks_kube_config
  sensitive   = true
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for the effective AKS cluster (module-created or existing). Useful for callers wiring their own federated identity credentials against workload identities this module does not manage."
  value       = local.effective_aks_oidc_issuer_url
}

output "n8n_workload_uami_client_id" {
  description = "Client ID of the n8n workload user-assigned identity. Consumed by n8n pods via the `azure.workload.identity/client-id` service-account annotation the Helm release (section 6) sets, and by callers extending the identity's role assignments. Marked sensitive because the identity's client_id is an authentication-relevant value."
  value       = azurerm_user_assigned_identity.n8n_workload.client_id
  sensitive   = true
}

output "n8n_workload_uami_principal_id" {
  description = "Principal (AAD object) ID of the n8n workload user-assigned identity. Distinct from `client_id`: the principal_id is the AAD-side object Azure RBAC role assignments target (e.g. `Storage Blob Data Contributor` in section 5), while client_id is the OIDC `sub` claim consumed by federated-identity-credential subject mappings. Marked sensitive per the same conservative shape as `client_id`."
  value       = azurerm_user_assigned_identity.n8n_workload.principal_id
  sensitive   = true
}

# ── PostgreSQL ───────────────────────────────────────────────────────────
# Derived from `local.postgres_connection` (database.tf, section 3) rather
# than the `azurerm_postgresql_flexible_server.n8n[0]` resource directly, so
# the same four outputs are meaningful on both the managed and external
# database paths.

output "postgres_fqdn" {
  description = "Hostname n8n connects to for PostgreSQL — either the module-managed Flexible Server's private FQDN (`create_database = true`) or the caller-supplied `postgres_external_host` (`create_database = false`)."
  value       = local.postgres_connection.host
}

output "postgres_database_name" {
  description = "Database name n8n connects to — either the module-managed database (`create_database = true`, always `n8n`) or `postgres_external_database` (`create_database = false`)."
  value       = local.postgres_connection.database
}

output "postgres_admin_username" {
  description = "Username n8n authenticates to PostgreSQL with — either `var.pg_admin_username` (`create_database = true`) or `postgres_external_username` (`create_database = false`)."
  value       = local.postgres_connection.username
}

output "postgres_server_id" {
  description = "Resource ID of the module-managed PostgreSQL Flexible Server (`create_database = true`), for caller-owned scoping such as an `azurerm_management_lock` with `lock_level = \"CanNotDelete\"` (see docs/deletion-safety.md). Null when `create_database = false`."
  value       = var.create_database ? azurerm_postgresql_flexible_server.n8n[0].id : null
}

output "postgres_admin_password" {
  description = "Password n8n authenticates to PostgreSQL with — either the generated `random_password.postgres_admin` (`create_database = true`) or `postgres_external_password` (`create_database = false`). Explicitly null when `postgres_password_secret_ref` selects a caller-managed Kubernetes Secret instead, because Terraform never reads that Secret's value. Marked sensitive."
  value       = local.postgres_connection.password
  sensitive   = true
}

# ── Redis ──────────────────────────────────────────────────────
# Derived from `local.redis_connection` (redis.tf, section 4) rather than
# the `azurerm_managed_redis.n8n[0]` resource directly, so the same outputs
# are meaningful on both the managed and external Redis paths.

output "redis_hostname" {
  description = "Hostname n8n and KEDA connect to for Redis — either the module-managed Azure Managed Redis instance's private hostname (`create_redis = true`) or the caller-supplied `redis_external_host` (`create_redis = false`)."
  value       = local.redis_connection.host
}

output "redis_port" {
  description = "Port n8n and KEDA connect to for Redis — either the module-managed instance's database port (`create_redis = true`) or `redis_external_port` (`create_redis = false`)."
  value       = local.redis_connection.port
}

output "redis_primary_access_key" {
  description = "Credential n8n and KEDA authenticate to Redis with — either the generated Azure Managed Redis primary access key (`create_redis = true`) or `redis_external_password` (`create_redis = false`). Explicitly null when `redis_password_secret_ref` selects a caller-managed Kubernetes Secret instead, because Terraform never reads that Secret's value. Marked sensitive."
  value       = local.redis_connection.password
  sensitive   = true
}

# ── Storage ───────────────────────────────────────────────────────────────

output "storage_account_name" {
  description = "Name of the Blob storage account n8n uses — the module-managed StorageV2 account (create_blob_storage = true, the default) or the caller-supplied existing_blob_storage_account_name (create_blob_storage = false)."
  value       = local.effective_blob_storage_account_name
}

output "storage_account_id" {
  description = "Resource ID of the module-managed Blob storage account (`create_blob_storage = true`), for caller-owned scoping such as an `azurerm_management_lock` with `lock_level = \"CanNotDelete\"` (see docs/deletion-safety.md). Null when `create_blob_storage = false`."
  value       = var.create_blob_storage ? azurerm_storage_account.n8n[0].id : null
}

output "azure_blob_container_name" {
  description = "Name of the private Azure Blob container n8n uses for binary data and optional Azure execution-data bundles — the module-managed container (create_blob_storage = true, the default) or the caller-supplied existing_blob_container_name (create_blob_storage = false)."
  value       = local.effective_blob_container_name
}

output "azure_blob_endpoint" {
  description = "Azure Blob endpoint n8n uses — the module-managed storage account endpoint (create_blob_storage = true, the default), a caller-supplied custom endpoint override, or the caller-supplied existing_blob_endpoint (create_blob_storage = false). Marked sensitive because custom endpoints may expose private topology names."
  value       = local.azure_blob_connection.endpoint
  sensitive   = true
}

output "n8n_encryption_key" {
  description = "Effective n8n encryption key that wraps every credential stored in n8n's database — the caller-supplied `var.n8n_encryption_key` when set, otherwise the module-generated key. Explicitly null when `n8n_encryption_key_secret_ref` selects a caller-managed Kubernetes Secret instead, because Terraform never reads that Secret's value. Back this up to a password manager immediately after the first apply — losing it makes existing credentials unrecoverable on any future deployment."
  value       = local.n8n_encryption_key
  sensitive   = true
}

# ── n8n workload and service discovery ───────────────────────────────────

output "n8n_namespace" {
  description = "Kubernetes namespace containing the n8n workload — the module-created namespace when create_namespace = true (the default), or the caller-supplied existing namespace name when create_namespace = false."
  # On the create_namespace = true path this deliberately reads the resource
  # attribute rather than the plan-time-constant local, so a caller's own
  # kubernetes_* resources referencing this output (e.g. the caller-managed
  # Secrets behind n8n_credentials_overwrite_secret_ref or
  # redis_password_secret_ref) get a dependency edge on the namespace. Without
  # it Terraform schedules them concurrently with the namespace on a cold
  # apply and they fail with `namespaces "n8n" not found`. The value is the
  # same string either way; only the graph edge differs. Mirrors the AWS
  # sibling's `namespace` output.
  value = var.create_namespace ? kubernetes_namespace.n8n[0].metadata[0].name : local.n8n_namespace
}

output "n8n_helm_release_name" {
  description = "Name of the n8n Helm release."
  value       = helm_release.n8n.name
}

output "n8n_helm_release_revision" {
  description = "Revision number of the most recent successful n8n Helm install or upgrade."
  value       = helm_release.n8n.metadata[0].revision
}

output "n8n_service_name" {
  description = "Name of the chart-rendered ClusterIP Service for n8n main pods. Point caller-owned editor and API ingress routes at this service."
  value       = "${helm_release.n8n.name}-main"
}

output "n8n_webhook_service_name" {
  description = "Name of the chart-rendered ClusterIP Service for dedicated webhook-processor pods."
  value       = "${helm_release.n8n.name}-webhook-processor"
}

output "n8n_service_port" {
  description = "Port exposed by both chart-rendered n8n ClusterIP Services."
  value       = local.n8n_service_port

  depends_on = [helm_release.n8n]
}

output "n8n_webhook_path_prefixes" {
  description = "Complete path-prefix set caller-owned ingress must route to n8n_webhook_service_name before its main-service catch-all."
  value       = local.n8n_webhook_path_prefixes

  depends_on = [helm_release.n8n]
}

output "n8n_test_webhook_path_prefixes" {
  description = "Editor test-mode path prefixes (test webhooks, Form Trigger test mode, MCP test mode) caller-owned ingress must route to n8n_service_name ahead of n8n_webhook_path_prefixes. Application Gateway matches string prefixes in declared order, so /webhook* would otherwise capture /webhook-test."
  value       = local.n8n_test_webhook_path_prefixes

  depends_on = [helm_release.n8n]
}

output "n8n_url" {
  description = "Canonical HTTPS URL for the n8n editor UI (N8N_EDITOR_BASE_URL). This is also the default webhook base unless n8n_webhook_url overrides it — see the n8n_webhook_url output for the effective advertised webhook base."
  value       = "https://${var.n8n_domain}"

  depends_on = [helm_release.n8n]
}

output "n8n_webhook_url" {
  description = "Effective HTTPS base URL n8n advertises as N8N_WEBHOOK_URL. Equals n8n_url unless the caller supplies var.n8n_webhook_url (port-aws-040-enhancements section 11), for example to advertise a separate public webhook host in examples/split-ingress."
  value       = local.n8n_effective_webhook_url

  depends_on = [helm_release.n8n]
}

# ── Application Gateway ingress ──────────────────────────────────────────

output "app_gateway_id" {
  description = "Resource ID of the module-managed Application Gateway. Null when create_ingress is false."
  value       = var.create_ingress ? azurerm_application_gateway.n8n[0].id : null
}

output "appgw_public_ip_address" {
  description = "Static public IPv4 address of the module-managed Application Gateway. Null for internal frontend mode or when create_ingress is false."
  value       = var.create_ingress && var.appgw_frontend_mode == "public" ? azurerm_public_ip.appgw[0].ip_address : null
}

output "appgw_private_ip_address" {
  description = "Private frontend IPv4 address of the module-managed Application Gateway. Null for public frontend mode or when create_ingress is false."
  value       = var.create_ingress && var.appgw_frontend_mode == "internal" ? azurerm_application_gateway.n8n[0].frontend_ip_configuration[0].private_ip_address : null
}

output "appgw_fqdn" {
  description = "Azure-assigned cloudapp.azure.com hostname of the public Application Gateway frontend. Null for internal frontend mode or when create_ingress is false."
  value       = var.create_ingress && var.appgw_frontend_mode == "public" ? azurerm_public_ip.appgw[0].fqdn : null
}
