# Troubleshooting

Failure modes observed in real `terraform apply` runs against this module — symptom, root cause, and the fix that gets the apply unstuck. Most of these are Azure-specific deltas vs `terraform-aws-n8n` (see [`AGENTS.md`](../AGENTS.md) → "Azure-specific deltas") or external dependencies (Helm CLI) the module relies on.

If you hit something not covered here, open an issue with the resource address that failed and the last 50 lines of `terraform apply` output.

## `terraform apply`: `no cached repo found … kedacore-index.yaml`

**Symptom**

`helm_release.keda` fails at create time with:

```
Error: could not download chart: no cached repo found.
(try 'helm repo update'):
open /Users/<you>/Library/Caches/helm/repository/kedacore-index.yaml: no such file or directory
```

**Root cause**

The `hashicorp/helm` Terraform provider (v2.x) embeds Helm SDK v3 and reuses the local Helm CLI's repository cache (`$HELM_REPOSITORY_CACHE`). When the system Helm CLI is **Helm 4** (released 2025) the cache layout differs slightly from the v3 SDK's expectations, so the SDK fails to find the index file even though the chart URL is hard-coded on `helm_release.keda`. This is environmental, not a module bug — but anyone running Helm 4 on macOS will see it.

The n8n chart (`oci://ghcr.io/n8n-io/n8n-helm-chart`) is OCI-pulled and is not affected — only the KEDA release, which uses a classic HTTPS Helm repo, is.

**Fix**

Pre-populate the v3-compatible cache once before the first apply:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
```

Then re-run `terraform apply`. Already-created resources are skipped; only the failed `helm_release.keda` is retried.

If your environment supports it, downgrading to Helm 3 also resolves the issue:

```bash
brew uninstall helm
brew install helm@3
```

The same workaround is documented in the AWS sibling at [`terraform-aws-n8n/docs/troubleshooting.md`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/docs/troubleshooting.md).

## `terraform apply`: KEDA TriggerAuthentication fails with `no matches for kind`

**Symptom**

The very first `terraform plan` (or `apply`) against a fresh module fails with:

```
Error: Failed to determine GroupVersionKind for manifest:
no matches for kind "TriggerAuthentication" in group "keda.sh"
```

…or a similar "schema not found" error from a `kubernetes_manifest` resource.

**Root cause**

KEDA's `TriggerAuthentication` is a **Custom Resource** — its CRD is installed by `helm_release.keda` (in [`controllers.tf`](../controllers.tf)). The `hashicorp/kubernetes_manifest` resource validates against the CRD's OpenAPI schema **at plan time**, before any apply has run, so the very first plan against a fresh cluster hits `no matches for kind` and forces a two-pass apply (first to install KEDA, then to plan the TriggerAuthentication).

**Resolution**

This is fixed in the module — `kubectl_manifest.keda_trigger_authentication` ([`keda.tf`](../keda.tf)) creates the TriggerAuthentication via the `gavinbunney/kubectl` provider, which uses the dynamic kubectl client rather than the typed openapi client. Schema resolution is deferred to apply time, so a single-pass apply works against a fresh cluster.

If you've forked the module and replaced `kubectl_manifest` with `hashicorp/kubernetes_manifest`, revert that change. Per [`AGENTS.md`](../AGENTS.md) → "What not to do": never use `hashicorp/kubernetes_manifest` for self-installed CRDs.

If the apply still fails because KEDA itself isn't Ready, check that `helm_release.keda` succeeded — `wait = true` and `atomic = true` are set, so a failed install rolls back and the TriggerAuthentication never runs. `kubectl -n keda get pods` should show `keda-operator` and `keda-metrics-apiserver` Ready.

To verify the CR landed after a successful apply:

```bash
kubectl -n n8n get triggerauthentication n8n-redis-keda-auth
kubectl -n n8n describe scaledobject     # KEDA reports the auth ref status
```

## `terraform apply`: `kubernetes_namespace.n8n` / `helm_release.keda` fails with `EOF` or `the server is currently unable to handle the request`

**Symptom**

A fresh `terraform apply` against a newly-created cluster fails on one of the first kubernetes-/helm-provider resources with errors of the form:

```
Error: Get "https://<cluster>.hcp.<region>.azmk8s.io/api?timeout=…": EOF

