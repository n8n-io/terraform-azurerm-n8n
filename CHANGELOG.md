# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Ports the applicable parts of `terraform-aws-n8n` 0.4.0 onto this module's
existing Azure foundation (see `openspec/changes/port-aws-040-enhancements/`
for the full per-item applicability assessment and source evidence). Ported
as Azure adaptations, not copied AWS semantics: `db_apply_immediately` and
other AWS maintenance-window controls are excluded (Flexible Server and
Managed Redis have no equivalent argument); AWS sizing values, load-test
measurements, and TPS/pool-sizing rules of thumb are excluded (Azure keeps
its own example sizing and pool-size guidance); the legacy AWS Redis TLS
input name is not introduced (Azure already uses `redis_external_tls_enabled`
against Managed Redis's always-on TLS). Every input below defaults to
preserve existing behavior; none of this release's tuning is applied
automatically.

### Fixed

- **Editor test-mode routing through the managed Ingress.** AGIC renders
  `pathType: Prefix` rules as Application Gateway string-prefix patterns, so
  the `/webhook`, `/form`, and `/mcp` rules also captured `/webhook-test`,
  `/form-test`, and `/mcp-test` and sent test webhooks, Form Trigger test
  mode, and MCP test mode to webhook-processor pods, which answered 404. The
  root Ingress now declares the three test-mode prefixes first, targeting the
  main Service, and exposes them as the new `n8n_test_webhook_path_prefixes`
  output. The caller-owned ingress examples (`split-ingress`,
  `customer-managed-cluster`, `customer-managed-everything`) apply the same
  ordering.
- **TLS certificate rotation via `app_gateway_tls_cert_secret_id` was a
  no-op on an existing gateway.** `azurerm_application_gateway.n8n` listed
  `ssl_certificate` in `lifecycle.ignore_changes`, so a new versioned Key
  Vault secret URI never reached the listener and the gateway kept serving
  the old pinned version. The block is no longer ignored (AGIC references the
  gateway certificate by name and never rewrites it), and
  `docs/tls-rotation.md` now describes the versioned-URI behavior and the
  Key Vault `Self` issuer the self-signed helper actually uses. The
  caller-owned gateways in `examples/split-ingress`,
  `examples/customer-managed-cluster`, and
  `examples/customer-managed-everything` carried the same ignore and were
  corrected too. Callers who rotated out-of-band with
  `az network application-gateway ssl-cert update` should expect one plan
  that repoints the listener at the Terraform-declared URI.

### Added

- **`tests/scripts/preflight-region-check.sh`**: a pre-`apply` check for the
  three region/subscription gaps that otherwise surface 10-20 minutes into a
  live apply: AKS `AvailabilityZoneNotSupported` (VM SKU not offered or
  zone-less in the region), PostgreSQL Flexible Server `ParameterOutOfRange
  'Version' ... in: []` (no versions offered), and Azure Managed Redis
  `InsufficientCapacity`. With no flags it plans the caller's own root
  (`-refresh=false`) and reads the region, VM size, zones, PostgreSQL
  version/SKU, and Redis SKU the plan would request; every value can be
  overridden, and `--probe-redis` creates and deletes a throwaway Managed
  Redis cluster because Azure exposes no capacity API. `docs/troubleshooting.md`
  gained entries for the PostgreSQL and Redis failures, the zone entry now
  covers the zone-less (`''`) variant, and its `az aks list-vm-skus` reference
  (which needs the `aks-preview` CLI extension) is replaced with the core-CLI
  `az vm list-skus`. `tests/scripts/README.md` documents the script; CI runs
  `bash -n`, `shellcheck`, and `--help` against it, and `openspec/init.sh`
  does the same (`shellcheck` when available).
- **Optional single-main queue mode** (`n8n_main_hpa_min_replicas = 1`): a
  Business-compatible topology for licenses without
  `feat:multipleMainInstances`. Clamps the main HPA to 1/1 regardless of
  `n8n_main_hpa_max_replicas`, switches the rollout strategy to `Recreate`
  (the chart's one shared `strategy` value, so worker and webhook-processor
  Deployments roll with `Recreate` too), and
  relaxes the main `PodDisruptionBudget` to `minAvailable = 0`. Multi-main
  (`n8n_main_hpa_min_replicas > 1`) remains the default. See ["Main topology:
  multi-main and single-main"](./README.md#main-topology-multi-main-and-single-main).
  `tests/scripts/smoke-test.sh` now detects the deployed topology from the
  rendered chart resources (not the observed pod count) and branches its
  main-replica, HPA, strategy, PDB, and leader-election checks accordingly.
- PostgreSQL connection and health-check timing: `postgres_connection_timeout_ms`,
  `postgres_ping_timeout_ms`, `postgres_ping_interval_seconds`, and
  `postgres_ping_max_failures_before_recovery`. All four are nullable and
  render through the shared main/worker/webhook application environment;
  unset inputs preserve n8n's existing pinned defaults.
- Bull worker timing: `n8n_queue_worker_lock_duration`,
  `n8n_queue_worker_lock_renew_time`, and `n8n_queue_worker_stalled_interval`,
  merged into the chart's `redis.worker` map. `n8n_queue_worker_lock_renew_time`
  validates against the effective (possibly default) lock duration so a
  configured renewal can never equal or exceed it.
- Execution-save policy inputs `n8n_executions_data_save_on_success`,
  `n8n_executions_data_save_on_error`, `n8n_executions_data_save_on_progress`,
  and `n8n_executions_data_save_manual_executions`, replacing the module's
  previously hardcoded `executions.data` literals with the same default
  values. The four settings are also rendered into the webhook-processor
  containers (`webhookProcessor.extraEnv`): the pinned chart only renders
  `executions.data` on main and worker pods, yet the webhook process decides
  retention when a queued webhook run finishes, so without this the
  configured success/error policy was silently ignored for webhook-triggered
  executions.
- `n8n_node_max_old_space_size_mb`: an opt-in V8 heap ceiling rendered as
  `NODE_OPTIONS=--max-old-space-size=<value>` on every application container
  (main, worker, webhook processor). Rejects a caller-supplied `NODE_OPTIONS`
  in `n8n_extra_env` only while this input is active.
- `n8n_task_runner_custom_config`: references a caller-managed ConfigMap
  mounted read-only at `/etc/n8n-task-runners.json` on the main and worker
  task-runner sidecars via `taskRunners.customConfig`. The module never
  reads or hashes the ConfigMap's contents; rotate it and manually restart
  both deployments.
- `n8n_dns_config`: optional pod `dnsConfig` (nameservers, search domains,
  options) applied identically to main, worker, and webhook-processor pods,
  validated against Kubernetes' supported DNS-config contract. Leaves
  `dnsPolicy` and CoreDNS untouched.
- Optional Redis exporter (`redis_exporter_enabled`, `redis_exporter_image`)
  in the new `observability.tf`: one `Recreate` Deployment plus a `ClusterIP`
  Service on port 9121, reusing the module's effective Redis connection and
  password/ACL references without reading a caller-managed Secret's payload
  or granting it the n8n workload identity. Shares its `bull:jobs:wait` /
  `bull:jobs:active` queue-key list with the existing KEDA worker
  `ScaledObject` triggers so the two can never observe different queue
  names. Independent of `n8n_metrics_enabled`; installs no monitoring
  backend.
- `aks_node_os_disk_size_gb`: optional OS-disk size (GB) for both
  module-managed AKS node pools. AzureRM cycles the affected pool on change
  and does not cordon/drain first — see
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#changing-aks_node_os_disk_size_gb-on-an-existing-cluster-disrupts-workloads).
- `n8n_webhook_url`: an independently overridable webhook base URL, distinct
  from the editor identity (`n8n_domain`). `examples/split-ingress` now
  passes its public webhook host through this input. `N8N_EDITOR_BASE_URL`
  is now also rendered explicitly rather than relying on chart/n8n defaults
  for editor identity. Azure already emitted and reserved `N8N_WEBHOOK_URL`;
  this release does not add the deprecated `WEBHOOK_URL` alias.
- A main-replica-floor passthrough (`n8n_main_hpa_min_replicas`) surfaced in
  all eight examples (`small`, `medium`, `large`, `split-ingress`, and the
  four `customer-managed-*` roots), defaulting to each example's existing
  floor (2, except medium's 3 and large's 6).
- `tests/scripts/check-n8n-chart.sh`: an offline Helm chart-rendering
  regression check with no Azure/Kubernetes-credential dependency, wired
  into CI and `openspec/init.sh`.
- [`docs/manual-azure-qualification.md`](./docs/manual-azure-qualification.md):
  a manual, non-blocking checklist for live Azure lifecycle evidence (fresh
  install, topology transitions, node/disk maintenance, Secret/ConfigMap
  rotation, split-host OAuth/webhook behavior, DNS, Redis TLS/ACL access,
  unavailable-API recovery) that the offline test matrix cannot prove.
- `n8n_credentials_overwrite_secret_ref`: mounts one key from a
  caller-managed Kubernetes Secret read-only on main, worker, and webhook
  processor pods and points `CREDENTIALS_OVERWRITE_DATA_FILE` at it. The module
  accepts only the Secret name and key, so the credential overwrite JSON does
  not enter its Helm values or managed resources. The input defaults to `null`,
  preserving existing behavior.

  When set, plan-time validation rejects `CREDENTIALS_OVERWRITE_DATA` and
  `CREDENTIALS_OVERWRITE_DATA_FILE` in `n8n_extra_env`, the managed
  `credentials-overwrite` volume name in `n8n_extra_volumes`, and the managed
  `/etc/n8n/credentials-overwrite` path in `n8n_extra_volume_mounts`. These
  names remain available through the escape hatches while the new input is
  null, preserving existing configurations.

  n8n reads overwrite data at startup. Rotating the caller-managed Secret does
  not roll pods because the module deliberately does not read or hash the
  payload. Restart the `n8n-main`, `n8n-worker`, and
  `n8n-webhook-processor` deployments manually after rotation.

## [0.1.0] — First release

Initial public release of `terraform-azurerm-n8n`: a single resource-bearing
root module that deploys a production-grade, multi-main [n8n](https://n8n.io)
Enterprise installation on Microsoft Azure. The module's shape mirrors its
[`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) sibling —
one root, `versions.tf`/`variables.tf`/`locals.tf`/`outputs.tf` plus one file
per concern, no nested `module` calls.

### Added

- **Azure Kubernetes Service (AKS)** with the OIDC issuer and workload
  identity enabled, availability-zone-spread node pools, optional API-server
  authorized IP ranges, a configurable node-image upgrade `max_surge`, and an
  autoscaler-owned node count.
- **Multiple n8n main pods** plus dedicated **worker** and
  **webhook-processor** pods (queue mode) — the Enterprise multi-main
  topology — each independently autoscaled (main/webhook HPA, worker KEDA
  `ScaledObject`).
- **PostgreSQL — Flexible Server**, on a delegated subnet with the
  `uuid-ossp` extension allow-listed via `azure.extensions`, or an external
  PostgreSQL endpoint (`create_database = false`).
- **Azure Managed Redis** behind a private endpoint (`NoCluster`, encrypted
  protocol, access-key auth) for the Bull queue backing workers, or an
  external Redis endpoint (`create_redis = false`).
- **Private Azure Blob Storage** for binary and execution data, authenticated
  via AKS workload identity by default, with `database`/`azure` binary-data
  modes and `database`/`azure` execution-data modes.
- **Application Gateway (WAF_v2 by default)** with **AGIC** and **KEDA** for
  ingress, queue-driven worker scaling, and HPA-driven main/webhook-processor
  scaling — or `create_ingress = false` for a caller-owned ingress topology.
- **Azure Key Vault**-backed TLS for the App Gateway listener via a single
  BYO-secret contract (`var.app_gateway_tls_cert_secret_id`), paired with
  `var.app_gateway_keyvault_id` for the optional role assignment.
- **Optional public or private Azure DNS** A-records for the canonical domain
  and every additional domain.
- The full n8n runtime, execution, lifecycle, task-runner, logging,
  template, personalization, community-package, and floating-license
  control surface, plus custom image/pull-secret/extra-volume/extra-env
  support and OpenTelemetry/log-streaming observability.
- A main HPA, a webhook HPA, and worker KEDA floors/ceilings tied to Helm
  replica counts, plus an advisory AKS capacity diagnostic.
- `examples/small`, `examples/medium`, `examples/large`, and
  `examples/split-ingress`.
- `modules/tls-letsencrypt/` and `modules/tls-self-signed/` TLS helper
  submodules.
- `docs/redis.md`, `docs/data-storage.md`, `docs/observability.md`,
  `docs/azure-key-vault-external-secrets.md`, `docs/post-deployment.md`,
  `docs/troubleshooting.md`, `docs/destroy-cleanup.md`,
  `docs/tls-rotation.md`.

[Unreleased]: https://github.com/n8n-io/terraform-azurerm-n8n/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/n8n-io/terraform-azurerm-n8n/releases/tag/v0.1.0
