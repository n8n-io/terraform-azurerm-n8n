# Pre-apply, post-deployment, and chart-rendering scripts

Five scripts. `check-n8n-chart.sh` is offline and runs in CI on every
pull request. `smoke-test.sh`'s topology-detection self-test
(`SMOKE_TEST_SELF_TEST=1`) also runs offline in CI; the rest of
`smoke-test.sh`, all of `verify-custom-image.sh`, and
`preflight-region-check.sh` are manual verification scripts that need live
Azure credentials, which a pull request check cannot provide (CI only
syntax-checks and shellchecks the preflight script).

| Script | Use it when |
|---|---|
| [`preflight-region-check.sh`](#region-preflight) | Before the first `terraform apply` in a new region or subscription. Checks AKS zone support, PostgreSQL Flexible Server version/SKU availability, and (opt-in) Managed Redis capacity against your own plan. |
| [`check-n8n-chart.sh`](#chart-rendering-check) | Any change to `n8n.tf`, chart-affecting variables, or the pinned `n8n_chart_version`. Runs offline in CI. |
| [`check-redis-exporter.py`](#redis-exporter-outage-check) | Changes to exporter probes, timeouts, or the pinned image. Runs against a local hanging TCP peer in CI. |
| [`smoke-test.sh`](#smoke-test) | Always, after any deploy. Checks the deployment is healthy end to end. Its offline self-test runs in CI on every pull request. |
| [`verify-custom-image.sh`](#custom-image-verification) | The deployment sets `n8n_image_repository` and `n8n_custom_extensions_path` to bake community packages into the image. |

## Region preflight

`preflight-region-check.sh` answers one question before a 15-30 minute
apply: can this subscription actually get the managed services the module
asks for in this region? Three failures observed in live runs only surface
after the VNet, Key Vault, and Application Gateway already exist, and are
region or subscription gaps rather than module bugs:

| Failure | Check |
|---|---|
| AKS `AvailabilityZoneNotSupported` | `az vm list-skus` for the planned `aks_node_vm_size`: SKU offered, no location-level subscription restriction, every planned zone in the SKU's zone list (zone-level restrictions are subtracted first) |
| PostgreSQL Flexible Server `ParameterOutOfRange: 'Version' should be in: []` | `az postgres flexible-server list-skus`: at least one version offered, the planned `pg_version` among them, the planned `pg_sku_name` under its edition |
| Azure Managed Redis `InsufficientCapacity` | Opt-in `--probe-redis` only: creates a throwaway cluster of the planned `redis_sku_name` in a tagged `n8n-preflight-*` resource group and deletes it. Azure has no capacity API, so the answer is valid only for the moment it runs |

It also confirms the seven resource providers the module needs are
registered, validates the region name, and reports `az` errors (expired
login, throttling) as such rather than as "not offered".

### Prerequisites

- `az` `>= 2.75` (the script checks and refuses older releases: they
  return a differently nested `az postgres flexible-server list-skus`
  payload that would report every version and SKU as missing, and the
  `redisenterprise` extension declares the same floor), logged in with the
  target subscription selected. `--probe-redis` installs the
  `redisenterprise` extension when missing
- `jq`
- `terraform` with `terraform init` already run in the root you are about
  to apply (not needed when `--region` is passed)

### Running it

Run it from the root you will apply, with the same `terraform.tfvars`:

```bash
az login
cd examples/small
terraform init
../../tests/scripts/preflight-region-check.sh                # plan + checks
../../tests/scripts/preflight-region-check.sh --probe-redis  # also probe Redis capacity
```

With no flags it runs `terraform plan -refresh=false` in the current
directory and reads the location, VM size, zones, PostgreSQL version/SKU,
and Redis SKU from the planned resources, so the check matches what apply
would request rather than the module defaults. A resource the
configuration does not create (`create_aks`, `create_database`,
`create_redis` = `false`) is absent from the plan and its check is skipped.

Every value can be overridden (`--dir`, `--region`, `--vm-size`, `--zones`,
`--pg-version`, `--pg-sku`, `--redis-sku`). `--region` alone skips the plan
and checks the root module's defaults plus your flags, not the current
root's `terraform.tfvars`; the script prints a note when it takes that
path. `--help` lists the options.

Pass `--zones ''` to check a zone-less region explicitly; an omitted flag
falls back to the plan (or the root default `1,2,3` with `--region`). If the
plan contains managed resources in more than one region the script stops and
asks for `--region`; data sources such as `data.azurerm_kubernetes_cluster.existing`
are ignored when detecting the region.

Exit code `0` when every check passes or is skipped, `1` on any failure,
`2` on a usage error. After the probe, deletion of the `n8n-preflight-*`
resource group is *submitted* (`--no-wait`) and Azure completes it in the
background; the script prints the submission result and fails with the
manual `az group delete` command if the submission itself is rejected, so a
billable probe cluster is never left behind silently. An abort mid-probe
(Ctrl-C) triggers the same deletion from an EXIT trap.

## Chart-rendering check

`check-n8n-chart.sh` renders the pinned n8n Helm chart
(`var.n8n_chart_version`) with the actual `helm_release.n8n.values`
exported from ten mocked, plan-only fixtures in
`tests/chart-values.tftest.hcl`, then asserts on the manifests Helm
actually produces. It therefore catches regressions in the wiring in
`n8n.tf`, rather than testing a separately reconstructed values map.

It needs no Azure or Kubernetes credentials and creates no
infrastructure: all providers are mocked, Terraform only plans, and
`helm template` renders locally against the chart pulled from its OCI
registry.

### Prerequisites

- Terraform 1.11+ (`override_during` is used by the mocked fixture)
- `helm` v3+ (Helm's built-in JSON-schema validation runs automatically
  on every `helm template` call this script makes; no flag is needed to
  enable it)
- `jq`

### Running it locally

```bash
terraform init -backend=false   # once, from the repo root
tests/scripts/check-n8n-chart.sh
```

### What it covers

- Deployment families (`deployment-main`, `deployment-worker`,
  `deployment-webhook-processor`) at their configured replica floors.
- The main `HorizontalPodAutoscaler` bounds/threshold and the main
  `PodDisruptionBudget` minimum/selector.
- The worker `ScaledObject`'s replica bounds and both `bull:jobs:wait` /
  `bull:jobs:active` triggers.
- Execution save-policy environment values (`EXECUTIONS_DATA_SAVE_*`) exactly
  once on main, worker, and webhook-processor containers. The module supplies
  the webhook entries because the pinned chart omits them for that role.
  Webhook processors need these settings to decide final execution retention.
- The current `N8N_WEBHOOK_URL` environment entry on all three
  application containers, and the absence of the chart's own deprecated
  `WEBHOOK_URL` alias (which only renders when `webhook.url` or
  `ingress.enabled` is set — neither is set by this module).
- A self-test proving the script's duplicate-environment-name detector
  actually flags an intentionally duplicated fixture, followed by a real
  duplicate-name scan of every rendered container.

This script does not prove a live Helm upgrade or rollback succeeds;
see the manual Azure qualification checklist for that.

## Redis exporter outage check

The check reads the exporter environment and probe paths from a mocked
Terraform plan. It starts the pinned exporter against a local TCP server
that accepts connections but never responds. Both probes must return `ok`
while a scrape is blocked, and the scrape must report `redis_up 0` within
10 seconds. This tests the upstream binary, not Kubernetes restart behavior
or the container image's TLS trust store.

Requires Python 3, Go, and initialized Terraform. Building the binary needs
network access; the test itself uses only loopback and mocked providers.
The check verifies that the binary's module version matches the default image.

```bash
export GOBIN="$(mktemp -d)"
go install github.com/oliver006/redis_exporter@v1.90.0
python3 tests/scripts/check-redis-exporter.py "$GOBIN/redis_exporter"
rm -rf "$GOBIN"
```

## Smoke test

Post-`terraform apply` smoke test for `terraform-azurerm-n8n`. Verifies the
Azure deployment is healthy end to end — pod health, queue mode, KEDA, App
Gateway HTTPS, API connectivity, and a full webhook → worker execution. The
script detects whether the cluster is running the default multi-main
topology or the optional single-main topology
(`n8n_main_hpa_min_replicas = 1`, port-aws-040-enhancements section 2) from
the rendered chart resources, and branches its main replica/HPA/strategy/PDB/
leader-election checks accordingly; every other check applies to both.

### Offline self-test

`detect_topology()` and `check_deployment()` — the two functions the
topology branching depends on — can be exercised without Azure credentials,
a live cluster, or Terraform state:

```bash
SMOKE_TEST_SELF_TEST=1 tests/scripts/smoke-test.sh
```

This stubs `kubectl` with synthetic fixtures for intentional single-main,
healthy multi-main, degraded multi-main with one ready pod of two desired,
and invalid HPA/strategy/PDB combinations. It asserts the expected
topology/floor/pass-fail outcome for each and exits before the script's
`Preflight` section (which requires `az login`). Missing or inconsistent
topology safeguards fail the live smoke test rather than producing warnings.
The self-test summary includes intentional failures from negative fixtures;
its final exit code reports whether all fixtures behaved as expected. Run it
after touching `detect_topology()`, `check_deployment()`, or their fixtures. This self-test (only) runs in CI on
every pull request; the live smoke test past it needs a real cluster and
stays a manual, post-`apply` step — see "Smoke test" above.

This is the Azure sibling of
[`terraform-aws-n8n/tests/scripts/smoke-test.sh`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/tests/scripts/README.md).
The two share the same overall structure (preflight → namespace →
deployment health → managed-service connectivity → ingress → API →
execution → opt-in load test); the deltas live in the Azure-specific
checks that have no AWS analogue (PostgreSQL Flexible Server, Azure Blob,
Application Gateway).

### What it covers

| Check | What it verifies |
|---|---|
| `kubectl` cluster connectivity | `az aks get-credentials` populates a kubeconfig and `kubectl get nodes` succeeds against the AKS API server |
| Namespace exists | The configured namespace is present |
| Topology detection | Reads the rendered `n8n-main` HPA/Deployment/PDB to determine single-main (HPA 1/1, `Recreate`, PDB minAvailable 0) vs. multi-main (HPA floor > 1, rolling update, PDB minAvailable 1) — never inferred from the current main pod count |
| Main / worker / webhook-processor pod health | Each deployment is at its detected-topology floor (`MAIN_MIN` = 1 for single-main or the rendered HPA floor for multi-main, `WORKER_MIN=1`, `WEBHOOK_MIN=2` — match the `kubernetes_horizontal_pod_autoscaler_v2.webhook_processor` `min_replicas = 2`) |
| Application version | `n8n --version` (and the pod's image tag) agree across main, worker, and webhook-processor pods — catches a half-finished rollout before any functional check runs |
| Leader election | Multi-main expects `N8N_MULTI_MAIN_SETUP_ENABLED=true` on main pods plus leadership activity in main logs; single-main expects the flag unset/false and skips the log check (single-main runs no Redis leader election) |
| Task runner sidecar (workers) | Runner sidecar is present on worker pods and connected to the broker (skipped when `n8n_task_runners_enabled = false`) |
| KEDA `TriggerAuthentication` | `n8n-redis-keda-auth` CR is present in the n8n namespace — the n8n chart's worker `ScaledObject` references it; without it KEDA can't authenticate against Azure Managed Redis and the worker pool won't scale |
| Autoscaler configuration | KEDA `ScaledObject` (workers, queue-depth driven against Azure Managed Redis) and HPA (`n8n-webhook-processor`) state |
| Redis connectivity | Worker pods see `QUEUE_BULL_REDIS_HOST` (the Azure Managed Redis private hostname) and the BullMQ-related log lines |
| PostgreSQL connectivity | Main pod's `DB_POSTGRESDB_HOST` matches `terraform output postgres_fqdn`, and its logs carry no connection or authentication errors |
| Azure Blob storage | Main pod's `N8N_EXTERNAL_STORAGE_AZURE_*` environment matches `storage_account_name` / `azure_blob_container_name`, and its logs carry no Blob authorization errors — skipped unless `N8N_DEFAULT_BINARY_DATA_MODE=azure` |
| App Gateway public IP reachable | TCP/443 listener responds on the static public IP |
| HTTPS reachability | `/healthz/readiness` (or `/healthz` on older n8n) returns HTTP 200 over the App Gateway listener — works via DNS or `--resolve` to `APPGW_PUBLIC_IP` when the parent zone isn't delegated yet |
| HTTP → HTTPS redirect | Port 80 redirects to 443 (the chart sets `appgw.ingress.kubernetes.io/ssl-redirect = "true"` on the n8n Ingress) |
| Webhook route ownership | Every prefix in `n8n_webhook_path_prefixes` (`/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, `/mcp`) routes to the webhook-processor Service ahead of the `/` catch-all, which routes to the main Service — skipped (with guidance) when `create_ingress = false` |
| API connectivity (if API key set) | `/api/v1/workflows?limit=1` responds with HTTP 200 |
| Workflow execution (if API key set) | Creates a webhook → set workflow, fires it through the App Gateway listener, confirms a `success` execution status, deletes it |
| n8n license validity | `n8n license:info` exec'd inside a Ready main pod surfaces the active license tier (no API key needed) |
| Worker scaling (opt-in, requires API key) | Queues CPU-burning webhook executions and confirms KEDA scales `n8n-worker` up via Redis queue depth |

> **Azure Blob acceptance note:** the checks above prove the
> *infrastructure* wiring (environment variables, Secrets, absence of
> authorization errors). The module-verification spec's stronger
> acceptance criteria — n8n actually writing, reading, downloading, and
> pruning binary/execution data through the private container — need a
> real workflow execution against a live deployment. Exercise those
> manually per `docs/data-storage.md` before treating a storage-mode
> change as verified; this script only proves the wiring is in place, not
> that every n8n-level data operation succeeds.

### Quick start

The script reads `n8n_namespace`, `n8n_url`, `aks_cluster_name`,
`aks_resource_group`, `appgw_public_ip`, `kubectl_config_command`,
`postgres_fqdn`, `storage_account_name`, and `azure_blob_container_name`
automatically from `terraform output`.

```bash
az login                              # the script verifies this up front
cd examples/small                     # or wherever your terraform.tfstate lives
../../tests/scripts/smoke-test.sh
```

The script automatically:

1. Reads the Terraform outputs above from `$TERRAFORM_DIR` (defaults to
   the current working directory).
2. Runs the `kubectl_config_command` output (which evaluates to
   `az aks get-credentials --name <cluster> --resource-group <rg>
   --overwrite-existing`) to point `kubectl` at the right cluster.
3. Runs all checks and prints a pass / fail / warn / skip summary.

> **Note:** Run the script from the directory that holds
> `terraform.tfstate` (e.g. `examples/small/`), not from
> `tests/scripts/`. The script calls `terraform output` against the
> current working directory by default.

### API key (required for API and execution tests)

The API connectivity, workflow execution, and load-scaling checks need
an n8n API key. Without one, those checks are skipped with a warning.

1. Open your n8n instance in a browser (DNS-resolved or via the AGW IP +
   `--resolve` if the parent zone isn't delegated yet).
2. Go to **Settings → API → Create API Key**.
3. Copy the key.

Set it before running the script:

```bash
N8N_API_KEY=your-key-here ../../tests/scripts/smoke-test.sh
```

Or persist it in a `.env` file. The script looks for `.env` next to
itself first, then in the current working directory:

```bash
cp ../../tests/scripts/.env.example ../../tests/scripts/.env
# edit .env, set N8N_API_KEY, then:
../../tests/scripts/smoke-test.sh
```

### Configuration

All settings can be overridden via environment variables or a `.env`
file.

| Variable | Default | Description |
|---|---|---|
| `TERRAFORM_DIR` | `$(pwd)` | Path to Terraform directory to read state from |
| `N8N_URL` | *(from `terraform output`)* | Base URL of the n8n deployment |
| `NAMESPACE` | *(from `terraform output`)* | Kubernetes namespace |
| `AKS_CLUSTER_NAME` | *(from `terraform output`)* | AKS cluster name (used by `az aks get-credentials`) |
| `AKS_RESOURCE_GROUP` | *(from `terraform output`)* | AKS resource group |
| `APPGW_PUBLIC_IP` | *(from `terraform output`)* | App Gateway public IP — used as the `--resolve` target when DNS hasn't propagated yet |
| `POSTGRES_FQDN` | *(from `terraform output`)* | Expected PostgreSQL FQDN, cross-checked against the main pod's `DB_POSTGRESDB_HOST` |
| `STORAGE_ACCOUNT_NAME` | *(from `terraform output`)* | Expected Azure Storage account name, cross-checked against the main pod's Blob environment |
| `BLOB_CONTAINER_NAME` | *(from `terraform output`)* | Expected Azure Blob container name, cross-checked against the main pod's Blob environment |
| `N8N_API_KEY` | — | API key for API and workflow execution tests |
| `LOAD_TEST` | `false` | Set to `true` to run the worker scaling test |
| `LOAD_REQUESTS` | `100` | Webhook executions to fire during the load test |
| `LOAD_CONCURRENCY` | `20` | Concurrent in-flight webhook calls |
| `LOAD_SEED_JOBS` | `40` | Jobs queued in phase 1 to trigger the autoscaler (see [Why 40?](#why-load_seed_jobs--40)) |
| `LOAD_JOB_DURATION_SECS` | `15` | CPU burn per worker job (seconds) |
| `SCALE_WAIT_SECS` | `240` | Seconds to wait for the autoscaler to react |

**Priority:** `.env` values → environment variables → Terraform outputs
→ built-in defaults.

## DNS delegation: the `--resolve` fallback

`var.n8n_domain` resolves publicly only after the parent zone's NS
records have been delegated to Azure DNS at the registrar — which the
example deliberately leaves to the operator
(`terraform output public_dns_zone_name_servers` lists the four
Azure-assigned name servers). Until that's in place the smoke test
falls back to `curl --resolve <fqdn>:443:<APPGW_PUBLIC_IP>` so the
HTTPS / API / webhook checks still hit the App Gateway listener
end-to-end.

The fallback fires automatically — the script does a regular DNS
resolution first, falls back to `--resolve` if that returns no answer,
and surfaces which path it took as an `info` line under each check.
You don't need to set anything to opt in.

## Worker scaling test (opt-in)

The scaling test creates real load and is therefore opt-in:

```bash
LOAD_TEST=true N8N_API_KEY=your-key ../../tests/scripts/smoke-test.sh
```

What it does:

1. Pre-checks the autoscaler — KEDA `ScaledObject` (the canonical worker
   autoscaler in this module — Azure Managed Redis queue depth) or the
   CPU-based HPA fallback. Skips if neither is found.
2. Creates a temporary n8n workflow with a Code node that burns CPU for
   `LOAD_JOB_DURATION_SECS` seconds per execution.
3. Activates it and queues `LOAD_SEED_JOBS` webhook calls in phase 1 to
   trigger the autoscaler.
4. Polls every 15 seconds for up to `SCALE_WAIT_SECS` seconds, watching
   worker replicas climb.
5. Once scale-up is detected, queues the remaining
   `LOAD_REQUESTS - LOAD_SEED_JOBS` calls (phase 2) so the new workers
   visibly pick up jobs.
6. Deactivates and deletes the test workflow (cleanup runs even on
   failure).

If workers don't scale within the wait window, the script warns and
suggests bumping `LOAD_REQUESTS` / `LOAD_JOB_DURATION_SECS`. KEDA's
default polling interval is 15 s and the ScaledObject's `cooldownPeriod`
is 300 s, so `SCALE_WAIT_SECS = 240` has comfortable headroom for two or
three poll cycles before the warning fires.

### Why `LOAD_SEED_JOBS = 40`?

KEDA only scales when `bull:jobs:wait` exceeds `listLength × replicas`.
With the module's defaults:

- `queueMode.workerConcurrency = 10` (chart default) — each worker pod
  processes 10 jobs in parallel
- `n8n_worker_keda_min_replicas = 2` — the floor
- `n8n_worker_keda_target_list_length = 5` — the per-replica wait-queue
  target

... the cluster runs `2 × 10 = 20` jobs concurrently and KEDA only
triggers when there are more than `2 × 5 = 10` jobs sitting in the wait
queue — i.e. the seed has to push past **30 jobs** before KEDA notices.
40 is the smallest round number that comfortably clears that floor.
Lower the seed only if you've also lowered the chart's `workerConcurrency`
or the module's `n8n_worker_keda_target_list_length` accordingly.

The load-test default also sets `LOAD_JOB_DURATION_SECS = 15` (vs the
AWS sibling's 10) so the 40 seed jobs don't drain before KEDA's first
poll cycle. With 15 s burn, 20 in-flight, the queue stays saturated for
~30 s — plenty of dwell time for the 15 s polling interval to register.

## Running against a remote deployment

You can run without local Terraform state — for example against a
cluster managed by someone else — by setting everything explicitly:

```bash
NAMESPACE=n8n \
N8N_URL=https://n8n.example.com \
AKS_CLUSTER_NAME=my-aks \
AKS_RESOURCE_GROUP=my-rg \
APPGW_PUBLIC_IP=20.160.15.211 \
N8N_API_KEY=your-key \
./tests/scripts/smoke-test.sh
```

You're responsible for `az login`'ing to the right subscription
yourself. The script still calls `az aks get-credentials` against the
provided cluster + RG to populate a transient kubeconfig — your default
`~/.kube/config` is left untouched. Skip `POSTGRES_FQDN`,
`STORAGE_ACCOUNT_NAME`, `BLOB_CONTAINER_NAME`, and `FILES_PVC_NAME` in
this mode and the corresponding checks fall back to reporting the
observed value without an expected-value comparison.

## Exit codes

Both scripts share these.

| Code | Meaning |
|---|---|
| `0` | All checks passed (warnings and skips are non-fatal) |
| `1` | One or more checks failed |

The summary line always prints the counts: `Passed: X  Failed: Y
Warnings: Z  Skipped: W`.

## Custom image verification

`verify-custom-image.sh` covers what `smoke-test.sh` cannot: a
deployment can be perfectly healthy and still have its baked nodes
silently unloaded. The specific failure it exists to catch is
**asymmetric loading**, where a node type resolves on main pods but not
on workers. That looks correct in the editor and fails only when a
production execution reaches the node.

This is the Azure sibling of
[`terraform-aws-n8n/tests/scripts/verify-custom-image.sh`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/tests/scripts/README.md).
The chart-level behavior it verifies (`N8N_CUSTOM_EXTENSIONS`, the
`/home/node/.n8n` shadowed directory, `N8N_REINSTALL_MISSING_PACKAGES`)
is identical between the two modules — only the registry you point
`n8n_image_repository` at differs (Azure Container Registry here, ECR on
AWS).

```bash
cd examples/small
../../tests/scripts/verify-custom-image.sh
```

### What it covers

| Check | What it verifies |
|---|---|
| Image consistency | Every Running pod, every replica, runs the same image, so a half-finished rollout is not mistaken for a loading bug. A pod whose image cannot be read fails rather than being skipped |
| Task runner sidecar | The runner image resolves and nothing is stuck in `ImagePullBackOff`, the symptom of a custom `n8n_image_tag` with no `n8n_task_runner_image_tag` |
| Extensions path | `N8N_CUSTOM_EXTENSIONS` is set, and set *identically*, on main, worker, and webhook-processor |
| Shadowed directory | The path is outside `/home/node/.n8n`, which the chart mounts over on main pods only |
| Baked files on disk | At least one `*.node.js` exists under the path, on every pod type |
| Loaded node types | n8n's generated type list contains at least one `CUSTOM.*` type. This is the difference between present on disk and actually loaded |
| Boot-time installs | Warns if `N8N_REINSTALL_MISSING_PACKAGES=true`, which reintroduces the per-pod npm install that baking exists to remove |
| Execution (opt-in) | Runs a workflow using a baked node through the queue, proving a *worker* resolved the type |

### The execution check

Everything above proves main loaded the nodes. None of it proves a
worker did, because workers serve no type list. Only executing a
workflow that uses a baked node settles that, and it needs a workflow
specific to whichever node you baked, so you supply one:

```bash
CUSTOM_NODE_WORKFLOW=./my-node-test.json \
  ../../tests/scripts/verify-custom-image.sh
```

The file is a workflow JSON with two requirements: a webhook trigger,
which is what routes the execution to a worker instead of the main
process, and at least one node whose `type` starts with `CUSTOM.`. The
script rewrites the webhook path to a unique value and its method to
`POST` (it copies the workflow before sending it, so your file is not
modified), creates and activates the workflow, fires it, waits for the
execution, then deactivates and deletes it.

```json
{
  "nodes": [
    { "id": "a", "name": "Webhook", "type": "n8n-nodes-base.webhook", "typeVersion": 2,
      "position": [0, 0],
      "parameters": { "httpMethod": "POST", "path": "placeholder", "responseMode": "lastNode" } },
    { "id": "b", "name": "Baked", "type": "CUSTOM.myNode", "typeVersion": 1,
      "position": [220, 0], "parameters": {} }
  ],
  "connections": { "Webhook": { "main": [[{ "node": "Baked", "type": "main", "index": 0 }]] } },
  "settings": { "executionOrder": "v1" }
}
```

Use the type name *as n8n loaded it*. A package installed from npm as
`n8n-nodes-example.myNode` becomes `CUSTOM.myNode` once baked, because
the custom directory loader registers everything under the package
name `CUSTOM`. Run the script once without a workflow and it lists the
loaded `CUSTOM.*` types.

A workflow with no `CUSTOM.*` node is rejected rather than run. It
would execute and report success while proving nothing, which is worse
than not running it at all.

### Settings

| Variable | Effect |
|---|---|
| `CUSTOM_NODE_WORKFLOW` | Path to the workflow JSON above. Enables the execution check (also needs `N8N_URL` and `N8N_API_KEY`) |
| `EXPECT_IMAGE_REPOSITORY` | Assert the deployed repository matches this exactly, e.g. `myregistry.azurecr.io/n8n` |
| `EXPECT_EXTENSIONS_PATH` | Assert `N8N_CUSTOM_EXTENSIONS` matches this exactly |

Against a deployment that sets no custom extensions path, the script
warns and exits 0 rather than failing, so it is safe to run anywhere.
