# Large example

A high-volume Azure reference topology with larger network ranges, zone-redundant PostgreSQL, highly available Azure Managed Redis, Azure execution-data offload, and a two-replica PgBouncer layer.

## Architecture and sizing

| Concern | Configuration |
|---|---|
| AKS | Two pools, `Standard_D16s_v5`, 5 to 20 nodes per pool, `/18` AKS subnet, Standard SKU tier |
| n8n main | 6 to 60 replicas |
| n8n webhook | 20 to 80 replicas, 500m CPU and 1 Gi memory requests |
| n8n workers | 20 to 160 replicas, concurrency 40 |
| PostgreSQL | `GP_Standard_D8s_v3`, 512 GB, zones 1 and 2, 35-day geo-redundant backups, storage autogrow enabled |
| PgBouncer | 2 replicas, required node anti-affinity, transaction pooling |
| Redis | `MemoryOptimized_M20`, high availability enabled |
| Blob | Private endpoint, ZRS, binary and execution-data modes |
| Ingress | WAF_v2 Prevention mode, autoscaling from 2 to 30 instances |

Storage autogrow only grows `storage_mb`, it never shrinks it. After Azure grows the live server past 512 GB, raise `storage_mb` on `azurerm_postgresql_flexible_server.n8n` to at least the new live size before the next apply, or the plan will try to shrink storage back down and Azure will reject it (or force a replacement).

The maximum n8n CPU requests fit the module's two-pool AKS model. PgBouncer bounds PostgreSQL server connections when all pod families scale out. This configuration is not a throughput guarantee. Load-test representative workflows and measure PostgreSQL I/O, connection waits, Redis queue latency, Blob latency, pod startup, and downstream service limits.

## PostgreSQL and PgBouncer

The example owns PostgreSQL rather than asking the root module to create it. This allows `module.n8n` to use its external PostgreSQL contract and connect through `pgbouncer.pgbouncer.svc.cluster.local`. PgBouncer connects privately to standard Azure PostgreSQL Flexible Server with TLS. The n8n-to-PgBouncer leg is unencrypted ClusterIP traffic inside AKS.

## Azure storage entitlements

This tier sets binary and execution-data writes to Azure Blob. These features require separate n8n Enterprise entitlements: `feat:binaryDataAz` and `feat:executionDataAz`. The module does not backfill data when modes change. The shared container has no lifecycle expiry because n8n owns execution-data pruning.

## Production considerations

| Module input | Default | Purpose |
| --- | --- | --- |
| `blob_delete_retention_days` | `null` | Soft-delete retention window, in days, for the module-managed Blob storage account's `delete_retention_policy` and `container_delete_retention_policy`. `null` leaves soft delete disabled, so a deleted blob or container is immediately unrecoverable. |
| `aks_sku_tier` | `"Standard"` (fixed) | AKS SKU tier. Fixed in this tier's `local.tier` in `main.tf`, not an example variable, so it cannot be set from `terraform.tfvars`. Overrides the module's `"Free"` default so the cluster's API server has a financially backed SLA. |

