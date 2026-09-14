## Context

See [proposal.md](proposal.md) for motivation and scope. The source is the tagged AWS `0.3.0..0.4.0` diff, not AWS HEAD or features from earlier releases. GitHub marks `0.4.0` as a prerelease, published on 2026-09-14.

Azure currently pins chart `1.10.0`, n8n `2.35.0`, and AKS `1.35`. The reviewed lock file selects AzureRM `4.81.0`. Its resource-bearing root already supports customer-managed infrastructure, PostgreSQL and Redis Secret references, Blob workload identity, and credential overwrites. Its broad `DB_`, `QUEUE_`, and `EXECUTIONS_` collision guards already block the raw environment names behind the proposed tuning controls.

User decisions:

1. Include optional Business-compatible single-main queue mode; keep multi-main as the default.
2. Add controls without adopting AWS sizing defaults or measured performance claims as Azure recommendations.
3. Complete implementation using offline tests, static checks, and Helm rendering, plus a documented manual Azure checklist. Live deployment is separate qualification.

## Goals and non-goals

**Goals:** Reuse Azure's ownership and effective-connection contracts, prefer chart-native configuration where available, and verify both Terraform values and the manifests Helm actually renders.

**Non-goals:** No resource-module split, provider configuration, provider/chart/application version bump, new cloud service topology, AWS maintenance switches, monitoring backend, Redis key-prefix feature, OS-disk-type feature, per-pool disk controls, chart fork, or automatic rollout on caller-managed payload rotation. Do not broaden Business-license claims to unrelated Enterprise features.

## Release applicability assessment

| AWS 0.4.0 change | Decision | Azure action and reason |
| --- | --- | --- |
| Single-main license support, HPA clamp, rollout/PDB safeguards | Port | Main minimum selects topology. Include the capacity-model and smoke-test changes, not just `multiMain.enabled`. |
| Main-floor passthrough in all examples | Adapt | Cover Azure's eight existing examples. Preserve floors of 2, 3, and 6 for small/default, medium, and large. |
| `node_disk_size` | Adapt | Add `aks_node_os_disk_size_gb` to both module-owned AKS pools. Use AzureRM rotation semantics, not EKS replacement or 20 GiB/100 GiB assumptions. |
| Database health-check timeout, interval, recovery threshold | Adapt naming, port behavior | Add `postgres_ping_timeout_ms`, `postgres_ping_interval_seconds`, and `postgres_ping_max_failures_before_recovery`, matching Azure's existing `postgres_pool_size` naming. |
| Database connection timeout | Adapt naming, port behavior | Add `postgres_connection_timeout_ms`; document its interaction with ping acquisition. |
| Bull lock duration, renewal, stalled interval | Port | Use one chart-native `redis.worker` map, numeric values, and effective renewal validation. |
| Four execution-data save controls | Port | Replace Azure's literals in `executions.data`, not the inaccurate `config.data` path used in some AWS prose. |
| Execution-save environment collision fix | Already present | Azure reserves the whole `EXECUTIONS_` family. Retain it and add regression assertions; do not claim a new breaking validation change. |
| Task-runner custom launcher ConfigMap | Port | Reference only the ConfigMap name/key; mount through `taskRunners.customConfig`. |
| Pod DNS configuration | Port with Azure guidance | Keep `null` by default. Explain resolver search behavior without copying AWS endpoint dot counts, query multipliers, or measured gains. |
| V8 heap ceiling and conditional `NODE_OPTIONS` guard | Port | One opt-in value for application containers; keep unrelated caller `NODE_OPTIONS` valid when unset. |
| Redis exporter | Adapt | Reuse `local.redis_connection`, Azure password references, ACL username, namespace and AKS ordering. Keep it opt-in. |
| Current webhook environment name | Already present | Azure already emits and reserves `N8N_WEBHOOK_URL` and explicitly tests that deprecated `WEBHOOK_URL` is absent. Do not copy AWS's legacy alias. |
| Editor URL fix | Adapt and close existing gap | Explicitly set `N8N_EDITOR_BASE_URL`; add `n8n_webhook_url`, which the Azure ingress spec promises but current code does not expose. Wire split ingress to it. |
| Credential-overwrite Secret reference | Already present | Preserve `n8n_credentials_overwrite_secret_ref`, mount/rotation semantics, and its existing tests. No second implementation or ownership change. |
| `db_apply_immediately`, Redis wiring and explicit-false state fix | Exclude | Reviewed AzureRM Flexible Server and Managed Redis resources have no equivalent `apply_immediately` argument. PostgreSQL maintenance windows are not equivalent. |
| Large-tier pool, Redis, worker, disk and PgBouncer resizing | Exclude values | Keep Azure example values, including large's two PgBouncer replicas and current connection pool size. Record measurement questions, not unverified replacements. |
| Database TPS rule, S3 comparison, pool-sizing and pruning guidance | Adapt guidance only | Explain lazy per-process pools, aggregate budgets, measured constraints, and retention limitations. Do not transplant AWS TPS bands, S3 speed comparisons, deletion-rate claims, or Redis ceilings as Azure evidence. |
| Customer-managed Redis TLS documentation correction | Already correct contract | Azure uses `redis_external_tls_enabled`, distinct from managed Redis's always-on TLS. Check documentation against that contract; do not introduce AWS names or transit-encryption modes. |
| Release bookkeeping, contributors and AWS tooling changes | Exclude | These do not change Azure deployment behavior. Add only the local verification integration needed for this change. |

