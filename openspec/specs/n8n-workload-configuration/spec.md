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

### Requirement: PostgreSQL connection and health-check timing

The module SHALL expose nullable `postgres_connection_timeout_ms`, `postgres_ping_timeout_ms`, `postgres_ping_interval_seconds`, and `postgres_ping_max_failures_before_recovery` inputs on both managed and external PostgreSQL paths. Non-null values SHALL configure `DB_POSTGRESDB_CONNECTION_TIMEOUT`, `DB_PING_TIMEOUT_MS`, `DB_PING_INTERVAL_SECONDS`, and `DB_PING_MAX_FAILURES_BEFORE_RECOVERY` respectively on main, worker, and webhook application containers. Null SHALL omit the corresponding environment variable and retain application defaults.

The connection timeout SHALL accept whole numbers from 0 through 2147483647 milliseconds, with zero disabling acquisition timeout. Ping timeout and interval SHALL require positive numbers. The recovery threshold SHALL require a whole number at least 1. Documentation SHALL explain the shared connection pool, overlapping acquisition deadlines, and the difference between marking a connection down and starting pool recovery.

#### Scenario: Tune an external database without changing its ownership
- **GIVEN** `create_database = false` and a valid external PostgreSQL configuration
- **WHEN** the caller sets connection timeout to 45000, ping timeout to 15000, ping interval to 5, and recovery threshold to 6
- **THEN** every application pod family SHALL receive those four values under the matching environment names
- **AND** no Azure database resource SHALL be created or modified by those runtime inputs

#### Scenario: Leave runtime database defaults intact
- **WHEN** all four timing inputs are null
- **THEN** the module SHALL emit none of the four environment variables
- **AND** the existing PostgreSQL pool-size value SHALL remain unchanged

#### Scenario: Reject invalid database timing
- **WHEN** connection timeout is negative, fractional, or above 2147483647, a ping timing is zero or negative, or recovery threshold is zero or fractional
- **THEN** Terraform planning SHALL fail at the relevant variable with its allowed range or granularity

#### Scenario: Disable acquisition timeout explicitly
- **WHEN** `postgres_connection_timeout_ms = 0`
- **THEN** all application pod families SHALL receive `DB_POSTGRESDB_CONNECTION_TIMEOUT=0`
- **AND** the independently configured ping timeout SHALL remain in effect

### Requirement: Bull worker timing controls

The module SHALL expose nullable `n8n_queue_worker_lock_duration`, `n8n_queue_worker_lock_renew_time`, and `n8n_queue_worker_stalled_interval` inputs through chart-native worker settings. Each non-null value SHALL be a whole number of milliseconds at least 1000. Null values SHALL preserve the pinned chart defaults of 60000, 10000, and 30000 milliseconds respectively. Effective renewal time SHALL be strictly below effective lock duration, including when one value is omitted. The module SHALL NOT expose disabling stall checks with zero or a maximum-stalled-count control unsupported by the pinned application.

#### Scenario: Compose all worker timing overrides
- **WHEN** duration, renewal, and stalled interval are set to 90000, 15000, and 45000
- **THEN** the rendered workload SHALL contain all three settings with those values
- **AND** no corresponding `QUEUE_WORKER_*` name SHALL be duplicated in a container environment list

#### Scenario: Reject a short lock with default renewal
- **WHEN** duration is 10000 and renewal is null, or effective renewal equals or exceeds effective duration
- **THEN** Terraform planning SHALL fail and explain the effective renewal/duration constraint

#### Scenario: Reject chart-incompatible timing
- **WHEN** any worker timing is fractional or below 1000, including a stalled interval of zero
- **THEN** Terraform planning SHALL fail before Helm schema validation

### Requirement: Execution-data save policies

The module SHALL expose independent `n8n_executions_data_save_on_success` and `n8n_executions_data_save_on_error` inputs accepting only `all` or `none`, plus boolean `n8n_executions_data_save_on_progress` and `n8n_executions_data_save_manual_executions` inputs. Defaults SHALL remain `all`, `all`, false, and true respectively, including when a caller passes null to these non-nullable inputs. Main and worker execution settings SHALL use the chart-native save-policy fields without duplicate environment entries. These settings SHALL remain separate from storage-backend selection and pruning.

