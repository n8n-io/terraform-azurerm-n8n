# Customer-managed cluster example

Deploys n8n onto an existing AKS cluster the module does not create or manage, demonstrating the `customer-managed-infrastructure` capability's AKS ownership boundary in isolation.

## How this differs from every other example

`azurerm_kubernetes_cluster.existing` in `main.tf` stands in for a cluster a platform team already runs — OIDC issuer and workload identity enabled, sized and autoscaled the same way the root module's own cluster would be. The `module "n8n"` call sets `create_aks = false` and points at that cluster by `existing_aks_cluster_name` / `existing_aks_resource_group_name`, with `existing_aks_cluster_prerequisites_confirmed = true` attesting that the cluster meets the module's existing-AKS contract (see `docs/customer-managed-infrastructure.md` in the module root for the full attestation).

`create_aks = false` requires `create_ingress = false` — the module cannot manage the AGIC addon on a cluster it does not own — so `ingress.tf` installs a standalone `ingress-azure` Helm release and its own Application Gateway, the same pattern `examples/split-ingress` uses, scaled down to one gateway that routes every path (editor UI, REST API, and every webhook prefix) to n8n's two chart-rendered Services.

Provider wiring in `providers.tf` targets `azurerm_kubernetes_cluster.existing` directly, not `module.n8n.aks_kube_config` — see `docs/customer-managed-infrastructure.md` for why.

PostgreSQL, Azure Managed Redis, and private Azure Blob storage remain module-managed here to keep this example scoped to the AKS ownership boundary alone. See `examples/customer-managed-redis`, `examples/customer-managed-storage`, and `examples/customer-managed-everything` for the other boundaries.

## Apply

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace the placeholders.
2. Run `terraform init` and `terraform apply`. The caller-owned AKS cluster, its node pool, and AGIC's role-assignment/federation RBAC propagation all need to settle before the first Ingress admission succeeds; this can take several minutes after `apply` reports success.
3. Point your own DNS at `appgw_public_ip` once you are ready to move off the self-signed certificate.

The root default writes binary data to private Azure Blob and requires the separate `feat:binaryDataAz` n8n Enterprise entitlement. Select `database` instead if that entitlement is unavailable; PostgreSQL is the durable queue-mode fallback. 0.1.0 does not support n8n's inline-memory `default` mode or a shared-filesystem mode.

## Production considerations

| Module input | Default | Purpose |
| ------------- | ------- | ------- |
| `pg_backup_retention_days` | `7` | Days to retain automated PostgreSQL Flexible Server backups. Azure enforces 7-35 days for Flexible Server. |
| `blob_delete_retention_days` | `null` | Optional soft-delete retention window, in days, for the module-managed Blob storage account. `null` leaves soft delete disabled. |

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.21.0, < 5.0.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4.21.0, < 5.0.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 2.12 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 3.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.14 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_tls_self_signed"></a> [tls\_self\_signed](#module\_tls\_self\_signed) | ../../modules/tls-self-signed | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_application_gateway.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_federated_identity_credential.agic](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_key_vault.tls](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_kubernetes_cluster.existing](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster) | resource |
| [azurerm_network_security_group.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_public_ip.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.agic_appgw_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_tls_identity_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.key_vault_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.n8n_tls_cert_kv_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.terraform_blob_data_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.private_endpoints](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_network_security_group_association.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [azurerm_user_assigned_identity.agic](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.n8n_tls_cert](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_virtual_network.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [helm_release.agic](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_ingress_v1.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace.agic](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [random_string.key_vault_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [time_sleep.key_vault_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.n8n_tls_cert_kv_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.storage_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_api_authorized_ip_ranges"></a> [aks\_api\_authorized\_ip\_ranges](#input\_aks\_api\_authorized\_ip\_ranges) | Operator and CI IPv4 CIDRs allowed to reach the public AKS API. Empty leaves it unrestricted and is not recommended for production. | `list(string)` | `[]` | no |
| <a name="input_aks_node_vm_size"></a> [aks\_node\_vm\_size](#input\_aks\_node\_vm\_size) | Azure VM SKU for the caller-owned AKS node pool. Confirm regional and zonal availability for the selected subscription before applying. | `string` | `"Standard_D2s_v5"` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Optional soft-delete retention window, in days, for the module-managed Blob storage account. Null (the default) leaves soft delete disabled. Passed through to the root module's blob\_delete\_retention\_days. | `number` | `null` | no |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags applied to example and module resources. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions. | `string` | `"n8ncmc"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there. | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n. This example issues its own lab-grade self-signed certificate for it (main.tf); replace that with a real certificate before production use. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum main replicas passed through to the root module's n8n\_main\_hpa\_min\_replicas, the sole topology selector. The default of 2 keeps this example on multi-main. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); other selected features, such as Azure Blob binary/execution-data entitlements, still require their own license grants and are not affected by this setting. | `number` | `2` | no |
| <a name="input_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#input\_pg\_backup\_retention\_days) | Number of days to retain automated PostgreSQL Flexible Server backups. Azure enforces a range of 7–35 days for Flexible Server. Passed through to the root module's pg\_backup\_retention\_days. | `number` | `7` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the caller-owned AKS stand-in cluster the module targets via create\_aks = false. |
| <a name="output_aks_resource_group"></a> [aks\_resource\_group](#output\_aks\_resource\_group) | Resource group containing the caller-owned AKS cluster and the n8n managed services. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Public IPv4 address of the caller-owned Application Gateway (ingress.tf). |
| <a name="output_azure_blob_container_name"></a> [azure\_blob\_container\_name](#output\_azure\_blob\_container\_name) | Name of the private Azure Blob container used for n8n binary and execution data. |
| <a name="output_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#output\_blob\_delete\_retention\_days) | Effective Blob soft-delete retention window, in days (or null), passed through to the root module's blob\_delete\_retention\_days. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that writes the AKS context into the local kubeconfig. |
| <a name="output_main_hpa_min_replicas"></a> [main\_hpa\_min\_replicas](#output\_main\_hpa\_min\_replicas) | Effective main-topology floor passed to the root module's n8n\_main\_hpa\_min\_replicas. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | Generated n8n encryption key. Back it up to a password manager immediately after the first apply. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace containing n8n. |
| <a name="output_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#output\_pg\_backup\_retention\_days) | Effective PostgreSQL backup retention window, in days, passed through to the root module's pg\_backup\_retention\_days. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Private FQDN n8n connects to for PostgreSQL. |
| <a name="output_postgres_password"></a> [postgres\_password](#output\_postgres\_password) | Generated PostgreSQL administrator password. Back it up in a secret manager. |
| <a name="output_redis_hostname"></a> [redis\_hostname](#output\_redis\_hostname) | Private hostname n8n and KEDA connect to for Redis. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Name of the private StorageV2 account holding the module-managed Azure Blob container. |
<!-- END_TF_DOCS -->
