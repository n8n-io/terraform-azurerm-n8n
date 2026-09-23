# Qualification run: pr6, Sweden Central, 2026-09-22

Filled-in copy of [`manual-azure-qualification.md`](../manual-azure-qualification.md)
for the live validation of PR #6 (`port-aws-050-enhancements`, including the
early-alpha `n8n_worker_pools` follow-up). It records what was observed on one
disposable deployment. It is not a release guarantee, and no result below
transfers to other regions, SKUs, or n8n versions.

```text
Environment:     n8n Solution Architects Production subscription, swedencentral.
                 pr6: examples/worker-pools root (a superset of examples/small:
                 same foundation plus the prerelease chart and three pools),
                 test-only overrides. A first attempt in germanywestcentral was
                 abandoned; see "Region note" below.
Module version:  port-aws-050-enhancements, 4b89f03 plus the review fix-up
                 committed on the same branch after this run
AKS version:     1.35.7 (desired 1.35)
n8n image tag:   2.39.0 (the example's default; runners 2.39.0)
Chart version:   1.11.0-preview.workerpools.1 (official preview build from
                 n8n-io/n8n-hosting preview/worker-pools)
Terraform:       1.16.3
Providers:       azurerm 4.81.0, kubernetes 3.2.1, helm 2.17.0,
                 kubectl 1.19.0, random 3.9.1, time 0.14.2
Date:            2026-09-22
Operator:        jan.repnak, with an AI coding agent preparing plans and
                 running checks; every apply ran against a saved plan the
                 operator had approved, and the region change was a separate
                 human decision
```

## How to read this report

- **PASS** means the expected outcome was observed for the stated scope.
- **PASS with findings** means the case passed but exposed a defect or a
  documentation gap; each finding names where it was addressed.
- **Not qualified** means the case was not run on this deployment, with the
  reason.
- Load and performance testing were excluded from this run.

## Deviations from the default configuration

Non-default inputs, all test values: `blob_delete_retention_days = 7` (to
exercise the new input), `common_tags` for the test owner, and
`n8n_chart_version = "1.11.0-preview.workerpools.1"` (required by the example).
Self-signed TLS from `modules/tls-self-signed`. The example-owned public zone
`pr6.n8ns.net` was delegated by hand from the shared `n8ns.net` Azure DNS zone
so public resolution could be verified. At the end of the run the four NS
records were removed; the now-empty `pr6` NS record set itself could not be
deleted because the shared zone carries a `CanNotDelete` lock that child
record sets inherit (the same inheritance `docs/deletion-safety.md`
describes). It is inert and can be deleted by whoever holds the lock.

## Region note

The run was requested for `germanywestcentral`. The preflight caught that
`Standard_D4s_v5` is offered in zones 2 and 3 only there (fixed with
`aks_availability_zones = ["2", "3"]`), and the first apply then failed on
`azurerm_managed_redis.n8n[0]` with `InsufficientCapacity` for `Balanced_B0`.
`Balanced_B1` failed the same way, and `--probe-redis` rejected
`Balanced_B3`, `MemoryOptimized_M10`, and `ComputeOptimized_X3` as well, so
the region had no Managed Redis capacity for any allowed SKU family at that
hour. Each failed attempt left a `CreateFailed` cluster outside Terraform
state that had to be deleted with `az redisenterprise delete` before retrying,
exactly as `docs/troubleshooting.md` describes. The 60 completed resources
were destroyed cleanly (59 in state plus the orphan), and the run moved to
`swedencentral`, where `--probe-redis` passed and the same configuration
applied with the example's default zones and SKU.

## Results

### 1. Fresh install (stage 1, pools declared but not wired)

**Result:** PASS with findings. 67 resources. The first `swedencentral` apply
failed on two read-after-create 404s (`azurerm_key_vault.tls` and
`azurerm_storage_account.n8n[0]`, ARM propagation lag); both were recorded
as tainted and replaced on the immediate re-apply before anything depended
on them (`32 added, 2 destroyed`, `Apply complete`). All five n8n pods
`Running`, four nodes `Ready` on `v1.35.7`, licence `isValid=true`.

Branch changes verified on this stage:

- `kubernetes ~> 3.0` / `time ~> 0.14`: resolved to 3.2.1 / 0.14.2; the plan
  and apply produced only the known "Deprecated Resource" warnings.
- `n8n_chart_version` prerelease passes the `helm_release.n8n` precondition;
  `helm list` reports `n8n-1.11.0-preview.workerpools.1 deployed`.
- `blob_delete_retention_days = 7`: `az storage account
  blob-service-properties show` reported `deleteRetentionPolicy` and
  `containerDeleteRetentionPolicy` both `enabled: true, days: 7`.
