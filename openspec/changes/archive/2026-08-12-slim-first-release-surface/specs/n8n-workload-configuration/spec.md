# Delta for n8n-workload-configuration: slim-first-release-surface

## MODIFIED Requirements

### Requirement: Azure binary-data storage
The module SHALL support the `database` (PostgreSQL-backed) and `azure` (Azure Blob) binary-data modes only, SHALL expose historical available modes separately from the default write mode, and SHALL reserve all module-owned `N8N_EXTERNAL_STORAGE_AZURE_*` and binary-mode variables. Neither n8n's inline-memory `default` mode nor a shared-filesystem binary-data path SHALL exist, and `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` SHALL always render `true`.

#### Scenario: Write new binary data to Azure
- **WHEN** the default binary-data mode is `azure`
- **THEN** all n8n pod families SHALL write new objects to Azure Blob while objects recorded under a configured historical mode remain readable

#### Scenario: Reject a non-durable binary mode
- **WHEN** `default` or `filesystem` is supplied as the binary-data mode or in the available-modes list
- **THEN** Terraform planning SHALL fail and explain that 0.1.0 supports the `database` and `azure` modes only

#### Scenario: Reject an unsupported application version
- **WHEN** Azure binary or execution-data mode is enabled with an n8n application version older than 2.29.0
- **THEN** Terraform planning SHALL fail before n8n can enter a startup-failure loop

### Requirement: Azure execution-data offload
The module SHALL support the `database` and Azure Blob `azure` execution-data modes only.

#### Scenario: Offload new execution data
- **WHEN** the execution-data mode changes between `database` and `azure`
- **THEN** all n8n pod families SHALL write new execution data through the newly selected backend while executions recorded under the previous mode remain readable

#### Scenario: Offload execution data to Azure Blob
- **WHEN** execution-data mode is `azure`
- **THEN** all n8n pod families SHALL use the configured Azure container for new execution bundles while n8n continues to read executions recorded in older modes

#### Scenario: Reject a filesystem execution-data mode
- **WHEN** `filesystem` is supplied as the execution-data storage mode
- **THEN** Terraform planning SHALL fail and explain that 0.1.0 supports the `database` and `azure` modes only