## Decisions

### 1. Keep the existing root and ownership graph

Extend `variables.tf`, `locals.tf`, `n8n.tf`, `aks.tf`, and `scaling.tf`. Add only `observability.tf` for the new concern. Reuse existing providers; do not introduce another nested module.

The exporter must depend on the namespace and the managed AKS warm-up gate even when `create_namespace = false`. Reference the managed Redis Secret resource when it exists, and preserve the private endpoint/DNS ordering needed by the managed Redis path. Caller-managed namespace, cluster, and Secret prerequisites remain the caller's responsibility. Do not make n8n or KEDA depend on the exporter.

**Alternative rejected:** Copying AWS resources and selectors would recreate connection logic, use the wrong password input, and lose Azure's first-apply ordering.

### 2. Derive topology from the existing main minimum

Use `n8n_main_hpa_min_replicas > 1` as the only topology selector. Allow positive whole-number minimums, retaining the default of 2 and the existing minimum/maximum validation. Do not add a second switch that can contradict the replica input.

| Setting | Minimum = 1 | Minimum > 1 |
| --- | --- | --- |
| `multiMain.enabled` | false | true |
| Effective main HPA maximum | 1, even when caller sets a higher maximum | Caller maximum |
| Main deployment floor | `replicaCount = 1` | `multiMain.replicas = minimum` |
| Main strategy override | `type = Recreate`, `rollingUpdate = null` | Omit override; retain chart strategy |
| Main PDB | enabled, `minAvailable = 0` | enabled, `minAvailable = 1` |
| Queue mode, workers, webhook processors | Retained | Retained |
| Floating-license detach default | false | false |

Set the active chart replica path explicitly rather than depending on a chart default for single-main. The pinned schema allows `multiMain.replicas = 1` when multi-main is disabled, but requires at least 2 when enabled. Test this conditional behavior with Helm schema validation on.

Use the effective ceiling in both the CPU calculation and its warning text. Leave worker/webhook scaling ownership unchanged. A PDB governs voluntary eviction, not Deployment upgrades. `Recreate` avoids ordinary upgrade surges, but is not protection against overlap after manual deletion, node loss, or forced operations.

License documentation must distinguish topology from feature entitlements. A license without `feat:multipleMainInstances` can use single-main; it does not gain `feat:binaryDataAz`, `feat:executionDataAz`, or external-secrets rights. For a new Business deployment without Azure storage entitlements, document a root-module example selecting `database` for binary and execution data and `["database"]` for available binary modes. Do not remove historical Azure modes from an existing deployment before its retained objects are addressed. A main-floor passthrough alone does not make the default Azure examples compatible with every Business license.

**Alternatives rejected:** Rejecting a higher configured maximum in single-main makes callers change two inputs for one decision. Disabling multi-main without changing the HPA, strategy, and PDB can create duplicate scheduled work or block maintenance.

### 3. Add PostgreSQL runtime inputs, not service maintenance controls

The four nullable inputs configure n8n on both managed and external PostgreSQL paths. They must not be included in the ignored-managed-database-tuning diagnostic.