#### Scenario: Save failures but omit successful execution data
- **WHEN** success is `none`, error is `all`, progress is true, and manual saving is false
- **THEN** main and worker application containers SHALL receive those four policies exactly once each
- **AND** the selected binary and execution-data backends and pruning values SHALL remain unchanged

#### Scenario: Preserve existing policies
- **WHEN** the caller leaves all save-policy inputs at their defaults
- **THEN** the rendered policies SHALL match the four literals used before this change

#### Scenario: Reject invalid and conflicting save policies
- **WHEN** success or error policy is `first`, or a caller supplies a chart-owned `EXECUTIONS_DATA_SAVE_*` name through `n8n_extra_env`
- **THEN** Terraform planning SHALL fail and direct the caller to the dedicated supported input

### Requirement: Optional application heap ceiling

The module SHALL expose nullable `n8n_node_max_old_space_size_mb`, accepting whole numbers at least 256. When set, it SHALL emit exactly one `NODE_OPTIONS` value containing `--max-old-space-size=<value>` on main, worker, and webhook application containers, without changing their memory limits or task-runner settings. When null, the module SHALL emit no heap-related `NODE_OPTIONS` and SHALL continue accepting caller-supplied `NODE_OPTIONS` through `n8n_extra_env`.

#### Scenario: Set a shared heap ceiling
- **WHEN** the caller sets `n8n_node_max_old_space_size_mb = 768`
- **THEN** each application container SHALL receive `NODE_OPTIONS=--max-old-space-size=768`
- **AND** documentation SHALL require sizing against the smallest application memory limit with non-heap headroom

#### Scenario: Preserve unrelated Node flags
- **WHEN** the heap input is null and `n8n_extra_env` contains `NODE_OPTIONS=--enable-source-maps`
- **THEN** Terraform planning SHALL accept and retain that caller value

#### Scenario: Reject an invalid or shadowed ceiling
- **WHEN** the heap value is fractional or below 256, or it is set alongside caller `NODE_OPTIONS`
- **THEN** Terraform planning SHALL fail rather than truncate, merge, or silently override flags

### Requirement: Caller-managed task-runner launcher configuration

The module SHALL accept nullable `n8n_task_runner_custom_config` containing `config_map_name` and an optional `config_map_key` defaulting to `n8n-task-runners.json`. It SHALL require a valid Kubernetes ConfigMap name and key and enabled task runners. The selected key SHALL replace `/etc/n8n-task-runners.json` in main and worker task-runner sidecars through the chart's custom-config mount. The module SHALL neither create nor read the referenced ConfigMap, and SHALL NOT promise automatic rollout when its contents change.

#### Scenario: Use a custom launcher key
- **GIVEN** task runners are enabled and a caller-owned ConfigMap exists in the effective n8n namespace
- **WHEN** its name and key are supplied
- **THEN** main and worker task-runner sidecars SHALL mount that key as their launcher configuration using a file `subPath`
- **AND** webhook processors SHALL gain no task-runner sidecar or launcher mount

#### Scenario: Keep image-provided configuration
- **WHEN** the custom-config input is null
- **THEN** the module SHALL add no custom launcher configuration and the runner image's file SHALL remain in use

#### Scenario: Reject an unusable reference
- **WHEN** the ConfigMap name/key is empty or malformed, the key traverses a path, or task runners are disabled
- **THEN** Terraform planning SHALL fail at the custom-config input

#### Scenario: Rotate a launcher configuration
- **WHEN** an operator reads the configuration-update procedure
- **THEN** it SHALL require deriving the complete file from the matching runner image and manually restarting main and worker deployments after ConfigMap changes
- **AND** it SHALL explain that `subPath` does not refresh the existing mounted file

### Requirement: Optional pod DNS configuration

The module SHALL accept nullable `n8n_dns_config` with optional nameserver and search lists and options containing a name and optional string value. It SHALL apply the effective DNS configuration to main, worker, and webhook pods without changing DNS policy or cluster DNS resources. Null attributes SHALL be omitted; a null or empty effective object SHALL omit the DNS block.

