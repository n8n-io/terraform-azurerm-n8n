# Worker pools example

Sizing-equivalent to [`small`](../small/) apart from `aks_node_vm_size` and `aks_node_count_max`, with one topology addition: three labelled **worker pools**, ready to run beside the chart's own unlabelled worker deployment, each with its own replica bounds, sizing, and autoscaler.

`aks_node_vm_size` goes from small's `Standard_D2s_v5` (2 vCPU) to `Standard_D4s_v5` (4 vCPU), and `aks_node_count_max` from small's 6 to 7. Pools are additional autoscalers on the same node pools rather than a redistribution of the ceilings already there, so their pods have to fit alongside the main, default-worker, and webhook maxima once they are active. See the comment on `local.tier.aks_node_count_max` in `main.tf` for the exact arithmetic.

> **Pools are declared but not deployed by default.** `local.worker_pools` in `main.tf` documents the three-pool topology and is what this example's outputs and tests read, but the line that actually wires it into `module "n8n"` (`n8n_worker_pools = local.worker_pools`) starts commented out. A plain `terraform apply` against this example therefore creates no pools and needs no `feat:workerPools` entitlement, the same as any other example. Uncomment that one line to deploy the topology documented below; see [Apply](#apply).

n8n's worker pools pin a project's executions to a named set of workers. A worker started with `N8N_WORKER_POOL_NAME=<name>` stops consuming the default `jobs` Bull queue and consumes `jobs-<name>` instead; a project assigned to that pool has its executions enqueued there. Assign a project to a pool in the n8n UI under **Project, Settings, Worker Pools**.

Use this example when some executions need different hardware or isolation: heavier jobs on bigger workers, or one team's projects kept off the shared pool.

