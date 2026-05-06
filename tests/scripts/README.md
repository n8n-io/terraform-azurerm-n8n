# Smoke test

Post-`terraform apply` smoke test for `terraform-azurerm-n8n`. Verifies the
multi-main Azure deployment is healthy end to end — pod health, queue
mode, KEDA, App Gateway HTTPS, API connectivity, and a full webhook →
worker execution.

This is the Azure sibling of
[`terraform-aws-n8n/tests/scripts/smoke-test.sh`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/tests/scripts/README.md).
The two share the same overall structure (preflight → namespace →
deployment health → ingress → API → execution → opt-in load test); the
deltas live in the Azure-specific checks that have no AWS analogue.

## What it covers

| Check | What it verifies |
|---|---|
| `kubectl` cluster connectivity | `az aks get-credentials` populates a kubeconfig and `kubectl get nodes` succeeds against the AKS API server |
| Namespace exists | The configured namespace is present |
| Main / worker / webhook-processor pod health | Each deployment is at the expected ready replica count (`MAIN_MIN=2`, `WORKER_MIN=1`, `WEBHOOK_MIN=2` — match the multi-main floor enforced by `var.n8n_main_replicas ≥ 2` and the `kubernetes_horizontal_pod_autoscaler_v2.webhook_processor` `min_replicas = 2`) |
| Multi-main leader election | `N8N_MULTI_MAIN_SETUP_ENABLED=true` on main pods + leadership activity in main logs |
| Task runner sidecar (workers) | Runner sidecar is present on worker pods and connected to the broker (skipped when `n8n_task_runners_enabled = false`) |
| KEDA `TriggerAuthentication` | `n8n-redis-keda-auth` CR is present in the n8n namespace — the n8n chart's worker `ScaledObject` references it; without it KEDA can't authenticate against Azure Redis and the worker pool won't scale |
| Autoscaler configuration | KEDA `ScaledObject` (workers, queue-depth driven against Azure Cache for Redis) and HPA (`n8n-webhook-processor`) state |
| Redis connectivity | Worker pods see `QUEUE_BULL_REDIS_HOST` (the Azure Cache for Redis FQDN) and the BullMQ-related log lines |
| App Gateway public IP reachable | TCP/443 listener responds on the static public IP |
| HTTPS reachability | `/healthz/readiness` (or `/healthz` on older n8n) returns HTTP 200 over the App Gateway listener — works via DNS or `--resolve` to `APPGW_PUBLIC_IP` when the parent zone isn't delegated yet |
| HTTP → HTTPS redirect | Port 80 redirects to 443 (the chart sets `appgw.ingress.kubernetes.io/ssl-redirect = "true"` on the n8n Ingress) |
| API connectivity (if API key set) | `/api/v1/workflows?limit=1` responds with HTTP 200 |
| Workflow execution (if API key set) | Creates a webhook → set workflow, fires it through the App Gateway listener, confirms a `success` execution status, deletes it |
| n8n license validity | `n8n license:info` exec'd inside a Ready main pod surfaces the active license tier (no API key needed) |
| Worker scaling (opt-in, requires API key) | Queues CPU-burning webhook executions and confirms KEDA scales `n8n-worker` up via Redis queue depth |

## Quick start

The script reads `n8n_namespace`, `n8n_url`, `aks_cluster_name`,
`aks_resource_group`, `appgw_public_ip`, and `kubectl_config_command`
automatically from `terraform output`.

```bash
az login                              # the script verifies this up front
cd examples/complete                  # or wherever your terraform.tfstate lives
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
> `terraform.tfstate` (e.g. `examples/complete/`), not from
> `tests/scripts/`. The script calls `terraform output` against the
> current working directory by default.

## API key (required for API and execution tests)

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

## Configuration

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
   autoscaler in this module — Azure Redis queue depth) or the CPU-based
   HPA fallback. Skips if neither is found.
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
`~/.kube/config` is left untouched.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed (warnings and skips are non-fatal) |
| `1` | One or more checks failed |

The summary line always prints the counts: `Passed: X  Failed: Y
Warnings: Z  Skipped: W`.
