# Troubleshooting

Failure modes observed in real `terraform apply` runs against this module — symptom, root cause, and the fix that gets the apply unstuck. Most of these are Azure-specific deltas vs `terraform-aws-n8n` (see [`AGENTS.md`](../AGENTS.md) → "Azure-specific deltas") or external dependencies (Helm CLI) the module relies on.

If you hit something not covered here, open an issue with the resource address that failed and the last 50 lines of `terraform apply` output.

Every recipe below assumes the module-managed AKS, namespace, and KEDA paths (the defaults). On a customer-managed layer (`create_aks = false`, `create_namespace = false`, or `install_keda = false`), the failure surfaces the same way but the fix is usually on the caller's side of the boundary — see [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md) for what each attestation actually requires before assuming a module bug.

The first four entries are region/subscription capability gaps that surface 10-20 minutes into an apply, after the network, Key Vault, and Application Gateway already exist. Run [`tests/scripts/preflight-region-check.sh`](../tests/scripts/preflight-region-check.sh) from the root you are about to apply to catch all four first: it plans your configuration, reads the region, sizing, and SKUs you actually selected, and checks them (including subscription vCPU quota headroom) against what the subscription is offered in that region (add `--probe-redis` to also test Managed Redis capacity with a throwaway cluster).

## `terraform apply`: AKS cluster creation fails with `AvailabilityZoneNotSupported`

**Symptom**

`azurerm_kubernetes_cluster.n8n` fails to create with something like:

```text
Error: creating Kubernetes Cluster ...: unexpected status 400 (400 Bad Request) with response:
{
  "code": "AvailabilityZoneNotSupported",
  "message": "The zone(s) '2' for resource 'system' is not supported. The supported zones for location 'germanywestcentral' are '1,3'",
  "subcode": "",
  "target": "agentPoolProfile.availabilityZone"
}
```

**Root cause**

`var.aks_availability_zones` defaults to `["1", "2", "3"]`, but not every region/VM-SKU/subscription combination supports all three zones for AKS node pools. Observed: `germanywestcentral` with `Standard_D2s_v5` offered only `'1,3'` in one subscription, and `eastus` reported `The supported zones for location 'eastus' are ''` (no zones at all) in another, where `az vm list-skus -l eastus --size Standard_D2s_v5` did not list the SKU for that subscription. This is a subscription- or SKU-level constraint as often as a fixed regional one, so don't take any zone list as gospel for every account. Confirm current zone support with `az vm list-skus --location <region> --size <vm size> --resource-type virtualMachines --query "[0].locationInfo[0].zones"` (core CLI, slow, ~1 minute), with `az aks list-vm-skus --location <region> --size <vm size>` if you have the `aks-preview` extension installed, or run the preflight script.

**Resolution**

Restrict `aks_availability_zones` to the zones your subscription/SKU/region combination actually supports, or clear it when the region offers none:

```hcl
aks_availability_zones = ["1", "3"]   # or [] for a zone-less region
```

Every example already exposes this variable for exactly this reason (see the `aks_availability_zones` input description). Re-running `terraform apply` after the fix picks up cleanly: resources created before the AKS failure (e.g. the Application Gateway) are left untouched and reused.

## `terraform apply`: PostgreSQL Flexible Server fails with `ParameterOutOfRange: The value of the 'Version' should be in: []`

**Symptom**

`azurerm_postgresql_flexible_server.n8n` fails to create:

```text
Error: creating Flexible Server ...: unexpected status 400 (400 Bad Request) with error:
ParameterOutOfRange: The value of the 'Version' should be in: []. Verify that the specified parameter value is correct.
```

**Root cause**

The empty list is the tell: Flexible Server offers *no* PostgreSQL versions to this subscription in this region, so no `pg_version` value can satisfy it. Observed against `eastus` in a subscription where `az postgres flexible-server list-skus -l eastus` returned no `supportedServerVersions` while `centralus` returned 11 through 18. It is a subscription/region offering gap, not a wrong `pg_version`; the same apply usually also fails AKS zone placement in that region (previous entry).

