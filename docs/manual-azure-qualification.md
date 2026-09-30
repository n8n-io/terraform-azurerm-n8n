# Manual Azure qualification checklist

This checklist is **not** part of implementation completion for
`port-aws-040-enhancements` or any other change in this repository.
`openspec/init.sh`, `terraform test`, and `tests/scripts/check-n8n-chart.sh`
prove the module's Terraform logic and the manifests Helm actually renders,
entirely offline. None of that proves live Azure lifecycle, performance,
licensing, or Redis TLS/ACL behavior — only an applied deployment can. Use
this document to record that evidence separately once you choose to run it;
leaving rows blank does not block implementation completion or a merge.
Mark those behaviors as unverified in release notes until evidence is recorded.
Do not claim a verified one-apply release guarantee without completing the
live lifecycle checks required by `AGENTS.md`.

Do not substitute `terraform-aws-n8n`'s measured outcomes, load-test numbers,
or qualification results for a row below. AWS and Azure use different
managed services (RDS vs. Flexible Server, ElastiCache vs. Managed Redis, EKS
vs. AKS) with different failure modes; an AWS result is not Azure evidence.

## How to use this checklist

For each case: apply the described configuration or transition against a
real (non-production, ideally) Azure subscription, observe the expected
outcome, and fill in the **Result** row with what actually happened,
including any deviation. Keep one filled-in copy per qualification run
(environment + module version), not a single shared document that gets
overwritten.

```text
Environment:     <subscription / resource group / region>
Module version:  <git tag or commit>
AKS version:     <az aks show --query kubernetesVersion>
n8n image tag:   <var.n8n_image_tag>
Chart version:   <var.n8n_chart_version>
Date:            <run date>
Operator:        <name>
```

## Safety and acceptance

Use a disposable deployment with separate state and an agreed spending limit.
Before disruptive cases, back up state, the n8n encryption key, and durable data.
Confirm node quota and subnet capacity, review each saved Terraform plan, and
obtain operator approval before applying it. Run the AKS replacement plan check
and destroy last. Never commit state, saved plans, Secrets, or credential-bearing logs.

A smoke-test exit code of 0 is not sufficient evidence by itself. Record and
resolve warnings and skips relevant to each case. Supply an API key for the
execution checks. For split ingress, test the advertised webhook host separately:
the script sends webhook requests to the editor URL. Validate TLS certificates
with a separate client because the script uses `curl -k`. With remote Terraform
state, supply the script's environment variables explicitly; its automatic
output discovery requires a local `terraform.tfstate` file.

## Checklist

### 1. Fresh install

**Setup:** `terraform apply` against an empty resource group using one of
`examples/small`, `examples/medium`, or `examples/large`.

**Expected outcome:** One apply completes without a second pass. AKS, node
pools, PostgreSQL, Redis, Blob storage (if enabled), App Gateway, KEDA, and
the n8n Helm release all reach a ready state. `tests/scripts/smoke-test.sh`
exits 0.

**Result:** _______________________________________________

### 2. No-op apply

**Setup:** `terraform apply` again immediately after case 1, with no
variable changes.

**Expected outcome:** Terraform reports no changes. A subsequent
`terraform plan -detailed-exitcode` returns 0. Repeat after autoscaler activity:
ignored node counts must not cause a reset or a Helm upgrade. Investigate any
remaining drift rather than accepting it as a no-op.

**Result:** _______________________________________________

### 3. Helm update and rollback

**Setup:** Change a value that only affects `helm_release.n8n` (e.g. a
runtime tuning input from section 3-8 of this change), apply, then revert
the input and apply again.

**Expected outcome:** The first apply performs a Helm upgrade; `wait = true`
and `atomic = true` mean a failed upgrade rolls back automatically. The
second apply performs a clean upgrade back to the prior values. No pods are
stuck `CrashLoopBackOff` after either apply.

**Result:** _______________________________________________

### 4. Multi-main to single-main maintenance transition

**Setup:** Follow the [maintenance-only transition checklist](./topology-maintenance.md)
on a disposable deployment. Disable triggers and incoming execution traffic,
resolve outstanding work, and prevent controllers from recreating old mains.
Record proof that all old main processes and their source workload controllers
are gone before applying a freshly reviewed plan with
`n8n_main_hpa_min_replicas = 1`. A direct live change is unsupported.

