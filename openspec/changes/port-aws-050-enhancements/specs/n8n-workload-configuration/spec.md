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