**Resolution**

Pick a region where `az postgres flexible-server list-skus -l <region> --query "[0].supportedServerVersions[].name"` lists your `pg_version` (and `pg_sku_name` under `supportedServerEditions`), or set `create_database = false` and point the module at an existing PostgreSQL endpoint. The preflight script checks both the version and the SKU. Resources created before the failure are reused on the next apply.

## `terraform apply`: Azure Managed Redis fails with `InsufficientCapacity`

**Symptom**

`azurerm_managed_redis.n8n` fails after a few minutes of polling:

```text
Error: creating Redis Enterprise ...: polling after Create: polling failed:
Code: "InsufficientCapacity"
Message: "Request failed due to insufficient capacity. Retry using a different Azure Managed Redis size or region."
```

The Azure resource is left behind in `resourceState = CreateFailed`, and the next `terraform apply` collides with it (`Conflict`).

**Root cause**

Azure Managed Redis is capacity-constrained per region and the constraint is point-in-time: the same `Balanced_B0` request was rejected in `germanywestcentral`, `westeurope`, `northeurope`, and `eastus2` on one day while `centralus`, `eastus`, `westus2`, `westus3`, `swedencentral`, `uksouth`, and `francecentral` accepted it within minutes. There is no capacity API, so a SKU being "available" in the region's catalogue says nothing about whether a create will succeed right now. Retrying the same SKU in the same region rarely helps within the hour; changing SKU (`Balanced_B1`, `MemoryOptimized_M10`) sometimes does, changing region usually does. On 2026-09-22 every SKU family (`Balanced_B0`/`B1`/`B3`, `MemoryOptimized_M10`, `ComputeOptimized_X3`) was rejected in `germanywestcentral` within the same hour while `swedencentral` accepted `Balanced_B0`, so when the probe rejects two families, move region rather than trying a third. See [`docs/redis.md`](./redis.md) for the allowed SKUs and the `NoCluster` ceiling.

**Resolution**

1. Delete the failed orphan before re-applying (Terraform never recorded it): `az redisenterprise delete --name <friendly_name_prefix>-redis --resource-group <resource_group_name> --yes`, where `<resource_group_name>` is the value you passed to the module (the sizing examples use `<friendly_name_prefix>-n8n-rg`).
2. Change region, change `redis_sku_name`, or set `create_redis = false` with an external Redis endpoint, then run a fresh `terraform plan`; a partial apply safely retains everything created before the Redis failure.
3. Before the next attempt, run the preflight script with `--probe-redis`: it creates a throwaway cluster of your configured SKU in your configured region (a rejection surfaces in under a minute, success in five to ten) and deletes it, so you learn about capacity before the 15-minute AKS/Postgres/App Gateway build instead of after it.

## `terraform apply`: `helm_release.n8n` times out because the AKS autoscaler can't add a node

**Symptom**

`helm_release.n8n` fails after its full `n8n_helm_timeout` (default 600s) with `context deadline exceeded`, and `atomic = true` rolls the release back. `kubectl -n kube-system get configmap cluster-autoscaler-status` shows the user node pool's `scaleUp.status: Backoff` with:

```text
errorMessage: |-
  failed to increase node group size: PUT .../virtualMachineScaleSets/aks-n8nuser-...
  RESPONSE 409: 409 Conflict
  ERROR CODE: OperationNotAllowed
  {"error": {"code": "OperationNotAllowed", "message": "Operation results in exceeding quota limits of Core. Maximum allowed: 10, Current in use: 8, ..."}}
```

n8n's main/worker/webhook pods sit `Pending` the whole time; the AKS cluster, PostgreSQL, and Redis all created successfully before this.

**Root cause**