Error: Kubernetes cluster unreachable: the server is currently unable to handle the request
```

**Root cause**

Azure reports the AKS resource as `Succeeded` before `/healthz` is consistently green; the kubernetes and helm providers fire 503s against the API server until the control plane finishes warming. The module gates downstream provider work behind `time_sleep.aks_api_warmup` ([`aks.tf`](../aks.tf), default `var.aks_api_warmup_seconds = 90s`, range 30..600) so the kubernetes/helm provider clients hit the API server only after the warm-up window. The providers' built-in retry on transient errors handles any stragglers after the gate. The legacy `null_resource.wait_for_aks_api` /healthz poll-loop (60 attempts × 10 s via `az` + `kubectl`) was removed in registry-hardening US-003 (Phase 1 R1.3) — no `az` / `kubectl` are required on the apply host any more.

**Resolution**

In most cases `terraform apply` will simply succeed on the next run — the gate fires fresh on each plan that touches a new cluster_id. If your subscription / region is unusually slow to warm a control plane, raise the gate:

```hcl
module "n8n" {
  # …
  aks_api_warmup_seconds = 180   # default 90; range 30..600
}
```

If a downstream apply is *still* failing after a 10-minute gate, the cluster is genuinely unreachable from the apply host (typical when AKS is provisioned into a VNet with private DNS and the apply host is outside that VNet — Phase 1 of this module always uses the public AKS API endpoint, so this only fires if you've forked and enabled `private_cluster_enabled = true`). Confirm reachability:

```bash
az account show
az aks get-credentials --resource-group <rg> --name <cluster> --overwrite-existing
kubectl get --raw=/healthz   # should return "ok"
```

## `permission denied to create extension "uuid-ossp"` from inside the cluster

**Symptom**

A pod or `psql` session running inside the VNet returns:

```
ERROR:  permission denied to create extension "uuid-ossp"
HINT:   Must be superuser to create this extension.
```

This is rare under default usage — n8n's current migrations don't issue `CREATE EXTENSION "uuid-ossp"` (identifiers are generated by `node:crypto.randomUUID()` at the application layer; see [`packages/@n8n/db/AGENTS.md`](https://github.com/n8n-io/n8n) for the project rule). The error surfaces when an operator runs the SQL by hand, or when an older fork's migration set is applied against a server where the allowlist hasn't propagated yet.

**Root cause**

PostgreSQL Flexible Server gates `CREATE EXTENSION` behind a server-level allowlist (`azure.extensions`). Even the server admin gets `permission denied` until the requested extension name appears in that list.

**Resolution**

Confirm the allowlist is set, then re-issue the SQL:

```bash
# 1. The module sets this via azurerm_postgresql_flexible_server_configuration.uuid_ossp.
#    Confirm the live value contains UUID-OSSP.
az postgres flexible-server parameter show \
  --resource-group <module-rg> \
  --server-name <server> \
  --name azure.extensions

# 2. From an in-cluster debug pod, retry CREATE EXTENSION.
kubectl run -it --rm dnsdebug --image=postgres:16 --restart=Never -- \
  /bin/sh -c "psql 'host=<server>.postgres.database.azure.com sslmode=require user=n8n dbname=n8n' \
                -c 'CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";'"
```

If step 1 returns `UUID-OSSP` but step 2 still fails, the parameter change has not propagated — wait 1–2 minutes and retry. If the allowlist is empty, re-run `terraform apply` to reconcile `azurerm_postgresql_flexible_server_configuration.uuid_ossp`.

## `terraform apply`: n8n UI hangs on "n8n is starting up"

**Symptom**

`terraform apply` reports `helm_release.n8n` as `Created`. The n8n UI loads but stays at the splash screen with the message **"n8n is starting up"** indefinitely. Pod logs show errors of the form:

```
QueryFailedError: relation "n8n_index_xxx" already exists
```

…or a session that hangs on `CREATE INDEX CONCURRENTLY`.

**Root cause**

When the Helm release first installs n8n with `multiMain.enabled = true` and `replicas >= 2`, both main pods boot in parallel and may attempt to run the same n8n migration set against an empty database. Several migrations issue `CREATE INDEX CONCURRENTLY`, which Postgres serialises across sessions: a follower pod can see the index in `pg_locks` and crash with a duplicate-relation or already-in-progress error.

**Resolution**

The chart's Redis-based multi-main leader election (`multiMain.setup.keyTtl` / `checkInterval`) plus `helm_release.n8n` running with `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true` together absorb the race natively: only the elected leader runs migrations, followers wait for the leader's signal, and helm waits for `replicas == readyReplicas` before returning. A small `time_sleep.n8n_helm_settle` ([`n8n.tf`](../n8n.tf), default 60 s, configurable via `var.n8n_helm_post_install_settle_seconds`) gates `kubernetes_ingress_v1.n8n` so AGIC reconciles against a fully-converged deployment rather than one still rolling.

If the UI hangs anyway:

```bash
# 1. Confirm both main pods are Ready.
kubectl -n n8n get pods -l app.kubernetes.io/component=main

# 2. Tail logs for the migration-race signature.
kubectl -n n8n logs -l app.kubernetes.io/component=main --tail=200 | grep -E 'already exists|CREATE INDEX'

# 3. Bounce the deployment so all pods come up against the migrated schema.
kubectl -n n8n rollout restart deployment/n8n
kubectl -n n8n rollout status deployment/n8n --timeout=5m
```

If the UI still hangs after a manual restart, the migration is probably wedged in `pg_stat_activity`. Connect from a bootstrap pod (see the uuid-ossp section above), run `SELECT pid, state, query FROM pg_stat_activity WHERE state != 'idle';`, and `pg_cancel_backend(pid)` any session stuck on `CREATE INDEX`. Then `kubectl -n n8n rollout restart deployment/n8n`. If the race recurs on subsequent applies, raise `var.n8n_helm_post_install_settle_seconds` (e.g. to 120) so the Ingress wait window comfortably outlasts the chart's leader-election bootstrap.

## `terraform destroy` hangs on namespace finalizers or App Gateway frontend IP release

See [`destroy-cleanup.md`](./destroy-cleanup.md) for the standard manual cleanup steps: removing stuck `kubernetes` finalizers from the n8n namespace, manually deleting the App Gateway frontend IP configuration if it survives the App Gateway destroy, and the safe re-apply path after a partial destroy.