| Azure input | Environment variable | Null behavior | Non-null validation |
| --- | --- | --- | --- |
| `postgres_connection_timeout_ms` | `DB_POSTGRESDB_CONNECTION_TIMEOUT` | Omit; pinned n8n default 20000 ms | Whole number, 0 through 2147483647; zero disables acquisition timeout |
| `postgres_ping_timeout_ms` | `DB_PING_TIMEOUT_MS` | Omit; pinned default 5000 ms | Positive number |
| `postgres_ping_interval_seconds` | `DB_PING_INTERVAL_SECONDS` | Omit; pinned default 2 seconds | Positive number |
| `postgres_ping_max_failures_before_recovery` | `DB_PING_MAX_FAILURES_BEFORE_RECOVERY` | Omit; pinned default 3 | Whole number at least 1 |

Render strings through shared `config.extraEnv` on main, worker, and webhook application containers. Keep the `DB_` guard. Preserve the AWS public numeric contract for the two ping timing inputs rather than inventing new granularity limits.

Explain that the health check acquires from the same process pool used by application traffic. Connection acquisition is subject to both the connection timeout and the ping timeout; whichever active timeout expires first bounds acquisition. A higher recovery threshold does not stop the first failed ping from marking the connection down. Raising timers does not solve pool saturation and delays detection of real failures.

Update `postgres_pool_size` guidance: it is a lazy per-process maximum, not one permanently open connection per workflow. Budget against effective main, worker, and webhook maxima and the database or PgBouncer limits. Do not change the value of any pool-size input or example.

**Alternative rejected:** Mapping AWS `apply_immediately` onto PostgreSQL maintenance windows or a CLI provisioner would offer different semantics under the same promise.

### 4. Use chart-owned paths for Bull and execution-save settings

Add nullable `n8n_queue_worker_lock_duration`, `n8n_queue_worker_lock_renew_time`, and `n8n_queue_worker_stalled_interval`. Each is a whole number of milliseconds at least 1000, matching the pinned chart schema. Build one inner `redis.worker` map with only non-null keys. A shallow merge of three separate `worker` maps would lose values.

Validate `effective renewal < effective duration` on the renewal variable only, using pinned defaults of 10000 and 60000 ms when absent. This rejects a duration of 10000 with an unset renewal interval. Keep default stalled checking at 30000 ms by omission. Do not expose stalled interval zero, which the chart rejects, or `QUEUE_WORKER_MAX_STALLED_COUNT`, which n8n v2 no longer uses as a runtime control.

Add non-nullable execution-save inputs with existing defaults:

- `n8n_executions_data_save_on_success = "all"` and `n8n_executions_data_save_on_error = "all"`, accepting only `all` or `none`.
- `n8n_executions_data_save_on_progress = false` and `n8n_executions_data_save_manual_executions = true`.

Map them to `executions.data.saveOnSuccess`, `saveOnError`, `saveOnProgress`, and `saveManualExecutions`. The pinned chart renders these execution settings on main and worker application containers; do not promise a new webhook-only execution-save path. Retain workflow-level override semantics in the documentation.

**Alternative rejected:** Duplicating `QUEUE_WORKER_*` or execution-save entries through shared `extraEnv` conflicts with chart-rendered environment entries. Retain Azure's existing broad guards instead of copying AWS's narrower exact-name list.

### 5. Keep heap, runner, and DNS controls opt-in

**Heap:** Add nullable `n8n_node_max_old_space_size_mb`, a whole number at least 256. When set, render exactly one `NODE_OPTIONS=--max-old-space-size=<value>` on each application container. Reject caller `NODE_OPTIONS` only while this input is active. Do not parse or merge arbitrary Node flags. Task-runner sidecars are not covered by application `config.extraEnv`. Document headroom against the smallest application memory limit without promising a fixed V8 default or treating a larger heap as a leak fix.

**Runner configuration:** Add nullable `n8n_task_runner_custom_config = object({ config_map_name = string, config_map_key = optional(string, "n8n-task-runners.json") })`. Validate a Kubernetes ConfigMap name, a valid non-path-traversing key, and enabled task runners. Map it to `taskRunners.customConfig`. The ConfigMap lives in the effective n8n namespace; the caller creates it before installation. The module neither reads it nor hashes its contents. Main and worker runner sidecars mount the full replacement launcher file at `/etc/n8n-task-runners.json` using `subPath`; webhook processors have no runner sidecar. Document deriving the file from the matching runner image, preserving restrictive allow-lists, and manually restarting main and worker after changes.

**DNS:** Add nullable `n8n_dns_config` with optional nameserver/search lists and options containing a name and optional string value. Strip null attributes, including option values; omit the chart block for null or an empty effective object. Apply top-level `dnsConfig` to all three pod families. Leave `dnsPolicy` unchanged. Validate at most 3 plain IP nameservers, at most 32 search domains totaling 2048 characters including separating spaces, valid search names, nonblank option names, and `ndots` as a string integer from 0 through 15. Use the supported Kubernetes search-name rules and document relaxed-search compatibility for older caller-managed clusters. Other options remain available without an invented allow-list.