The subscription's regional vCPU quota, either the per-VM-family cap (e.g. `standardDSv5Family`) or the aggregate `cores` cap, is too tight for both the system and user node pools (each scaling `aks_node_count_min..aks_node_count_max` nodes of `aks_node_vm_size`, so worst case is `2 x aks_node_count_max` nodes) plus whatever else already runs in that region on the subscription. A fresh subscription or a shared sandbox often starts with a `cores` limit of 10. With `Standard_D2s_v5` (2 vCPUs) and the default `aks_node_count_min = 2`, the two pools start with four nodes (8 vCPUs), and the autoscaler can add only one more node before it reaches that limit.

Node upgrades and pool rotations need quota on top of this. `aks_node_upgrade_max_surge` (default `10%` of the pool's current node count, rounded up to whole nodes, which is one node per pool at the root module's default sizing) adds nodes during a Kubernetes or node-image upgrade. Changing a setting that rotates a pool through `temporary_name_for_rotation` (for example `aks_node_os_disk_size_gb`) briefly creates a temporary copy of that pool. The preflight script checks only the autoscaler ceiling, so leave extra headroom if you plan either operation.

**Resolution**

1. Run `tests/scripts/preflight-region-check.sh` before applying. It checks both the per-family and the aggregate vCPU quota against the worst case (the sum of every module node pool's `max_count`, which is `2 x aks_node_count_max` with the module's two pools). When the plan only creates AKS clusters and node pools, a shortfall fails the run before the 15-20 minute build reaches this point. When the plan keeps or replaces an existing cluster, the result is a warning, because `az vm list-usage` may already count that cluster's nodes.
2. If it fails, request a quota increase: `az quota update --resource-name <cores|standardXxxFamily> --scope /subscriptions/<id>/providers/Microsoft.Compute/locations/<region> --limit-object value=<new> --resource-type dedicated`. This command is part of the `quota` Azure CLI extension (`az extension add -n quota`). Many subscriptions approve this within a minute or two.
3. After a quota increase, the autoscaler's own backoff (observed up to 10-15 minutes) still has to expire before it retries. A `terraform apply` retry immediately after the quota change can fail the same way. Watch `kubectl -n kube-system get configmap cluster-autoscaler-status -o yaml` until the pool's `scaleUp.status` is no longer `Backoff`, then re-run `terraform apply`.
4. Alternatively, lower `aks_node_vm_size` or `aks_node_count_max`, or move to a region/subscription with more headroom.

## Changing `aks_node_os_disk_size_gb` on an existing cluster disrupts workloads

**Symptom**

After changing `aks_node_os_disk_size_gb` on a cluster that already exists, `terraform apply` succeeds but pods on the affected node pool restart unexpectedly, or the apply takes noticeably longer than a routine change.

**Root cause**

`aks_node_os_disk_size_gb` is null by default, which leaves OS-disk sizing to the provider/Azure default for the selected VM size — this module makes no 20 GiB/100 GiB assumption and adds no disk-type control. Setting or changing this value on an existing `default_node_pool` or `n8n_user` pool requires AzureRM to cycle that pool through its `temporary_name_for_rotation` (`systemtemp` for the system pool, `n8nusrtemp` for the user pool): nodes are recreated with the new disk size. This rotation is **not** a cordon-and-drain operation — AzureRM does not guarantee pods are gracefully evicted before their node is replaced, and neither the AKS node-pool `max_surge` upgrade setting nor the n8n PDBs promise an uninterrupted rotation.

This control has no effect at all when `create_aks = false`; `check.aks_tuning_requires_module_managed_aks` warns (non-failing) if the input is left non-null in that mode, because the existing cluster's disk sizing is owned by whoever created it.

**Resolution**

Treat an OS-disk size change as its own maintenance operation, separate from any topology or application change in the same apply:

1. Run `terraform plan` first and confirm which node pool(s) the change affects.
2. Confirm subnet IP headroom, node quota, and available capacity for the temporary rotation node before applying — the rotation briefly needs room for an extra node per pool being resized.
3. Apply during a maintenance window. Expect workloads scheduled on the affected pool to be interrupted; the multi-main topology, worker KEDA scaling, and webhook HPA reduce — but do not eliminate — the chance of simultaneous downtime across every main pod.
4. Verify pod health and re-run the smoke test (`tests/scripts/smoke-test.sh`) after the rotation completes.

