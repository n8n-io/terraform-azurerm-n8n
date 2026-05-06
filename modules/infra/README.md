# `terraform-azurerm-n8n` — `modules/infra/`

IaaS layer for the production-grade n8n Enterprise deployment on Microsoft
Azure. This submodule provisions everything that lives **below** Kubernetes:

- Azure Kubernetes Service (AKS) cluster + node pool + AKS-related
  user-assigned identities (US-015).
- Azure Database for PostgreSQL Flexible Server + private DNS zone (US-016).
- Azure Cache for Redis + private endpoint + private DNS zone (US-017).
- Storage Account + Azure Files share (US-018).
- Application Gateway + Public IP + Key Vault + IAM (US-019).

The Kubernetes-side workload (KEDA + n8n Helm release + manifests) lives in
the sibling [`modules/workload/`](../workload/) submodule (US-021..US-024).
The root [`terraform-azurerm-n8n`](../../README.md) module's
`examples/complete/` (US-025) wires both submodules together end-to-end.

## Why a separate IaaS submodule?

The Phase 5 split mirrors the
[`terraform-azurerm-terraform-enterprise-hvd`](https://github.com/hashicorp/terraform-azurerm-terraform-enterprise-hvd)
HashiCorp Validated Design's posture: the IaaS layer pins a single provider
(`azurerm`, plus `random` for resource-name suffixing) and exposes its
contract through plain outputs. The workload layer pulls the
kubernetes / helm / kubectl provider tree on top.

The split keeps `terraform init` lean for callers who only need the
infrastructure piece (e.g. building a fleet of AKS clusters and wiring n8n
into them later from a separate state file), and gives the registry-readiness
audit a clean module boundary to point at.

## Pre-requisites

- An existing Azure resource group (`var.resource_group_name`).
- An existing VNet (`var.vnet_id`) with five pre-configured subnets:
  AKS, Application Gateway, PostgreSQL Flexible Server (delegated to
  `Microsoft.DBforPostgreSQL/flexibleServers`), Redis Cache private
  endpoint, and an additional private-endpoint subnet for Storage / Key
  Vault. See `examples/complete/` in the root module for an AVM-based
  reference VNet that satisfies all of these requirements.
- The principal running `terraform apply` must hold `Contributor` (or
  more granular role assignments) on the resource group, plus the rights
  needed to create User-Assigned Managed Identities and role assignments
  inside the subscription.

## Status

The **R5.1f** Application Gateway + Key Vault + IAM slice
(registry-hardening US-019) is in place — `ingress.tf` declares the
Application Gateway v2 (caller-tunable WAF_v2 / Standard_v2 SKU and
capacity), the static Standard-SKU Public IP, the `appgw_tls_cert` UAMI,
and the AGIC-addon-scoped Contributor role assignment on the App
Gateway. `keyvault.tf` declares the count-gated `data.azurerm_key_vault.byo`
data lookup and the count-gated `Key Vault Secrets User` role assignment
that lets the App Gateway UAMI fetch the TLS cert at runtime when
`var.app_gateway_keyvault_id` is set. `iam.tf` declares the explicit
(forward-reference) `agic` UAMI, the `agic_rg_reader` role assignment
binding it to the BYO resource group, and the `agic_addon_rg_reader`
role assignment binding the AKS-addon's auto-created identity to the
same RG. The `aks.tf` AKS cluster gains the `ingress_application_gateway`
addon block pointing at the new App Gateway. R5.1e (US-018) shipped the
Storage slice — `storage.tf` declares the Azure Storage Account that
backs the n8n Azure Files share (Standard / StorageV2 with caller-tunable
replication type; hardened HTTPS-only + TLS 1.2 posture), the
`n8n-binary-data` Azure Files share, and the `Storage Account Key
Operator Service Role` role assignment binding the `n8n_workload` UAMI
to the storage account so the workload tier (US-023) can resolve the
access key via workload-identity federation instead of embedding the
static key in a long-lived Kubernetes Secret. R5.1d (US-017) shipped the
Redis slice — `redis.tf` declares the private-only Azure Cache for
Redis, its private endpoint on `var.redis_subnet_id`, and the
`privatelink.redis.cache.windows.net` private DNS zone + VNet link.
R5.1c (US-016) shipped the PostgreSQL slice — `database.tf` declares
the PostgreSQL Flexible Server (private-only, delegated subnet +
private DNS zone), the `azure.extensions = UUID-OSSP` server-level
allowlist (preserved from US-001 as a forward-compatible safety belt),
the `random_password.postgres_admin` admin password, and the `n8n`
database. R5.1b (US-015) shipped the AKS slice — `aks.tf` declares the
AKS cluster, the optional user node pool, the `aks_kubelet` and
`n8n_workload` user-assigned identities, the `aks_kubelet` Network
Contributor role assignment on the AKS subnet, and the
`time_sleep.aks_api_warmup` gate (replaces the legacy
`null_resource.wait_for_aks_api`, US-003). Subsequent story (US-020)
finalises the outputs contract that `modules/workload/` consumes;
US-025 rewrites `examples/complete/main.tf` to call this submodule and
`modules/workload/`.

## Provider configuration

This submodule declares `required_providers` for `azurerm`, `random`, and
`time` (the `time_sleep.aks_api_warmup` gate). Provider configuration is
the caller's job — the submodule does not include any `provider {}` blocks.
A minimal caller `providers.tf`:

```hcl
provider "azurerm" {
  features {}
}

provider "random" {}

provider "time" {}
```

## Outputs contract

The auto-generated block below lists every input variable + output that
`modules/workload/` (US-021..US-024) and the umbrella example (US-025)
contract against. Consumer code should read every cross-module value
through one of these named outputs — the `output_contract_complete` run
in `tests/defaults.tftest.hcl` asserts each one resolves to a non-null
value at apply time.

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.12 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_application_gateway.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_federated_identity_credential.n8n_workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_kubernetes_cluster.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.n8n_user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_postgresql_flexible_server.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server) | resource |
| [azurerm_postgresql_flexible_server_configuration.uuid_ossp](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_configuration) | resource |
| [azurerm_postgresql_flexible_server_database.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_database) | resource |
| [azurerm_private_dns_zone.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_dns_zone_virtual_network_link.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_endpoint.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_public_ip.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_redis_cache.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/redis_cache) | resource |
| [azurerm_role_assignment.agic_addon_appgw_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_addon_appgw_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_addon_appgw_tls_uami_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_addon_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_kubelet_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.appgw_kv_secrets_user](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.n8n_workload_storage_account_key_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_share.n8n_binary](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_share) | resource |
| [azurerm_user_assigned_identity.agic](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.aks_kubelet](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.appgw_tls_cert](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.n8n_workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_web_application_firewall_policy.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/web_application_firewall_policy) | resource |
| [random_password.postgres_admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.aks_api_warmup](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.appgw_kv_secrets_user_rbac_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_key_vault.byo](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/key_vault) | data source |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_api_warmup_seconds"></a> [aks\_api\_warmup\_seconds](#input\_aks\_api\_warmup\_seconds) | Seconds to wait after `azurerm_kubernetes_cluster.n8n` reports success before downstream Kubernetes-/Helm-provider resources (in modules/workload/) are created. Replaces the legacy `null_resource.wait_for_aks_api` /healthz poll-loop (registry-hardening US-003) with a deterministic `time_sleep`. Azure reports the AKS resource as `Succeeded` before /healthz is consistently green; the kubernetes/helm providers' built-in retry handles any transient 503s after the gate. Default 90 s covers the typical AKS post-provision warm-up. Operators on cold regions or capacity-constrained subscriptions can extend this; the floor (30 s) is below which the providers' retry budget alone is insufficient, the ceiling (600 s) matches the legacy probe's 10-minute upper bound. | `number` | `90` | no |
| <a name="input_aks_kubernetes_version"></a> [aks\_kubernetes\_version](#input\_aks\_kubernetes\_version) | Kubernetes version for the AKS cluster (e.g. 1.33, 1.33.4). Must be a version Azure currently supports on the standard plan in the target region — check with `az aks get-versions --location <region>` and the AKS support-plan matrix at https://learn.microsoft.com/azure/aks/supported-kubernetes-versions. Defaults to 1.33; bump deliberately. Versions outside the standard support window (e.g. 1.30 in mid-2026) are LTS-only and require a Premium-tier cluster to provision — the 400 `K8sVersionNotSupported` error from the AKS API surfaces with that exact subcode. | `string` | `"1.33"` | no |
| <a name="input_aks_node_count_max"></a> [aks\_node\_count\_max](#input\_aks\_node\_count\_max) | Maximum number of nodes in the AKS default node pool. The cluster autoscaler will not scale above this. Sized to absorb webhook bursts (HPA on the webhook-processor Deployment) and worker scale-out (KEDA on Redis queue depth). | `number` | `6` | no |
| <a name="input_aks_node_count_min"></a> [aks\_node\_count\_min](#input\_aks\_node\_count\_min) | Minimum number of nodes in the AKS default node pool. The cluster autoscaler will not scale below this. Floor of 2 keeps the multi-main topology (≥2 main pods, ≥1 worker, ≥2 webhook processors) schedulable across single-node failures. | `number` | `2` | no |
| <a name="input_aks_node_vm_size"></a> [aks\_node\_vm\_size](#input\_aks\_node\_vm\_size) | Azure VM SKU for the AKS default node pool (e.g. Standard\_D4s\_v4, Standard\_D8s\_v4). Recommended minimum is Standard\_D4s\_v4 (4 vCPU, 16 GB) — multi-main runs 6+ pods at minimum replicas (~3,600m CPU); smaller SKUs leave no headroom for HPA / KEDA scale-out. | `string` | `"Standard_D4s_v4"` | no |
| <a name="input_aks_subnet_id"></a> [aks\_subnet\_id](#input\_aks\_subnet\_id) | Resource ID of the subnet the AKS node pool attaches to (Azure CNI). Sized to fit `aks_node_count_max` plus pod IPs (CNI consumes one IP per pod). No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>. | `string` | n/a | yes |
| <a name="input_app_gateway_keyvault_id"></a> [app\_gateway\_keyvault\_id](#input\_app\_gateway\_keyvault\_id) | Resource ID of the Key Vault holding `var.app_gateway_tls_cert_secret_id`. When `var.app_gateway_keyvault_role_assignment_enabled = true`, this submodule grants the App Gateway TLS-cert reader UAMI (created in `ingress.tf`) `Key Vault Secrets User` on the supplied vault — the minimum role needed for the gateway to fetch the cert at runtime. When the toggle is false (default), the caller is responsible for granting the UAMI access (e.g. via an `access_policy` block on a vault in legacy access-policy mode, or an out-of-band role assignment). The vault should be in the same tenant as the App Gateway. May be `null` when the toggle is false. | `string` | `null` | no |
| <a name="input_app_gateway_keyvault_role_assignment_enabled"></a> [app\_gateway\_keyvault\_role\_assignment\_enabled](#input\_app\_gateway\_keyvault\_role\_assignment\_enabled) | When true, grant the App Gateway TLS-cert reader UAMI `Key Vault Secrets User` on `var.app_gateway_keyvault_id`. Default false; the caller is then responsible for granting the UAMI access out-of-band (e.g. an `access_policy` on a vault in legacy access-policy mode, or an out-of-band role assignment). When set to true, `var.app_gateway_keyvault_id` MUST also be supplied. The toggle is isolated from `var.app_gateway_keyvault_id` so the `count` it drives is plan-time-known even when the ID is a same-plan-built resource attribute (e.g. `azurerm_key_vault.shared.id`). | `bool` | `false` | no |
| <a name="input_app_gateway_tls_cert_secret_id"></a> [app\_gateway\_tls\_cert\_secret\_id](#input\_app\_gateway\_tls\_cert\_secret\_id) | Versioned Azure Key Vault Secret URI for the App Gateway listener's TLS certificate (e.g. `https://<vault>.vault.azure.net/secrets/<cert>/<version>`). Required — the caller is responsible for provisioning the cert and importing it into a Key Vault. The two `modules/tls-letsencrypt/` and `modules/tls-self-signed/` submodules expose this exact value as their `app_gateway_tls_cert_secret_id` output; callers with an existing PKI / DigiCert / Sectigo cert can supply the secret URI directly. Pair with `var.app_gateway_keyvault_id` so this submodule grants the App Gateway UAMI `Key Vault Secrets User` on the vault holding the cert; alternatively grant the UAMI access out-of-band. The legacy `var.tls_mode` + per-mode inputs and the module-owned `azurerm_key_vault.n8n` were removed in registry-hardening US-012 (Phase 4 R4.3). | `string` | n/a | yes |
| <a name="input_appgw_capacity"></a> [appgw\_capacity](#input\_appgw\_capacity) | Number of compute units to allocate for the Application Gateway (manual scaling). Range 1–125 per Azure App Gateway v2 quota. Default 2 keeps a baseline of redundancy without over-provisioning; raise this for higher RPS or larger SSL throughput. Autoscaling (`autoscale_configuration`) is out of scope for this submodule today. | `number` | `2` | no |
| <a name="input_appgw_sku_name"></a> [appgw\_sku\_name](#input\_appgw\_sku\_name) | Application Gateway v2 SKU. `WAF_v2` enables the OWASP-3.2 ruleset in detection mode (logs only, no blocking); `Standard_v2` skips WAF entirely. WAF\_v2 is the recommended default; switch to Standard\_v2 only when WAF licensing is undesirable. Phase 2 work will expose firewall\_mode (Detection vs Prevention) and a BYO firewall\_policy\_id. | `string` | `"WAF_v2"` | no |
| <a name="input_appgw_subnet_id"></a> [appgw\_subnet\_id](#input\_appgw\_subnet\_id) | Resource ID of the subnet the Application Gateway attaches to. Must be dedicated to Application Gateway (no other workloads), with a /24 or larger CIDR per Azure App Gateway sizing guidance. No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>. | `string` | n/a | yes |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags merged onto every taggable resource this module creates. Combined with the module's built-in `ManagedBy = terraform` and `Project = n8n` tags via `local.common_tags`. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Short, lowercase name prefix used in every resource name and as the value of the `Name` tag (e.g. `n8nprod`, `n8ndev`). 2–12 characters, lowercase alphanumeric only — Azure storage-account names cap at 24 chars and must be alnum-lowercase, so this prefix is the binding constraint. | `string` | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | Azure region to deploy into (e.g. eastus, westeurope, australiaeast). Must match the region the azurerm provider is configured for. | `string` | n/a | yes |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must match the CN/SAN on the TLS certificate the App Gateway terminates with. Surfaced through to `modules/workload/` (US-023) so the chart's Ingress object writes the matching `host:` rule + AGIC's `appgw-ssl-certificate` annotation. | `string` | n/a | yes |
| <a name="input_pg_admin_username"></a> [pg\_admin\_username](#input\_pg\_admin\_username) | PostgreSQL administrator (login role) name. Surfaced to n8n via the chart's database-credentials Secret in `modules/workload/` (US-023). Azure Flexible Server reserves a small set of names (`azure_superuser`, `azure_pg_admin`, `admin`, `administrator`, `root`, `guest`, `public`) — the validation below blocks them. Default 'n8n' matches the legacy umbrella module's hardcoded login. | `string` | `"n8n"` | no |
| <a name="input_pg_enable_high_availability"></a> [pg\_enable\_high\_availability](#input\_pg\_enable\_high\_availability) | Enable zone-redundant HA on the PostgreSQL Flexible Server (synchronous standby in a different availability zone). Requires a non-Burstable SKU (GP\_* or MO\_*) — Burstable does NOT support HA. Adds a ~2× cost premium. | `bool` | `false` | no |
| <a name="input_pg_sku_name"></a> [pg\_sku\_name](#input\_pg\_sku\_name) | Azure PostgreSQL Flexible Server SKU (e.g. B\_Standard\_B1ms for dev, GP\_Standard\_D2s\_v3 for production). Format: `<tier>_Standard_<family>` where tier is B (Burstable), GP (General Purpose), or MO (Memory Optimized). Burstable does NOT support zone-redundant HA — set `pg_enable_high_availability = false` when using B\_*. | `string` | `"GP_Standard_D2s_v3"` | no |
| <a name="input_pg_storage_mb"></a> [pg\_storage\_mb](#input\_pg\_storage\_mb) | Allocated storage for the PostgreSQL Flexible Server in MB. Azure minimum is 32768 (32 GB). Storage can be grown but not shrunk in place — size for projected growth. | `number` | `32768` | no |
| <a name="input_pg_version"></a> [pg\_version](#input\_pg\_version) | PostgreSQL major version (e.g. 14, 15, 16). 16 is the current GA on Azure Flexible Server. Major-version upgrades are not in-place — see Azure docs for the upgrade workflow. | `string` | `"16"` | no |
| <a name="input_postgres_subnet_id"></a> [postgres\_subnet\_id](#input\_postgres\_subnet\_id) | Resource ID of the subnet the PostgreSQL Flexible Server is injected into. Must be delegated to `Microsoft.DBforPostgreSQL/flexibleServers` and contain no other workloads (Flexible Server consumes the entire subnet). Format: /subscriptions/<sub>/.../subnets/<name>. | `string` | n/a | yes |
| <a name="input_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#input\_private\_endpoint\_subnet\_id) | Resource ID of the subnet additional private endpoints (e.g. Storage Account, Key Vault) attach to. Must have `private_endpoint_network_policies` disabled (Azure refuses to create a private endpoint when network policies are enforced on the subnet). No subnet delegation required. May be the same as `redis_subnet_id` when callers prefer to consolidate all PEs onto a single subnet, but a dedicated subnet keeps blast-radius smaller. Format: /subscriptions/<sub>/.../subnets/<name>. | `string` | n/a | yes |
| <a name="input_redis_capacity"></a> [redis\_capacity](#input\_redis\_capacity) | Azure Redis Cache capacity (size). For family C: 0–6 (250 MB → 53 GB). For family P: 1–5 (6 GB → 120 GB). The default 1 = 1 GB on the Standard SKU — sized for queue-mode metadata, not n8n binary data (which goes to Azure Files). | `number` | `1` | no |
| <a name="input_redis_family"></a> [redis\_family](#input\_redis\_family) | Azure Redis Cache family. `C` = Basic/Standard tier (default). `P` = Premium tier. Must be consistent with `redis_sku_name`: Standard ⇒ C, Premium ⇒ P. | `string` | `"C"` | no |
| <a name="input_redis_sku_name"></a> [redis\_sku\_name](#input\_redis\_sku\_name) | Azure Redis Cache SKU. `Standard` is two-node replicated (suitable for production). `Premium` adds VNet injection (the module uses a private endpoint instead), data persistence, clustering, and zone redundancy. Basic is excluded — the module always uses a private endpoint, which Basic does not support. | `string` | `"Standard"` | no |
| <a name="input_redis_subnet_id"></a> [redis\_subnet\_id](#input\_redis\_subnet\_id) | Resource ID of the subnet the Redis Cache private endpoint attaches to. Must have `private_endpoint_network_policies` disabled (Azure refuses to create a private endpoint when network policies are enforced on the subnet). No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>. | `string` | n/a | yes |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | Name of an existing Azure resource group all IaaS resources this submodule creates land in. The submodule does NOT create the resource group — the caller provisions it (or supplies one) so the lifecycle is decoupled from any single Phase 5 submodule. | `string` | n/a | yes |
| <a name="input_storage_account_replication_type"></a> [storage\_account\_replication\_type](#input\_storage\_account\_replication\_type) | Azure storage account replication type (`LRS` = locally-redundant, `ZRS` = zone-redundant, `GRS` = geo-redundant, `RAGRS` = read-access geo-redundant, `GZRS` = geo-zone-redundant, `RAGZRS` = read-access geo-zone-redundant). Default `LRS` matches the legacy umbrella module's hardcoded value — backward-compatible for callers migrating from v1.x. Production deployments seeking cross-region disaster recovery should set `GZRS` or `RAGZRS`; the cost premium is ~2× LRS but the share survives a single-region outage. | `string` | `"LRS"` | no |
| <a name="input_storage_share_quota_gb"></a> [storage\_share\_quota\_gb](#input\_storage\_share\_quota\_gb) | Quota for the Azure Files share that backs n8n binary data, in GB. Azure Files Standard tier supports 1–5120 GB per share; raise this for production workloads with large attachments. The default 100 GB is sized for typical workflow attachments without bloating the storage-account bill. | `number` | `100` | no |
| <a name="input_vnet_id"></a> [vnet\_id](#input\_vnet\_id) | Resource ID of the VNet n8n will deploy into. The module creates `privatelink.postgres.database.azure.com` and `privatelink.redis.cache.windows.net` private DNS zones and links them to this VNet so that the PostgreSQL Flexible Server and the Redis private endpoint resolve to private IPs. Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_id"></a> [aks\_cluster\_id](#output\_aks\_cluster\_id) | Resource ID of the AKS cluster. Consumed by example wiring that scopes role assignments to the cluster (e.g. AGIC Contributor). |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster. Used by the umbrella example (US-025) when configuring the kubernetes / helm providers (e.g. for `data.azurerm_kubernetes_cluster.n8n` lookups in callers that prefer data-source-based kubeconfig refresh over the `kube_config` output). |
| <a name="output_aks_kube_config"></a> [aks\_kube\_config](#output\_aks\_kube\_config) | Local-account kubeconfig block for the AKS cluster. The cluster has no AAD-RBAC integration so this IS the local-account admin credential — equivalent in trust shape to `kube_admin_config` on AAD-enabled clusters. Consumed by `modules/workload/` (and the umbrella example's providers.tf) to configure certificate-based kubernetes / helm provider auth without a kubelogin / exec dependency. |
| <a name="output_aks_oidc_issuer_url"></a> [aks\_oidc\_issuer\_url](#output\_aks\_oidc\_issuer\_url) | OIDC issuer URL for the AKS cluster. Consumed by `modules/workload/` (US-023) when it creates the federated-identity-credential binding the n8n Kubernetes service account to `n8n_workload_uami_client_id` so n8n pods can authenticate to Azure services without static credentials. |
| <a name="output_app_gateway_id"></a> [app\_gateway\_id](#output\_app\_gateway\_id) | Resource ID of the Application Gateway. Consumed by the umbrella example (US-025) for diagnostics and by `modules/workload/` (US-023) when the chart-side n8n Ingress sets the `appgw-ssl-certificate` annotation against this gateway. |
| <a name="output_appgw_fqdn"></a> [appgw\_fqdn](#output\_appgw\_fqdn) | Azure-assigned cloudapp.azure.com hostname of the Application Gateway public IP (e.g. `<friendly_name_prefix>-n8n.<region>.cloudapp.azure.com`). Always-on Azure-managed alternative to `appgw_public_ip_address` for callers that want to CNAME `var.n8n_domain` at a hostname rather than an IP. Resolves to the same address as `appgw_public_ip_address`. |
| <a name="output_appgw_public_ip_address"></a> [appgw\_public\_ip\_address](#output\_appgw\_public\_ip\_address) | Static public IPv4 address of the Application Gateway. Callers wire DNS — manual A-record or one of the Phase-2 automated public/private DNS paths in the umbrella example — to point `var.n8n_domain` at this address. |
| <a name="output_key_vault_id"></a> [key\_vault\_id](#output\_key\_vault\_id) | Resource ID of the Key Vault holding the App Gateway TLS cert (mirrors `var.app_gateway_keyvault_id`). Null when the caller did NOT supply a vault — in which case the caller is responsible for granting the `appgw_tls_cert` UAMI access on the cert's vault out-of-band. Consumed by the umbrella example (US-025) for diagnostics and by `modules/workload/` (US-023) when the chart-side AGIC annotation references the cert. |
| <a name="output_key_vault_uri"></a> [key\_vault\_uri](#output\_key\_vault\_uri) | Vault URI of the Key Vault holding the App Gateway TLS cert (e.g. `https://<vault>.vault.azure.net/`). Resolved via `data.azurerm_key_vault.byo` when `var.app_gateway_keyvault_role_assignment_enabled = true`; null otherwise. The legacy module-owned `azurerm_key_vault.n8n` was removed in registry-hardening US-012 — this submodule never owns a vault, only optionally references one supplied by the caller. |
| <a name="output_n8n_workload_uami_client_id"></a> [n8n\_workload\_uami\_client\_id](#output\_n8n\_workload\_uami\_client\_id) | Client ID of the n8n workload user-assigned identity. Consumed by `modules/workload/` (US-023) to (a) bind a Kubernetes-side federated identity credential to the AKS OIDC issuer + n8n service account, and (b) annotate the n8n service account with `azure.workload.identity/client-id`. Marked sensitive because the identity's client\_id is an authentication-relevant value. |
| <a name="output_n8n_workload_uami_principal_id"></a> [n8n\_workload\_uami\_principal\_id](#output\_n8n\_workload\_uami\_principal\_id) | Principal (AAD object) ID of the n8n workload user-assigned identity. Distinct from `client_id`: the principal\_id is the AAD-side object that Azure RBAC role assignments target, while client\_id is the OIDC `sub` claim consumed by federated-identity-credential subject mappings. Consumed by `modules/workload/` (US-023) and the umbrella example (US-025) when scoping role assignments to the n8n\_workload identity (e.g. `Storage Blob Data Reader` / `Key Vault Secrets User` extensions on the caller side). Marked sensitive per the same conservative shape as `client_id`. |
| <a name="output_postgres_admin_password"></a> [postgres\_admin\_password](#output\_postgres\_admin\_password) | PostgreSQL administrator password generated by `random_password.postgres_admin`. Consumed by `modules/workload/` (US-023) when it builds the n8n database-credentials Secret. Rotating the password is a destructive operation under the current shape — the chart and helm release would have to be reconciled in lockstep; document the rotation recipe in a follow-up runbook story. |
| <a name="output_postgres_admin_username"></a> [postgres\_admin\_username](#output\_postgres\_admin\_username) | PostgreSQL administrator login name (mirrors `var.pg_admin_username`). Consumed by `modules/workload/` (US-023) when it builds the n8n database-credentials Secret. Marked sensitive because it is part of the database credential pair. |
| <a name="output_postgres_database_name"></a> [postgres\_database\_name](#output\_postgres\_database\_name) | Name of the PostgreSQL database `azurerm_postgresql_flexible_server_database.n8n` provisions. Always `n8n` today (matches the legacy umbrella module's hardcoded database name). Consumed by `modules/workload/` (US-023) when it builds the n8n database connection string. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Fully qualified domain name of the PostgreSQL Flexible Server. Resolves to the server's private IP from inside `var.vnet_id` via the `privatelink.postgres.database.azure.com` private DNS zone created by this submodule. Consumed by `modules/workload/` (US-023) when it builds the n8n database connection string. |
| <a name="output_redis_hostname"></a> [redis\_hostname](#output\_redis\_hostname) | Hostname of the Azure Cache for Redis instance. Resolves to the cache's private IP from inside `var.vnet_id` via the `privatelink.redis.cache.windows.net` private DNS zone created by this submodule. Consumed by `modules/workload/` (US-023) when it builds the n8n queue-backend connection string and the KEDA TriggerAuthentication Secret. |
| <a name="output_redis_primary_access_key"></a> [redis\_primary\_access\_key](#output\_redis\_primary\_access\_key) | Primary access key for the Azure Cache for Redis instance (the bearer credential n8n + KEDA use to authenticate). Consumed by `modules/workload/` (US-023) when it builds the n8n queue-backend Secret and the KEDA TriggerAuthentication Secret. Marked sensitive. |
| <a name="output_redis_ssl_port"></a> [redis\_ssl\_port](#output\_redis\_ssl\_port) | TLS-only port the Azure Cache for Redis listens on (always 6380 — `non_ssl_port_enabled = false` is hardcoded). Consumed by `modules/workload/` (US-023) when it builds the n8n queue-backend connection string. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Name of the Azure storage account that backs the n8n Azure Files share. Consumed by `modules/workload/` (US-023) when it builds the chart-side `azurefiles-credentials` Kubernetes Secret + the static `PersistentVolume` referenced by every n8n pod's binary-data mount. Mirrors `local.storage_account_name`. |
| <a name="output_storage_account_primary_access_key"></a> [storage\_account\_primary\_access\_key](#output\_storage\_account\_primary\_access\_key) | Primary access key for the storage account that backs the n8n Azure Files share. Consumed by `modules/workload/` (US-023) when it builds the chart-side `azurefiles-credentials` Kubernetes Secret. The workload tier may instead resolve the key at runtime via the `n8n_workload` UAMI's `Storage Account Key Operator Service Role` role assignment (also created by this submodule, see `storage.tf`); the static-key path stays available for callers that prefer the legacy v1.x wiring. Marked sensitive. |
| <a name="output_storage_share_name"></a> [storage\_share\_name](#output\_storage\_share\_name) | Name of the Azure Files share that backs n8n binary data. Always `n8n-binary-data` today (the resource name is fixed in `storage.tf` because the chart-side wiring in `modules/workload/` references it directly). Consumed by `modules/workload/` (US-023) when it builds the chart-side `PersistentVolume` mount. |
<!-- END_TF_DOCS -->

