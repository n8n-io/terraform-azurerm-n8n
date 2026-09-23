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
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.13.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `"2.35.0"`, pinned. Unlike the AWS and GCP siblings this module never leaves the tag to the chart, so a chart bump on its own never changes the running n8n version. |
| `n8n_task_runner_image_tag` | Task runner image tag; keep aligned with the underlying n8n version when using a custom application tag. | `null`, meaning `n8n_image_tag` |

Bumping the image tag alone gets you a new n8n version without changing the
chart's templates or value schema. Bumping the chart version can also change
what values the chart accepts and what the chart renders, so treat it as the
larger-blast-radius change of the two.

## Moving from chart 1.11.0 to 1.13.0

Chart `1.12.0` was never this module's default; a deployment on `1.11.0`
takes both releases in one step. `tests/scripts/chart-values-diff.sh 1.13.0`
shows only the new KEDA pause keys and the `image.tag` default; the two
changes that matter are in `templates/`, which is why the offline
`tests/scripts/check-n8n-chart.sh` renders the real chart rather than
diffing values.

**The chart's `image.tag` default moved from floating `stable` to its
`appVersion`.** Inert here: this module always sets `image.tag` from
`n8n_image_tag`, so nothing about the running application changes on the
chart bump. The AWS and GCP siblings, whose `n8n_image_tag` defaults to
null, have to pin before upgrading; this module does not.

**Worker pods lose their explicit `replicas` field on this upgrade, once.**
Chart `1.13.0` stops setting `spec.replicas` on the worker Deployment
wherever an autoscaler already owns the count (n8n-hosting #201), which is
true for every deployment from this module: `keda.enabled` is always on,
the worker `ScaledObject` always has two Redis queue-depth triggers, and
`n8n_worker_keda_min_replicas` is validated to at least 1. Because Helm
*removes* the field rather than changing it, Kubernetes applies its default
of 1 on that one `helm upgrade`, and the HPA that KEDA manages behind the
`ScaledObject` (`kubectl get hpa keda-hpa-n8n-worker -n <namespace>`)
restores `minReplicas` on its next reconciliation. This is HPA-driven, not
bounded by `keda.worker.pollingInterval`, which only sets how often KEDA
refreshes the external metric. Measured on a live `examples/small` upgrade
with a floor of 2: `2 -> 1 -> 2` in about 5 seconds, during the same
rollout that moved worker pods onto the new pod template. Invisible at the
default floor of 1. After the upgrade a Helm apply at the floor no longer
writes a static count back over KEDA's decision, which is the point of the
upstream fix. If the deployment cannot tolerate even a short dip, upgrade in
a quiet window; raising the floor beforehand does not avoid it, because the
HPA only reacts after the drop.

**Main pods lose the task-runner sidecar.** From chart `1.12.0`
(n8n-hosting #179) the sidecar, its env, and the launcher ConfigMap mount
render on main only in standalone mode. This module always runs queue mode,
where n8n offloads manual executions to workers and starts no broker on
main, so the sidecar was idle there. Main pods roll once to drop the
container. `n8n_task_runner_*` resources now describe worker pods only, and
the advisory capacity check (`check.autoscaling_maxima_fit_aks_capacity`)
stops adding the sidecar request to the main ceiling for the verified
charts `1.12.0` and `1.13.0` (`local.n8n_chart_has_worker_only_runners`);
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
drains them to zero while jobs wait in Redis. The chart's matching
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