A valid `aks_node_os_disk_size_gb` value is not a promise that every Azure VM/disk combination accepts that size — confirm against Azure's current documentation for the configured `aks_node_vm_size` before applying.

## Enabling `aks_system_pool_critical_addons_only` moves module-installed workloads to the user pool

**Validation scope.** One live run (swedencentral, `Standard_D2s_v5`, AKS v1.35.7, Terraform 1.13.3) switched this input from false to true on an existing cluster with `create_ingress = true`. It confirmed the taint on the system-pool nodes only, n8n and KEDA pods on `n8nuser`, CoreDNS and the AKS-managed AGIC add-on running on the tainted system pool, and an HTTPS 200 through the Application Gateway. That run did not load-test user-pool autoscaler headroom or vCPU quota during the rotation, so size both before you apply.

**Symptom**

After setting `aks_system_pool_critical_addons_only = true` on an existing cluster, `terraform apply` succeeds, but the system pool's nodes are recreated and every n8n, KEDA, and Redis-exporter pod restarts on the `n8nuser` pool.

**Root cause**

`aks_system_pool_critical_addons_only` is false by default, so n8n, KEDA, and the Redis exporter can schedule on the system pool alongside CoreDNS, konnectivity, and metrics-server. Setting it to true applies AzureRM's `only_critical_addons_enabled` attribute, which taints the system pool `CriticalAddonsOnly=true:NoSchedule`. Because AzureRM cannot add a taint to a live node in place, it cycles the system pool through its `temporary_name_for_rotation` (`systemtemp`): nodes are recreated, not updated in place. This rotation is **not** a cordon-and-drain operation, the same caveat that applies to `aks_node_os_disk_size_gb` above.

None of the workloads this module installs (n8n, KEDA, the Redis exporter) set a `nodeSelector` or `toleration`, so once the taint lands, the scheduler moves all of them onto the `n8nuser` pool. The AKS-managed `ingress_application_gateway` (AGIC) addon is unaffected: AKS deploys it with its own explicit `CriticalAddonsOnly` toleration (`op=Exists`), unlike a caller-deployed, self-hosted upstream `application-gateway-kubernetes-ingress` Helm chart, which would need one added manually. Live testing (AGIC add-on, AKS v1.35.7) confirms the AGIC pod schedules on a tainted system node and serves traffic normally; this module has no check for that combination because module-managed ingress always uses the AKS-managed add-on, not the self-hosted chart.

This control has no effect at all when `create_aks = false`; `check.aks_tuning_requires_module_managed_aks` warns (non-failing) if the input is left non-default in that mode, because the existing cluster's system-pool taint is owned by whoever created it.

**Resolution**

1. Size first, in its own apply. `aks_node_count_max` must leave enough headroom on `n8nuser` alone for the whole workload that used to spread across both pools; the capacity check models only that pool once the input is true. `aks_node_count_min`, `aks_node_count_max`, and `aks_node_vm_size` apply to both pools, so a change there also resizes (and, for the VM size, rotates) the system pool. Do not combine a sizing change with the toggle: `n8nuser` depends on the cluster, so its changes apply only after the system-pool rotation has already moved workloads. A higher maximum also does not add Ready nodes until the autoscaler scales out; raise `aks_node_count_min` if you need the capacity in place before the rotation.
2. Confirm subnet IP headroom and vCPU quota (see the quota entry above) for the temporary `systemtemp` pool the rotation creates and for the user-pool scale-out that follows, on top of both pools at their current size.
3. For each apply, save the plan (`terraform plan -out=...`), review and approve it, and apply that saved plan during a maintenance window. For the toggle, confirm the only AKS change is `only_critical_addons_enabled` on the default node pool. Expect the system-pool nodes to cycle and every module-installed workload on them to restart on the user pool.
4. Verify pod health and re-run the smoke test (`tests/scripts/smoke-test.sh`) after the rotation completes.
5. Confirm `kubectl get nodes -o json` shows the `CriticalAddonsOnly` taint on the system-pool nodes, and that n8n, KEDA, and the Redis exporter pods now run on `n8nuser`.

