## Purpose

Expose the advanced cloud-neutral n8n runtime controls already available in the AWS sibling while preserving safe Azure workload defaults.

## ADDED Requirements

### Requirement: Reproducible application images
The module SHALL expose separate n8n repository, application tag, task-runner tag, pull-secret, and Helm-timeout inputs with validation and diagnostics for incompatible combinations. Azure Blob storage modes SHALL require n8n 2.29.0 or later, and all n8n components SHALL use the same application version.

#### Scenario: Deploy a private custom image
- **WHEN** a caller supplies a custom repository, custom application tag, matching task-runner tag, and existing image pull-secret names
- **THEN** all n8n pod families SHALL use the custom application image and authenticate through a module-managed service account without storing registry credentials in Terraform inputs

### Requirement: Custom extensions and volumes
The module SHALL support one custom-extension path and typed ConfigMap, Secret, or persistent-volume sources mounted consistently on main, worker, and webhook pods.

#### Scenario: Mount community nodes on every pod family
- **WHEN** a declared volume is mounted over the configured custom-extension path
- **THEN** all n8n containers SHALL receive the volume mount and `N8N_CUSTOM_EXTENSIONS`

#### Scenario: Reject an unsafe extension path
- **WHEN** a custom-extension path is non-canonical, contains multiple semicolon-delimited paths, or is under `/home/node/.n8n`
- **THEN** Terraform planning SHALL fail with the specific unsafe condition

### Requirement: Runtime and lifecycle controls
The module SHALL expose the AWS sibling's timezone, logging, pod resources, worker concurrency, execution timeout, execution concurrency, pruning, termination grace, pre-stop, task-runner, template, personalization, community-package, and floating-license controls.

#### Scenario: Preserve a multi-main license during rollout
- **WHEN** the caller accepts the default floating-license shutdown behavior
- **THEN** every n8n pod SHALL receive `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false`

### Requirement: Safe additional environment variables
The module SHALL accept arbitrary non-secret n8n environment variables while rejecting duplicate names and names reserved by the chart or module.

#### Scenario: Reject a managed connection override
- **WHEN** `n8n_extra_env` contains `DB_POSTGRESDB_HOST`, `QUEUE_BULL_REDIS_HOST`, `N8N_ENCRYPTION_KEY`, or another reserved connection, identity, storage, license, or topology variable
- **THEN** Terraform planning SHALL fail and direct the caller to the dedicated input

### Requirement: Azure binary-data storage
The module SHALL support Azure Blob and shared-filesystem binary-data modes, SHALL expose historical available modes separately from the default write mode, and SHALL reserve all module-owned `N8N_EXTERNAL_STORAGE_AZURE_*` and binary-mode variables.

#### Scenario: Write new binary data to Azure
- **WHEN** the default binary-data mode is `azure`
- **THEN** all n8n pod families SHALL write new objects to Azure Blob while configured historical filesystem objects remain readable

#### Scenario: Reject an unsupported application version
- **WHEN** Azure binary or execution-data mode is enabled with an n8n application version older than 2.29.0
- **THEN** Terraform planning SHALL fail before n8n can enter a startup-failure loop

### Requirement: Azure execution-data offload
The module SHALL support `database`, shared-Azure-Files `filesystem`, and Azure Blob `azure` execution-data modes.

#### Scenario: Offload new execution data
- **WHEN** execution-data mode is `filesystem`
- **THEN** all n8n pod families SHALL use the shared Azure Files path for new execution data while existing database-backed executions remain readable

#### Scenario: Offload execution data to Azure Blob
- **WHEN** execution-data mode is `azure`
- **THEN** all n8n pod families SHALL use the configured Azure container for new execution bundles while n8n continues to read executions recorded in older modes

### Requirement: Independent Enterprise entitlements
The module documentation SHALL identify `feat:binaryDataAz` and `feat:executionDataAz` as separate n8n Enterprise entitlements and SHALL not imply that one enables the other.

#### Scenario: Enable one Azure storage feature
- **WHEN** a caller enables only one Azure storage mode
- **THEN** the module SHALL configure and test that mode without requiring the other mode to be enabled

### Requirement: Azure Key Vault external-secrets boundary
The module SHALL document n8n Azure Key Vault external secrets as a caller-configured Enterprise integration that uses tenant ID, client ID, and client secret, and SHALL distinguish it from App Gateway certificate access and Blob workload identity.

#### Scenario: Use a non-public Azure Key Vault endpoint
- **WHEN** an operator configures a US Government, China, or custom Key Vault endpoint
- **THEN** the module documentation SHALL identify the required vault and authority endpoint settings without claiming sovereign-cloud certification

### Requirement: Metrics, tracing, and log streaming
The module SHALL expose Prometheus metrics, OpenTelemetry tracing, and Enterprise environment-managed log-streaming controls without bundling an observability backend.

#### Scenario: Export traces from queue mode
- **WHEN** OpenTelemetry is enabled with an OTLP endpoint
- **THEN** the corresponding `N8N_OTEL_*` values SHALL be applied to main, worker, and webhook pods

#### Scenario: Keep sensitive observability values redacted
- **WHEN** OTLP headers or log-streaming destinations contain credentials
- **THEN** their Terraform variables SHALL be sensitive and documentation SHALL warn that rendered pod environment values still reside in state
