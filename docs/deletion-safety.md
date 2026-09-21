# Deletion safety

[terraform-aws-n8n 0.5.0](https://github.com/n8n-io/terraform-aws-n8n/blob/main/CHANGELOG.md#050---2026-09-21)
added five inputs governing what happens to RDS and S3 when a caller
destroys the AWS module: `db_deletion_protection`, `db_skip_final_snapshot`,
`db_final_snapshot_identifier`, `db_delete_automated_backups`, and
`s3_force_destroy`. This module (`port-aws-050-enhancements`) ported the
applicable parts as an honest, best-effort mapping onto Azure's actual
provider surface rather than a literal re-implementation: an input is added
only where a real Azure or provider attribute exists to wire it to. Where
none exists, that gap is documented here instead of shipping a
non-functional input named after a control it cannot enforce.

## PostgreSQL Flexible Server

| AWS input | Azure outcome | Why |
|---|---|---|
| `db_deletion_protection` | **No analog. Documentation only.** | `azurerm_postgresql_flexible_server` (azurerm 4.x) exposes no deletion-protection attribute, and Terraform's `lifecycle.prevent_destroy` cannot be driven by a variable, so there is no way to make this input actually prevent a destroy. Guard against accidental destroys operationally: require a second approval step in your deployment pipeline, or scope the identity that runs `terraform destroy` separately from the one that runs `apply`. |
| `db_skip_final_snapshot` / `db_final_snapshot_identifier` | **No analog. Documentation only.** | Flexible Server has no destroy-time final-snapshot concept on the server resource itself. `pg_backup_retention_days` (7-35 days, Azure forbids disabling backups entirely) is the closest recovery mechanism: automated backups continue independently of the server's lifecycle and can restore a database deleted within that window, via `create_mode = "PointInTimeRestore"` against a new server. This is not equivalent to a final, destroy-time snapshot: restoring after the retention window closes is not possible. |
| `db_delete_automated_backups` | **Covered by `pg_backup_retention_days`.** | Azure Flexible Server does not expose a separate "delete backups when the server is deleted" toggle. Automated backups are retained for `pg_backup_retention_days` regardless of whether the server that produced them still exists; there is nothing additional to control. |

## Blob storage

| AWS input | Azure outcome | Why |
|---|---|---|
| `s3_force_destroy` | **`blob_delete_retention_days` (new input), inverted default posture.** | Azure Blob containers and their contents delete immediately on `terraform destroy` with no built-in guard, so the account's default behavior is already closer to `force_destroy = true` than `false`: there is no equivalent "refuse to destroy a non-empty container" behavior to disable. The nearest real safety net is [soft delete](https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-overview): `blob_delete_retention_days` (default `null`, disabled) wires `blob_properties.delete_retention_policy` and `container_delete_retention_policy` on the module-managed storage account. When set, a deleted blob or container is recoverable within the configured window (1-365 days) instead of being gone immediately. This does not block `terraform destroy` from proceeding; it only makes the deletion recoverable for a bounded time. |

## What this means operationally

- Setting `blob_delete_retention_days` protects against accidental blob or
  container deletion (including a `terraform destroy` of just the storage
  layer), not against the AKS/PostgreSQL cluster being destroyed with it.
- There is no input in this module that can turn `terraform destroy`
  itself into a no-op for the PostgreSQL server or the storage account.
  Production protection against destroys is a process control (approval
  gates, separate destroy credentials, state-locking policy), not a
  Terraform variable; this mirrors the reality of the underlying Azure
  APIs, not a gap specific to this module.
- Existing `pg_backup_retention_days` and `pg_geo_redundant_backup_enabled`
  remain the primary recovery mechanisms for PostgreSQL. See
  [`docs/data-storage.md`](./data-storage.md) for the full binary/execution
  data retention picture and [`docs/destroy-cleanup.md`](./destroy-cleanup.md)
  for the destroy-order and backup-before-you-destroy checklist.