Setting the input back to false is a second rotation of the system pool with the same disruption, not an instant rollback. If an apply fails partway through the rotation, inspect the actual node pools (`az aks nodepool list`) and build a fresh, reviewed plan from that state rather than toggling the input back blindly.

## Changing `aks_sku_tier` briefly interrupts the AKS API server

**Validation scope.** One live run (`examples/small`, `Standard_D2s_v5`) changed this input from `"Free"` to `"Standard"` and back on an existing cluster, probing the API server's `/readyz` every 5 seconds. Both changes were in-place updates with no replacement and no drift afterwards. Free to Standard took about 6 minutes, with one failed probe out of 81. Standard to Free took about 3 minutes, with the API server unavailable for about 50 seconds (7 of 10 probes failed) and one more failed probe near the end of the update. n8n, KEDA, and AGIC pods kept running and did not restart in either direction. Treat these timings as one observation, not a guarantee.

**Symptom**

While `azurerm_kubernetes_cluster.n8n` updates its `sku_tier`, `kubectl` or the Kubernetes and Helm providers fail with errors such as `InternalError`, `ServiceUnavailable`, or `Unable to connect to the server ... context deadline exceeded`. The n8n workload itself keeps serving traffic.

**Root cause**

Changing the tier is an in-place update of the managed control plane (no node or pod is recreated), but AKS reconfigures the API server while it runs, so the API server can be unavailable for up to about a minute. Terraform applies Kubernetes and Helm changes that depend on the cluster only after the cluster update finishes, and `time_sleep.aks_api_warmup` does not run again on an update (it re-runs only when the cluster ID changes). A Kubernetes or Helm change in the same apply can therefore still hit the tail of the interruption.

This input has no effect at all when `create_aks = false`; `check.aks_tuning_requires_module_managed_aks` warns (non-failing) if it is left non-default in that mode, because the existing cluster's tier is owned by whoever created it.

**Resolution**

1. Change `aks_sku_tier` in its own apply, without other module changes. Save the plan (`terraform plan -out=...`) and confirm the only change is `sku_tier` on `azurerm_kubernetes_cluster.n8n`, as an in-place update.
2. Do not run other `kubectl` or Helm operations against the cluster while the update runs.
3. If an apply that combined the tier change with Kubernetes or Helm changes fails with one of the errors above, wait until `kubectl get --raw=/readyz` returns `ok`, then run `terraform plan` and `terraform apply` again. The tier change has already been applied, so the next plan contains only the remaining changes.

The Standard and Premium tiers add an hourly charge per cluster. Premium is a prerequisite for AKS Long Term Support, but this module does not set the cluster's `support_plan`.

## `terraform apply`: `no cached repo found … kedacore-index.yaml`

**Symptom**

`helm_release.keda` fails at create time with:

```text
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

```text
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

```text
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

```text
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

