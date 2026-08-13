## Purpose

Expose the advanced cloud-neutral n8n runtime controls already available in the AWS sibling while preserving safe Azure workload defaults.
## Requirements
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

### Requirement: Caller-managed workload credentials
The module SHALL accept mutually exclusive literal-value and existing Kubernetes Secret references for the n8n license key and n8n encryption key, and SHALL preserve the selected Secret name and key across main, worker, and webhook pod families.

#### Scenario: Use an existing license Secret
- **WHEN** a caller supplies the name and key of a Kubernetes Secret containing the n8n license
- **THEN** the module SHALL create no license Secret and the chart SHALL reference the caller-managed Secret

#### Scenario: Use an existing encryption-key Secret
- **WHEN** a caller supplies the name and key of a Kubernetes Secret containing the n8n encryption key
- **THEN** the module SHALL create no encryption-key Secret, SHALL not generate or output an effective encryption key, and SHALL configure every pod family from that Secret

#### Scenario: Reject two credential sources
- **WHEN** a caller supplies both a literal value and an existing Secret reference for one credential
- **THEN** Terraform planning SHALL fail and require exactly one selected source

### Requirement: Caller-managed namespace
The module SHALL allow n8n to deploy into a pre-existing namespace without creating or deleting that namespace.

#### Scenario: Use a platform-owned namespace
- **WHEN** namespace creation is disabled and a valid namespace name is supplied
- **THEN** every n8n Secret, ServiceAccount, manifest, Helm release, HPA, and output SHALL use that namespace while no namespace resource is created

### Requirement: Independent webhook HPA ownership
The module SHALL allow callers to disable only the module-managed webhook HPA while retaining the webhook deployment and service.

#### Scenario: Use a platform autoscaler
- **WHEN** the module-managed webhook HPA is disabled
- **THEN** the module SHALL create no webhook HPA and SHALL leave the webhook deployment available for a caller-managed autoscaler

### Requirement: External KEDA ownership
The module SHALL allow callers to use a pre-existing KEDA installation while preserving worker ScaledObject and TriggerAuthentication behavior.

#### Scenario: Use existing KEDA
- **WHEN** KEDA installation is disabled and the caller confirms a compatible KEDA installation already exists
- **THEN** the module SHALL install no KEDA operator or KEDA namespace and SHALL still create the n8n-specific authentication resource and chart-rendered worker ScaledObject after the caller-provided ordering edge

#### Scenario: Reject an unconfirmed external KEDA path
- **WHEN** KEDA installation is disabled without confirming that compatible CRDs and controllers exist
- **THEN** Terraform planning SHALL fail before applying the n8n release
