# Customer-managed Redis example

Deploys n8n against an external Redis endpoint and a caller-managed Kubernetes Secret for its password, demonstrating the `customer-managed-infrastructure` capability's Redis ownership boundary in isolation.

## How this differs from every other example

`azurerm_managed_redis.existing` in `main.tf` stands in for a Redis instance managed outside this module — for example an Azure Managed Redis instance in another subscription, or any other Redis-compatible endpoint. The `module "n8n"` call sets `create_redis = false` and supplies `redis_external_host`, `redis_external_port`, and `redis_external_tls_enabled` to describe that endpoint.

The password never reaches Terraform's module inputs as a literal: `kubernetes_secret.redis_password` creates a Kubernetes Secret directly (not through the module), and `redis_password_secret_ref` on the module call names that Secret and key. The module renders only the name and key into the n8n chart's Redis configuration and the KEDA `TriggerAuthentication` — it never reads the Secret's value.

AKS, PostgreSQL, private Azure Blob storage, and ingress remain module-managed here to keep this example scoped to the Redis ownership boundary alone. See `examples/customer-managed-cluster`, `examples/customer-managed-storage`, and `examples/customer-managed-everything` for the other boundaries.

## Ordering

`kubernetes_secret.redis_password` uses `module.n8n.n8n_namespace`, so it waits
for the module-managed namespace. The module call then uses the Secret's name
in `redis_password_secret_ref`, so the n8n Helm release waits for the Secret.
This creates the namespace, Secret, and workload in the required order during
one `terraform apply`.

## Apply

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace the placeholders.
2. Run `terraform init` and `terraform apply`.
3. Point your own DNS at `appgw_public_ip` once you are ready to move off the self-signed certificate.

The root default writes binary data to private Azure Blob and requires the separate `feat:binaryDataAz` n8n Enterprise entitlement. Select `database` instead if that entitlement is unavailable; PostgreSQL is the durable queue-mode fallback. 0.1.0 does not support n8n's inline-memory `default` mode or a shared-filesystem mode.

## Production considerations

| Module input | Default | Purpose |
| --- | --- | --- |
| `pg_backup_retention_days` | `7` | Days to retain automated PostgreSQL Flexible Server backups. Azure enforces 7-35; raise it for a longer recovery window. |
| `blob_delete_retention_days` | `null` (soft delete disabled) | Days to retain a deleted blob or container before it is purged for good. Azure Blob has no `force_destroy`-style guard, so leaving this `null` means a delete is unrecoverable; set 1-365 to add a recovery window. |

See [`docs/build-time-decisions.md`](../../docs/build-time-decisions.md) for settings above (and elsewhere in the root module) that are fixed at the first `terraform apply`.

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |
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
| [azurerm_key_vault.tls](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_managed_redis.existing](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/managed_redis) | resource |
| [azurerm_private_dns_zone.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_endpoint.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.key_vault_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.terraform_blob_data_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.private_endpoints](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_virtual_network.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [kubernetes_secret.redis_password](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [random_string.key_vault_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [time_sleep.key_vault_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.storage_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_api_authorized_ip_ranges"></a> [aks\_api\_authorized\_ip\_ranges](#input\_aks\_api\_authorized\_ip\_ranges) | Operator and CI IPv4 CIDRs allowed to reach the public AKS API. Empty leaves it unrestricted and is not recommended for production. | `list(string)` | `[]` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Optional soft-delete retention window, in days, for the module-managed Blob storage account, passed through to the root module. Null (the default) leaves soft delete disabled. | `number` | `null` | no |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags applied to example and module resources. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions. | `string` | `"n8ncmr"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there. | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n. This example issues its own lab-grade self-signed certificate for it (main.tf); replace that with a real certificate before production use. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum main replicas passed through to the root module's n8n\_main\_hpa\_min\_replicas, the sole topology selector. The default of 2 keeps this example on multi-main. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); other selected features, such as Azure Blob binary/execution-data entitlements, still require their own license grants and are not affected by this setting. | `number` | `2` | no |
| <a name="input_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#input\_pg\_backup\_retention\_days) | Number of days to retain automated PostgreSQL Flexible Server backups, passed through to the root module. Azure enforces a range of 7–35 days for Flexible Server (unlike RDS, Azure does not allow disabling backups). | `number` | `7` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Public IPv4 address of the module-managed Application Gateway. |
| <a name="output_azure_blob_container_name"></a> [azure\_blob\_container\_name](#output\_azure\_blob\_container\_name) | Name of the private Azure Blob container used for n8n binary and execution data. |
| <a name="output_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#output\_blob\_delete\_retention\_days) | Effective Blob soft-delete retention window, in days, passed to the root module's blob\_delete\_retention\_days. Null leaves soft delete disabled. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that writes the AKS context into the local kubeconfig. |
| <a name="output_main_hpa_min_replicas"></a> [main\_hpa\_min\_replicas](#output\_main\_hpa\_min\_replicas) | Effective main-topology floor passed to the root module's n8n\_main\_hpa\_min\_replicas. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | Generated n8n encryption key. Back it up to a password manager immediately after the first apply. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace containing n8n. |
| <a name="output_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#output\_pg\_backup\_retention\_days) | Effective PostgreSQL backup retention window, in days, passed to the root module's pg\_backup\_retention\_days. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Private FQDN n8n connects to for PostgreSQL. |
| <a name="output_postgres_password"></a> [postgres\_password](#output\_postgres\_password) | Generated PostgreSQL administrator password. Back it up in a secret manager. |
| <a name="output_redis_hostname"></a> [redis\_hostname](#output\_redis\_hostname) | Hostname of the caller-owned Redis stand-in n8n and KEDA connect to. |
| <a name="output_redis_password_secret_name"></a> [redis\_password\_secret\_name](#output\_redis\_password\_secret\_name) | Name of the caller-managed Kubernetes Secret holding the Redis password, referenced by redis\_password\_secret\_ref on the module call. The module never reads this Secret's value. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Name of the private StorageV2 account holding the module-managed Azure Blob container. |
<!-- END_TF_DOCS -->
