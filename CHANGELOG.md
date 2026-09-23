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

Also ports the applicable parts of `terraform-aws-n8n` 0.5.0 onto this
module (see `openspec/changes/port-aws-050-enhancements/` for the full
applicability assessment and source evidence), including its alpha
`n8n_worker_pools` feature (see the **Early Alpha** entry below). Excluded:
the `metrics_server_chart_version` bump (this module installs no
metrics-server; AKS ships one as a managed addon), the RDS
`db_engine_version` bump (PostgreSQL Flexible Server version currency is
tracked separately), and `docs/istio-ingress.md` (`examples/split-ingress`
already documents the `create_ingress = false` contract).

**What moves on apply** for a caller who changes nothing but the module
source pin: `helm_release.n8n` plans an in-place `version` change
(`1.10.0` → `1.11.0`); the chart's only two functional changes at that
bump (a KEDA `listName` default and an ingress-webhook `/mcp/` route) are
both inert here (this module sets `listName` explicitly, and
`ingress.enabled` defaults `false` and is never set by this module). The
`kubernetes` provider bump (`~> 2.0` → `~> 3.0`) plans no resource changes,
only the existing cosmetic "Deprecated Resource" warnings on unversioned
resource types already noted in `AGENTS.md`. Enabling
`redis_exporter_enabled` for the first time now pulls a digest-pinned
image instead of a floating tag.

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
- **`n8n_image_pull_secrets` accepted Secret names Kubernetes would reject.**
  Each entry was bounded to 253 characters total but not to 63 characters
  per dot-separated label, the actual Kubernetes DNS-1123 subdomain rule.
  Values that were always going to fail at apply now fail at plan.
  `examples/split-ingress`'s `webhook_subdomain` gets the same 63-character
  bound folded into its existing single-label validation.
- **`pg_backup_retention_days` failed on an explicit `null`** instead of
  falling back to its default of 7 (missing `nullable = false`).
- **checkov never evaluated the disabled-by-default Redis exporter.**
  checkov answers every check on a `count = 0` resource with UNKNOWN and
  drops it from the report, and `redis_exporter_enabled` is `false` in
  every default and example, so `kubernetes_deployment_v1.redis_exporter`
  and its Service drew zero findings under any prior CI run.
  `tests/scripts/check-checkov.sh` now runs a second pass with
  `tests/checkov/opt-in.tfvars` and fails if that pass does not reach both
  resources, closing the same class of gap `terraform-aws-n8n` found and
  fixed in its own 0.5.0. `AGENTS.md`'s prior diagnosis (that checkov
  ignores `_v1`/`_v2` Kubernetes resource types) was incorrect and is
  corrected.

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
- `n8n_worker_extra_env`: worker-only environment variables (chart
  `queueMode.workerExtraEnv`), reaching the chart's own default worker
  deployment and, since the **Early Alpha** `n8n_worker_pools` entry below,
  every labelled pool as well. Reuses `n8n_extra_env`'s reserved-name guard,
  and `n8n_credentials_overwrite_secret_ref`'s conflict check now also
  covers this input.
- `blob_delete_retention_days`: optional soft-delete retention window
  (1-365 days) for the module-managed Blob storage account
  (`blob_properties.delete_retention_policy` and
  `container_delete_retention_policy`). The nearest Azure analog to AWS's
  `s3_force_destroy`. One-way from Terraform's side: reverting to `null`
  after an apply plans no change (azurerm treats `blob_properties` as
  Optional+Computed); disable soft delete out of band if needed. See
  [`docs/deletion-safety.md`](./docs/deletion-safety.md) for how AWS's
  four RDS deletion-time controls map onto PostgreSQL Flexible Server: a
  caller-owned `CanNotDelete` management lock with `prevent_destroy` is
  the deletion-protection analog, and a dropped server's backup survives
  5 days only.
- `postgres_server_id` and `storage_account_id` outputs (null on the
  respective `create_* = false` path), so a caller can scope an
  `azurerm_management_lock` to the module-managed server or account.
- `tests/scripts/chart-values-diff.sh` and `tests/scripts/lib/tf-defaults.sh`:
  diffs the pinned n8n chart's `values.yaml` against a candidate version
  via `helm show values`, sharing a `read_default` helper with the new
  version-drift script below.
- `tests/scripts/check-version-drift.sh`, wired into a report-only
  `version-drift` CI job (runs with the rest of the workflow on push,
  pull request, and manual dispatch): currency for every Terraform
  provider, the CI toolchain, and the pinned n8n chart against public
  release feeds, and `aks_kubernetes_version` against Azure's published
  AKS supported-versions page (not `endoflife.date`, which has no
  AKS-specific entry). See [`docs/versioning.md`](./docs/versioning.md)
  for the full pin inventory.
