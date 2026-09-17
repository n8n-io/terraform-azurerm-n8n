# Qualification run: pr4 and pr4cm, Germany West Central, 2026-09-15 to 2026-09-16

Filled-in copy of [`manual-azure-qualification.md`](../manual-azure-qualification.md)
for the live validation of PR #4 (`port-aws-040-enhancements`). It records
what was observed on one disposable deployment. It is not a release
guarantee, and no result below transfers to other regions, SKUs, or n8n
versions.

```text
Environment:     n8n Solution Architects Production subscription, germanywestcentral.
                 pr4: examples/small root, zones 2 and 3, test-only overrides.
                 pr4cm: examples/customer-managed-everything root (second, shorter
                 deployment on 2026-09-16 for the customer-managed path, with the
                 Redis stand-in deviation described under case 11)
Module version:  jrx/port-aws-040-enhancements, 6192d7d through 03dfb09 (pr4cm ran 03dfb09)
                 (fixes found during this run were committed on the same branch)
AKS version:     1.35.7 (desired 1.35), Ubuntu 24.04
n8n image tag:   2.35.0 (runners 2.35.0)
Chart version:   1.10.0
Terraform:       1.16.1 (signed HashiCorp archive, isolated binary)
Providers:       azurerm 4.81.0, kubernetes 2.38.0, helm 2.17.0,
                 kubectl 1.19.0, random 3.9.0, time 0.14.0
Date:            2026-09-15 to 2026-09-16
Operator:        jan.repnak, with an AI coding agent preparing plans and
                 harnesses; every apply, disruptive step, and reopening had a
                 separate human approval against a hashed saved plan
```

## How to read this report

- **PASS** means the expected outcome was observed for the stated scope.
- **PASS with findings** means the case passed but exposed a defect or a
  documentation gap; each finding lists the commit that addressed it.
- **Not qualified** means the case was not run on this deployment, with the
  reason.
- Harness failures caused by the test tooling itself (not the module) were
  kept as failed artifacts and are listed under "Harness notes" rather than
  being rewritten as passes.
- Load and performance testing were excluded from this run.

## Deviations from the default configuration

Non-default inputs active for most of the run, all test values rather than
sizing recommendations: `redis_exporter_enabled = true`,
`appgw_waf_mode = "Detection"`, `aks_node_os_disk_size_gb = 256`,
`aks_node_vm_size = Standard_D4s_v5` (after the migration in case 6),
execution save policy `none`/`none`/`true`/`true`, PostgreSQL timing
30000/5000/5/3, Bull timing 90000/15000/45000, `n8n_node_max_old_space_size_mb
= 512`, pod DNS options `ndots=2`, `timeout=2`, `attempts=2`, a caller-managed
task-runner launcher ConfigMap (JavaScript `crypto,path,url`, 180 second
timeout), and a dummy `n8n_credentials_overwrite_secret_ref` Secret.
Self-signed TLS from `modules/tls-self-signed`.

## Results

### 1. Fresh install

**Result:** PASS. One apply created 67 resources. Licensing, private
connectivity to PostgreSQL, Redis, and Blob, HTTPS, the public API, and
production webhooks worked. Baseline smoke test: 41 passed, 0 failed, 1
warning, 1 skipped.

### 2. No-op apply

**Result:** PASS. Every follow-up plan after each applied change during the
run exited 0 with no resource or output changes (recorded per case).

### 3. Helm update and rollback

**Result:** PASS. Updates that only changed chart values rolled the affected
pods and converged. A deliberately failing same-topology change (missing
launcher ConfigMap) ended with `release n8n failed, and has been rolled back
due to atomic being set: context deadline exceeded`; Helm history showed the
failed revision and the rollback revision, workflows kept executing, and
public HTTPS stayed 200 across 60 samples.

### 4. Multi-main to single-main maintenance transition

**Result:** PASS with findings. A **live** crossing (changing
`n8n_main_hpa_min_replicas` on a running deployment) is unsafe in both
directions: during a single-to-multi crossing the old ReplicaSet scaled back
to 2, up to 3 mains claimed leadership, and a worker failure with missing
execution data was hidden behind 6 successful API ticks. The stopped-source
procedure (delete the main HPA, Deployment, ReplicaSets, and pods with the
normal grace period, prove no main container remains, apply the destination
topology, restore `atomic`/`cleanup_on_fail` afterwards) passed: one Ready
main with `Recreate`, HPA 1..1, PDB `minAvailable 0`, `multiMain` off, three
scheduled ticks produced exactly three worker jobs, no leader conflicts.