- No `worker-group` Deployment or ScaledObject and no
  `N8N_WORKER_POOLS_ENABLED` on the mains while the pools line is commented
  out.
- Default worker ScaledObject baseline: both triggers `enableTLS=true`,
  `authenticationRef=n8n-redis-keda-auth`, `Ready=True`.

Finding: `examples/worker-pools/main.tf` shipped with
`n8n_worker_pools = local.worker_pools` active although the README and the
comment above it say it starts commented out. Fixed in the review fix-up.

### Smoke test (stage 1)

**Result:** PASS. `tests/scripts/smoke-test.sh` from `examples/worker-pools`
with `N8N_API_KEY` set: DNS, HTTPS readiness, HTTP to HTTPS redirect, all six
path-routing checks, `TriggerAuthentication` present, worker KEDA
`Ready=True`, PostgreSQL/Redis/Blob env and log checks, API `200`, and an
end-to-end queue-mode execution (workflow created, activated, webhook fired,
execution completed). Load test skipped (opt-in). Two pre-existing
informational warnings about leader-election log evidence.

### 3. Helm update (stage 2, pools wired in)

**Result:** PASS. Uncommenting `n8n_worker_pools = local.worker_pools`
planned `0 to add, 1 to change, 0 to destroy` (in-place `helm_release.n8n`
with three `queueMode.workerGroups` entries and `N8N_WORKER_POOLS_ENABLED`),
and the apply completed without rollback. `n8n license:info` on a main pod
reports `feat:workerPools: true` and `feat:multipleMainInstances: true`, so
the unlicensed-pool rollback path was not exercised (it is confirmed in
`packages/cli/src/commands/worker.ts` at `n8n@2.39.0`: log error and
`process.exit(1)`).

Observed after the apply: `n8n-worker-heavy` 1/1, `n8n-worker-secteam` 1/1,
`n8n-worker-itop` 0/0 (parked, KEDA-owned), the default `n8n-worker` still
1/1 with no `N8N_WORKER_POOL_NAME`, `N8N_WORKER_POOLS_ENABLED=true` on both
mains, worker log line `* Pool: heavy`. All four ScaledObjects `Ready=True`.
Every pool trigger: `listName` `bull:jobs-<pool>:{wait,active}`,
`listLength` 5, `enableTLS=true`, `authenticationRef.name=n8n-redis-keda-auth`,
no `passwordFromEnv` or `username` in metadata. This is the shape the review
fix-up introduces; the PR's original flat `passwordFromEnv` metadata would
have failed the verifier's key-for-key comparison against the default
worker's scaler.

### Worker pools verifier

**Result:** PASS. `tests/scripts/verify-worker-pools.sh` from
`examples/worker-pools`: 3 Deployments and 3 ScaledObjects matching the
declaration, image floor, labels, `N8N_WORKER_POOL_NAME`, `READY=True`,
`scaleTargetRef`, queue names, Redis contract on all six triggers, external
metrics resolving for all three pools, default worker unlabelled. One
expected skip (no running `itop` pod to inspect at 0 replicas). This closes
task 7.10 of `openspec/changes/port-aws-050-enhancements/tasks.md`.

### Smoke test (stage 2)

**Result:** PASS. Re-run with the pools active: identical results to stage 1;
the default queue still executes end to end.

### 15. Normal destroy

**Result:** PASS for the `germanywestcentral` partial stack (59 resources
destroyed cleanly after the Redis orphan was removed by hand). The
`swedencentral` stack (67 resources, pools active) was destroyed after the
PR merged: `Destroy complete! Resources: 67 destroyed`, no `pr6*` resource
groups, no Managed Redis orphan, and no soft-deleted Key Vault left behind.
The manual project-to-pool routing check below was not performed before the
destroy.

### Cases 2, 4 to 14

**Not qualified** on this deployment. The 2026-09-16 pr4 run covers the
topology, rotation, DNS, and recovery cases on the same module shape; this
run was scoped to the changes PR #6 introduces.

## Not verified, needs a manual check

- Project-to-pool routing end to end (assign a project to `heavy` in the
  editor, run a workflow, confirm it executes on `n8n-worker-heavy` and the
  default worker stays idle). Needs an editor session; the example README
  describes the steps.
- The unlicensed-pool rollback path (code-confirmed only, see case 3).
- Reverting `blob_delete_retention_days` to `null` after an apply
  (documented as a one-way switch; not exercised).

## Harness notes

- The preflight's default run does not probe Managed Redis capacity; only
  `--probe-redis` does, and it is what found the `germanywestcentral` gap
  after the fact and cleared `swedencentral` before the retry. Run it before
  every live apply.
- `smoke-test.sh` prints the licence feature list on one long line; read
  `n8n license:info` directly when checking for a specific entitlement.