**Expected outcome:** The destination has one ready main, HPA bounds 1/1,
`Recreate`, and PDB minimum 0. No source main overlaps with the destination.
Before restoring business workflows, a temporary scheduled fixture completes
at least three healthy ticks. Reconcile canonical scheduled times, execution
IDs, queue jobs, and all main/worker logs; successful execution counts alone
do not rule out duplicate attempts. Record maintenance downtime and missed
ticks separately. Resume traffic only after verification and a no-op plan.

**Result:** _______________________________________________

### 5. Single-main to multi-main maintenance transition

**Setup:** Use the same [stop-before-start procedure](./topology-maintenance.md)
with a destination license that has `feat:multipleMainInstances`. Verify all
old single-main processes and their source workload controllers are gone
before applying a freshly reviewed plan with `n8n_main_hpa_min_replicas = 2`
or more. A direct live change is unsupported, even during a maintenance window.

**Expected outcome:** New mains pass licensing and converge on the destination
topology without source-process overlap. HPA bounds and PDB match the selected
floor. Capture leadership, duplicate suppression, queue jobs, worker failures,
and execution outcomes through at least three healthy schedule ticks. Inspect
all main logs; a leader-election message alone does not prove unique leadership.
Resume business workflows and traffic only after verification and a no-op plan.

