# Azure Managed Redis operator guidance

This module's Redis backend is **Azure Managed Redis** (`azurerm_managed_redis`, the current Redis Enterprise-based Azure offering), not the legacy Azure Cache for Redis. n8n's Bull queue and KEDA's Redis scaler both read from `local.redis_connection` ([`redis.tf`](../redis.tf)), which selects between the module-managed instance and an external endpoint based on `var.create_redis`.

## Regional and SKU availability

Azure Managed Redis is not available in every region, and not every SKU is available in every region it does support. Before setting `location` or `redis_sku_name`, check current availability:

```bash
az redisenterprise list-skus-for-scaling --location <region>   # or the Azure portal's "Availability" tab for New Redis (Preview/GA) resources
```

`redis_sku_name` (default `Balanced_B1`) is validated against a curated allowlist across the `Balanced_B<N>`, `ComputeOptimized_X<N>`, and `MemoryOptimized_M<N>` families — see [Sizing and `NoCluster` capacity](#sizing-and-nocluster-capacity) below for why `FlashOptimized_*` is excluded entirely. An unlisted SKU name fails Terraform validation before any Azure API call.

Azure can still reject a listed SKU with a capacity-allocation error even when the SKU is generally available in the region. This is a live regional-capacity constraint, not a Terraform validation failure. Do not repeatedly retry the same SKU and region. Confirm another allowed SKU has capacity, deploy the complete stack in another region, or set `create_redis = false` and provide an external Redis endpoint. After changing the selected option, run a fresh `terraform plan`; a partial apply safely retains already-created AKS, PostgreSQL, storage, and networking resources while Terraform completes Redis and the dependent n8n workload on the next apply.

## Sizing and `NoCluster` capacity

The module always requests `clustering_policy = "NoCluster"` on `default_database`, because n8n's Bull client and KEDA's Redis scaler both assume a single logical keyspace, not Enterprise/OSS-cluster key-slot routing. Per [Microsoft's cluster-policy documentation](https://learn.microsoft.com/en-us/azure/redis/architecture#cluster-policies), `NoCluster` "only applies to caches sized 25 GB and smaller" — this is why `redis_sku_name`'s validation allowlists only SKUs documented at 25 GB or smaller, and excludes the `FlashOptimized_*` family (which starts at 250 GB) outright. The module never offers a SKU where `NoCluster` is unavailable in the first place.

## Eviction policy

`redis_eviction_policy` defaults to `NoEviction`. The azurerm provider's own default for `azurerm_managed_redis` is `VolatileLRU`, which evicts keys that carry a TTL once Redis runs out of memory. n8n's Bull queue keys can carry a TTL, so `VolatileLRU` (or any other eviction policy) can silently drop in-flight jobs under memory pressure instead of failing loudly. With `NoEviction`, a full Redis instance rejects new writes with an out-of-memory error on enqueue instead of evicting a queue key — set an alert on used memory (`redis-cli -h <redis_hostname> -p <redis_port> --tls INFO memory` or the Azure Monitor `usedmemorypercentage` metric) so that OOM condition is caught before it starts rejecting writes.

**Upgrading an existing deployment:** if you deployed this module before `redis_eviction_policy` was added, your instance already has the provider's `VolatileLRU` default. Adding this input with its `NoEviction` default forces Azure to recreate the instance on the next apply (see below). Either pin `redis_eviction_policy = "VolatileLRU"` to keep your existing instance in place, or drain the queue and let Terraform recreate it with `NoEviction`.

## Changing high availability, clustering policy, or eviction policy

`redis_high_availability_enabled`, the (always-`NoCluster`) clustering policy, and `redis_eviction_policy` are all **ForceNew** attributes on `azurerm_managed_redis` — Azure requires destroying and recreating the instance to change any of them. On a live deployment this means:

- In-flight Bull jobs are dropped.
- Multi-main leader election breaks until the new instance is reachable and n8n/KEDA reconnect.

Before flipping `redis_high_availability_enabled` or `redis_eviction_policy` on a deployment carrying real traffic:

1. Scale workers to zero (`kubectl -n n8n scale deployment/n8n-worker --replicas=0`) and let in-flight executions finish.
2. Confirm the queue is drained (`redis-cli -h <redis_hostname> -p <redis_port> --tls LLEN bull:*:wait` from a debug pod, or watch the n8n UI's active-execution count reach zero).
3. Apply the Terraform change. Expect the recreate to take several minutes; n8n main pods will show Redis connection errors in their logs until the new instance's private endpoint DNS resolves.
4. Scale workers back up once `kubectl -n n8n get pods -l app.kubernetes.io/component=worker` reports Ready.

## Managed vs. external Redis

Set `create_redis = false` and supply `redis_external_host` to point n8n and KEDA at a Redis you already run — an unauthenticated endpoint is supported (`redis_external_username` and `redis_external_password` are both optional in that case), but `redis_external_host` is required. The module's `check` diagnostics (`external_redis_inputs_require_create_redis_false` / `redis_tuning_requires_module_managed_redis` in [`redis.tf`](../redis.tf)) flag the two directions Terraform can't reject outright: managed-only tuning left non-default while external Redis is active, and external inputs supplied while a managed instance is still created (and used instead).

## Connectivity

The managed path is always TLS-only (`client_protocol = "Encrypted"`, `public_network_access = "Disabled"`) with access-key authentication, reachable only from inside the linked VNet via a private endpoint on `redis_pe_subnet_id` — the subnet must have `private_endpoint_network_policies` disabled or the private endpoint fails to create. DNS resolves through the Azure Managed Redis `privatelink.redis.azure.net` private zone this module creates and links to `vnet_id`.
