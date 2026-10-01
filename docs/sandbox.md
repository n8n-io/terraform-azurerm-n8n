# Sandbox profile

The [`small`](../examples/small/) example is already the module's cheapest
end-to-end reference, but it is still a multi-main footprint: two AKS node
pools with at least two nodes each (`aks_node_count_min = 2`), two main
pods, two webhook processors, and a worker with a task-runner sidecar. This
document describes a cheaper single-main sandbox profile and calls out the
one piece that is not available yet.

## What you can set today

Two of the inputs below, `aks_node_vm_size` and `n8n_main_hpa_min_replicas`,
are plain tfvars overrides on the `small` example today. The rest are not
exposed as example-level variables: `small`'s `locals.tier` block
(`examples/small/main.tf`) hardcodes `aks_node_count_min`,
`aks_node_count_max`, and `pg_sku_name`, and never passes
`postgres_pool_size`, `n8n_main_hpa_max_replicas`,
`n8n_webhook_hpa_min_replicas`, or `n8n_worker_keda_min_replicas` /
`n8n_worker_keda_max_replicas` through to the module at all. Applying the
sandbox values for those inputs means editing `examples/small/main.tf`
directly (either its `locals.tier` block or the `module "n8n"` call), or
passing them through your own root module if you are not starting from
`small`:

| Input | Sandbox value | Why |
|---|---|---|
| `n8n_main_hpa_min_replicas` | `1` | Single-main mode. Does not require `feat:multipleMainInstances`. |
| `n8n_main_hpa_max_replicas` | `1` | Not required: the effective ceiling already clamps to 1 in single-main mode (`locals.tf`), so the capacity diagnostics model one main replica regardless of this value. Setting it to `1` here just keeps the input honest about what single-main mode actually runs. |
| `n8n_webhook_hpa_min_replicas` / `n8n_webhook_hpa_max_replicas` | `1` | One webhook processor. |
| `n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas` | `1` | One worker. |
| `aks_node_count_min` | `1` | The autoscaler's floor on **each** node pool (see below). |
| `aks_node_count_max` | `2` | Leaves headroom for a rolling node upgrade without paying for a second pool's steady-state node. |
| `aks_node_vm_size` | A smaller SKU than the `Standard_D4s_v4` default, e.g. `Standard_D2s_v4` | Both node pools share this input; see the AKS caveat below. |
| `pg_sku_name` | `B_Standard_B1ms` | Cheapest Burstable Flexible Server tier. Has a low `max_connections`; see the budget section below. |
| `postgres_pool_size` | `3` or lower | See the budget section below. |

## AKS caveat: still two node pools

`aks_node_count_min` and `aks_node_count_max` size **both** the system and
user AKS node pools identically (`aks.tf`); there is no per-pool override
today. Setting `aks_node_count_min = 1` gets you two pools at one node each
(two nodes total, both schedulable for n8n since neither is tainted), not
the single node pool this profile's name implies. A true single-node-pool
sandbox needs per-pool sizing, tracked separately; until that lands, treat
`aks_node_count_min = 1, aks_node_count_max = 2` as this profile's floor.

## PostgreSQL connection budget

Azure Database for PostgreSQL Flexible Server computes `max_connections`
once, at provisioning, from the SKU's memory size, and does **not**
recalculate it if you change `pg_sku_name` later — the old ceiling sticks
until the server is re-created
([Microsoft Learn: limits in Azure Database for PostgreSQL flexible
server](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-limits)).
`B_Standard_B1ms` (1 vCore, 2 GiB) allows only 35 user connections by
default. Each main, worker, and webhook-processor pod can lazily open up to
`postgres_pool_size` connections against the same server
(`postgres_pool_size` variable description), so the aggregate ceiling is:

```
postgres_pool_size * (main replicas + worker replicas + webhook replicas + any n8n_worker_pools ceilings)
```

At the single-main sandbox sizes above (1 main + 1 worker + 1 webhook = 3
pods), `postgres_pool_size = 10` (the module default) would request up to
30 connections, comfortably under 35 — but there is no room to raise any of
those replica counts, add a worker pool, or leave `postgres_pool_size` at
its default while also lowering the pod counts less aggressively than this
profile does. `postgres_pool_size = 3` leaves more headroom (up to 9
connections at these replica counts). The root module's
`check.postgres_pool_size_fits_known_max_connections` (`database.tf`) warns
at plan time whenever this arithmetic exceeds the known limit for
`pg_sku_name`; it stays silent for SKUs outside its small table, and it is
advisory only (it does not fail the plan or apply).

## Redis and storage

This profile does not change `redis_sku_name` or
`storage_replication_type` from the `small` example's `Balanced_B0` /
`LRS` — Azure Managed Redis is already sized independently of PostgreSQL
and AKS, and the module's Redis connection-count guidance lives in
[`docs/redis.md`](./redis.md).
