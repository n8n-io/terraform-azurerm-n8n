# Build-time decisions

Some inputs and hardcoded values are hard or impossible to change after the
first apply. If you change one of them on an existing deployment, Terraform
either plans to replace the resource (downtime and possible data loss), or
Azure has no supported way to make the change through this module. This page
lists those inputs so you can decide them before the first apply.

Other inputs are often assumed to be fixed but are updated in place. Those
changes can still disrupt running workloads. They are listed in a second
table so you know what to expect.

Each row applies only when the module creates the resource in question: the
AKS rows need `create_aks = true`, the PostgreSQL rows `create_database =
true`, the Redis rows `create_redis = true`, and the Blob rows
`create_blob_storage = true`. For a layer you bring yourself, the same Azure
constraints exist, but they belong to whoever manages that resource.

The provider behavior on this page was checked against the
`hashicorp/azurerm` provider source at `v4.81.0`, the version in this
module's lock file. The module's constraint (`>= 4.39.0, < 5.0.0`) allows other 4.x
releases, which can behave differently. Always read `terraform plan` before
you apply a change to a live deployment. A replacement shows as `must be
replaced`.

## Protections

None of the module-managed stateful resources has a deletion-protection
input. `azurerm_postgresql_flexible_server` and `azurerm_storage_account`
expose no such attribute, and `lifecycle.prevent_destroy` cannot be set from
a variable. A planned replacement therefore goes ahead unless you add a
guard yourself:

- A caller-owned `CanNotDelete` management lock on the PostgreSQL server or
  the storage account, with `lifecycle.prevent_destroy` on the lock
  resource. The lock rejects the plan before anything changes only if it
  already exists in the same state and its `scope` references the module
  output (`module.n8n.postgres_server_id` or
  `module.n8n.storage_account_id`). A planned replacement makes that ID
  unknown, `scope` is `ForceNew`[^lock-scope], and `prevent_destroy` then
  rejects the replacement of the lock. A lock with a literal `scope`, or one
  outside this state, only makes Azure refuse the delete during apply,
  after other changes in the same apply may already have run. See
  [`docs/deletion-safety.md`](./deletion-safety.md#storage-autogrow-and-replacement).
- `pg_storage_drift_guard_enabled` stops a plan that would shrink
  `pg_storage_mb` below the live size. It is a best-effort early warning,
  not a deletion control (see the `pg_storage_mb` row).
- `blob_delete_retention_days` makes deleted blobs and containers
  recoverable for a bounded time. It does not protect the storage account
  itself.

Do not remove a lock to get past a failed plan until you have a tested
backup and a migration plan.

## Changes that force replacement or have no in-place path

| Module input (or hardcoded value) | Provider behavior | What happens on an existing deployment | Guidance |
| --- | --- | --- | --- |
| `friendly_name_prefix`, `location`, `resource_group_name` | `name`, `location`, and `resource_group_name` are `ForceNew` on the AKS cluster, the PostgreSQL server, the Managed Redis instance, and the storage account[^names][^commonschema] | `friendly_name_prefix` is part of every resource name (`locals.tf`). Changing any of the three plans replacement of the cluster, the database server, the Redis instance, and the storage account, with all data in them. | Treat all three as fixed for the life of the deployment. To move, build a new deployment and migrate the data to it. |
| Hardcoded `service_cidr = "172.16.0.0/16"` and `dns_service_ip = "172.16.0.10"` (`aks.tf`) | Both are `ForceNew`[^aks-network] | Not reachable today, because the module does not expose these values. A fork that changes them replaces the cluster. The network plugin (Azure CNI) and the absence of a network policy engine are hardcoded too. | Confirm `172.16.0.0/16` does not overlap any network the pods must reach before the first apply. For a different range, plugin, or policy engine, bring your own cluster with `create_aks = false` (see [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#aks-cluster-create_aks)). |
| `aks_subnet_id` (subnet size) | `vnet_subnet_id` is a rotation property on both node pools[^aks-default-rotation][^aks-pool-rotation] | The module does not size the subnet, but Azure lets you resize a subnet only when nothing is deployed in it[^vnet-faq]. Moving to a larger subnet means changing `aks_subnet_id`, which rotates both node pools onto the new subnet. The module does not test that path. | Size the subnet before the first apply. With Azure CNI, every node and every pod takes a VNet IP address. Both pools share this subnet, so plan for `2 x aks_node_count_max` nodes, each needing `max_pods + 1` addresses (the module does not set `max_pods`, so the AKS default for Azure CNI applies), plus the surge nodes from `aks_node_upgrade_max_surge` and the temporary rotation pools[^aks-ip-planning]. |
| `postgres_subnet_id` and the PostgreSQL networking model | `delegated_subnet_id` is `ForceNew`[^pg-subnet] | The module always attaches the server to a delegated subnet with a private DNS zone and no public access. It has no private-endpoint mode. Changing `postgres_subnet_id` replaces the server, and the new server starts empty. Microsoft documents a migration from VNet integration to private-endpoint networking[^pg-network-migration], but the module does not support the result. | Decide the subnet and connectivity before the first apply. To use a server with a different networking model, manage it yourself and set `create_database = false` with the `postgres_external_*` inputs. Read [Moving a layer to a caller-owned resource](#moving-a-layer-to-a-caller-owned-resource) first. |
| `pg_geo_redundant_backup_enabled` | `geo_redundant_backup_enabled` is `ForceNew`[^pg-geo] | Terraform deletes the server and creates a new, empty one. The module then creates an empty `n8n` database. Existing data is not carried over. | Decide before the first apply. To enable it later, take a logical backup (for example `pg_dump`), test it, and keep it outside the server. Then let Terraform replace the server and restore the backup into the new one. Do not rely on Azure-managed backups for this: point-in-time restore always creates a separate server[^pg-pitr], and recovery of a deleted server is limited to five days and is not guaranteed[^pg-deleted]. |
| `pg_admin_username`, `pg_version` (decrease) | The provider forces replacement when `administrator_login` changes on an existing server, or when `version` decreases[^pg-login-version] | Terraform replaces the server with an empty one. A `pg_version` increase is sent as an in-place major version upgrade[^pg-version-update], not a replacement. Azure stops the server during the upgrade, and a successful upgrade cannot be rolled back except by a point-in-time restore to a new server[^pg-major-upgrade]. | Pick the admin username before the first apply. Never lower `pg_version` on a deployment with data. Before raising it, read Azure's upgrade prerequisites (unsupported extensions, read replicas, free storage) and plan a maintenance window. |
| `pg_storage_mb` (decrease) | The provider forces replacement whenever `storage_mb` decreases[^pg-storage] | Increasing `pg_storage_mb` is an in-place resize. Decreasing it replaces the server with an empty one. With `pg_storage_auto_grow_enabled = true`, Azure grows storage outside Terraform, so a `pg_storage_mb` that was not raised to the live size also plans a replacement. | Raise `pg_storage_mb` to at least the live size before every apply after autogrow fires. Use `pg_storage_drift_guard_enabled` and a caller-owned lock as described in [Storage autogrow and replacement](./deletion-safety.md#storage-autogrow-and-replacement). |
| `redis_high_availability_enabled` | `high_availability_enabled` is `ForceNew`[^redis-ha] | Terraform replaces the Managed Redis instance. In-flight Bull jobs are dropped, and multi-main leader election fails until n8n and KEDA reconnect to the new instance. | Decide before the first apply. To change it later, follow the drain procedure in [`docs/redis.md`](./redis.md#changing-high-availability-or-the-clustering-policy). |
| Hardcoded `clustering_policy = "NoCluster"` (`redis.tf`) | `clustering_policy` is not `ForceNew`, but a change makes the provider delete and recreate the default database during the update[^redis-clustering] | Not reachable today, because the module does not expose this value. If it changed, the plan would show an in-place update, but the queue data would still be lost. | None. See [`docs/redis.md`](./redis.md#changing-high-availability-or-the-clustering-policy). |
| `storage_account_replication_type` | `account_replication_type` uses `ForceNewIfChange`[^storage-replication]. A change between `{LRS, GRS, RAGRS}` and `{ZRS, GZRS, RAGZRS}` forces replacement; a change within one group updates in place | A change across the two groups, for example from the default `LRS` to `ZRS`, makes Terraform delete the storage account and create a new, empty one. The binary and execution data in it is lost. This happens whatever conversions Azure itself supports in your region. A change within one group, for example `LRS` to `GRS`, is an in-place update. | Pick the final replication type before the first apply. To move across the groups later, provision a new storage account yourself, copy the container's contents, and move n8n to it with `create_blob_storage = false`. Read [Moving a layer to a caller-owned resource](#moving-a-layer-to-a-caller-owned-resource) first. |
| `azure_blob_container_name` | The container `name` is `ForceNew`[^storage-container] | Terraform deletes the container, with every object in it, and creates a new, empty container. | Treat the container name as fixed once n8n has written binary or execution data. |
| `n8n_encryption_key` (or the module-generated key when it is `null`), `n8n_encryption_key_secret_ref` | n8n encrypts stored credentials with this key | Not enforced by Azure. If the effective key changes, n8n cannot decrypt the credentials already stored in PostgreSQL. The module-generated key changes only if you set a different `n8n_encryption_key`, or if `random_password.n8n_encryption_key` is replaced or removed from state. Putting the original key back makes the credentials readable again, so they are lost only if the original key is lost. | Back up the key right after the first apply. For a module-generated or literal key, run `terraform output -raw n8n_encryption_key`. With `n8n_encryption_key_secret_ref`, that output is `null`, so back up the key from wherever the Secret's contents come from. See [`docs/post-deployment.md`](./post-deployment.md#capture-the-n8n-encryption-key). |
| `aks_kms_key_vault_key_id` (the KMS key version it names) | Not a provider constraint: AKS encrypts etcd Secrets with this key version once KMS is on | If the current or previous key version is deleted, disabled, or expires, or the key is deleted after KMS is turned off, or the cluster identity loses access to the vault, Microsoft warns that the API server can stop working, including after KMS is turned off. | Decide on the vault, key, and access model before turning KMS on. Keep the current and the previous key version enabled and unexpired, keep the key after KMS is turned off, and keep the vault grant in place. To turn KMS off, clear only `aks_kms_key_vault_key_id` and keep the KMS toggle on. See [Delivering secrets from Azure Key Vault](./customer-managed-infrastructure.md#delivering-secrets-from-azure-key-vault). |

## Changes that update in place, with caveats

| Module input | Provider behavior | What happens on an existing deployment | Guidance |
| --- | --- | --- | --- |
| `aks_availability_zones` | `zones` is a rotation property on both node pools[^aks-default-rotation][^aks-pool-rotation], not `ForceNew` | The cluster is not replaced. AzureRM rotates each pool through its `temporary_name_for_rotation` pool (`systemtemp`, `n8nusrtemp`) and recreates every node in the new zones. This is not a graceful cordon-and-drain, so pods on both pools restart. | Pick the final zone set before the first apply. If you must change it, treat it as a maintenance window, as described for [`aks_node_os_disk_size_gb`](./troubleshooting.md#changing-aks_node_os_disk_size_gb-on-an-existing-cluster-disrupts-workloads). To add capacity in other zones without rotating the module's pools, create an extra `azurerm_kubernetes_cluster_node_pool` in your own configuration against the `aks_cluster_id` output. The module does not manage that pool. |
| `aks_node_vm_size`, `aks_node_os_disk_size_gb` | `vm_size` and `os_disk_size_gb` are rotation properties on both node pools[^aks-default-rotation][^aks-pool-rotation] | Both pools rotate through their temporary pools, with the same disruption as a zone change. | See [Changing `aks_node_os_disk_size_gb` on an existing cluster disrupts workloads](./troubleshooting.md#changing-aks_node_os_disk_size_gb-on-an-existing-cluster-disrupts-workloads). |
| `aks_system_pool_critical_addons_only` | `only_critical_addons_enabled` is a rotation property on the default node pool[^aks-default-rotation] | The system pool rotates through `systemtemp`, and every n8n, KEDA, and Redis-exporter pod moves to the `n8nuser` pool. Setting it back to `false` is a second rotation. | See [Enabling `aks_system_pool_critical_addons_only` moves module-installed workloads to the user pool](./troubleshooting.md#enabling-aks_system_pool_critical_addons_only-moves-module-installed-workloads-to-the-user-pool). |
| `aks_sku_tier` | `sku_tier` is updated in place | The AKS API server can be unavailable for up to about a minute while the tier changes. Nodes and pods keep running. | Change it in its own apply. See [Changing `aks_sku_tier` briefly interrupts the AKS API server](./troubleshooting.md#changing-aks_sku_tier-briefly-interrupts-the-aks-api-server). |
| `aks_kms_role_assignment_enabled`, `aks_kms_cluster_identity_enabled` | The cluster `identity` block changes between `SystemAssigned` and the module-managed `UserAssigned` identity in place | The cluster is not replaced (confirmed live for `SystemAssigned` to `UserAssigned`). Setting both toggles back to `false` deletes the subnet grant and the module's Key Vault grant. Without a caller-owned private DNS zone it also switches the identity back to `SystemAssigned` and deletes the identity; with one, the identity and its DNS and VNet grants stay. | Leave the toggle on for as long as the cluster has ever used KMS. Turn KMS off by clearing `aks_kms_key_vault_key_id` only. |
| `pg_enable_high_availability`, `pg_primary_zone`, `pg_standby_zone` | HA can be turned on or off in place. `zone` and `high_availability[0].standby_availability_zone` are in `lifecycle.ignore_changes` (`database.tf`) | `pg_enable_high_availability` changes in place. On an existing server, Terraform ignores changes to the two zone inputs, because Azure allows a zone swap only as part of an HA failover. | Leave both zone inputs `null` to let Azure pick, unless you have a specific placement requirement. Treat a zone move as an out-of-band failover, not a Terraform change. |

## Moving a layer to a caller-owned resource

Several rows suggest moving a layer to a resource you manage yourself, with
`create_aks = false`, `create_database = false`, or `create_blob_storage =
false`. On an existing deployment, each switch sets the module-managed
resource's `count` to `0`, so Terraform deletes the module-managed cluster,
server, or storage account in the same apply that points n8n at the new one.

- For Blob storage, set all the `existing_blob_*` references, not only
  `azure_blob_endpoint`. The workload identity's role assignment is scoped
  to the container that `existing_blob_container_id` selects, so an
  endpoint override alone leaves n8n authorized against the old container.
- Copy the data first and check the copy. Keep the source until you have
  accepted the cutover.
- Save the plan (`terraform plan -out=...`) and review every destroy
  action before you apply it.

See [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md)
for the reference inputs each layer needs. That page also covers the
pre-release upgrade boundary, which deals with Terraform state changes (for
example the `modules/controllers` composition) separately from the Azure
constraints on this page.

[^names]: `azurerm_kubernetes_cluster`: [`kubernetes_cluster_resource.go#L227-L232`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/containers/kubernetes_cluster_resource.go#L227-L232). `azurerm_postgresql_flexible_server`: [`postgresql_flexible_server_resource.go#L66-L71`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/postgres/postgresql_flexible_server_resource.go#L66-L71). `azurerm_managed_redis`: [`managed_redis_resource.go#L96-L101`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/managedredis/managed_redis_resource.go#L96-L101). `azurerm_storage_account`: [`storage_account_resource.go#L96-L101`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/storage/storage_account_resource.go#L96-L101).
[^commonschema]: All four resources use the shared `commonschema.Location()` and `commonschema.ResourceGroupName()` schemas, which are `ForceNew`: [`location.go#L11-L20`](https://github.com/hashicorp/go-azure-helpers/blob/v0.81.1/resourcemanager/commonschema/location.go#L11-L20), [`resource_group_name.go#L11-L18`](https://github.com/hashicorp/go-azure-helpers/blob/v0.81.1/resourcemanager/commonschema/resource_group_name.go#L11-L18).
[^aks-network]: [`kubernetes_cluster_resource.go#L1168-L1173`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/containers/kubernetes_cluster_resource.go#L1168-L1173) and [`#L1211-L1216`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/containers/kubernetes_cluster_resource.go#L1211-L1216)
[^aks-default-rotation]: [`kubernetes_cluster_resource.go#L2747-L2788`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/containers/kubernetes_cluster_resource.go#L2747-L2788)
[^aks-pool-rotation]: [`kubernetes_cluster_node_pool_resource.go#L1009-L1048`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/containers/kubernetes_cluster_node_pool_resource.go#L1009-L1048)
[^vnet-faq]: [Azure Virtual Network FAQ](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-faq): "You can add, remove, expand, or shrink a subnet if no VMs or services are deployed in it."
[^aks-ip-planning]: [AKS: IP address planning](https://learn.microsoft.com/en-us/azure/aks/concepts-network-ip-address-planning)
[^pg-subnet]: [`postgresql_flexible_server_resource.go#L206-L211`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/postgres/postgresql_flexible_server_resource.go#L206-L211)
[^pg-network-migration]: [Azure Database for PostgreSQL: Migrate a VNet-integrated server to a private-endpoint-capable server](https://learn.microsoft.com/en-us/azure/postgresql/network/how-to-migrate-vnet-private-endpoint-capable-server)
[^pg-geo]: [`postgresql_flexible_server_resource.go#L276-L281`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/postgres/postgresql_flexible_server_resource.go#L276-L281)
[^pg-pitr]: [Azure Database for PostgreSQL: Backup and restore, point-in-time recovery](https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/concepts-backup-restore#point-in-time-recovery)
[^pg-deleted]: [Azure Database for PostgreSQL: Restore a deleted server](https://learn.microsoft.com/en-us/azure/postgresql/backup-restore/how-to-restore-deleted-server)
[^pg-login-version]: [`postgresql_flexible_server_resource.go#L389-L408`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/postgres/postgresql_flexible_server_resource.go#L389-L408)
[^pg-version-update]: [`postgresql_flexible_server_resource.go#L1096-L1099`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/postgres/postgresql_flexible_server_resource.go#L1096-L1099)
[^pg-major-upgrade]: [Azure Database for PostgreSQL: Major version upgrade](https://learn.microsoft.com/en-us/azure/postgresql/configure-maintain/concepts-major-version-upgrade)
[^lock-scope]: [`management_lock_resource.go#L47-L51`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/resource/management_lock_resource.go#L47-L51)
[^pg-storage]: [`postgresql_flexible_server_resource.go#L427-L430`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/postgres/postgresql_flexible_server_resource.go#L427-L430)
[^redis-ha]: [`managed_redis_resource.go#L249-L254`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/managedredis/managed_redis_resource.go#L249-L254)
[^redis-clustering]: [`managed_redis_resource.go#L158-L163`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/managedredis/managed_redis_resource.go#L158-L163) and [`#L563-L573`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/managedredis/managed_redis_resource.go#L563-L573)
[^storage-replication]: [`storage_account_resource.go#L1183-L1197`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/storage/storage_account_resource.go#L1183-L1197)
[^storage-container]: [`storage_container_resource.go#L76-L81`](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/internal/services/storage/storage_container_resource.go#L76-L81)
