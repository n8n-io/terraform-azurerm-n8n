## ADDED Requirements

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
