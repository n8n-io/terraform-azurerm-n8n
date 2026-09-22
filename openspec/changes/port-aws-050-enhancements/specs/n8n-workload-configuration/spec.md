## ADDED Requirements

### Requirement: Worker-only extra environment variables

The module SHALL expose nullable `n8n_worker_extra_env`, defaulting to an
empty list, mapped to the chart's `queueMode.workerExtraEnv`. Entries SHALL
render only on the worker Deployment, never on main or webhook-processor
containers. The module SHALL apply the same reserved-prefix and
C_IDENTIFIER validation `n8n_extra_env` already applies. When
`n8n_credentials_overwrite_secret_ref` is set, the module SHALL reject
`CREDENTIALS_OVERWRITE_DATA` and `CREDENTIALS_OVERWRITE_DATA_FILE` in
`n8n_worker_extra_env` in addition to the existing `n8n_extra_env` check.

#### Scenario: Set worker-only environment variables

- **WHEN** `n8n_worker_extra_env` contains a valid entry
- **THEN** the value SHALL render only in the worker Deployment's
  `queueMode.workerExtraEnv` and SHALL NOT appear on main or
  webhook-processor containers

#### Scenario: Reject a reserved or malformed worker entry

- **WHEN** `n8n_worker_extra_env` contains a module-managed prefix name or
  an invalid environment-variable name
- **THEN** the module SHALL fail at plan time with the same guard
  `n8n_extra_env` applies

#### Scenario: Reject a worker-side credential-overwrite conflict

- **GIVEN** `n8n_credentials_overwrite_secret_ref` is set
- **WHEN** `n8n_worker_extra_env` contains `CREDENTIALS_OVERWRITE_DATA` or
  `CREDENTIALS_OVERWRITE_DATA_FILE`
- **THEN** the module SHALL fail at plan time

### Requirement: Labelled worker pools (early alpha)

The module SHALL expose non-nullable `n8n_worker_pools`, defaulting to an
empty list, mapped one-to-one onto the chart's `queueMode.workerGroups`
(EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE). Each entry SHALL render one
worker Deployment carrying `N8N_WORKER_POOL_NAME=<name>` and one KEDA
`ScaledObject` watching that pool's own `jobs-<name>` queue, with per-pool
replica bounds, concurrency, resources, and extra env falling back to the
module-wide worker settings when null. When the list is empty the module
SHALL omit `queueMode.workerGroups` entirely. When it is non-empty the module
SHALL append `N8N_WORKER_POOLS_ENABLED=true` to the shared `config.extraEnv`.
`N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME` SHALL be reserved names
in `n8n_extra_env`, `n8n_worker_extra_env`, and every pool's `extra_env`.

Each pool's `ScaledObject` SHALL authenticate to Redis through the same
`TriggerAuthentication` the default worker's scaler references
(`authenticationRef.name` set when Redis has a password or username; the
`authenticationRef` key omitted otherwise, since the chart schema rejects an
empty name) and SHALL carry `enableTLS` in trigger metadata unconditionally,
matching the default worker's triggers. The module SHALL NOT place Redis
credentials (`passwordFromEnv`, `username`) in pool scaler metadata.

Pool names SHALL be validated at plan time to 1-43 lowercase DNS-label
characters (so `n8n-worker-<name>` fits KEDA's 54-character ScaledObject
cap), SHALL be unique, and SHALL NOT be `default`.

#### Scenario: Declare pools

- **WHEN** `n8n_worker_pools` contains two valid entries
- **THEN** the Helm values SHALL contain exactly two `queueMode.workerGroups`
  entries whose `name` and `poolName` equal each pool's name, and
  `config.extraEnv` SHALL contain `N8N_WORKER_POOLS_ENABLED=true`

#### Scenario: No pools declared

- **WHEN** `n8n_worker_pools` is empty
- **THEN** the Helm values SHALL contain no `queueMode.workerGroups` key and
  no `N8N_WORKER_POOLS_ENABLED` entry

#### Scenario: Pool scaler reuses the default worker's authentication

