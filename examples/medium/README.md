# Medium example

A sustained-production reference tier with more warm AKS and n8n capacity than `small`, larger PostgreSQL and Redis SKUs, ZRS Blob storage, and autoscaling Application Gateway capacity.

## Sizing

| Concern | Configuration |
|---|---|
| AKS | Two pools, `Standard_D8s_v5`, 3 to 10 nodes per pool, Standard SKU tier |
| n8n main | 3 to 16 replicas, 1500m CPU and 3 Gi memory requests |
| n8n webhook | 4 to 24 replicas, 500m CPU and 1 Gi memory requests |
| n8n workers | 4 to 30 replicas, concurrency 20, 750m CPU and 2 Gi memory requests |
| PostgreSQL | `GP_Standard_D4s_v3`, 128 GB, 14-day backups |
| Redis | `Balanced_B5`, single replica |
| Storage | Private Azure Blob with ZRS |
| Ingress | WAF_v2 autoscaling from 2 to 10 instances |

At all workload ceilings, the configured CPU requests remain below the module's modeled supply from two 10-node D8s_v5 pools. This is not a throughput guarantee. Benchmark representative workflows and inspect memory, database connections, queue latency, and external API latency.

## Apply

Copy `terraform.tfvars.example` to `terraform.tfvars`, replace the placeholders, then run `terraform init` and `terraform apply`. Delegate `terraform output -json public_dns_zone_name_servers` at your registrar.

The included Key Vault certificate is self-signed. Replace it with the Let's Encrypt helper or a certificate from your public key infrastructure before production.

The root default writes binary data to private Azure Blob and requires the separate `feat:binaryDataAz` n8n Enterprise entitlement. Select `database` instead if that entitlement is unavailable; PostgreSQL is the durable queue-mode fallback. 0.1.0 does not support n8n's inline-memory `default` mode or a shared-filesystem mode.

## Cost and operational caveats

The warm node floor, the AKS Standard tier, larger PostgreSQL and Redis SKUs, ZRS storage, and Application Gateway autoscaling make this materially more expensive than `small`. The Standard tier adds a per-cluster hourly charge for the financially backed API server SLA. On an existing deployment of this example that predates `aks_sku_tier`, the next apply upgrades the cluster from Free to Standard in place. Zone-redundant storage does not replace backups. PostgreSQL HA remains disabled in this tier. Use `large` when database or Redis availability, connection pressure, or substantially higher pod ceilings require those controls.

See [the tier comparison](../README.md).

## Production considerations

| Module input | Default | Purpose |
| --- | --- | --- |
| `pg_backup_retention_days` | `14` | Days Azure retains automated PostgreSQL Flexible Server backups. Azure enforces a 7-35 day range; this tier doubles the module's 7-day default for extra recovery headroom. |
| `aks_sku_tier` | `"Standard"` (fixed) | AKS SKU tier. Fixed in this tier's `local.tier` in `main.tf`, not an example variable, so it cannot be set from `terraform.tfvars`. Overrides the module's `"Free"` default so the cluster's API server has a financially backed SLA. |
| `blob_delete_retention_days` | `null` | Optional Blob soft-delete retention window, in days (1-365). `null` leaves soft delete disabled, so a deleted blob or container is immediately unrecoverable. |

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
| [azurerm_dns_zone.public](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dns_zone) | resource |
| [azurerm_key_vault.tls](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
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
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions. | `string` | `"n8nmedium"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there. | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Canonical fully-qualified domain for n8n. It must be the Azure DNS zone apex or a subdomain of public\_dns\_zone\_name. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum main replicas passed through to the root module's n8n\_main\_hpa\_min\_replicas, the sole topology selector. The default of 3 keeps this example on multi-main. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); other selected features, such as Azure Blob binary/execution-data entitlements, still require their own license grants and are not affected by this setting. | `number` | `3` | no |
| <a name="input_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#input\_pg\_backup\_retention\_days) | Number of days to retain automated PostgreSQL Flexible Server backups, passed through to the root module. The medium tier defaults to 14. Azure enforces a range of 7-35 days for Flexible Server. | `number` | `14` | no |
| <a name="input_public_dns_zone_name"></a> [public\_dns\_zone\_name](#input\_public\_dns\_zone\_name) | Public Azure DNS zone created by this example. Delegate its output name servers at the domain registrar. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster. |
| <a name="output_aks_resource_group"></a> [aks\_resource\_group](#output\_aks\_resource\_group) | Resource group containing AKS and the n8n managed services. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Public IPv4 address of the module-managed Application Gateway. |
| <a name="output_azure_blob_container_name"></a> [azure\_blob\_container\_name](#output\_azure\_blob\_container\_name) | Name of the private Azure Blob container used for n8n binary and execution data. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#output\_blob\_delete\_retention\_days) | Value of var.blob\_delete\_retention\_days passed into the root module's blob\_delete\_retention\_days input. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that writes the AKS context into the local kubeconfig. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | Generated n8n encryption key. Back it up to a password manager immediately after the first apply. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings. |
| <a name="output_n8n_webhook_path_prefixes"></a> [n8n\_webhook\_path\_prefixes](#output\_n8n\_webhook\_path\_prefixes) | Complete path-prefix set the Ingress routes to the webhook-processor service. Consumed by tests/scripts/smoke-test.sh to verify webhook route ownership. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace containing n8n. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Private FQDN n8n connects to for PostgreSQL. |
| <a name="output_postgres_password"></a> [postgres\_password](#output\_postgres\_password) | Generated PostgreSQL administrator password. Back it up in a secret manager. |
| <a name="output_public_dns_zone_name_servers"></a> [public\_dns\_zone\_name\_servers](#output\_public\_dns\_zone\_name\_servers) | Azure DNS name servers to delegate at the registrar. |
| <a name="output_redis_hostname"></a> [redis\_hostname](#output\_redis\_hostname) | Private hostname n8n and KEDA connect to for Redis. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Name of the private StorageV2 account holding the Azure Blob container. Consumed by tests/scripts/smoke-test.sh to verify Azure Blob access. |
| <a name="output_tier_configuration"></a> [tier\_configuration](#output\_tier\_configuration) | Plan-known sizing decisions passed into the root module by this example. |
| <a name="output_tls_certificate_secret_id"></a> [tls\_certificate\_secret\_id](#output\_tls\_certificate\_secret\_id) | Versioned Key Vault Secret URI consumed by Application Gateway. |
<!-- END_TF_DOCS -->