```text
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

## Main topology changes report competing leaders or missing execution data

A live single-main to multi-main transition can finish successfully while old
single-main processes overlap with the destination topology. Observed symptoms
include multiple instances claiming leadership, duplicate scheduled attempts,
and a worker failing to find execution data. Successful execution counts can
hide failed attempts because schedule deduplication suppresses some duplicates.

Live changes between single-main and multi-main are unsupported in either
direction. Follow the [maintenance-only transition checklist](./topology-maintenance.md):
stop execution producers, prevent controllers from recreating the source
workload, and verify that all old main processes have stopped before starting
the destination. A maintenance window, `Recreate`, or a successful Helm rollback
alone does not enforce this boundary. The current module does not enforce it
either.

If a live transition has already produced these symptoms, pause further topology
changes, preserve logs from all affected pods, and reconcile queue jobs and
execution outcomes. Do not treat healthy replacement pods as proof that the
transition was safe.

## Switching to multi-main fails because the license lacks `feat:multipleMainInstances`

Check the destination license before the
[maintenance-only transition](./topology-maintenance.md). Raising
`n8n_main_hpa_min_replicas` above 1 without the multi-main entitlement active on
`var.n8n_license_key` does not fail at plan time: Terraform cannot inspect the
license's entitlements. Instead:

1. `helm_release.n8n` renders `multiMain.enabled = true` and the additional main pod(s) start.
2. Each additional main pod fails its license check for `feat:multipleMainInstances` and crash-loops (or the leader stops serving, depending on which pod loses the race).
3. `helm_release.n8n` runs with `wait = true`, so Helm never observes `replicas == readyReplicas` and blocks until `timeout` (`var.n8n_helm_timeout`, default 600 s).
4. `atomic = true` makes Helm attempt an automatic rollback to the previous revision; `cleanup_on_fail = true` permits cleanup of newly created upgrade resources. Terraform reports the failed upgrade. Inspect the resulting workload rather than assuming the prior topology is healthy or that no source and destination processes overlapped.

Diagnose with:

```bash
kubectl -n n8n get pods -l app.kubernetes.io/component=main
kubectl -n n8n exec -it <a-main-pod> -c n8n-main -- n8n license:info
```

`n8n license:info` reports the active plan and its entitlements. If
`feat:multipleMainInstances` is absent, keep traffic and triggers disabled while
you choose either a suitable license or recovery to single-main. Inspect Helm
history, actual controllers, and surviving pods before planning recovery.

Do not blindly toggle the input, run `helm rollback`, or reapply. Follow the
[maintenance failure and rollback procedure](./topology-maintenance.md#failure-and-rollback),
re-establish the stopped-workload boundary, and review a fresh recovery plan.
Neither automatic nor manual Helm rollback provides a topology-transition
safety guarantee.

## `terraform plan -replace` on the AKS cluster fails with `connection refused`

**Symptom:** planning a replacement of `azurerm_kubernetes_cluster.n8n[0]`
(explicitly with `-replace`, or implicitly through a change that forces a new
cluster, such as a new `friendly_name_prefix`, subnet, or SKU-level immutable
attribute) exits 1 with
`Get "http://localhost/api/v1/namespaces/n8n": dial tcp [::1]:80: connect: connection refused`
for `kubernetes_namespace.n8n` and `module.controllers.kubernetes_namespace.keda`.

**Cause:** the caller's `kubernetes`, `helm`, and `kubectl` providers are
configured from `module.n8n.aks_kube_config` (or, with `create_aks = false`,
from the caller's own cluster resource). When the cluster is planned for
replacement those values are unknown during plan, and the providers fall back
to an empty configuration that targets `localhost`. HashiCorp states that a
provider "cannot refer to anything unknown before it's configured" and that
this "cannot work if the provider needs to use that configuration during plan
or refresh" ([hashicorp/terraform#24131](https://github.com/hashicorp/terraform/issues/24131)).
The module's one-apply contract covers fresh installs and updates on an
existing cluster, not in-place cluster replacement.

**Resolution:** do not replace the cluster in place. Back up the encryption
key (`terraform output -raw n8n_encryption_key`) and durable data, run
`terraform destroy` while the AKS API is reachable, and re-apply. PostgreSQL,
Redis, Blob storage, and the Key Vault certificate are separate resources and
are not affected by the failed plan, but a full destroy removes the
module-managed database and storage account; restore from backup or move to
the `create_database = false` / `create_blob_storage = false` reference
inputs first if the data must survive. Targeted destroys or `terraform state
rm` of the Kubernetes-provider resources can make the replacement plan
succeed, but that is manual state surgery outside the supported path and is
not covered by the module's tests.

## `terraform destroy` hangs on namespace finalizers or App Gateway frontend IP release

See [`destroy-cleanup.md`](./destroy-cleanup.md) for the standard manual cleanup steps: removing stuck `kubernetes` finalizers from the n8n namespace, manually deleting the App Gateway frontend IP configuration if it survives the App Gateway destroy, and the safe re-apply path after a partial destroy.