Explain that lowering `ndots` changes when dotted relative names use search suffixes. AKS private DNS and in-cluster names must be checked with the chosen setting. Do not assume four search domains on every cluster or change example resolver defaults.

**Alternatives rejected:** Auto-generating launcher content would couple Terraform to image internals. Changing CoreDNS or `dnsPolicy` is unnecessary. Applying AWS heap or DNS tuning by default would silently change Azure workloads without measurements.

### 6. Export Redis metrics through the effective connection

Add non-nullable `redis_exporter_enabled = false` and `redis_exporter_image = "oliver006/redis_exporter:v1.90.0"`. Reject blank or whitespace-containing image references. The image override supports caller mirrors or digest references but must retain the CA bundle and work under UID 59000. Document that any private-registry pull access is caller-provided; do not reuse the n8n workload identity to grant exporter privileges.

Create one `kubernetes_deployment_v1` and one `kubernetes_service_v1` only when enabled. Use one replica and `Recreate`, a `ClusterIP` Service on port 9121, and pod scrape annotations for `/metrics`. Prometheus discovery and any ServiceMonitor remain caller-owned. Exporter enablement and `n8n_metrics_enabled` are independent.

- Derive `REDIS_ADDR` from `local.redis_connection.host`, `.port`, and `.tls_enabled`. Never embed credentials in the URL.
- Emit `REDIS_USER` only when the effective ACL username is present.
- Emit `REDIS_PASSWORD` as a Secret reference using `local.redis_password_secret_name` and `.key` only when a password source exists. Never read a caller-managed Secret or create a duplicate password Secret.
- Extract the current `bull:jobs:wait` and `bull:jobs:active` names into one shared queue-key local consumed by KEDA and `REDIS_EXPORTER_CHECK_SINGLE_KEYS`. Keep database zero and the existing prefix; no new queue namespace contract.
- Leave TLS verification enabled. Use the effective Azure Managed Redis hostname and returned port, not a legacy Cache for Redis suffix, a hardcoded 6380, or a private endpoint IP. For external Redis, document the need for a certificate-valid hostname and trusted CA. Custom TLS server-name and CA inputs are outside this port.
- Retain the upstream hardening: read-only root filesystem, UID 59000, no privilege escalation, dropped capabilities, memory request/limit, and liveness/readiness probes. Use the reference requests of 10m CPU and 32Mi memory and a 64Mi memory limit. Add the optional 10m request to the existing advisory capacity model. These new component requests do not retune existing workloads.

Tests must assert security settings directly, since scanner support for versioned Kubernetes resource names varies. Azure Managed Redis command permissions and live TLS behavior still need manual verification; a rendered `rediss://` URL is not proof of successful scraping.

**Alternative rejected:** n8n's built-in queue metrics are not supported for multi-main in the pinned application configuration. A monitoring stack or wildcard key scan would expand scope and add avoidable cost.

### 7. Make AKS OS-disk size configurable without changing defaults

Add `aks_node_os_disk_size_gb`, default null, validated as a positive whole number in the provider's GB unit. Pass it to `default_node_pool.os_disk_size_gb` and the user pool's `os_disk_size_gb`. Null delegates sizing to Azure/provider behavior; it is not a 20 GiB promise. Leave `os_disk_type` unchanged.

The system pool already has `temporary_name_for_rotation = "systemtemp"`. Add a stable, distinct valid temporary name for the user pool when configuring disk-size rotation. Preserve autoscaler-owned `node_count` lifecycle ignores. Extend the existing ignored-AKS-tuning warning to cover a non-null disk size when `create_aks = false`.

AzureRM documents that cycling these pools does not cordon and drain pods and can disrupt workloads. Documentation must require plan review, node/subnet/quota headroom, and a maintenance procedure before changing an existing size. Neither `max_surge` nor the n8n PDB is a guarantee of safe disk-size rotation. Valid positive input is not a promise that every Azure VM/disk combination accepts that size.

**Alternative rejected:** Per-pool sizes, disk types, and automated drain provisioners are unnecessary for the requested control. Copying AWS's 100 GiB large-tier value could shrink an Azure default disk as well as lack performance evidence.

### 8. Separate editor identity from webhook advertisement

