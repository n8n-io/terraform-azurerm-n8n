# Delta for deployment-examples: slim-first-release-surface

## MODIFIED Requirements

### Requirement: Large Azure topology
The `large` example SHALL use Azure-native high-throughput and high-availability choices, including zone-redundant PostgreSQL, highly available Azure Managed Redis, private Azure Blob storage, larger AKS subnets, and PgBouncer where connection pressure requires it.

#### Scenario: Plan the large example
- **WHEN** the mocked large example test runs
- **THEN** it SHALL assert the high-availability, sizing, PgBouncer, storage, and autoscaling decisions that distinguish it from medium

## REMOVED Requirements

### Requirement: DNS-provider variants
**Reason**: The `cloudflare` and `godaddy` examples demonstrated ACME DNS-01 validation, which is a property of the `modules/tls-letsencrypt/` helper, not of the n8n module. For the 0.1.0 release the guidance moves into that submodule's README and the two example roots are deleted, removing two cells from every CI matrix.
**Migration**: Operators using a non-Azure DNS provider follow `modules/tls-letsencrypt/README.md` for provider wiring and pass the resulting secret URI to any sizing example.