Finding: documented in [`topology-maintenance.md`](../topology-maintenance.md)
and the troubleshooting entry (commit f2f1db4). The smoke test's leader check
sampled one main and could report a false positive; fixed to read all mains
(commit 2048447).

### 5. Single-main to multi-main maintenance transition

**Result:** PASS (stopped-source procedure only). Two Ready mains, HPA 2..6,
PDB `minAvailable 1`, `RollingUpdate`, `multiMain` on. Three scheduled ticks
produced exactly three worker jobs and one leader claim matching 37 Redis
lease samples. The live crossing is unsupported (see case 4).

### 6. Node maintenance

**Result:** PASS. Ordinary drain and uncordon of one system node with the
pool minimum raised from 2 to 3 for headroom: 149 seconds, 21 HTTPS samples
all 200, one transient KEDA metrics gap, no leader conflicts. A staged VM-size
migration (`Standard_D2s_v5` to `Standard_D4s_v5`, system pool then user
pool, each with a 15 minute stability gate) kept the durable fixtures and
returned 72 and 91 HTTPS 200 samples respectively with temporary KEDA
errors. Both pools cycle their nodes despite an in-place plan.

### 7. AKS OS-disk rotation

**Result:** PASS with interruption. 128 GiB to 256 GiB, staged per pool.
System stage: 63 HTTPS 200 samples and one public read timeout at
06:06:06 UTC plus one KEDA error. User stage: 58 HTTPS 200 samples, two KEDA
errors. Both stages recovered within their 15 minute gates. Not a
zero-interruption qualification.

### 8. Secret / ConfigMap rotation

**Result:** PASS with expected restart requirement. Launcher ConfigMap and
credential-overwrite Secret changes project into the pods, but the launcher
mounts through `subPath` and n8n reads the overwrite file at startup, so
sequential main and worker rollout restarts were needed both times. After
restart the new launcher allowlist and the v2 overwrite header were in
effect. Credential overwrites were only observed on the worker; the
dedicated webhook process in n8n 2.35.0 does not initialize
`CredentialsOverwrites`.

Additional runtime checks in the same area: JavaScript tasks up to 110
seconds succeeded with the 180 second override, a 210 second task failed at
`Task execution timed out after 180 seconds` and the next task succeeded;
native Python allowed imports (`math`), rejected `os` and `requests` with the
exact policy errors, timed out at 10 seconds with the same runner process
serving the next task. Main-runner execution was not exercised.

### 9. Split-host OAuth and webhook behavior

**Result:** PASS with findings. With `n8n_additional_domains =
["hooks.pr4.n8ns.net"]` and `n8n_webhook_url = "https://hooks.pr4.n8ns.net"`,
all pods carried `N8N_WEBHOOK_URL` on the hooks host and
`N8N_EDITOR_BASE_URL` on the editor host, both hosts served a two-SAN
certificate, production webhooks returned 200 on both hosts and ran on the
webhook processors, and the instance base URL (source of the OAuth callback
URLs) stayed on the editor host. The full OAuth2 authorization round trip
and test-webhook execution need an editor session and were not exercised.
Public DNS resolution was not verified: the example-owned zone was never
delegated from its parent, so resolution used `/etc/hosts` and direct IP with
SNI.

Findings, both pre-existing since the initial commit and fixed in 08efb95:

- Editor test-mode paths (`/webhook-test`, `/form-test`, `/mcp-test`) were
  routed to the webhook processors because AGIC renders `Prefix` rules as
  string-prefix patterns (`/webhook*`). Fixed by routing the test prefixes to
  the main Service first; verified live (gateway path maps reordered, main
  answers the test paths).
- Changing `app_gateway_tls_cert_secret_id` was a no-op on an existing
  gateway because `ssl_certificate` was in `ignore_changes`. Fixed by
  reconciling the block; the plan showed no gateway churn afterwards. A
  Terraform-driven rotation was not re-run after the fix.

### 10. Private DNS resolution

**Result:** Not qualified. Requires `appgw_frontend_mode = internal`, which
would have replaced the public path every other case depended on.

### 11. Redis metrics, TLS, and ACL access

**Result:** PASS on both paths, with a deviation on the external path.
Module-managed (`pr4`): the exporter scraped Azure Managed Redis over TLS,
reported `redis_up 1`, and queue-length metrics tracked a queued execution
0 to 1 to 0; a checksum-verified local Prometheus 3.14.0 ingested it.
Disabling and re-enabling the exporter did not affect KEDA.

