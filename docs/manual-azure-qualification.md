# Manual Azure qualification checklist

This checklist is **not** part of implementation completion for
`port-aws-040-enhancements` or any other change in this repository.
`openspec/init.sh`, `terraform test`, and `tests/scripts/check-n8n-chart.sh`
prove the module's Terraform logic and the manifests Helm actually renders,
entirely offline. None of that proves live Azure lifecycle, performance,
licensing, or Redis TLS/ACL behavior — only an applied deployment can. Use
this document to record that evidence separately once you choose to run it;
leaving every row blank does not block a release or a merge.

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

**Expected outcome:** Terraform reports no changes (or only expected
computed-attribute drift, e.g. AKS-managed node counts under
`ignore_changes`). No Helm release upgrade fires.

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

### 4. Multi-main → single-main transition

**Setup:** Starting from a healthy multi-main deployment, set
`n8n_main_hpa_min_replicas = 1` and apply.

**Expected outcome:** Helm reduces the main Deployment to one replica, using
`Recreate`. Editor/API/scheduled-trigger requests are briefly interrupted
during the swap. `tests/scripts/smoke-test.sh` detects `single-main` and
passes with one ready main and no leader-election warning.

**Result:** _______________________________________________

### 5. Single-main → multi-main transition

**Setup:** Starting from a healthy single-main deployment on a license that
has `feat:multipleMainInstances`, set `n8n_main_hpa_min_replicas` back to 2+
and apply. Repeat once more on a license that does **not** have the
entitlement to confirm the failure/rollback path in
[`docs/troubleshooting.md`](./troubleshooting.md#switching-to-multi-main-fails-because-the-license-lacks-featmultiplemaininstances).

**Expected outcome (entitled license):** The additional main pod(s) start,
pass their license check, and elect a leader; `tests/scripts/smoke-test.sh`
detects `multi-main` and shows leader-election activity.
**Expected outcome (non-entitled license):** The additional main pod(s)
fail their license check, the Helm release times out, and `atomic = true`
rolls it back to the prior single-main revision. `terraform apply` reports
the Helm release as failed, but the cluster is left serving the old,
working topology.

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
main/worker task-runner sidecars reflect the new launcher allow-list.

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