`pg_backup_retention_days` does not apply to this example: it sets `create_database = false` and owns PostgreSQL itself (see [PostgreSQL and PgBouncer](#postgresql-and-pgbouncer)), so PostgreSQL backup retention is a property of the Flexible Server resource this example manages directly, not of the root module.

## Apply

Copy `terraform.tfvars.example` to `terraform.tfvars`, replace the placeholders, verify regional SKU and zone availability, then run `terraform init` and `terraform apply`. Delegate `terraform output -json public_dns_zone_name_servers` at your registrar.

The included certificate is self-signed. Replace it with a publicly trusted certificate before production.

## Cost and availability caveats

This tier has a high warm-node floor, large PostgreSQL compute, geo-redundant backups, Redis HA, WAF autoscaling, and replicated storage. Those services dominate cost. The AKS Standard tier adds a smaller per-cluster hourly charge for the financially backed API server SLA. On an existing deployment of this example that predates `aks_sku_tier`, the next apply upgrades the cluster from Free to Standard in place. The AKS API server can be unavailable for up to about a minute during that update, so apply it without other changes where possible; see [Changing `aks_sku_tier` briefly interrupts the AKS API server](../../docs/troubleshooting.md#changing-aks_sku_tier-briefly-interrupts-the-aks-api-server). GZRS is not available in every region. Zone identifiers and SKU availability also vary. Confirm current Azure availability and pricing before apply. Add organization-specific deletion protection, restore drills, observability, and policy enforcement.

See [the tier comparison](../README.md).

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
| [azurerm_dns_zone.public](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dns_zone) | resource |
| [azurerm_key_vault.tls](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_postgresql_flexible_server.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server) | resource |
| [azurerm_postgresql_flexible_server_configuration.uuid_ossp](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_configuration) | resource |
| [azurerm_postgresql_flexible_server_database.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_database) | resource |
| [azurerm_private_dns_zone.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
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
| [kubernetes_deployment.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment) | resource |
| [kubernetes_namespace.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_pod_disruption_budget_v1.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/pod_disruption_budget_v1) | resource |
| [kubernetes_secret.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_service.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service) | resource |
| [random_password.postgres](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_string.key_vault_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [time_sleep.key_vault_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.storage_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_api_authorized_ip_ranges"></a> [aks\_api\_authorized\_ip\_ranges](#input\_aks\_api\_authorized\_ip\_ranges) | Operator and CI IPv4 CIDRs allowed to reach the public AKS API. Empty leaves it unrestricted and is not recommended for production. | `list(string)` | `[]` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Optional soft-delete retention window, in days, passed through to the root module's blob\_delete\_retention\_days. Null (the default) leaves soft delete disabled on this tier's module-managed Blob storage account. | `number` | `null` | no |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags applied to example and module resources. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions. | `string` | `"n8nlarge"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there. | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Canonical fully-qualified domain for n8n. It must be the Azure DNS zone apex or a subdomain of public\_dns\_zone\_name. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key with the Azure binary-data and execution-data entitlements used by this tier. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum main replicas passed through to the root module's n8n\_main\_hpa\_min\_replicas, the sole topology selector. The default of 6 keeps this example on multi-main. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); other selected features, such as Azure Blob binary/execution-data entitlements, still require their own license grants and are not affected by this setting. | `number` | `6` | no |
| <a name="input_public_dns_zone_name"></a> [public\_dns\_zone\_name](#input\_public\_dns\_zone\_name) | Public Azure DNS zone created by this example. Delegate its output name servers at the domain registrar. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster. |
| <a name="output_aks_resource_group"></a> [aks\_resource\_group](#output\_aks\_resource\_group) | Resource group containing AKS and the n8n managed services. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Public IPv4 address of the module-managed Application Gateway. |
| <a name="output_azure_blob_container_name"></a> [azure\_blob\_container\_name](#output\_azure\_blob\_container\_name) | Name of the private Azure Blob container used for n8n binary and execution data. Consumed by tests/scripts/smoke-test.sh. |
| <a name="output_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#output\_blob\_delete\_retention\_days) | Soft-delete retention window, in days, passed through to the root module's blob\_delete\_retention\_days input. Null (the default) leaves Blob soft delete disabled. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that writes the AKS context into the local kubeconfig. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | Generated n8n encryption key. Back it up to a password manager immediately after the first apply. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings. |
| <a name="output_n8n_webhook_path_prefixes"></a> [n8n\_webhook\_path\_prefixes](#output\_n8n\_webhook\_path\_prefixes) | Complete path-prefix set the Ingress routes to the webhook-processor service. Consumed by tests/scripts/smoke-test.sh to verify webhook route ownership. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace containing n8n. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Private FQDN of the example-owned zone-redundant PostgreSQL server behind PgBouncer. |
| <a name="output_postgres_password"></a> [postgres\_password](#output\_postgres\_password) | Generated PostgreSQL administrator password. Back it up in a secret manager. |
| <a name="output_public_dns_zone_name_servers"></a> [public\_dns\_zone\_name\_servers](#output\_public\_dns\_zone\_name\_servers) | Azure DNS name servers to delegate at the registrar. |
| <a name="output_redis_hostname"></a> [redis\_hostname](#output\_redis\_hostname) | Private hostname n8n and KEDA connect to for Redis. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Name of the private StorageV2 account holding the Azure Blob container. Consumed by tests/scripts/smoke-test.sh to verify Azure Blob access. |
| <a name="output_tier_configuration"></a> [tier\_configuration](#output\_tier\_configuration) | Plan-known sizing and availability decisions used by this example and passed into the root module. |
| <a name="output_tls_certificate_secret_id"></a> [tls\_certificate\_secret\_id](#output\_tls\_certificate\_secret\_id) | Versioned Key Vault Secret URI consumed by Application Gateway. |
<!-- END_TF_DOCS -->