Add nullable `n8n_webhook_url`, defaulting effectively to `https://${var.n8n_domain}`. Validate a nonblank absolute HTTPS base URL with a host, no credentials, whitespace, query, or fragment, and a valid optional port. Preserve a valid path or trailing slash if supplied. This input advertises a URL; it does not create its DNS record, certificate, or ingress route.

Render `N8N_WEBHOOK_URL` from that effective URL and `N8N_EDITOR_BASE_URL` from `https://${var.n8n_domain}` in shared `config.extraEnv`. Keep `N8N_HOST`, internal HTTP protocol, service port, and all URL collision guards unchanged. Do not set chart `webhook.url` or chart ingress values as an alternate path, because those also render URL environment entries. Do not add legacy `WEBHOOK_URL`; the Azure convention and pinned n8n source already use the current name.

Wire `examples/split-ingress` to `https://${local.webhook_domain}`. The editor/OAuth callback remains on the admin domain, while advertised production webhooks use the public gateway. Preserve all five production webhook route prefixes, no public catch-all, and the existing private routing. The pinned n8n version also uses its configured webhook base for test webhook URLs; include test-webhook/form behavior in manual checks and do not claim a routing redesign as part of this fix.

**Alternative rejected:** Deriving editor identity from the public webhook host sends REST/OAuth callbacks to the wrong service. Adding a separate editor override would duplicate the role of `n8n_domain`.

### 9. Preserve example sizing and bound verification

All eight example roots receive a main-floor passthrough. Medium keeps 3, large keeps 6, and the other examples keep 2. Keep their existing maxima and sizing decisions; assert the new single-main effective ceiling without weakening the default sizing assertions. Show Business/storage entitlement selection in root documentation rather than claiming that changing one example input removes every license requirement.

Add a chart-rendering script wired to CI and `openspec/init.sh`. It must use the pinned chart and module-derived values with non-secret fixtures, not a separate hand-written approximation. Prefer plan assertions on consumed selector locals; if provider mocking leaves Helm values unknown, use a fully mocked apply only to materialize the actual values for rendering. This remains offline and creates no infrastructure. Check YAML structure and resolve relevant ConfigMap-backed environment values when asserting effective settings.

Cover defaults, single-main with a high supplied maximum, multi-main rollback values, all tuning controls together, and omitted optional blocks. Verify no duplicate managed environment names or entries carrying both `value` and `valueFrom`, valid numeric chart values, the correct main-only strategy/PDB, runner mounts, URLs, and pod DNS. Do not claim that two successful template renders prove a live upgrade.

Update the smoke script to inspect the rendered topology, not infer it from current pod count. Single-main checks HPA 1/1, `Recreate`, a zero-minimum PDB, one ready main, and license validity without expecting leader election. Multi-main retains entitlement/leader checks and replica floors. Keep live invocation outside CI. Shell syntax and topology-detection behavior can be checked offline with recorded or synthetic command fixtures.

Complete the full existing offline matrix without Azure credentials, with Terraform test suites remaining under the repository's five-minute budget. Generated documentation checks remain limited to directories that actually have generated blocks; do not rewrite the hand-maintained TLS/controller READMEs or fix unrelated historical spec wording.

## Risks and trade-offs

- **Single-main downtime and overlap limits:** Document editor/API/scheduled-trigger downtime and the limits of `Recreate`; require explicit staging qualification before production use.
- **Independent storage entitlements:** Provide a database-only new-deployment recipe and a warning about retained Blob data. Do not automatically change storage when topology changes.
- **Chart versus application behavior:** Pin offline rendering to the current chart, verify against the pinned application source, and rerun these checks on future upgrades. Custom image versions remain the caller's compatibility responsibility.
- **Helm updates and rollback:** Inspect both rendered topology branches and require manual testing of transitions. A failed license activation can leave a Deployment or release needing recovery.
- **AKS disk rotation:** Expose the control but do not promise a non-disruptive update. Document AzureRM's cycling behavior and require operator planning.
- **Redis exporter availability and access:** Keep it independent of n8n readiness. Document `redis_up`, command/ACL permissions, TLS trust, and the lack of a monitoring backend. Optional exporter restarts can leave scrape gaps.
- **Tuning without evidence:** Keep values unset by default; explain memory, connection, DNS, and Redis load trade-offs rather than prescribing AWS measurements.
- **Caller-managed payload updates:** Names do not reveal payload changes. Retain manual rollout requirements for runner configuration, credential overwrites, and Secret-based authentication.

## Migration plan