External (`pr4cm`, `create_redis = false`): Azure Managed Redis returned
`InsufficientCapacity` in the region for `Balanced_B0`, `Balanced_B1`, and
`MemoryOptimized_M10`, with and without zone-redundant high availability, over
about 90 minutes, so the caller-owned endpoint was an in-cluster `redis:7.4`
stand-in with TLS-only port 6379 and an ACL file (`default` disabled, `n8n`
user with `~* &* +@all` minus destructive and admin commands). It carried a
publicly trusted Let's Encrypt certificate for `pr4cm-redis.n8ns.net`
because the module exposes no private-CA input (see "Additional
observations"). Observed: certificate verification against the system CA
bundle succeeds without an insecure flag, the plaintext port is closed,
`default` and wrong-password logins are rejected, `CONFIG GET` and `LLEN`
are allowed and `FLUSHALL` / `ACL LIST` denied for `n8n`, all 49 client
connections (mains, worker, webhooks, KEDA, exporter) authenticate as `n8n`,
the exporter reports `redis_up 1` with both Bull queue keys, the KEDA
`ScaledObject` is `READY`, and a queued webhook execution ran on the
worker. Azure Managed Redis has no password ACL users, so a scoped user
against the managed service itself remains untested.

### 12. Recovery when the API is unavailable

**Result:** PASS for pre-write failure and for an unplanned partial apply;
mid-write interruption not induced. On `pr4`, a process-local CONNECT proxy
denied the AKS API host during a saved-plan apply: Terraform exited 1 after
13.8 seconds with `Kubernetes cluster unreachable: ... Service Unavailable`,
made no changes, and a fresh unproxied plan and apply reconciled cleanly.

On `pr4cm`, the fresh install stopped at 47 of 63 resources because of two
Azure-side failures in the same apply: Managed Redis `InsufficientCapacity`
and an ARM `HTTP response was nil; connection may have been reset` on a
role assignment whose PUT had actually succeeded. The reconciling plan
correctly proposed only the missing 16 resources, but two of them collided
with orphans Azure had kept (the `CreateFailed` Redis instance and the
orphaned role assignment). Recovery consisted of deleting the orphans in
Azure (`az redisenterprise delete`, `az role assignment delete`), no
`terraform import` or `state rm`, and re-applying; three further Redis
attempts each left one more `CreateFailed` orphan to delete before the
stand-in replaced it. Total: 1 partial apply, 3 failed retries, 1 recovery
apply, 5 orphan deletions, final plan `No changes`.

### 13. AKS credential rotation

**Result:** PASS. One `az aks rotate-certs` run (about 5 minutes), CA and
client fingerprints changed, the old kubeconfig was rejected, the cluster
was stable 15 minutes after completion with 4 Ready nodes and all roles
Ready. A normal plan with unchanged provider wiring showed no changes;
because the refreshed credentials only appear in state after an apply, a
no-change apply was run to persist them. Encryption key, stored credential,
and Blob object survived.

### 14. AKS replacement

**Result:** FAIL at plan time, recorded as unsupported. `terraform plan
-replace='module.n8n.azurerm_kubernetes_cluster.n8n[0]'` computed the eight
dependent changes correctly but exited 1 with `Get
"http://localhost/api/v1/namespaces/n8n": dial tcp [::1]:80: connect:
connection refused`, because the Kubernetes-side providers are configured
from `aks_kube_config`, which is unknown while the cluster is replaced
(hashicorp/terraform#24131). No apply was attempted. Documented in the
troubleshooting guide (commit 1c78166); the supported path is destroy and
recreate.

### 15. Normal destroy and caller-owned resource preservation

**Result:** PASS for `pr4` (module-managed half): `Resources: 0 added, 0
changed, 71 destroyed` in 888.5 seconds with the AKS API reachable. All Helm
releases, Kubernetes objects, and the KEDA TriggerAuthentication were
destroyed before the cluster. No forced finalizer removal or manual
cleanup. Afterwards no `pr4` resource groups, resources, or soft-deleted
Key Vaults remained (the example vault has purge protection disabled and
was purged).

`pr4cm` destroy: PASS after two Azure-side interruptions, three applies
(67 + 0 + 5 of 75 resources). First stop: the test-owned A record in the
shared `n8ns.net` zone could not be deleted (`409 ScopeLocked`) because the
zone carries a `CanNotDelete` lock from the Azure domain purchase, and zone
locks also block record-set deletion; the record and lego's leftover
`_acme-challenge` TXT set were removed with the zone lock temporarily
lifted and then restored (both locks verified identical afterwards).
Second stop: the AKS delete failed with `ResourceGroupDeletionBlocked`
because an Azure platform-initiated "VM Agent Rolling Upgrade" on the node
VMSS (started 18:46 UTC, after the last apply) refused the VMSS delete; the
AzureRM provider kept polling the failed operation past its 90 minute
delete timeout and was stopped with a single `SIGINT` at 95 minutes. A
fresh destroy plan after the upgrade completed removed the remaining five
resources in 206 seconds. No `pr4cm` resources, DNS records, or soft-deleted
vaults remain.

The caller-owned preservation half (remove only the `module "n8n"` call and
keep caller-owned resources) was not run on either deployment.

## Additional observations outside the checklist

- **Webhook execution retention (fixed, commit 2842ce9).** The pinned chart
  renders `executions.data` on main and worker pods only, so the configured
  success/error save policy was ignored for webhook-triggered executions.
  The module now renders the four settings into
  `webhookProcessor.extraEnv`; verified live with an A/B before and after.
- **TLS rotation through Terraform (verified after the fix, `pr4cm`).**
  Replacing the self-signed Key Vault certificate produced one plan with the
  certificate replacement and exactly one in-place `ssl_certificate` update
  on the Application Gateway; after a 73 second apply the served
  certificate fingerprint changed, state and Azure both reference the new
  version, and the follow-up plan is a no-op. The same `ssl_certificate`
  ignore was also present in the four caller-owned gateways of
  `split-ingress`, `customer-managed-cluster`, and
  `customer-managed-everything`; removed in the same follow-up commit.
- **No private-CA input for external Redis TLS.** KEDA's redis scaler
  accepts `ca` in `TriggerAuthentication`, the exporter accepts a CA file,
  and n8n honors `NODE_EXTRA_CA_CERTS`, but the module renders all three
  itself and exposes none of them. External Redis with a private CA is
  therefore unsupported; a publicly trusted chain is required.
- **Fresh-install license race (`pr4cm`).** Worker and webhook-processor pods
  each exited once with `Could not activate license ... Azure Blob binary
  data storage requires a valid license` before the main had activated the
  license, then restarted and stayed healthy. One restart per pod, chart
  start ordering, no action needed beyond awareness.
- **Startup warnings observed repeatedly and unchanged across the run:**
  Confluence node `Unknown credential name "confluenceCloudOAuth2Api"`,
  PostgreSQL 16 compatibility-support deprecation, `MultiMainSetup`
  listener-limit warning.
- **WAF maintenance gate.** A Prevention-mode block-all custom rule kept the
  public path closed during the topology and certificate maintenance; it
  does not recall already-admitted connections, and an empty main backend
  returns 502 through the gateway, which is not gate evidence.

## Harness notes (retained failed artifacts)

- Helm rollback preflight: `'function' object has no attribute 'client'`
  before the corrected run.
- Multi-main stop assessment: `Public gate not confirmed` because the empty
  backend returned 502; an independent assessment proved the boundary.
- Certificate rotation: VMSS query used `diskSizeGb` instead of `diskSizeGB`;
  the recovery continuation used the corrected field.
- Python qualification: one 15 second public request timeout right after the
  main rollout (four later rounds all 200); the task-runner container logs
  carry launcher messages only, so runner-receipt timing is unqualified.
- Split-host: a fixture using `$env` was blocked by n8n's default
  `N8N_BLOCK_ENV_ACCESS_IN_NODE` and returned 500; rerun without it.
- Ingress fix: the `/form-test` assertion expected JSON; n8n answers with an
  HTML page from main.
- `pr4cm` TLS rotation: a regex against `terraform state show` failed on the
  sensitive `secret_id`; verification continued from the pulled state JSON.
- `pr4cm` destroy: the AzureRM AKS delete did not honor its timeout after
  Azure had marked the operation failed; stopped with one `SIGINT`.

## Not covered in this run

Case 10 (private DNS with an internal gateway); a scoped ACL user against
Azure Managed Redis itself (no password ACL users exist there); the
caller-owned preservation half of case 15; an induced mid-write apply
interruption (case 12); main-runner task execution; custom n8n images;
failure behavior when the license lacks an entitlement; backup restoration
(seven-day PostgreSQL retention was confirmed as metadata only); load and
performance.
