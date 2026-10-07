# Sandbox profile

The [`small`](../examples/small/) example is already the module's cheapest
end-to-end reference, but it is still a multi-main footprint: two AKS node
pools with at least two nodes each (`aks_node_count_min = 2`), two main
pods, two webhook processors, and a worker with a task-runner sidecar. This
document describes a cheaper single-main sandbox profile.

## What you can set today

Two of the inputs below, `aks_node_vm_size` and `n8n_main_hpa_min_replicas`,
are plain tfvars overrides on the `small` example today. The rest are not
exposed as example-level variables: `small`'s `locals.tier` block
(`examples/small/main.tf`) hardcodes `aks_node_count_min`,
`aks_node_count_max`, and `pg_sku_name`, and never passes
`postgres_pool_size`, `n8n_main_hpa_max_replicas`,
`n8n_webhook_hpa_min_replicas`, `n8n_worker_keda_min_replicas` /
`n8n_worker_keda_max_replicas`, or the `aks_system_*` overrides through to
the module at all. Applying the sandbox values for those inputs means
editing `examples/small/main.tf` directly (either its `locals.tier` block or
the `module "n8n"` call), or passing them through your own root module if
you are not starting from `small`:

| Input | Sandbox value | Why |
|---|---|---|
| `n8n_main_hpa_min_replicas` | `1` | Single-main mode. Does not require `feat:multipleMainInstances`. |
| `n8n_main_hpa_max_replicas` | `1` | Not required: the effective ceiling already clamps to 1 in single-main mode (`locals.tf`), so the capacity and connection-budget diagnostics model one main replica regardless of this value. Setting it to `1` here keeps the input honest about what single-main mode actually runs. |
| `n8n_webhook_hpa_min_replicas` / `n8n_webhook_hpa_max_replicas` | `1` | One webhook processor. |
| `n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas` | `1` | One worker. |
| `aks_node_count_min` | `1` | The autoscaler's floor on the user pool, and on the system pool unless `aks_system_node_count_min` overrides it (see below). |
| `aks_node_count_max` | `2` | Leaves headroom for a rolling node upgrade without paying for a second steady-state node per pool. |
| `aks_node_vm_size` | A smaller SKU than the default, e.g. `Standard_D2s_v5` | The module's own default is `Standard_D4s_v4`; the `small` example already defaults this input to `Standard_D2s_v5`. It sizes both pools unless `aks_system_node_vm_size` overrides the system pool. |
| `pg_sku_name` | `B_Standard_B1ms` | Cheapest Burstable Flexible Server tier. Has a low `max_connections`; see the budget section below. |
| `postgres_pool_size` | `3` or lower | See the budget section below. |

## AKS caveat: still two node pools

The module always creates a system pool and a user (`n8nuser`) pool
(`aks.tf`); there is no single-pool mode. `aks_node_count_min = 1` gives
you two pools at one node each. `aks_system_node_count_min`,
`aks_system_node_count_max`, and `aks_system_node_vm_size` size the system
pool separately, so you can make it smaller than the user pool.

Both pools are schedulable for n8n by default. If you set
`aks_system_pool_critical_addons_only = true`, the system pool is tainted
and n8n, KEDA, and the Redis exporter all move onto the user pool. Size
the user pool for every n8n pod in that case, because the capacity
diagnostic then counts only the user pool.

## PostgreSQL connection budget

Azure Database for PostgreSQL Flexible Server computes the default
`max_connections` when the server is provisioned, from the SKU you select.
A later change to `pg_sku_name` does **not** update that value. Microsoft
recommends adjusting the `max_connections` server parameter after every
SKU change, and the new value takes effect only after a server restart
([Microsoft Learn: limits in Azure Database for PostgreSQL flexible
server](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-limits)).
For example, a server created on `B_Standard_B1ms` and later resized to
`GP_Standard_D2s_v3` still allows 35 user connections until you raise
`max_connections` and restart.

`B_Standard_B1ms` (1 vCore, 2 GiB) allows only 35 user connections by
default: 50 `max_connections` minus 15 slots Azure reserves for replication
and monitoring. Microsoft notes that the reserved count can change. The
live budget is `max_connections - (reserved_connections +
superuser_reserved_connections)`, and every other client of the server
draws from it too.

Each main, worker, and webhook-processor pod can lazily open up to
`postgres_pool_size` connections against the same server
(`postgres_pool_size` variable description), so the aggregate ceiling is:

```text
postgres_pool_size * (main replicas + worker replicas + webhook replicas + any n8n_worker_pools ceilings)
```

These are configured steady-state ceilings. Pods added during a rolling
update are not counted, so leave some headroom. While
`n8n_worker_keda_pause = true`, the worker term uses
`n8n_worker_keda_paused_replica_count` when that is larger than
`n8n_worker_keda_max_replicas`.

At the single-main sandbox sizes above (1 main + 1 worker + 1 webhook = 3
pods), `postgres_pool_size = 10` (the module default) would request up to
30 connections, under 35, but there is no room to raise any of those
replica counts, add a worker pool, or keep the default pool size with
larger replica counts. `postgres_pool_size = 3` leaves more headroom (up to
9 connections at these replica counts).

The root module's `check.postgres_pool_size_fits_known_max_connections`
(`database.tf`) warns at plan time whenever this arithmetic exceeds the
default user-connection limit Microsoft publishes for `pg_sku_name`. Keep
these limits in mind:

- It models the SKU default, not the live server. After a SKU change, or
  if someone set `max_connections` outside Terraform, a silent check does
  not prove the pools fit. Confirm the live budget with
  `SHOW max_connections`, `SHOW reserved_connections`, and
  `SHOW superuser_reserved_connections`, and count other clients.
- It stays silent for SKUs outside its table and when
  `create_database = false`.
- It counts `n8n_webhook_hpa_max_replicas` even when
  `n8n_webhook_hpa_enabled = false`, as a stand-in for a caller-owned
  webhook autoscaler whose ceiling the module cannot see.
- It is advisory only. It does not fail the plan or apply.

## Redis and storage

This profile does not change `redis_sku_name` or the storage replication
type from the `small` example's `Balanced_B0` / `LRS`. In `small`, the
replication type is the `storage_replication_type` key of `locals.tier`,
which the example passes to the module's `storage_account_replication_type`
input. Azure Managed Redis is already sized independently of PostgreSQL
and AKS; see [`docs/redis.md`](./redis.md) for SKU availability, sizing,
and `NoCluster` capacity guidance.
