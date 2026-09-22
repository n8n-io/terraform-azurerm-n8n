## ADDED Requirements

### Requirement: Blob soft-delete retention

The module SHALL expose nullable `blob_delete_retention_days` (default
null). When set, it SHALL configure blob and container soft-delete
retention on the module-managed storage account; when null, it SHALL leave
the account's current behavior unchanged so existing deployments see no
plan diff. Supplying a value while `create_blob_storage = false` SHALL
raise the existing ignored-Blob-tuning warning.

#### Scenario: Enable soft delete

- **WHEN** `blob_delete_retention_days = 14` with module-managed Blob
- **THEN** the storage account SHALL render blob and container delete
  retention policies of 14 days

#### Scenario: Keep current behavior by default

- **WHEN** the input is null
- **THEN** no retention policy block SHALL be rendered

#### Scenario: Warn on caller-managed Blob

- **WHEN** the input is set and `create_blob_storage = false`
- **THEN** the module SHALL emit the ignored-Blob-tuning check warning

### Requirement: Deletion-safety documentation

The module SHALL document, for every AWS-sibling deletion-time control
without an Azure equivalent (database deletion protection, final snapshot,
automated-backup deletion), why none exists and what Azure mechanism
covers the concern instead. It SHALL NOT expose an input named after a
control it cannot wire to a real Azure or provider attribute.

#### Scenario: Document an absent analog

- **WHEN** `azurerm_postgresql_flexible_server` exposes no
  final-snapshot-on-destroy attribute
- **THEN** `docs/deletion-safety.md` SHALL state this and point to
  `pg_backup_retention_days` as the recovery window

## MODIFIED Requirements

### Requirement: PostgreSQL reliability controls

The managed database path SHALL expose version, SKU, storage, backup
retention, geo-redundant backup, maintenance window, primary zone, and
zone-redundant high-availability controls with cross-input validation.
`pg_backup_retention_days` SHALL be non-nullable so an explicit `null`
resolves to its default of 7 rather than failing validation.

#### Scenario: Reject unsupported high availability

- **WHEN** zone-redundant high availability is enabled with a Burstable
  PostgreSQL SKU or identical primary and standby zones
- **THEN** the module SHALL fail at plan time

#### Scenario: Fall back on null retention

- **WHEN** a caller passes `pg_backup_retention_days = null`
- **THEN** the effective retention SHALL be 7 days
