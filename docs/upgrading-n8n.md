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
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.14.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `"2.35.0"`, pinned. Unlike the AWS and GCP siblings this module never leaves the tag to the chart, so a chart bump on its own never changes the running n8n version. |
| `n8n_task_runner_image_tag` | Task runner image tag; keep aligned with the underlying n8n version when using a custom application tag. | `null`, meaning `n8n_image_tag` |

Bumping the image tag alone gets you a new n8n version without changing the
chart's templates or value schema. Bumping the chart version can also change
what values the chart accepts and what the chart renders, so treat it as the
larger-blast-radius change of the two.

## Moving to chart 2.0

This module targets n8n Helm chart `2.0` ([n8n-hosting#250](https://github.com/n8n-io/n8n-hosting/pull/250),
still unreleased). `n8n_chart_version`'s default stays `1.14.0` on this
branch; the default moves to `2.0.0` only once that release exists, in
lockstep with this change, so read this section as the shipped behavior of
`feat/chart-2.0`, not a plan for the future.

- **`config.extraEnv` becomes per-component maps** (chart decision 0012).
  The chart's single shared list, plus `queueMode.workerExtraEnv`, are
  replaced by `env.shared`, `env.worker`, and `env.webhookProcessor` flat
  `NAME: value` maps. `n8n.tf` builds these from the module's existing
  inputs; nothing user-facing changes except one pod roll, because every
  n8n pod's environment moves from `valueFrom` list entries into ConfigMaps
  the chart loads with `envFrom`.
- **`n8n_worker_concurrency` is a tombstone.** The chart no longer renders
  `queueMode.workerConcurrency`, and its render fails if that value is set
  together with `executions.concurrency.productionLimit`. This module
  always sets `productionLimit` from `n8n_execution_concurrency_limit`,
  which n8n now uses as each worker's concurrency, so
  `n8n_worker_concurrency` is validated null-only (like
  `n8n_available_binary_data_modes` before it) and has no effect anymore.
  Remove it from your configuration; `n8n_execution_concurrency_limit` is
  the one input that governs worker concurrency.
- **The caller-managed encryption Secret needs only one key.** The chart's
  `secretRefs.existingSecret` (`n8n_encryption_key_secret_ref`) used to
  require `N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, and `N8N_PROTOCOL`
  in one Secret. Chart 2.0 reads only `N8N_ENCRYPTION_KEY` from it; the
  chart sets `N8N_PORT` from `service.port` itself and never sets
  `N8N_HOST` or `N8N_PROTOCOL`. A Secret that still carries the other three
  keeps working — the chart ignores the extra keys — so there is nothing
  to migrate on an existing Secret.
- **Public URLs come from `editor.url` / `webhook.url`, not `N8N_HOST` /
  `N8N_PROTOCOL`.** `n8n.tf` sets both values explicitly from `n8n_domain`
  and `n8n_webhook_url`, so n8n's public editor and webhook URLs no longer
  depend on the removed Secret keys. `N8N_HOST` and `N8N_PROTOCOL` are
  dropped from `local.n8n_managed_env_names`: the chart never sets either,
  so a caller may still render them through `n8n_extra_env` if some other
  integration needs them.
- **`n8n_postgres_ssl_enabled_env` is removed.** It worked around
  n8n-hosting#175 by setting `DB_POSTGRESDB_SSL_ENABLED=true` through
  `config.extraEnv` whenever the effective `ssl_mode` was not `disable`.
  Chart 2.0 includes the upstream fix and sets the variable itself from
  `database.ssl.enabled`; see [`docs/postgresql-tls.md`](./postgresql-tls.md).
- **`WEBHOOK_URL` legacy-image fallback renamed `n8n_legacy_webhook_url_env`.**
  A `locals.tf` rename only, matching the chart's current naming; no
  behavior change.

Every pod restarts once on this upgrade, because its environment moves into
the new per-component ConfigMaps.

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

The chart's `appVersion` moved to `2.41.4`; inert here because
`n8n_image_tag` always sets the image.

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
`appVersion`.** Inert here: this module always sets `image.tag` from
`n8n_image_tag`, so nothing about the running application changes on the
chart bump. The AWS and GCP siblings, whose `n8n_image_tag` defaults to
null, have to pin before upgrading; this module does not.

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
charts `1.12.0`, `1.13.0`, and `1.14.0` (`local.n8n_chart_has_worker_only_runners`);
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
   custom application tag, the matching `n8n_task_runner_image_tag`.
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