- **GIVEN** Redis authentication is enabled
- **WHEN** a pool is declared
- **THEN** its `keda.authenticationRef.name` SHALL equal the module's
  TriggerAuthentication name and its `keda.triggerMetadata` SHALL be exactly
  `{ enableTLS = "<true|false>" }`

#### Scenario: Pool scaler on unauthenticated Redis

- **GIVEN** Redis has no password and no username
- **WHEN** a pool is declared
- **THEN** its `keda` block SHALL contain no `authenticationRef` key and
  `enableTLS` SHALL still be rendered

#### Scenario: Reject an invalid pool name

- **WHEN** a pool name contains uppercase, an underscore, a trailing hyphen,
  exceeds 43 characters, duplicates another, or is `default`
- **THEN** the module SHALL fail at plan time

### Requirement: Worker pool chart and image pairing guards

The module SHALL fail the plan (via a `lifecycle.precondition` on the n8n
Helm release) when `n8n_worker_pools` is non-empty and `n8n_chart_version`
is a numbered release not attested by `n8n_worker_pools_chart_verified`; a
SemVer prerelease version SHALL pass on the version string alone. The module
SHALL fail the plan (via a validation on `n8n_image_tag`) when
`n8n_worker_pools` is non-empty and `n8n_image_tag` carries a semantic
version below 2.39.0.

#### Scenario: Numbered chart with pools

- **WHEN** `n8n_worker_pools` is non-empty, `n8n_chart_version = "1.11.0"`,
  and `n8n_worker_pools_chart_verified = false`
- **THEN** the plan SHALL fail on the Helm release precondition

#### Scenario: Prerelease chart with pools

- **WHEN** `n8n_worker_pools` is non-empty and
  `n8n_chart_version = "1.11.0-preview.workerpools.1"`
- **THEN** the precondition SHALL pass

#### Scenario: Old image with pools

- **WHEN** `n8n_worker_pools` is non-empty and `n8n_image_tag = "2.38.1"`
  (or the module default `2.35.0`)
- **THEN** the plan SHALL fail on the `n8n_image_tag` validation

#### Scenario: Old image without pools

- **WHEN** `n8n_worker_pools` is empty and `n8n_image_tag = "2.30.0"`
- **THEN** the `n8n_image_tag` pool floor SHALL NOT apply

## MODIFIED Requirements

### Requirement: Optional Redis queue metrics exporter

The module SHALL expose non-nullable `redis_exporter_enabled`, default
false, and `redis_exporter_image`, default
`oliver006/redis_exporter:v1.90.0` pinned by digest as well as tag. When
enabled, it SHALL create a single-replica exporter Deployment using
`Recreate` and an internal Service on port 9121 in the effective n8n
namespace. It SHALL publish pod scrape annotations for `/metrics` without
installing a monitoring backend or ServiceMonitor. The feature SHALL be
independent of `n8n_metrics_enabled`.

The exporter SHALL use the same effective Redis host, port, TLS selection,
optional ACL username, and password Secret name/key as n8n. Caller-owned
passwords SHALL NOT be read into Terraform. It SHALL collect exact lengths
of the waiting and active Bull lists used by KEDA, without a wildcard key
scan. TLS certificate verification SHALL remain enabled. The container
SHALL run as non-root UID 59000, with a read-only root filesystem, dropped
capabilities, no privilege escalation, resource requests, a memory limit,
and liveness/readiness probes. The default image reference SHALL remain
immutable under the default `IfNotPresent` pull policy because it is
pinned by digest, not tag alone.

#### Scenario: Keep the default deployment unchanged

- **WHEN** exporter enablement is false or explicitly null
- **THEN** the module SHALL create no exporter Deployment or Service

#### Scenario: Pin the default image immutably

- **WHEN** `redis_exporter_image` is left at its default
- **THEN** the rendered image reference SHALL include both the `v1.90.0`
  tag and its resolved digest

#### Scenario: Observe managed Azure Redis

- **WHEN** the exporter is enabled with module-managed Redis
- **THEN** it SHALL scrape over TLS using the managed access key without a
  caller-supplied password

#### Scenario: Reject an unusable exporter image

- **WHEN** the image reference is empty or contains whitespace
- **THEN** the module SHALL fail at plan time