**Separate failure case:** With explicit approval on a disposable deployment,
repeat destination startup without the required entitlement to qualify the
[license-failure path](./troubleshooting.md#switching-to-multi-main-fails-because-the-license-lacks-featmultiplemaininstances).
Keep triggers and traffic disabled. Record the failed apply, automatic rollback,
actual remaining processes, and recovery steps. Do not assume rollback preserves
the stop-before-start boundary or restores a healthy topology. Review a fresh
recovery plan before restarting either topology.

**Result:** _______________________________________________

### 6. Node maintenance

**Setup:** Cordon and drain one AKS node in the default node pool
(`kubectl cordon` / `kubectl drain`) while the deployment is under light
synthetic load.

**Expected outcome:** Evicted pods reschedule onto remaining nodes; the main
PDB (`minAvailable = 1` in multi-main, `0` in single-main) governs how many
main pods the drain can evict at once. n8n continues serving requests
throughout (multi-main) or experiences the same brief interruption as a
`Recreate` rollout (single-main).

**Result:** _______________________________________________

### 7. AKS OS-disk rotation

**Setup:** Set `aks_node_os_disk_size_gb` to a new value on an existing
cluster and apply — see
[`docs/troubleshooting.md`](./troubleshooting.md#changing-aks_node_os_disk_size_gb-on-an-existing-cluster-disrupts-workloads).

**Expected outcome:** AzureRM cycles the affected node pool. This is
disruptive — it does **not** cordon and drain pods first. Confirm workload
recovery afterward and that no data was lost (the OS disk is ephemeral to
the node, not to workload state).

**Result:** _______________________________________________

### 8. Secret / ConfigMap rotation

**Setup:** Rotate the credential-overwrite Secret's payload
(`n8n_credentials_overwrite_secret_ref`) and the task-runner launcher
ConfigMap (`n8n_task_runner_custom_config`), each followed by the documented
manual `kubectl rollout restart`.

**Expected outcome:** Neither rotation triggers an automatic pod restart
(by design — the module never reads either payload). After the manual
restart, main/worker/webhook pods reflect the new credential-overwrite data;
worker task-runner sidecars reflect the new launcher allow-list (main pods
carry no sidecar in queue mode on chart 1.14.0).

**Result:** _______________________________________________

### 9. Split-host OAuth and webhook behavior

**Setup:** Apply `examples/split-ingress` (or an equivalent split-host
configuration using `n8n_webhook_url`). Register an OAuth2 credential and
complete its authorization flow; trigger a production webhook and a test
webhook.

**Expected outcome:** OAuth2 redirects return to
`https://<admin-domain>/rest/oauth2-credential/callback` (the editor host),
not the webhook host. Production webhooks resolve against the public
webhook host. Test-webhook and Form Trigger test-mode URLs use n8n's
configured webhook base — verify their behavior explicitly, since this is a
compatibility check, not a guaranteed no-op.

**Result:** _______________________________________________

### 10. Private DNS resolution

**Setup:** Apply with `create_private_dns_record = true` and a
`private_dns_zone_id` linked to the AKS VNet.

**Expected outcome:** In-cluster and VNet-joined clients resolve
`var.n8n_domain` to the App Gateway's private frontend IP. External clients
do not resolve it (or resolve it differently, if a public zone also
exists).

**Result:** _______________________________________________

### 11. Redis metrics, TLS, and ACL access

**Setup:** Enable `redis_exporter_enabled = true` against both a
module-managed Azure Managed Redis instance and an external Redis endpoint
with `redis_external_tls_enabled = true` and a scoped ACL user.

**Expected outcome:** The exporter's `/metrics` endpoint reports `redis_up
1` on both paths. Confirm the ACL user has only the permissions the exporter
needs (key reads, `INFO`, `CONFIG GET`) — a rendered `rediss://` URL is not
proof the ACL is correctly scoped or that the TLS handshake actually
succeeds; only a live scrape confirms both.

**Result:** _______________________________________________

### 12. Recovery when the API is unavailable

**Setup:** During a `terraform apply`, block egress to the Azure or AKS API
momentarily (e.g. a transient network policy or a simulated outage window)
and observe the apply's behavior; re-run once connectivity is restored.

**Expected outcome:** The interrupted apply fails cleanly rather than
leaving state inconsistent with reality. A subsequent `terraform plan`
reconciles state against the actual (possibly partially-applied) resources,
and a following `terraform apply` completes without manual state surgery.

**Result:** _______________________________________________

### 13. AKS credential rotation

**Setup:** On the disposable module-managed cluster, rotate the AKS cluster
certificates using the Azure procedure supported by its installed version.
Wait for the rotation to complete. Refresh the operator's kubeconfig, then
run a normal Terraform plan and apply using the caller's existing
`kubernetes`, `helm`, and `kubectl` provider configuration.

**Expected outcome:** All three providers use the refreshed cluster credentials
without manual state edits or provider rewiring. The workload recovers, the
smoke test passes, and a subsequent plan reports no changes. Record any
transient provider failure and whether a retry was needed. Do not record
certificate keys or kubeconfig contents in the qualification results.

**Result:** _______________________________________________

### 14. AKS replacement

**Setup:** Use a disposable module-managed deployment with backed-up encryption
key and durable data. Request replacement of its AKS resource through a saved
Terraform plan (`terraform plan -replace='module.n8n.azurerm_kubernetes_cluster.n8n[0]'`).
Review all dependent changes: PostgreSQL, Redis, Blob storage, the Key Vault
certificate, the Application Gateway, and the encryption key must not be
replaced.

**Expected outcome:** The plan cannot be produced. Replacing the cluster makes
`aks_kube_config` unknown at plan time, and the caller's `kubernetes`, `helm`,
and `kubectl` providers, which are configured from it, fall back to an empty
configuration. Refreshing the existing namespaces then fails with
`Get "http://localhost/api/v1/namespaces/n8n": dial tcp [::1]:80: connect: connection refused`.
This is a Terraform provider-configuration constraint, not a module defect
(see [`troubleshooting.md`](./troubleshooting.md#terraform-plan--replace-on-the-aks-cluster-fails-with-connection-refused)).
In-place AKS replacement is therefore **outside the one-apply contract**.
Record the failing plan as evidence; do not fall back to `-target` or
`terraform state rm` in the qualification. The supported path is destroy and
recreate with the backed-up encryption key and durable data, exercised by
case 15 followed by case 1.

See [`qualification-runs/`](./qualification-runs/) for filled-in copies of
this checklist from previous runs.

**Result:** _______________________________________________

### 15. Normal destroy and caller-owned resource preservation

**Setup:** After all other cases, stop test traffic and back up any data to
retain. Review a saved destroy plan and apply it while the AKS API is reachable.
Record the test deployment's Azure and Kubernetes resource inventory before
and after teardown.

For the caller-managed path, remove only the n8n module call from a disposable
caller configuration and apply the reviewed plan. Keep caller-owned cluster,
namespace, KEDA, Secrets, ConfigMaps, and data resources declared. Destroying an
entire example root would also destroy resources that the example itself owns.

**Expected outcome:** Managed workload resources uninstall before their cluster
becomes unavailable. Normal teardown completes without forced finalizer removal
or manual state surgery, and no unexpected billable resources remain. Removing
only the n8n module preserves caller-owned resources and their data. Record
expected retained resources, including Azure soft-deleted objects, separately
from cleanup failures.

**Result:** _______________________________________________
