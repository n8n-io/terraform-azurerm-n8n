# Maintenance-only main topology changes

Changing between single-main and multi-main is a maintenance operation, not a
supported live rollout. This applies in both directions when
`n8n_main_hpa_min_replicas` crosses the boundary between `1` and `2` or more.
Choosing a topology for a fresh installation is unaffected. Changing replica
counts within multi-main does not cross this boundary.

The module is pre-release. Terraform currently accepts a live topology change;
it does not enforce this maintenance policy or stop old main processes for you.
A successful apply, healthy pods, or a no-op follow-up plan does not establish
that a transition was safe.

## Why a maintenance window alone is insufficient

A live qualification run with n8n `2.35.0` and chart `1.10.0` observed the old
single-main ReplicaSet scale from one pod to two while new multi-main pods
started. Logs reported two, then three instances claiming leadership. One
scheduled attempt was suppressed by deduplication, and a worker job failed
because its execution data could not be found. All six expected schedule ticks
had one successful API-visible execution, masking the failed attempt.

The evidence does not establish whether the HorizontalPodAutoscaler (HPA) or
Deployment reconciliation caused the old ReplicaSet to scale. Both must be
accounted for in a maintenance plan. Using `Recreate` alone, pausing a rollout,
or setting replicas to zero once is not a sufficient safeguard against
controllers starting old-spec pods again.

Schedule deduplication can suppress competing attempts. Clean execution counts
therefore do not prove unique leadership, and this schedule test says nothing
about polling triggers or external side effects.

## Prepare an operator-reviewed maintenance plan

The following is a required operational checklist, not a live-qualified,
copy-and-paste migration script. Qualify the exact stop/start and recovery
procedure on a disposable deployment before using it with retained workloads.
The module has no maintenance-mode input that automates these steps.

1. Confirm the subscription, cluster, namespace, release, Terraform working
   directory, and state. Use an isolated kubeconfig. Record the current topology,
   Helm revision, pod identities, and workload-controller ownership.
2. Back up Terraform state, the encryption key, and durable data. Record active
   workflows and their activation state. Confirm the destination license has
   `feat:multipleMainInstances` before selecting multi-main.
3. Arrange downtime for the editor, API, triggers, and incoming webhook traffic.
   Agree how missed schedule ticks, polling windows, and external retries will
   be reconciled. Do not promise automatic catch-up or blindly replay requests.
4. Review the stop procedure and recovery procedure separately from the
   destination Terraform plan. Preserve PostgreSQL, Redis, Blob storage,
   credentials, namespaces, and other caller-owned resources. Do not destroy the
   module or uninstall unrelated releases to change topology.

## Stop and verify before starting the destination

1. Block incoming execution-producing traffic and stop workflow activation
   changes. Deactivate scheduled and polling workflows while the source topology
   still serves its API. Drain queued and running work; account separately for
   waiting executions and retries. Do not flush Redis or delete execution data
   to make a queue appear empty.
2. Pause automated Terraform, Helm, and GitOps reconciliation. Disable or remove
   the main HPA and any other controller that could scale or recreate the source
   workload. Record these temporary changes for later reconciliation.
3. Stop the source main workload and remove its old Deployment and owned
   ReplicaSets under the reviewed maintenance procedure. Merely scaling the
   Deployment to zero leaves its old pod template available to reconciliation.
   Preserve the Helm release record and data resources.
4. Verify that **no old main process remains**, including terminating pods, and
   that no old controller can recreate one. A pod deletion request or a missing
   readiness endpoint is not proof of process termination. If a node is
   unreachable, stop here until its old processes are known to be stopped or the
   node is fenced from shared services.
5. Generate and review a fresh saved Terraform plan for the destination topology
   after these maintenance changes. Account for the missing workload resources;
   Helm values alone are not a complete inventory of manual Kubernetes changes.
   Reject unexpected data-resource replacement or deletion. Do not reuse a plan
   prepared before the stop procedure.
6. Apply only the approved plan. Keep triggers and incoming traffic disabled
   while Helm recreates the destination main workload and its HPA. Verify that
   every new main uses the destination configuration and no old main or old
   ReplicaSet returns.

The required invariant is: **do not start the destination topology while any
source-topology main process can still run or be recreated**. There is no
Terraform safeguard enforcing this invariant in the current module.

## Verify and resume

- Check readiness, main HPA bounds, deployment strategy, and PodDisruptionBudget
  against the selected topology. For multi-main, confirm the required license
  and inspect all main logs for competing leadership claims.
- Run a temporary, side-effect-free scheduled workflow before restoring business
  workflows. Record canonical scheduled times where available, execution IDs,
  retries, queue jobs, and worker outcomes. Capture logs from every main and
  worker, including pods that terminate during recovery.
- Observe at least three complete healthy schedule ticks. Report missed ticks
  during maintenance separately from steady-state failures, duplicate attempts,
  suppressed duplicates, and duplicate completions. A passing API count alone
  is insufficient.
- While reconciliation is still paused, align every reconciler's configuration
  with the destination topology. Resume reconciliation with business triggers
  and traffic still disabled. Recheck the workload and confirm a final Terraform
  plan reports no changes. Only then restore the recorded workflow activation
  state and traffic.

## Failure and rollback

Keep traffic and triggers disabled if startup, licensing, or validation fails.
Preserve logs and state before attempting recovery. Helm's `atomic` rollback can
restore a prior release revision, but it does not enforce the stop-before-start
invariant or prove that in-flight work was safe.

Do not repeatedly toggle `n8n_main_hpa_min_replicas`, blindly run `helm rollback`,
or reapply an old plan. Inspect the actual controllers and processes left by the
failed apply or automatic rollback. Re-establish the stopped-workload boundary,
then review a fresh recovery plan for one chosen topology before resuming work.

See [manual Azure qualification](./manual-azure-qualification.md) for the separate
live evidence required for each transition direction.