- `scripts/check-example-parity.sh`, wired into a new `example-parity` CI
  job: fails when an example declares a variable name absent from
  `examples/small` and from that example's allowlist.
- markdownlint CI job (`.markdownlint.yml`) over `README.md`, `AGENTS.md`,
  `docs/**/*.md`, and every example/submodule README.
- **`n8n_worker_pools` (EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE)**:
  labelled n8n worker pools, one per entry, each rendered by the chart's
  `queueMode.workerGroups` as a worker Deployment carrying
  `N8N_WORKER_POOL_NAME=<name>` plus a KEDA `ScaledObject` watching that
  pool's own `jobs-<name>` queue. Per-pool replica bounds, concurrency,
  resources, and extra env each fall back to the module-wide worker
  setting when null. Declaring any pool also emits
  `N8N_WORKER_POOLS_ENABLED=true` on every pod. Default `[]`, which omits
  `queueMode.workerGroups` from the Helm values entirely rather than
  sending an empty list, so a deployment that declares no pool sees no
  `helm_release` diff at all. Pool names are validated at plan to the
  pattern n8n itself only warns about, capped at 43 characters because the
  ScaledObject name `n8n-worker-<name>` must fit KEDA's 54, and `"default"`
  is refused since `jobs-default` is not the default queue. The node
  capacity check in `scaling.tf` now counts every pool at its ceiling.

  **Upstream dependency, alpha on both sides.** n8n's own worker pools
  feature is alpha, and the chart support for it
  (`queueMode.workerGroups`, n8n-io/n8n-hosting#189) is merged to the
  chart's `preview/worker-pools` branch but not released to a numbered
  chart version, so a chart that predates it accepts the key and silently
  renders nothing. A `lifecycle.precondition` on `helm_release.n8n` fails
  the plan when the pinned `n8n_chart_version` is a numbered release,
  since no numbered release carries the feature yet (a prerelease version
  is taken at the caller's word, which is how a preview build installs;
  the new `n8n_worker_pools_chart_verified` input lets a caller attest a
  numbered release instead, for a private mirror already verified to carry
  the feature), and a validation on `n8n_image_tag` fails the plan when
  pools are declared and the pinned tag is below `2.39.0`, the first n8n
  release that reads the pool variables (the module's own default,
  `2.35.0`, predates it, so declaring a pool also means pinning the image).
  Each pool's KEDA `ScaledObject` authenticates through the same
  `TriggerAuthentication` CR the default worker's scaler references; only
  `enableTLS` goes into scaler metadata. The `feat:workerPools` licence entitlement is
  required as well, and its absence is not silent: a worker started with
  `N8N_WORKER_POOL_NAME` it is not licensed for exits 1, so the pool pods
  crash-loop and the Helm release rolls back, failing the apply. Terraform
  cannot see entitlements at plan. `tests/scripts/verify-worker-pools.sh`
  counts the rendered pools after a live apply, which is the only place
  the silent case (a chart too old to render pools) is visible. A pool
  started at `min_replicas = 0` cannot be assigned to a project until it
  has been raised to 1 once, since n8n only offers a pool for assignment
  while one of its workers is registered; the stored assignment then
  survives a later scale-down. Documented on the input and in the example.

- `examples/worker-pools/` (EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE):
  topology variant of `small` running three pools beside the default
  worker deployment, sized so `aks_node_count_max` clears their combined
  ceiling. `n8n_chart_version` is a required input there, since the module
  default renders no pools, and its README documents the official
  preview-build path and the private-mirror fallback plus an end-to-end
  routing test. Covered by `scripts/check-example-parity.sh`, whose
  allowlist explains the chart inputs it declares beyond `small`'s. Draft
  until the chart and n8n releases both ship.

- `tests/scripts/verify-worker-pools.sh`: post-apply check for
  `n8n_worker_pools`. Reads the pool names and namespace from the
  example's outputs and asserts, per pool, the Deployment and ScaledObject
  exist and are labelled, the ScaledObject is `READY=True`, its triggers
  watch `jobs-<pool>` with the default worker's `enableTLS` flag and
  `TriggerAuthentication` reference (and no credential in trigger
  metadata), pods carry `N8N_WORKER_POOL_NAME`, and the mains carry
  `N8N_WORKER_POOLS_ENABLED`.
- **`n8n_worker_keda_pause` and `n8n_worker_keda_paused_replica_count`**
  (chart `keda.worker.pause` / `pausedReplicaCount`, n8n-hosting #177).
  `pause = true` annotates the worker `ScaledObject` with
  `autoscaling.keda.sh/paused` so workers hold their current count; a
  `paused_replica_count` (0 included) adds `paused-replicas` and drains
  to that count while jobs wait in Redis. A count set without `pause`
  draws a plan-time warning (`check.worker_keda_paused_replica_count_requires_pause`)
  since the chart ignores it. The chart's matching
  `keda.webhookProcessor.pause` is deliberately not exposed: this module
  scales webhook processors with its own HPA (`scaling.tf`), so no
  webhook `ScaledObject` exists for the annotation to land on.
  `tests/scripts/smoke-test.sh` skips the worker-floor assertion while the
  `ScaledObject` is paused.

### Changed

- **`kubernetes` provider requirement bumped to `~> 3.0`** (was `~> 2.0`),
  across all 12 `versions.tf` files (root, `modules/controllers`, all
  eight examples). Verified live-plan-shape-safe against `examples/small`
  under mocked providers: only the two known cosmetic "Deprecated
  Resource" warnings on unversioned resource types, no resource
  replacement.
- **`time` provider requirement bumped to `~> 0.14`** (was `~> 0.12`).
  Additive; no plan diff.
- **Default `n8n_chart_version` bumped to `1.13.0`** (was `1.11.0`; the
  AWS sibling pins `1.12.0`, so this module now leads). Two chart changes
  reach every deployment on the first `helm upgrade`:
  - **Worker `spec.replicas` is now KEDA-owned** (n8n-hosting #201). The
    chart omits the field once a worker `ScaledObject` renders, which this
    module's configuration always does. Helm's three-way merge removes the
    field it used to manage, so the worker Deployment drops to 1 replica
    until the KEDA-created HPA restores `minReplicas` (measured at about
    5 s on a live `examples/small` upgrade from `1.11.0` with a floor of
    2, during the same rollout that moved worker pods onto the new chart's
    pod template). Invisible at the default `n8n_worker_keda_min_replicas = 1`; a
    one-time dip for higher floors. After that, a Helm upgrade at the
    floor no longer writes a static count back over KEDA's decision.
    Webhook processors are unaffected: the module's own HPA is outside the
    chart's view, so the chart keeps rendering `webhookProcessor.replicaCount`.
  - **Main pods lose the task-runner sidecar** (n8n-hosting #179). In queue
    mode n8n offloads manual executions to workers and starts no broker on
    main, so the chart renders the sidecar, its env, and the launcher
    ConfigMap mount on workers only. Main pods roll once to drop the
    container; `n8n_task_runner_*` resources now apply to workers alone,
    and `check.autoscaling_maxima_fit_aks_capacity` no longer adds the
    sidecar request to the main ceiling (modeled peak demand falls by
    `n8n_main_hpa_max_replicas x n8n_task_runner_cpu_request`).
  Inert here: the chart's `image.tag` default moving from floating
  `stable` to its appVersion (this module always sets `n8n_image_tag`),
  and the `keda` block gaining a typed schema (this module's values
  already pass it; `tests/scripts/check-n8n-chart.sh` renders every
  fixture with schema validation on). `queueMode.workerGroups` is still
  unreleased, so `n8n_worker_pools` callers stay on the `1.11.0`-based
  preview chart and do not pick up either change until a new preview
  build is cut.
- CI toolchain currency: `TF_VERSION` `1.16.2` (was `1.15.1`),
  `TFLINT_VERSION` `v0.64.0` (was `v0.53.0`), pinned `CHECKOV_VERSION`
  `3.3.17` (was unpinned via `bridgecrewio/checkov-action@v12`'s own
  floating tag), `azure/setup-helm` pinned to `v4.3.0`.
- `n8n_extra_env` and `n8n_worker_extra_env` now reject
  `N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME`, which
  `n8n_worker_pools` owns. A caller who was setting either through the
  escape hatch fails at plan on upgrade rather than silently: set through
  `n8n_extra_env` the pool name would put every main, worker, and webhook
  pod into one pool, and the flag alone would switch routing on with no
  pool to route to. Declare the pool with `n8n_worker_pools` instead.

### Security

- `redis_exporter_image`'s default is now pinned by digest as well as tag
  (`oliver006/redis_exporter:v1.90.0@sha256:a129504e...`, the multi-arch
  index). The tag alone was mutable, so the default `IfNotPresent` pull
  policy could keep running a superseded image on a node that already had
  it cached; the digest makes the reference immutable. Deployments with
  `redis_exporter_enabled = true` roll the exporter pod once on the next
  apply; nothing changes for the default `false`.

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
