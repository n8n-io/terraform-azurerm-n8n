# Delta for module-verification: slim-first-release-surface

## ADDED Requirements

### Requirement: First-release versioning baseline
The repository SHALL present itself as an unreleased module whose first published version is `0.1.0`: `CHANGELOG.md` SHALL contain a single `0.1.0` entry describing the released surface, no migration runbook or v2/v3/v4 upgrade language SHALL remain in the documentation, and internal pre-release history SHALL not be presented as published versions.

#### Scenario: Read the release history
- **WHEN** an operator reads `CHANGELOG.md` and the README
- **THEN** they SHALL find exactly one released version (`0.1.0`) and no reference to migrating from earlier module versions

## MODIFIED Requirements

### Requirement: Live deployment smoke test
The smoke test SHALL verify AKS access, namespace and controller readiness, minimum ready replicas, PostgreSQL and Redis connectivity, Azure Blob access, Application Gateway reachability, HTTPS health, complete webhook route ownership, and n8n license validity.

#### Scenario: Verify an applied small deployment
- **WHEN** the smoke test runs after applying `examples/small`
- **THEN** it SHALL exit zero only if every infrastructure, workload, route, storage, and license assertion passes

### Requirement: Azure storage acceptance
Live verification SHALL test Azure Blob startup access and binary and execution-data operations through n8n, not only direct Azure API access.

#### Scenario: Verify Azure Blob across pod families
- **WHEN** the smoke test restarts main, worker, and webhook pods with Azure storage enabled
- **THEN** n8n SHALL write, read, download, and delete binary data and SHALL write, read, and prune execution data through the private container

#### Scenario: Preserve historical reads
- **WHEN** the default binary mode changes from `database` to `azure`
- **THEN** the smoke test SHALL read one historical database-backed object and one new Azure Blob object before the old mode can be dropped from the available-modes list