Implementation does not require state moves, module restructuring, or resource renames. Existing defaults keep their sizing and topology. The new explicit editor environment variable changes Helm values and can roll pods, so do not advertise a byte-for-byte no-op upgrade.

1. Review the plan and current license entitlements. Preserve the encryption key and durable data under the existing operator procedures.
2. Introduce runtime controls individually, leaving nullable controls unset unless needed. Existing `NODE_OPTIONS` remains valid when the heap input is null.
3. For split ingress, set the webhook override and verify OAuth2 redirect registration against `https://<admin-domain>/rest/oauth2-credential/callback`.
4. Switch to single-main only in a maintenance window. Returning to multiple mains requires the multi-main entitlement before raising the minimum; use the documented Helm recovery procedure if activation fails.
5. Treat OS-disk changes as a separate maintenance operation. Do not combine disk rotation with topology or application changes.
6. Roll back optional tuning by returning to null/default and disabling the exporter. Restoring old module code also removes these inputs, so remove them from the calling configuration first. Do not assume reverting an OS-disk value reverses a completed node rotation safely.

Manual Azure qualification remains separate from implementation completion. Document checks for fresh install, no-op apply, Helm update and rollback, both topology transitions, node maintenance, disk rotation, Secret/ConfigMap rotation, split-host callbacks and webhook tests, Redis TLS/ACL scraping and queue lengths, DNS/private endpoint resolution, and recovery when the API is unavailable. Record environment, versions, outcomes, and untested cases without reusing AWS outcomes as Azure evidence.

## Source evidence

Reviewed sources are pinned where possible. These establish contracts, not live Azure qualification.

- [AWS 0.4.0 changelog](https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/CHANGELOG.md), [release](https://github.com/n8n-io/terraform-aws-n8n/releases/tag/0.4.0), and [0.3.0 comparison](https://github.com/n8n-io/terraform-aws-n8n/compare/0.3.0...0.4.0).
- AWS reference [workload values](https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/n8n.tf), [inputs](https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/variables.tf), [exporter](https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/observability.tf), and [chart check](https://github.com/n8n-io/terraform-aws-n8n/blob/0.4.0/tests/scripts/check-main-chart.sh).
- Chart artifact `oci://ghcr.io/n8n-io/n8n-helm-chart/n8n:1.10.0`: inspected `values.yaml`, `values.schema.json`, deployment templates, PDB, and environment helpers. This artifact, not prose that says `config.data`, defines the value paths.
- n8n `n8n@2.35.0` [database configuration](https://github.com/n8n-io/n8n/blob/n8n%402.35.0/packages/%40n8n/config/src/configs/database.config.ts), [execution configuration](https://github.com/n8n-io/n8n/blob/n8n%402.35.0/packages/%40n8n/config/src/configs/executions.config.ts), [scaling configuration](https://github.com/n8n-io/n8n/blob/n8n%402.35.0/packages/%40n8n/config/src/configs/scaling-mode.config.ts), [URL service](https://github.com/n8n-io/n8n/blob/n8n%402.35.0/packages/cli/src/services/url.service.ts), and runner image `docker/images/runners/n8n-task-runners.json` at the same tag.
- AzureRM `v4.81.0` [AKS cluster](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/kubernetes_cluster.html.markdown), [node pool](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/kubernetes_cluster_node_pool.html.markdown), [Managed Redis](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/managed_redis.html.markdown), and [Flexible Server](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.81.0/website/docs/r/postgresql_flexible_server.html.markdown) contracts. Node-pool implementation validates OS disk size as an integer at least 1.
- Kubernetes `v1.35.0` [pod validation](https://github.com/kubernetes/kubernetes/blob/v1.35.0/pkg/apis/core/validation/validation.go): `validatePodDNSConfig`, nameserver/search limits, joined search-string length, relaxed search validation, and required option names.
- Redis exporter `v1.90.0` [README](https://github.com/oliver006/redis_exporter/blob/v1.90.0/README.md) and [Dockerfile](https://github.com/oliver006/redis_exporter/blob/v1.90.0/Dockerfile): exact-key collection, TLS, authentication, CA bundle, and UID.
- Local Azure evidence: `locals.tf` reserved prefixes and Secret selectors; `n8n.tf` existing URL/storage/save-policy values; `aks.tf` rotation names; `scaling.tf` capacity model; `tests/defaults.tftest.hcl` credential-overwrite and deprecated-URL assertions; and `examples/split-ingress/main.tf`, which currently supplies no separate webhook URL.
