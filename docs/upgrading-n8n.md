# Upgrading n8n

This covers bumping the deployed n8n version or Helm chart on an existing
deployment. It does not cover upgrading this module or its providers; see
[Compatibility](../README.md#compatibility) for those and
[`docs/versioning.md`](./versioning.md) for the full inventory of every
version this module pins (providers, engines, controller charts, CI
toolchain) and how each is bumped. The AWS and GCP siblings carry the same
guide; the per-version sections below cover only what reaches this module.

## Version inputs

| Variable | Controls | Default |
| --- | --- | --- |
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.16.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `null`, meaning the chart's `appVersion` (`2.43.5` at chart `1.16.0`), as in the AWS and GCP siblings. A chart bump then also upgrades n8n. Pin a version in production to upgrade n8n deliberately. |
| `n8n_task_runner_image_tag` | Task runner image tag; keep aligned with the underlying n8n version when using a custom application tag. | `null`, meaning `n8n_image_tag`, else the chart's `appVersion` |

Bumping the image tag alone gets you a new n8n version without changing the
chart's templates or value schema. Bumping the chart version can also change
what values the chart accepts and what the chart renders, so treat it as the
larger-blast-radius change of the two. With `n8n_image_tag = null` a chart
bump is both changes at once: the new chart's `appVersion` replaces the
running n8n version, across its database migrations.

## Moving to the chart-default image tag

`n8n_image_tag` now defaults to `null` (it was `"2.35.0"`;
[#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)). With a
null tag the module sends no `image.tag` or `taskRunners.image.tag`, so the
chart's own default runs: its `appVersion` on upstream charts from `1.12.0`
(`2.43.5` at `1.16.0`). A caller that relied on the old default therefore
moves from n8n `2.35.0` to `2.43.5` on the next apply after upgrading the
module, and every later `n8n_chart_version` bump moves n8n again. A caller
that already sets `n8n_image_tag` sees no change: the rendered values are
byte-identical.

1. Read the version running now:

   ```bash
   kubectl -n <namespace> get deploy n8n-main \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

   or the "Application version" table `tests/scripts/smoke-test.sh` prints.
2. Decide. To stay on that version (recommended for production), set
   `n8n_image_tag = "2.35.0"` (or the tag after the last `:` in the image
   reference step 1 printed) in the same change that upgrades the module, and plan the n8n upgrade separately with
   [Bumping](#bumping). To accept the move, continue.
3. Before accepting, take a PostgreSQL backup (a Flexible Server on-demand
   backup or restore point, or `pg_dump` for an external database) and back
   up the n8n encryption key (`n8n_encryption_key` output, or your own
   Secret).
4. `terraform apply`. The first n8n pod to start on the new version (main
   or worker; the live upgrade saw a worker run them) runs the forward-only
   migrations from the version step 1 printed (`2.35.0` if you relied on the
   old default) to the chart's `appVersion` during the rollout, inside
   `n8n_helm_timeout` (600 seconds by default). On a large database, raise
   `n8n_helm_timeout` first.
5. Rolling back means restoring the database backup with the old tag pinned.
   `atomic = true` rolls back Kubernetes objects, not migrations, so setting
   the tag back alone is not enough once the migrations have run.

The version floors treat a null tag on an upstream numbered chart at
`1.12.0` or later as current (`local.n8n_chart_default_image_current`).
With a null tag on any other chart (older, a prerelease including the
worker-pools preview, or a custom `n8n_chart_repository`), the plan warns
through `check.n8n_image_version_is_known`, still renders `WEBHOOK_URL`
next to `N8N_WEBHOOK_URL`, and fails when `n8n_worker_pools` is set. Pin
the tag there.

## Moving from KEDA chart 2.15.0 to 2.21.0

The default `keda_chart_version` (root module and `modules/controllers`)
moved from `2.15.0` to `2.21.0`
([KEDA v2.21.0](https://github.com/kedacore/keda/releases/tag/v2.21.0)),
matching `terraform-aws-n8n` #159 (`terraform-google-n8n` #37 makes the
same bump and is still open). KEDA 2.15 is tested only on Kubernetes 1.28
to 1.30, so the module's `aks_kubernetes_version` default at the time
(`1.35`) ran it outside its tested window; 2.21 is tested on 1.34 to 1.36
([compatibility matrix](https://keda.sh/docs/2.21/operate/cluster/#kubernetes-compatibility)),
which covers both `1.35` and the current default, `1.36`, but not `1.37`.

- **Security fix.** `2.21.0` is the first patched release for KEDA's
  critical CVE-2026-77524
  ([GHSA-637c-6jxx-4rwm](https://github.com/advisories/GHSA-637c-6jxx-4rwm)):
  a namespace admin can escalate to cluster admin through a
  `TriggerAuthentication`. Every release before `2.21.0`, including the old
  `2.15.0` default, is affected. KEDA's own repository advisory lists no
  patched version; the GitHub Advisory Database records `2.21.0` as the
  first patched version of `github.com/kedacore/keda/v2`.

- **Who this applies to.** Only `install_keda = true` (the default), where
  the module installs KEDA through `modules/controllers`. With
  `install_keda = false` the module plans no KEDA Helm release and ignores
  `keda_chart_version`, so nothing below happens on apply: whoever owns
  that KEDA install upgrades it (to `2.21.0` or later for the security fix
  above), choosing a release KEDA tests on that cluster's Kubernetes
  version.
- **What the next apply does.** A caller that does not pin
  `keda_chart_version` plans one in-place change,
  `module.controllers.helm_release.keda[0]` `2.15.0` to `2.21.0`. The Helm
  upgrade rolls the operator, metrics API server, and admission webhook
  pods once; nothing in the n8n namespace is replaced. Expect a short
  external-metrics gap while the pods restart, during which the worker HPA
  holds its current replica count. Through the root module the release is
  always `atomic` (direct `modules/controllers` callers control this with
  `keda_helm_atomic`, default `true`), so a failed upgrade rolls back to
  `2.15.0`. KEDA is cluster-wide: the upgrade also changes the controller
  for every other `ScaledObject` and `ScaledJob` in the cluster, which
  matters most on a shared cluster with `create_aks = false`.
- **The jump crosses six minors in one Helm upgrade.** KEDA publishes
  migration notes only for 2.20 to 2.21. The breaking changes on the way
  (2.16 to 2.21) remove the NATS Streaming scaler, remove settings from
  the Pulsar, CPU/memory, IBM MQ, External, GCP Pub/Sub, Huawei Cloudeye,
  InfluxDB, Azure Data Explorer, and Temporal scalers, enforce service
  account token audiences (Vault Kubernetes authentication and
  `boundServiceAccountToken`), and change the Azure Pipelines scaler
  default. The module uses none of them: its `TriggerAuthentication`
  (`locals.tf`) uses only `secretTargetRef`, and
  the n8n chart's worker `ScaledObject` uses only the `redis` scaler with
  `address`, `listName`, `listLength`, and `enableTLS`, all still read the
  same way by the 2.21 Redis scaler. If you run your own KEDA objects on the
  same install, read KEDA's [migration guide](https://keda.sh/docs/2.21/migration/)
  and the release notes for each minor first.
- **CRDs upgrade with the release.** The chart renders its CRDs from
  `templates/`, so the Helm upgrade updates them in place. Every KEDA CRD
  still serves and stores only `v1alpha1`, so no stored object is
  converted. The upgrade from 2.15 adds one CRD,
  `clustercloudeventsources.eventing.keda.sh`, which the chart has shipped
  since 2.16.
  Since 2.20 the CRDs carry schema validation (`minimum`, `minLength`,
  `minItems`, `enum`, and a rule that `minReplicaCount` must not exceed
  `maxReplicaCount`). The module's own objects satisfy it (the worker and
  pool replica bounds are already validated at plan time); a caller's own
  object that does not is rejected on its next create or update.
- **ScaledObject conditions.** In 2.21 the `Ready` condition reflects only
  the `ScaledObject`'s own validity; HPA health moved to a new `HPAActive`
  condition. Read both when checking scaling after the upgrade.
- **KEDA's own Prometheus metrics.** 2.17 removed the deprecated KEDA
  operator metric names. The module scrapes none of them; update any
  dashboard or alert of your own that does.
- **Older clusters.** With `install_keda = true`, check the Kubernetes
  version of the cluster KEDA runs on: `aks_kubernetes_version` when
  `create_aks = true`, or the caller-managed cluster's own version when
  `create_aks = false` (`aks_kubernetes_version` does not describe that
  cluster). Below 1.34, pin a release KEDA tests there (`"2.20.2"` on
  1.33, `"2.19.0"` on 1.32, `"2.18.3"` on 1.31) as a temporary hold. None of them carries the
  CVE-2026-77524 fix above, so weigh that before holding, and move to the
  default as soon as the cluster reaches 1.34.

## Moving from chart 1.15.0 to 1.16.0

`helm_release.n8n` plans only the `version` change: the module sends
`1.16.0` the same values it sent `1.15.0`. Every n8n pod still rolls once,
because the chart version is a pod template label (`helm.sh/chart`) and
also changes each pod's `checksum/config` annotation. Unpinned callers (`n8n_image_tag = null`) also move n8n from
`2.42.4` to `2.43.5`, the new `appVersion`, across its database migrations;
see [Moving to the chart-default image tag](#moving-to-the-chart-default-image-tag).
Rendering the module's fixtures against both charts shows three changes for
this module, apart from those labels and that checksum:

- **No main PodDisruptionBudget in single-main** (n8n-hosting #228). The
  chart now renders the main PDB only while main can run more than one
  replica. Multi-main (`n8n_main_hpa_min_replicas` of 2 or more) keeps its
  `minAvailable: 1` budget. Single-main loses its `minAvailable: 0` budget,
  and Helm deletes `pdb/n8n-main` on the upgrade. That budget already
  permitted every voluntary eviction, so node drains and AKS upgrades behave
  as before. The module still sends `pdb.minAvailable = 0` for single-main,
  which older charts (including the worker-pools preview) render.
  `tests/scripts/smoke-test.sh` now accepts either shape for single-main and
  still requires `minAvailable: 1` for multi-main.
- **Liveness probe on the worker task-runner sidecar** (n8n-hosting #223):
  an HTTP GET on `/healthz`, port 5680, the launcher's own health server,
  every 10 seconds; Kubernetes restarts the sidecar after 6 failures. The
  module never sets `N8N_RUNNERS_LAUNCHER_HEALTH_CHECK_PORT`, and a
  caller-managed launcher file (`n8n_task_runner_custom_config`) cannot move
  that port, because the launcher reads it from the environment only. Main
  pods carry no sidecar in queue mode, so only workers get the probe. This
  module does not expose `taskRunners.probes`.
- **New render-time guards** (n8n-hosting #229): more than one main
  (`replicaCount`, or `hpa.main.maxReplicas` above 1) requires
  `multiMain.enabled`, which requires `license.enabled`. The module derives
  `multiMain.enabled` from `n8n_main_hpa_min_replicas`, clamps the
  single-main HPA to 1, and always enables the license, so every
  configuration it accepts passes. `tests/scripts/check-n8n-chart.sh`
  renders both topologies.

Not exposed by this module: `editor.url` (#243; the module keeps rendering
its own `N8N_EDITOR_BASE_URL` and sets neither `ingress` nor `webhook.url`,
so the chart renders none), `hostAliases` (#167), image digests and
`persistence.annotations` (#240), per-role `podSecurityContext` and
`containerSecurityContext` (#236; their defaults render the same security
contexts as `1.15.0`), and `secretRefs.env.N8N_ENCRYPTION_KEY_FILE` (#183;
the module passes its key through `secretRefs.existingSecret`). The
task-runner sidecar moved into a shared template helper with the same
resources and the same placement, so `1.16.0` joins
`local.n8n_chart_has_worker_only_runners`.

**Check after the upgrade** (namespace `n8n` unless you changed it):

1. `helm history n8n -n n8n`: the newest revision is `deployed` with chart
   `n8n-1.16.0`, and no `failed` or rolled-back revision came after the
   previous one.
2. `kubectl rollout status deploy/n8n-main deploy/n8n-worker deploy/n8n-webhook-processor -n n8n`.
3. `kubectl get deploy n8n-main -n n8n -o jsonpath='{.spec.template.spec.containers[0].image}'`
   prints `docker.n8n.io/n8nio/n8n:2.43.5` with `n8n_image_tag = null`, or
   your pinned tag.
4. `kubectl get pdb -n n8n`: multi-main lists `n8n-main` with
   `MIN AVAILABLE` 1; single-main lists no `n8n-main`.
5. `kubectl get deploy n8n-worker -n n8n -o json | jq '.spec.template.spec.containers[] | select(.name == "task-runner") | .livenessProbe.httpGet'`
   prints path `/healthz` and port `5680`. Over the next few minutes the
   worker pods' restart counts stay flat and
   `kubectl get events -n n8n --field-selector reason=Unhealthy` lists no
   `task-runner` liveness failures.
6. `tests/scripts/smoke-test.sh` passes.

Failure signs: the Helm upgrade fails with an `n8n` values-validation error
naming `multiMain`, `replicaCount`, or `hpa.main` (not expected from any
configuration the module accepts; report it), worker `task-runner`
containers restarting on `Liveness probe failed` (read the sidecar logs for
the launcher's health server), or the apply rolling back to `1.15.0`.

## Moving from chart 1.14.0 to 1.15.0

`helm_release.n8n` plans the `version` change and, on the upstream chart
repository with PostgreSQL TLS on (always on the module-managed Flexible
Server; on the external path unless
`postgres_external_ssl_mode = "disable"`), the removal of the module's own
`DB_POSTGRESDB_SSL_ENABLED` entry from `config.extraEnv`. A custom `n8n_chart_repository` or a
prerelease version keeps that entry (see below). Every n8n pod rolls once. No `deployment-*.yaml` template changed, so replica
ownership, the worker `ScaledObject`, and task-runner placement are as on
`1.14.0`. The upstream changes:

- **`DB_POSTGRESDB_SSL` renamed to `DB_POSTGRESDB_SSL_ENABLED`** in the
  chart ConfigMap and pod env (n8n-hosting #175). This is the name n8n
  reads, and the module had been setting it itself through
  `config.extraEnv` because older charts used the wrong one (see
  [PostgreSQL TLS](./postgresql-tls.md#chart-workaround-for-db_postgresdb_ssl_enabled)).
  Kept as is, every n8n container would carry the name twice, so on the
  upstream repository at a numbered `1.15.0` or newer the module now leaves
  it to the chart (`local.n8n_chart_renders_postgres_ssl_enabled`). The
  rendered manifests give each n8n container exactly one
  `DB_POSTGRESDB_SSL_ENABLED`, a `configMapKeyRef` to the chart's ConfigMap
  key of the same name (value `"true"`), and no `DB_POSTGRESDB_SSL`;
  `tests/scripts/check-n8n-chart.sh` verifies this offline. The live pods
  match after the upgrade, keeping the effective value `"true"` so n8n's
  TLS behavior does not change (verified on a live in-place upgrade from
  `1.14.0`, see below).
- **`extraObjects`** (n8n-hosting #219) renders extra Kubernetes objects
  inside the release, and **`database.ssl.existingSecret`** (n8n-hosting
  #222) sources a CA, client certificate, or client key from a Secret.
  Neither is exposed by this module. The chart's `NOTES.txt` warns when
  `database.ssl.key` is set; the module never sets it.

The chart's `appVersion` moved to `2.42.4`. Unpinned callers
(`n8n_image_tag = null`) also move n8n to `2.42.4` with this bump; see
[Moving to the chart-default image tag](#moving-to-the-chart-default-image-tag).

**What the upgrade from `1.14.0` does (verified live once).** On `1.14.0`
the chart's entry is `DB_POSTGRESDB_SSL` and the module's is
`DB_POSTGRESDB_SSL_ENABLED`, so no container carries a duplicate name
before or after. Helm's three-way strategic merge patch keys env entries
by `name`, so it replaces the module's `value: "true"` literal with the
chart's `configMapKeyRef` in place and deletes `DB_POSTGRESDB_SSL`. This
was observed on a live `examples/small` upgrade in swedencentral (upstream
repository, chart `1.14.0` to `1.15.0`, TLS on, multi-main): the Helm
release went to revision 2 as `deployed` with no rollback and no
`value`/`valueFrom` error, main, worker and webhook-processor stayed at
their replica floors, each n8n container carried exactly one
`DB_POSTGRESDB_SSL_ENABLED` from ConfigMap `n8n`, and `printenv` in a main
pod printed `true`. It is one run on one chart source: run the checks below
on every upgraded deployment, against the expected shape for your chart
source.

Duplicates can only arise where the module cannot verify the chart: a
custom `n8n_chart_repository` or a prerelease at `1.15.0` or newer keeps
the module's entry, and if that chart also renders
`DB_POSTGRESDB_SSL_ENABLED` (as upstream `1.15.0` does), each container
carries the name twice (both `"true"`; Kubernetes may print a "hides
previous definition" warning). A chart that does not render it leaves the
module's entry as the only one. A strategic merge patch matches list
entries by `name`, so a later change that removes one of two same-named
entries (for example switching such a deployment to the upstream
repository) is the riskiest path: check the pods afterwards as below, and
`kubectl rollout restart` with a re-apply if the name went missing.

**Expected `DB_POSTGRESDB_SSL_ENABLED` shape after the upgrade**, per n8n
container (main, worker, and webhook-processor; the `task-runner` sidecar
carries none):

| Chart source and TLS | Expected entries | ConfigMap `n8n` |
| --- | --- | --- |
| Upstream `n8n_chart_repository`, numbered `1.15.0` or newer, TLS on | Exactly one, `configMapKeyRef` `n8n` / `DB_POSTGRESDB_SSL_ENABLED` | `DB_POSTGRESDB_SSL_ENABLED: "true"`, no `DB_POSTGRESDB_SSL` |
| Custom repository or prerelease whose chart does not render the name | Exactly one, the module's `value: "true"` | Whatever that chart renders (for example `DB_POSTGRESDB_SSL`); not checked |
| Custom repository or prerelease whose chart renders the name | Two by design: the chart's `configMapKeyRef` first, then the module's `value: "true"` | `DB_POSTGRESDB_SSL_ENABLED: "true"` |
| `postgres_external_ssl_mode = "disable"` (any chart) | None | No `DB_POSTGRESDB_SSL*` key |

**Check after the upgrade** (namespace `n8n` unless you changed it):

1. `helm history n8n -n n8n`: the newest revision is `deployed` with the
   chart you selected in `n8n_chart_version` (`n8n-1.15.0` for the
   default; a prerelease or mirrored chart shows its own version), and no
   `failed` or rolled-back revision came after the previous one
   (`atomic = true` rolls a failed upgrade back, so a successful-looking
   apply that left `1.14.0` deployed means it failed).
2. `kubectl rollout status deploy/n8n-main deploy/n8n-worker deploy/n8n-webhook-processor -n n8n`.
3. For each of those Deployments, the n8n container's
   `DB_POSTGRESDB_SSL_ENABLED` entries match the table row for your chart
   source:
   `kubectl get deploy n8n-main -n n8n -o json | jq '[.spec.template.spec.containers[] | {name, ssl: [.env[]? | select(.name | startswith("DB_POSTGRESDB_SSL"))]}]'`
   (the filter also lists `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` and
   `DB_POSTGRESDB_SSL_CA` where your TLS mode renders them; those do not
   change, and the `task-runner` sidecar lists none).
4. Where the table expects a ConfigMap key, check it with
   `kubectl get configmap n8n -n n8n -o json | jq '.data | with_entries(select(.key | startswith("DB_POSTGRESDB_SSL")))'`.
5. With TLS on, `printenv DB_POSTGRESDB_SSL_ENABLED` in a running pod
   prints `true`, and the n8n logs show no PostgreSQL connection or TLS
   errors.
6. `tests/scripts/smoke-test.sh` passes.

Failure signs: the Helm upgrade fails with
`valueFrom: Invalid value: "": may not be specified when 'value' is not empty`
(the patch kept the old literal next to the new reference), a container
whose `DB_POSTGRESDB_SSL_ENABLED` entries differ from its table row (for
example none with TLS on, or two on the upstream chart), or main pods
failing their readiness probe on database connection errors after the
roll.

## Moving from chart 1.13.0 to 1.14.0

`helm_release.n8n` plans the `version` change plus the removal of the
module's own `N8N_AVAILABLE_BINARY_DATA_MODES` env entry (below), so every
n8n pod rolls once. The chart's own template changes render nothing
different for this module's configurations. The three upstream changes:

- **`WEBHOOK_URL` renamed to `N8N_WEBHOOK_URL`** in the chart ConfigMap and
  pod env (n8n-hosting #184). The chart emits it only from `webhook.url` or
  an enabled chart ingress; this module sets neither and already renders
  `N8N_WEBHOOK_URL` itself through `config.extraEnv`.
- **`N8N_AVAILABLE_BINARY_DATA_MODES` dropped from the chart's S3 block**
  (n8n-hosting #185). This module never enables `s3`. In the same change
  the module stops rendering the variable itself and replaces
  `n8n_available_binary_data_modes` with `azure_blob_retain_read_access`.
  n8n 2.x never read the variable, so the env removal changes no behavior,
  but it is a pod-template change: every n8n pod rolls once on this apply.
  Setting the old input now fails the plan with a migration message. If
  your list contained `azure` and both storage modes are `database`, set
  `azure_blob_retain_read_access = true` in the same change that deletes
  it; see [Binary data modes](./data-storage.md#binary-data-modes).
- **Values validation reports every failure in one render** (n8n-hosting
  #209). Only the error text changes when several checks fail at once.

The chart's `appVersion` moved to `2.41.4`. This was inert at the time,
when `n8n_image_tag` always set the image; with today's null default an
unpinned caller on this chart runs `2.41.4`.

## Moving from chart 1.11.0 to 1.13.0

This module has not been released with a `1.11.0` default, so this section
only applies to pre-release deployments (for example qualification stacks)
created before the bump, or to callers who pinned `n8n_chart_version` to an
older chart and now move to `1.13.0`. Chart `1.12.0` was never this
module's default; a deployment on `1.11.0` takes both releases in one step. `tests/scripts/chart-values-diff.sh 1.13.0`
shows only the new KEDA pause keys and the `image.tag` default; the two
changes that matter are in `templates/`, which is why the offline
`tests/scripts/check-n8n-chart.sh` renders the real chart rather than
diffing values.

**The chart's `image.tag` default moved from floating `stable` to its
`appVersion`.** This was inert at the time of this bump, when the module
always set `image.tag` from `n8n_image_tag`. Since `n8n_image_tag` defaults
to null, this is what lets a null tag count as a known version on charts
from `1.12.0` (see
[Moving to the chart-default image tag](#moving-to-the-chart-default-image-tag));
on `1.11.0` and older a null tag runs the floating `stable` tag, and the
plan warns.

**The first upgrade resets the worker count to 1, once.**
Chart `1.13.0` stops setting `spec.replicas` on the worker Deployment
wherever an autoscaler already owns the count (n8n-hosting #201), which is
true for every deployment from this module: `keda.enabled` is always on,
the worker `ScaledObject` always has two Redis queue-depth triggers, and
`n8n_worker_keda_min_replicas` is validated to at least 1. Because Helm
*removes* the field rather than changing it, Kubernetes applies its default
of 1 on that one `helm upgrade`. The target is always 1, not the configured
floor, and not the count KEDA had scaled to under load:

- Whenever the worker Deployment runs more than 1 replica at upgrade time,
  Kubernetes starts terminating the surplus pods. That includes a
  deployment sitting exactly at a floor above 1 (`examples/medium` runs a
  floor of 4, `examples/large` a floor of 20) and one KEDA has scaled up
  on queue depth.
- A terminated worker stops taking new jobs and waits for its running
  executions, but only up to its shutdown window: the chart's
  `redis.worker.timeout` (30 seconds by default, rendered as
  `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`); `n8n_graceful_shutdown_timeout`
  overrides it. Setting the value through `n8n_extra_env`,
  `n8n_worker_extra_env`, or a worker pool's `extra_env` is rejected at
  plan time: the chart always renders it as a ConfigMap reference and
  `extraEnv` is appended after it, so a second entry with the same name
  would silently replace the chart's value. The pod is also bounded by
  `n8n_termination_grace_period`: the timeout plus `n8n_prestop_sleep`
  must stay below it. An explicit `n8n_graceful_shutdown_timeout` that does
  not fit fails validation; with the input unset, a chart default that does
  not fit only raises a plan-time warning. Executions still running after
  that can be interrupted.
- The HPA that KEDA manages behind the `ScaledObject`
  (`kubectl get hpa keda-hpa-n8n-worker -n <namespace>`) then restores the
  floor, and scales above it as queue demand requires. This is HPA-driven,
  not bounded by `keda.worker.pollingInterval`, which only sets how often
  KEDA refreshes the external metric. Measured on a live `examples/small`
  upgrade with a floor of 2: `2 -> 1 -> 2` in about 5 seconds, during the
  same rollout that moved worker pods onto the new pod template. Larger
  floors were not measured.
- A deployment at the default floor of 1 that has not scaled above 1 sees
  no change.

Raising the floor beforehand does not help, because the reset goes to 1
either way. For a deployment that runs more than 1 worker, upgrade in a
low-traffic window, pause or reduce incoming work and let running
executions finish before you apply, then confirm the worker count is back
at the floor (`kubectl get deploy n8n-worker -n <namespace>`) and check the
n8n execution list for interrupted runs. After the upgrade a Helm apply at
the floor no longer writes a static count back over KEDA's decision, which
is the point of the upstream fix.

**Main pods lose the task-runner sidecar.** From chart `1.12.0`
(n8n-hosting #179) the sidecar, its env, and the launcher ConfigMap mount
render on main only in standalone mode. This module always runs queue mode,
where n8n offloads manual executions to workers and starts no broker on
main, so the sidecar was idle there. Main pods roll once to drop the
container. `n8n_task_runner_*` resources now describe worker pods only, and
the advisory capacity check (`check.autoscaling_maxima_fit_aks_capacity`)
stops adding the sidecar request to the main ceiling for the verified
charts `1.12.0`, `1.13.0`, `1.14.0`, `1.15.0`, and `1.16.0` (`local.n8n_chart_has_worker_only_runners`);
any other `n8n_chart_version` keeps the conservative allowance. Verify
JavaScript and Python Code nodes through workers after the upgrade,
including manual executions from the editor.

**Webhook processors are unaffected.** Their autoscaler is this module's
own `kubernetes_horizontal_pod_autoscaler_v2` in `scaling.tf`, outside the
chart's KEDA/HPA model (`keda.webhookProcessor.enabled` and
`hpa.webhookProcessor.enabled` are never set), so the chart keeps rendering
`webhookProcessor.replicaCount` exactly as before.

**New inputs.** `n8n_worker_keda_pause` and
`n8n_worker_keda_paused_replica_count` expose the chart's
`keda.worker.pause` / `pausedReplicaCount` (n8n-hosting #177): pause holds
workers at their current count for a maintenance window, and a count of 0
scales them to zero while jobs wait in Redis. Pause applies to the
default worker Deployment only; `n8n_worker_pools` pools keep scaling on
their own queues. It needs `n8n_chart_version` `1.13.0` or later, and
`check.worker_keda_pause_requires_a_supported_chart` warns otherwise:
charts before `1.12.0` (including the `1.11.0`-based worker-pools preview)
ignore the key, and `1.12.0` still writes the worker's `spec.replicas` on
every Helm upgrade, overwriting the held count. The chart's matching
`keda.webhookProcessor.pause` is not exposed, because no webhook
`ScaledObject` exists here for the annotation to act on.

`queueMode.workerGroups` is still not in any numbered chart release, so
`n8n_worker_pools` callers stay on the `1.11.0`-based preview chart and
receive neither #201 nor #179 until a new preview build exists.

## Before bumping

1. Read the breaking-changes doc for every n8n major version you are
   crossing, not just the target: [n8n v2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes/),
   [n8n v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes).
2. Check whether the target n8n version needs a newer chart. If the chart's
   own `values.yaml` schema changed, `n8n_chart_version` needs bumping too,
   not just `n8n_image_tag`. `tests/scripts/chart-values-diff.sh <candidate>`
   diffs the pinned and candidate `values.yaml`; also diff `templates/`
   directly, since a values diff hides rendering changes such as #201 and
   #179 above.
3. On multi-main (`n8n_main_hpa_min_replicas > 1`, the default), any upgrade
   is a rolling restart of the main pods; see
   [`docs/troubleshooting.md`](./troubleshooting.md) for what a failed
   rollout leaves behind. On single-main, the `Recreate` strategy means the
   editor, REST API, and scheduled triggers are unavailable until the
   replacement main is Ready; plan a window (see
   [`docs/topology-maintenance.md`](./topology-maintenance.md)).
4. Take a PostgreSQL Flexible Server on-demand backup or equivalent
   external-database backup. Helm's `atomic` rollback restores Kubernetes
   objects, not database migrations.

## Bumping

1. Set `n8n_image_tag`, any required `n8n_chart_version`, and, when using a
   custom application tag, the matching `n8n_task_runner_image_tag`. With
   `n8n_image_tag = null`, the chart bump alone is the n8n upgrade.
2. `terraform plan` and review the diff and warnings. A chart-only bump
   plans as exactly one in-place change to `module.n8n.helm_release.n8n`.
3. `terraform apply`. Watch the main pods through the rollout:

   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=main -w
   ```

4. Confirm the version actually running matches what you set:

   ```bash
   kubectl exec -n <namespace> <main-pod> -c n8n-main -- n8n --version
   helm -n <namespace> list
   ```

5. Run `tests/scripts/smoke-test.sh` from the root you applied.

## Rolling back

Do not only restore the old tags. If the upgrade ran database migrations,
stop n8n and either run `n8n db:revert` on the current version once per
reversible migration or restore the pre-upgrade database. Check release
notes for irreversible migrations. Then restore the previous chart,
application, and task-runner tags and apply. See n8n's
[reverting an upgrade](https://docs.n8n.io/deploy/host-n8n/install-options/install-with-npm/#reverting-an-upgrade)
guidance.

`helm_release.n8n` runs with `atomic = true`, so a failed upgrade rolls the
release back on its own; if it is left in `pending-rollback`, unstick the
release with `helm rollback` before the next `terraform apply`.
