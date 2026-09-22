# Deletion safety

[terraform-aws-n8n 0.5.0](https://github.com/n8n-io/terraform-aws-n8n/blob/main/CHANGELOG.md#050---2026-09-21)
added five inputs governing what happens to RDS and S3 when a caller
destroys the AWS module: `db_deletion_protection`, `db_skip_final_snapshot`,
`db_final_snapshot_identifier`, `db_delete_automated_backups`, and
`s3_force_destroy`. This module (`port-aws-050-enhancements`) ported the
applicable parts as an honest, best-effort mapping onto Azure's actual
provider surface rather than a literal re-implementation: an input is added
only where a real Azure or provider attribute exists to wire it to. Where
none exists inside the module's own resource surface, that gap is
documented here instead of shipping a non-functional input named after a
control it cannot enforce.

## PostgreSQL Flexible Server

| AWS input | Azure outcome | Why |
|---|---|---|
| `db_deletion_protection` | **Caller-owned analog: an Azure resource lock.** Not a module input in this release. | `azurerm_postgresql_flexible_server` (azurerm 4.x) exposes no deletion-protection attribute, and Terraform's `lifecycle.prevent_destroy` cannot be driven by a variable. Azure's platform-level equivalent is a [`CanNotDelete` management lock](https://learn.microsoft.com/azure/azure-resource-manager/management/lock-resources) on the server, which Microsoft's own [Flexible Server guidance](https://techcommunity.microsoft.com/blog/adforpostgresql/prevent-accidental-deletion-of-an-instance-in-azure-postgres/4447969) recommends for exactly this purpose: it blocks deletion through the portal, CLI, ARM, and Terraform alike while leaving configuration and data operations untouched. The module does not create one, because a lock in the same Terraform state as the server is destroyed first by the same `terraform destroy` it is meant to guard; only `lifecycle.prevent_destroy` on the lock resource (which cannot be variable-driven) or a lock held outside the destroying state makes the destroy itself fail. Create it from your own root against the `postgres_server_id` output (see the snippet below), and remove it deliberately, as its own change, before a planned destroy. A module-managed opt-in lock is a candidate follow-up. |
| `db_skip_final_snapshot` / `db_final_snapshot_identifier` | **No analog. Documentation only.** | Flexible Server has no destroy-time final-snapshot concept on the server resource itself. Two recovery paths exist, with different windows. While the server exists, `pg_backup_retention_days` (7-35 days; Azure forbids disabling backups entirely) is the point-in-time restore window, via `create_mode = "PointInTimeRestore"` against a new server. Once the server is deleted, Azure keeps its backup for **5 days only**, regardless of `pg_backup_retention_days`, and it can be recovered through the separate ["restore a dropped server"](https://learn.microsoft.com/azure/postgresql/flexible-server/how-to-restore-dropped-server) flow documented by Microsoft (the deletion event from the portal's Activity Log supplies the parameters for a REST API `createMode` revive; Microsoft describes success as best effort, not guaranteed) from the same subscription. After those 5 days the data is gone. Neither path is a final, destroy-time snapshot you control: take an explicit `pg_dump` before a planned destroy (see [`docs/destroy-cleanup.md`](./destroy-cleanup.md)). |
| `db_delete_automated_backups` | **No separate toggle; see the 5-day rule above.** | Azure Flexible Server does not expose a "delete backups when the server is deleted" switch. Deleting the server implicitly shortens backup retention to 5 days; keeping the server keeps them for `pg_backup_retention_days`. There is nothing additional for a module input to control. |

Caller-owned deletion lock, from the root that calls this module:

```hcl
resource "azurerm_management_lock" "postgres" {
  name       = "n8n-postgres-no-delete"
  scope      = module.n8n.postgres_server_id
  lock_level = "CanNotDelete"
  notes      = "Remove in its own change before a planned terraform destroy."

  # Without this, terraform destroy removes the lock first and then the
  # server, and the lock protects nothing against Terraform itself.
  lifecycle {
    prevent_destroy = true
  }
}
```

What this gives you: the server cannot be deleted from the portal, the CLI,
ARM, or a targeted or out-of-band Terraform run while the lock exists, and a
plain `terraform destroy` of the root fails on the lock's `prevent_destroy`
before it reaches the server. A planned destroy is then two visible steps:
remove the lock resource (and its `prevent_destroy`) in one change, then
destroy in the next. `prevent_destroy` cannot be toggled by a variable, so a
`count` switch on this resource would itself trip it. If the lock lives in
a different Terraform state (or was created outside Terraform), the destroy
fails with a `ScopeLocked` error on the server or, since Azure locks are
inherited, on one of its child resources (the database or a server
configuration). The server survives, but Terraform has already destroyed
everything ahead of it in the graph (AKS, the Helm release, Redis, storage)
by then, so prefer the same-state `prevent_destroy` form, which stops the
destroy before it touches anything.

## Blob storage

| AWS input | Azure outcome | Why |
|---|---|---|
| `s3_force_destroy` | **`blob_delete_retention_days` (new input), inverted default posture.** | Azure Blob containers and their contents delete immediately on `terraform destroy` with no built-in guard, so the account's default behavior is already closer to `force_destroy = true` than `false`: there is no equivalent "refuse to destroy a non-empty container" behavior to disable. The nearest real safety net is [soft delete](https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-overview): `blob_delete_retention_days` (default `null`) wires `blob_properties.delete_retention_policy` and `container_delete_retention_policy` on the module-managed storage account. When set, a deleted blob or container is recoverable within the configured window (1-365 days) instead of being gone immediately. This does not block `terraform destroy` from proceeding; it only makes the deletion recoverable for a bounded time. |

`blob_delete_retention_days` is a one-way switch from Terraform's side.
`null` renders no `blob_properties` block, so a freshly created account keeps
soft delete disabled (Azure's API default). azurerm treats `blob_properties`
as Optional+Computed, so setting a value and later reverting to `null` plans
no change: soft delete stays enabled at the last applied window. Disable it
out of band if that is what you want:

```bash
az storage account blob-service-properties update \
  --account-name <storage-account> --resource-group <rg> \
  --enable-delete-retention false \
  --enable-container-delete-retention false
```

Soft delete is scoped to blobs and containers inside a live account.
Deleting the account itself is a different operation with its own,
best-effort recovery path ([recover a deleted storage account](https://learn.microsoft.com/azure/storage/common/storage-account-recover),
within 14 days and only if the name has not been reused), which
`blob_delete_retention_days` does not influence. If the account must survive
a `terraform destroy`, the same caller-owned `CanNotDelete` lock pattern
shown for PostgreSQL applies, scoped to `module.n8n.storage_account_id`.

## What this means operationally

- Setting `blob_delete_retention_days` protects against accidental blob or
  container deletion (including a `terraform destroy` of just the storage
  layer), not against the AKS/PostgreSQL cluster being destroyed with it,
  and not against deletion of the storage account itself.
- No input in this module turns `terraform destroy` into a no-op for the
  PostgreSQL server or the storage account. The Azure-native guard is a
  caller-owned `CanNotDelete` management lock with `prevent_destroy`
  (snippet above), which turns a destroy into a deliberate two-step change,
  layered with the usual process controls (approval gates, separate
  destroy credentials, state-locking policy).
- Existing `pg_backup_retention_days` and `pg_geo_redundant_backup_enabled`
  remain the primary recovery mechanisms for a PostgreSQL server that
  still exists; a dropped server is recoverable for 5 days only. See
  [`docs/data-storage.md`](./data-storage.md) for the full binary/execution
  data retention picture and [`docs/destroy-cleanup.md`](./destroy-cleanup.md)
  for the destroy-order and backup-before-you-destroy checklist.