> **Early Alpha, subject to change without notice.** Worker pools are an alpha n8n feature, and the chart side that renders them (`queueMode.workerGroups`) is merged to a preview branch, not released. This example, the root module's `n8n_worker_pools` input, and the guidance below may all change to track either upstream feature. What it needs once the pools above are uncommented:
>
> - **n8n 2.39.0 or later** on the image (this example's `n8n_image_tag` default). That is the first release that reads `N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME`; an older image accepts both and ignores them, so the pods come up healthy with the feature doing nothing. The root module enforces the floor as a validation on `n8n_image_tag` whenever `n8n_worker_pools` is non-empty; its own default (`2.35.0`) predates it, which is why this example pins its own default rather than leaving it at the module default.
> - **A license carrying `feat:workerPools`.** Without it a worker started with `N8N_WORKER_POOL_NAME` exits 1 with `worker pools are not licensed`, every pool pod crash-loops, and the Helm release fails its wait and is rolled back by `atomic`, so the apply fails. Terraform cannot see entitlements at plan, so the log line is the diagnosis: `kubectl -n n8n logs -l n8n.io/worker-pool=<pool> -c n8n-worker --previous | grep licensed`. Multi-main (this example's default) also needs `feat:multipleMainInstances`; set `n8n_main_hpa_min_replicas = 1` to run single-main on a license that lacks it.
> - **A Helm chart that renders `queueMode.workerGroups`.** No published chart *release* carries it yet; the feature is [n8n-io/n8n-hosting#189](https://github.com/n8n-io/n8n-hosting/pull/189), merged to the chart's `preview/worker-pools` branch. An official prerelease build is published from that branch to `oci://ghcr.io/n8n-io/n8n-helm-chart` via [n8n-io/n8n-hosting#191](https://github.com/n8n-io/n8n-hosting/pull/191)'s `Preview chart` GitHub Action, which is why `n8n_chart_version` is a required input of this example and the root module fails the plan when the pinned chart is a numbered release that predates the feature (prerelease builds are exempt). See [Getting a chart that renders pools](#getting-a-chart-that-renders-pools) below.
>
> Treat the pool topology as non-production until all three are released.

## What it creates

- Everything [`small`](../small/) creates: VNet and five subnets, a public Azure DNS zone, a Key Vault-issued self-signed TLS certificate, AKS, PostgreSQL Flexible Server, Azure Managed Redis, private Blob storage, and the n8n Helm release
- With `n8n_worker_pools = local.worker_pools` uncommented in `main.tf`: three additional worker Deployments (`n8n-worker-heavy`, `n8n-worker-secteam`, `n8n-worker-itop`), each with its own KEDA `ScaledObject` of the same name watching that pool's own `jobs-<name>` queue, and `N8N_WORKER_POOLS_ENABLED` across mains, workers, and webhook pods. **Only with a chart that renders `queueMode.workerGroups`**; an older chart accepts the key and renders none of this, which is the failure [`verify-worker-pools.sh`](../../tests/scripts/verify-worker-pools.sh) exists to catch.

## The pool topology

Defined in [`main.tf`](./main.tf) as `local.worker_pools` rather than a variable, since the topology is the point of the example rather than a knob (a local is also reachable from the example's tests, where a literal at the module call site would not be):

| Pool | Replicas | Concurrency | Sizing | Why |
|---|---|---|---|---|
| *(unlabelled)* | 1 to 10 | module default | module default | Serves the default `jobs` queue for every unpinned project |
| `heavy` | 1 to 4 | 5 | 1-2 vCPU, 2-4 GiB | Heavier executions, fewer jobs per worker. Same node pools as everything else; bigger requests, not different hardware |
| `secteam` | 1 to 3 | module default | module default | Isolation for one team's projects |
| `itop` | 0 to 3 | module default | module default | Scales to zero when idle |

A pool with no live workers is not an error. A job routed to it waits on the pool's queue and KEDA scales the pool up (0 to 1 within one polling interval), so `itop` costs nothing while idle. The catch is assignment: a project can only be pinned to a pool that currently has a registered worker, so a pool that starts life at 0 has to be raised to 1 once for the assignment. See step 4 of the [end-to-end test](#an-end-to-end-execution-on-a-pool).

Pool names are lowercase letters, digits, and hyphens, 1 to 43 characters, starting and ending alphanumeric. The 43 comes from KEDA by way of the chart: the pool's ScaledObject is named `n8n-worker-<name>`, KEDA caps that at 54 characters because it doubles as a label value and as part of the generated HPA's name, and the chart fails the render past it. The chart's own schema allows 53, but that only holds for a shorter release name than the module's fixed `n8n`, so the module enforces the tighter figure and a name cannot pass plan and fail at apply. `default` is rejected too: it would mean a queue named `jobs-default`, which is not the real default queue.

## Prerequisites

- A domain you control, delegatable to the public Azure DNS zone this example creates.
- An n8n Enterprise license carrying `feat:workerPools`. For multi-main (the default) it also needs `feat:multipleMainInstances`; set `n8n_main_hpa_min_replicas = 1` to run single-main on a Business-tier license instead.
- A chart that renders `queueMode.workerGroups`, reachable from your workstation: the official preview build `1.11.0-preview.workerpools.1` is already published to the root module's hardcoded chart repository, `oci://ghcr.io/n8n-io/n8n-helm-chart` (see the next section for how it was built).
- `helm` 3.8+ on your workstation, to confirm the pinned chart resolves before applying.

## Getting a chart that renders pools

Skip this section, and pin your released chart directly with `n8n_worker_pools_chart_verified = true`, once you have confirmed your target chart renders `queueMode.workerGroups`.

Until then, the fastest path is the chart repo's own **official preview build**. [n8n-io/n8n-hosting#191](https://github.com/n8n-io/n8n-hosting/pull/191) registered a `Preview chart` GitHub Action on `main` that packages the `preview/worker-pools` branch (carrying [#189](https://github.com/n8n-io/n8n-hosting/pull/189)) and pushes a prerelease build to `oci://ghcr.io/n8n-io/n8n-helm-chart`, the same registry `helm_release.n8n` in this module's `n8n.tf` hardcodes. Anyone with write access to n8n-io/n8n-hosting can dispatch it:

```bash
# From the GitHub UI: Actions -> Preview chart -> Run workflow, ref preview/worker-pools.
# Equivalent via the CLI:
gh workflow run preview-chart.yml --repo n8n-io/n8n-hosting --ref preview/worker-pools \
  -f build=1 -f repository=oci://ghcr.io/n8n-io/n8n-helm-chart
```

That publishes `n8n-1.11.0-preview.workerpools.1` (bump `build` for a later attempt; the workflow rejects re-pushing an existing version). Confirm it landed, then pin it:

```bash
helm show chart oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version 1.11.0-preview.workerpools.1 | head -5
```

```hcl
n8n_chart_version = "1.11.0-preview.workerpools.1"
n8n_image_tag     = "2.39.0"
```

**No write access to n8n-io/n8n-hosting, or want a mirror you control?** Unlike the AWS sibling module, this module does not expose an `n8n_chart_repository` override: `helm_release.n8n` (`n8n.tf`) pins `repository = "oci://ghcr.io/n8n-io/n8n-helm-chart"` literally, so pushing a build to your own Azure Container Registry does not by itself make this module pull from it. Today that leaves two options: use the official GHCR preview build above, or fork the module to parameterize that one line. If you take the fork path, package and push exactly the same way the AWS module's private-mirror fallback does, adapted to `az acr`:

```bash
RESOURCE_GROUP=n8n-chart-mirror-rg
LOCATION=eastus
ACR_NAME=n8nchartmirror$(openssl rand -hex 3)   # globally unique
CHART_VERSION="1.11.0-preview.workerpools.1"    # base version of the branch's Chart.yaml, plus a prerelease suffix

# 1. Check out the branch (#189 is merged into it, not a standalone PR head anymore).
git clone https://github.com/n8n-io/n8n-hosting.git /tmp/n8n-hosting
cd /tmp/n8n-hosting
git checkout preview/worker-pools

# 2. Lint and render once locally, with this example's values shape, before pushing.
helm lint charts/n8n -f charts/n8n/ci/workerGroups-values.yaml
helm template n8n charts/n8n -f charts/n8n/ci/workerGroups-values.yaml \
  | grep -E '^kind: (Deployment|ScaledObject)$' | sort | uniq -c

# 3. Package with a prerelease version. Helm never picks a prerelease up by
#    accident, and the module's chart-version check takes one at your word.
helm package charts/n8n --version "$CHART_VERSION" --destination /tmp/chart-pkg

# 4. Create the registry and push. The OCI path is <registry>/<repo>/<chart
#    name>, so the ACR repository is named n8n-helm-chart/n8n, matching the
#    parent path the public ghcr.io default uses.
az acr create --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --sku Basic --location "$LOCATION"
az acr login --name "$ACR_NAME"
helm registry login "$ACR_NAME.azurecr.io" \
  --username "00000000-0000-0000-0000-000000000000" \
  --password "$(az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken)"
helm push "/tmp/chart-pkg/n8n-$CHART_VERSION.tgz" "oci://$ACR_NAME.azurecr.io/n8n-helm-chart"

# 5. Confirm the push landed. This module still cannot pull from it until the
#    fork replaces the hardcoded repository in n8n.tf with this address.
helm show chart "oci://$ACR_NAME.azurecr.io/n8n-helm-chart/n8n" --version "$CHART_VERSION" | head -5
```

`CHART_VERSION` above is suffixed as a prerelease so a fork's chart-version guard would take it at your word without any extra input, the same as the official build. If you would rather package and distribute this internally under a real numbered version (dropping the `-preview.workerpools.1` suffix), pair that fork with `n8n_worker_pools_chart_verified = true`: that is the one thing the guard cannot infer from a numbered version string, so it has to be an explicit attestation that you have already confirmed that exact chart renders pools.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain, public_dns_zone_name, n8n_license_key,
# and n8n_chart_version (already a prerelease default; change it only if you built your own).

terraform init
terraform apply
```

This first apply creates no worker pools: `n8n_worker_pools = local.worker_pools` in `main.tf`'s `module "n8n"` block starts commented out. To deploy the three-pool topology documented above, uncomment that line and re-apply:

```bash
terraform plan   # fails on the n8n_image_tag validation if the pinned image predates 2.39.0
terraform apply
```

Delegate the values from `terraform output -json public_dns_zone_name_servers` at your registrar before either apply completes DNS validation.

## Verifying the pools

Run the scripted check first, once the pools are uncommented and applied. It reads `worker_pool_names` and `namespace` from this example's outputs and counts what the cluster actually has against them, which is the one check that catches a chart that ignored `queueMode.workerGroups`:

```bash
../../tests/scripts/verify-worker-pools.sh
```

It asserts, per pool: the `n8n-worker-<pool>` Deployment exists and carries the `n8n.io/worker-pool` label; the ScaledObject of the same name exists and targets that Deployment; the ScaledObject is `READY=True` and its triggers watch `bull:jobs-<pool>:wait` / `:active` with the same `enableTLS` flag and `TriggerAuthentication` reference the default worker's triggers carry, and no credential in trigger metadata; running pool pods have `N8N_WORKER_POOL_NAME` set; the main Deployment has `N8N_WORKER_POOLS_ENABLED=true`; and KEDA's external metric for the pool's queue resolves. It also fails if the cluster has pool Deployments the outputs do not list.

By hand, the same thing:

```bash
eval "$(terraform output -raw kubectl_config_command)"

# One Deployment and one ScaledObject per pool.
kubectl -n n8n get deploy,scaledobject -l app.kubernetes.io/component=worker-group

# The pool name reached the pods.
kubectl -n n8n get pods -l n8n.io/worker-pool=heavy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[?(@.name=="n8n-worker")].env[?(@.name=="N8N_WORKER_POOL_NAME")].value}{"\n"}{end}'
```

The pools also appear in the n8n UI under **Settings, Workers**, which shows each worker's pool and queue, and in a project's **Worker Pools** settings once a worker for that pool is running.

### An end-to-end execution on a pool

The scripted check proves the topology exists; this proves routing. Nothing in the module can do it for you because assigning a project to a pool is a UI (or internal API) action, not a Terraform one.

1. In n8n, open a project, then **Settings, Worker Pools**, and assign it to `heavy`.
2. Create a trivial workflow in that project (Manual Trigger, then a Wait node of ~20 seconds so it stays visible) and run it.
3. While it runs, the execution should be on a `heavy` pod and nowhere else:

   ```bash
   kubectl -n n8n logs -l n8n.io/worker-pool=heavy -c n8n-worker --since=2m | grep -i 'execution'
   kubectl -n n8n logs -l app.kubernetes.io/component=worker -c n8n-worker --since=2m | grep -i 'execution' || echo "default workers idle, as expected"
   ```

4. Scale-from-zero, using `itop`. A project can only be assigned to a pool that currently has a registered worker, so a pool parked at 0 is invisible in the Worker Pools dropdown until something scales it up. To pin a project to `itop` the first time, raise the floor briefly and drop it again once the assignment is saved; the assignment is stored per project and survives the scale-down:

   ```bash
   kubectl -n n8n patch scaledobject n8n-worker-itop --type merge -p '{"spec":{"minReplicaCount":1}}'
   # assign the project in the UI, then
   kubectl -n n8n patch scaledobject n8n-worker-itop --type merge -p '{"spec":{"minReplicaCount":0}}'
   ```

   Or set `min_replicas = 1` in `main.tf` for the first apply and lower it afterwards; Terraform reconciles the patched ScaledObject back to the declared value on the next apply either way.

5. Negative control: unassign the project from `heavy`, run again, and confirm the execution now lands on a default worker.

### Checking a pool's autoscaler

A pool that cannot reach Redis does not crash. It sits at its `min_replicas` and the queue simply never drains, so it is worth knowing which signal actually tells you.

```bash
# READY=True is the one to trust. A scaler that cannot reach Redis reads False.
kubectl -n n8n get scaledobject
```

Do not read `kubectl get hpa` for this. Its TARGETS column shows `<unknown>` for a KEDA-backed worker HPA whether the scaler is healthy or broken, so it gives a false alarm either way. When something is genuinely wrong, `kubectl -n keda logs -l app=keda-operator` says so in as many words, usually a Redis connection timeout.

## Cost and operational caveats

Every n8n process opens up to `postgres_pool_size` connections against PostgreSQL (root module default 10). Adding three pools on top of the default worker deployment grows that aggregate the same way raising `n8n_worker_keda_max_replicas` does; budget the pool ceilings into that arithmetic, not on top of it unaccounted for, especially against `small`'s `GP_Standard_D2s_v3` sizing, which has the least headroom of any tier this module ships.

AKS nodes, Application Gateway WAF_v2, PostgreSQL, and Azure Managed Redis dominate cost. This example's larger `aks_node_vm_size` and `aks_node_count_max` raise the AKS floor above `small`'s. See [the tier comparison](../README.md) before choosing this example over a sizing tier.

## Post-deployment

See [`docs/post-deployment.md`](../../docs/post-deployment.md) for activating your n8n Enterprise license.

## Teardown

```bash
terraform destroy
```

## Production considerations

This example is a reference deployment optimized for clean `apply` / `destroy` cycles during evaluation. The root module ships with teardown-friendly defaults that you should review before promoting to production:

| Module input | Current default | Production |
|---|---|---|
| `pg_backup_retention_days` | `7` | Match your RPO (up to 35 days) |
| `blob_delete_retention_days` | `null` (disabled) | Set a retention window to recover an accidentally deleted blob or container |

These inputs are passed straight through to the root module; set them in `terraform.tfvars` (or via any other variable source) to override the defaults.

See [`docs/build-time-decisions.md`](../../docs/build-time-decisions.md) for settings above (and elsewhere in the root module) that are fixed at the first `terraform apply`.

## Reference

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.14 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_tls_self_signed"></a> [tls\_self\_signed](#module\_tls\_self\_signed) | ../../modules/tls-self-signed | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_dns_zone.public](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dns_zone) | resource |
| [azurerm_key_vault.tls](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.key_vault_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.terraform_blob_data_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.private_endpoints](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_virtual_network.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [random_string.key_vault_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [time_sleep.key_vault_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.storage_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_api_authorized_ip_ranges"></a> [aks\_api\_authorized\_ip\_ranges](#input\_aks\_api\_authorized\_ip\_ranges) | Operator and CI IPv4 CIDRs allowed to reach the public AKS API. Empty leaves it unrestricted and is not recommended for production. | `list(string)` | `[]` | no |
| <a name="input_aks_availability_zones"></a> [aks\_availability\_zones](#input\_aks\_availability\_zones) | Availability zones used by both AKS node pools. Restrict this list when the selected VM SKU is unavailable in one or more regional zones. | `list(string)` | <pre>[<br/>  "1",<br/>  "2",<br/>  "3"<br/>]</pre> | no |
| <a name="input_aks_node_vm_size"></a> [aks\_node\_vm\_size](#input\_aks\_node\_vm\_size) | Azure VM SKU for both AKS node pools. Defaults larger than examples/small's Standard\_D2s\_v5 because the three worker pools below add their own CPU ceilings on top of the main/worker/webhook ceilings; see the arithmetic on local.tier.aks\_node\_count\_max in main.tf. Confirm regional and zonal availability for the selected subscription before applying. | `string` | `"Standard_D4s_v5"` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Optional soft-delete retention window, in days, passed through to the root module's blob\_delete\_retention\_days. Null (the default) leaves Blob soft delete disabled, this example's current behavior. | `number` | `null` | no |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags applied to example and module resources. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions. | `string` | `"n8nwpool"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there. | `string` | `"eastus"` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | n8n Helm chart version to deploy, passed to the module's n8n\_chart\_version. Required by this example because the module default predates queueMode.workerGroups and would render no pools once local.worker\_pools is wired in. Pin the first release that carries the feature once it exists, or a prerelease build (e.g. 1.11.0-preview.workerpools.1, published via n8n-io/n8n-hosting's Preview chart GitHub Action) in the meantime. | `string` | n/a | yes |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Canonical fully-qualified domain for n8n. It must be the Azure DNS zone apex or a subdomain of public\_dns\_zone\_name. | `string` | n/a | yes |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | Pinned n8n application version, passed to the module's n8n\_image\_tag. Defaults to 2.39.0, the first n8n release that reads N8N\_WORKER\_POOLS\_ENABLED and N8N\_WORKER\_POOL\_NAME; an older image accepts both and silently ignores them once local.worker\_pools is wired in, so the pods come up healthy with the feature doing nothing. The root module's own default (2.35.0) predates that floor, which is why this example pins its own default rather than leaving the module default in place. | `string` | `"2.39.0"` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Worker pools need the feat:workerPools entitlement on top of whatever else the deployment uses. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum main replicas passed through to the root module's n8n\_main\_hpa\_min\_replicas, the sole topology selector. The default of 2 keeps this example on multi-main, which needs feat:multipleMainInstances on top of feat:workerPools. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); worker pools still need feat:workerPools either way. | `number` | `2` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Maximum worker replicas KEDA may scale the default (unlabelled) worker deployment to. | `number` | `10` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Minimum worker replicas KEDA keeps running for the default (unlabelled) worker deployment. | `number` | `1` | no |
| <a name="input_n8n_worker_pools_chart_verified"></a> [n8n\_worker\_pools\_chart\_verified](#input\_n8n\_worker\_pools\_chart\_verified) | Passed to the module's n8n\_worker\_pools\_chart\_verified. Leave false for the documented path, a prerelease build such as 1.11.0-preview.workerpools.1, which the module accepts from the version string alone. Set true only when n8n\_chart\_version is a numbered build of the feature branch you have confirmed renders queueMode.workerGroups; the module takes that at your word and never re-checks it. | `bool` | `false` | no |
| <a name="input_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#input\_pg\_backup\_retention\_days) | Number of days to retain automated PostgreSQL Flexible Server backups, passed through to the root module's pg\_backup\_retention\_days. The default of 7 matches this example's documented sizing (Azure enforces 7-35 days for Flexible Server; it cannot disable backups). | `number` | `7` | no |
| <a name="input_public_dns_zone_name"></a> [public\_dns\_zone\_name](#input\_public\_dns\_zone\_name) | Public Azure DNS zone created by this example. Delegate its output name servers at the domain registrar. | `string` | n/a | yes |
| <a name="input_resource_group_location"></a> [resource\_group\_location](#input\_resource\_group\_location) | Optional Azure metadata location for both resource groups. Defaults to location. Set this only when moving regional resources while retaining existing resource groups and global DNS zones. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster. |
| <a name="output_aks_resource_group"></a> [aks\_resource\_group](#output\_aks\_resource\_group) | Resource group containing AKS and the n8n managed services. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Public IPv4 address of the module-managed Application Gateway. |
| <a name="output_azure_blob_container_name"></a> [azure\_blob\_container\_name](#output\_azure\_blob\_container\_name) | Name of the private Azure Blob container used for n8n binary and execution data. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that writes the AKS context into the local kubeconfig. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | Generated n8n encryption key. Back it up to a password manager immediately after the first apply. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Canonical HTTPS URL for n8n. The self-signed example certificate causes browser warnings. |
| <a name="output_n8n_webhook_path_prefixes"></a> [n8n\_webhook\_path\_prefixes](#output\_n8n\_webhook\_path\_prefixes) | Complete path-prefix set the Ingress routes to the webhook-processor service. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace containing n8n. Read by tests/scripts/verify-worker-pools.sh. |
| <a name="output_postgres_fqdn"></a> [postgres\_fqdn](#output\_postgres\_fqdn) | Private FQDN n8n connects to for PostgreSQL. |
| <a name="output_postgres_password"></a> [postgres\_password](#output\_postgres\_password) | Generated PostgreSQL administrator password. Back it up in a secret manager. |
| <a name="output_public_dns_zone_name_servers"></a> [public\_dns\_zone\_name\_servers](#output\_public\_dns\_zone\_name\_servers) | Azure DNS name servers to delegate at the registrar. |
| <a name="output_redis_hostname"></a> [redis\_hostname](#output\_redis\_hostname) | Private hostname n8n and KEDA connect to for Redis. |
| <a name="output_storage_account_name"></a> [storage\_account\_name](#output\_storage\_account\_name) | Name of the private StorageV2 account holding the Azure Blob container. |
| <a name="output_tier_configuration"></a> [tier\_configuration](#output\_tier\_configuration) | Plan-known sizing decisions passed into the root module by this example. |
| <a name="output_tls_certificate_secret_id"></a> [tls\_certificate\_secret\_id](#output\_tls\_certificate\_secret\_id) | Versioned Key Vault Secret URI consumed by Application Gateway. |
| <a name="output_worker_pool_names"></a> [worker\_pool\_names](#output\_worker\_pool\_names) | Names of the worker pools this example documents, in declaration order, whether or not local.worker\_pools is currently wired into module "n8n".n8n\_worker\_pools. Read by tests/scripts/verify-worker-pools.sh, which counts the rendered pool Deployments and ScaledObjects on the cluster against this list: a chart that predates queueMode.workerGroups (or pools left commented out) leaves the cluster with nothing behind it, and only a live count can see that. |
<!-- END_TF_DOCS -->