The module SHALL validate at most 3 plain IP nameservers, at most 32 search domains totaling 2048 characters including spaces, Kubernetes-compatible search names, nonblank option names, and an `ndots` value that is a string integer from 0 through 15. Documentation SHALL distinguish supported relaxed search-name validation from older caller-managed cluster restrictions.

#### Scenario: Lower ndots without changing resolver ownership
- **WHEN** DNS options contain `ndots` with value `1`
- **THEN** all three pod families SHALL receive that option
- **AND** the module SHALL leave DNS policy, CoreDNS, private DNS zones, and default example DNS settings unchanged

#### Scenario: Omit unset DNS fields
- **WHEN** configuration contains only options, including an option such as `edns0` with no value
- **THEN** the pod DNS block SHALL contain no null nameserver/search fields or null option values
- **AND** passing an empty configuration SHALL omit the block entirely

#### Scenario: Reject invalid DNS settings
- **WHEN** a nameserver contains a hostname, port, or CIDR prefix, list limits are exceeded, a search name is invalid, an option name is blank, or an `ndots` option has a missing, fractional, nonnumeric, negative, or above-15 value
- **THEN** Terraform planning SHALL fail with the invalid DNS field identified

### Requirement: Optional Redis queue metrics exporter

The module SHALL expose non-nullable `redis_exporter_enabled`, default false, and `redis_exporter_image`, default `oliver006/redis_exporter:v1.90.0`. When enabled, it SHALL create a single-replica exporter Deployment using `Recreate` and an internal Service on port 9121 in the effective n8n namespace. It SHALL publish pod scrape annotations for `/metrics` without installing a monitoring backend or ServiceMonitor. The feature SHALL be independent of `n8n_metrics_enabled`.

The exporter SHALL use the same effective Redis host, port, TLS selection, optional ACL username, and password Secret name/key as n8n. Caller-owned passwords SHALL NOT be read into Terraform. It SHALL collect exact lengths of the waiting and active Bull lists used by KEDA, without a wildcard key scan. TLS certificate verification SHALL remain enabled. The container SHALL run as non-root UID 59000, with a read-only root filesystem, dropped capabilities, no privilege escalation, resource requests, a memory limit, and liveness/readiness probes.

#### Scenario: Keep the default deployment unchanged
- **WHEN** exporter enablement is false or explicitly null
- **THEN** the module SHALL create no exporter Deployment or Service
- **AND** setting `n8n_metrics_enabled = true` alone SHALL NOT create an exporter

#### Scenario: Observe managed Azure Redis
- **WHEN** the exporter is enabled with module-managed Redis
- **THEN** it SHALL use `rediss://` with the managed hostname and returned port, without credentials in the address
- **AND** its password SHALL reference the same Secret key as n8n
- **AND** its exact observed queue keys SHALL equal KEDA's waiting and active list names

#### Scenario: Observe caller-managed authenticated Redis
- **GIVEN** external Redis uses TLS, an ACL username, and a caller-managed password Secret
- **WHEN** the exporter is enabled
- **THEN** it SHALL use the external host/port, username, and exact caller Secret name/key with certificate verification enabled
- **AND** it SHALL create no duplicate password Secret or read the caller Secret's payload

#### Scenario: Observe unauthenticated Redis without inventing credentials
- **WHEN** an external Redis endpoint has neither username nor password and TLS is disabled
- **THEN** the exporter SHALL use `redis://` and omit authentication environment entries

#### Scenario: Reject an unusable exporter image
- **WHEN** the image reference is empty or contains whitespace
- **THEN** Terraform planning SHALL fail at `redis_exporter_image`

#### Scenario: Keep exporter ownership and security separate
- **WHEN** the exporter is enabled with a caller-managed namespace or AKS cluster
- **THEN** it SHALL target that effective namespace/cluster without creating either layer
- **AND** it SHALL retain the documented pod hardening and internal-only Service without acquiring n8n's Azure workload identity
