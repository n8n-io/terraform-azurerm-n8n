# Destroy & cleanup guide

This guide covers how to cleanly tear down the n8n infrastructure with `terraform destroy` and how to recover from the most common partial-destroy hangs (Azure Files volume detach, Application Gateway frontend-IP release, namespace finalizers, half-uninstalled Helm release).

Every workaround below is grounded in a real failure mode the prototype hit while iterating on the module — see [`troubleshooting.md`](./troubleshooting.md) for the create-time counterparts.

## Before you destroy

Back up everything you cannot regenerate. The encryption key in particular is unrecoverable once state is gone.

```bash
terraform output -raw encryption_key   > /path/to/secret-vault/n8n-encryption-key.txt
terraform output -raw kube_config_raw  > /path/to/secret-vault/kubeconfig-n8n.yaml
```

Set shell variables used throughout this guide so the commands below copy-paste cleanly:

```bash
CLUSTER=$(terraform output -raw aks_cluster_name)
RG=$(terraform output -raw aks_resource_group)
NS=$(terraform output -raw n8n_namespace)        # always "n8n"
SUB=$(az account show --query id -o tsv)
```

`terraform destroy` itself does not call `az` or `kubectl` — the destroy-time drain gate is now a declarative `time_sleep.wait_for_aks_drain` (registry-hardening US-005) instead of a `null_resource` apply-host bash drain. Make sure your `azurerm` provider credentials still have permission to delete the resources Terraform created (the same role that succeeded on `apply`); the troubleshooting recipes below need `az login` only when they're invoked manually.

## Standard destroy

```bash
terraform destroy
```

The destroy-time pivot is `time_sleep.wait_for_aks_drain` in [`cleanup.tf`](../cleanup.tf). It mirrors the AWS sibling's [`time_sleep.wait_for_alb_cleanup`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/n8n.tf) pattern: a deterministic destroy-time pause sits between two resources, and Terraform unwinds them in the order forced by the dependency edges.

```text
Dependency chain (create order, reversed for destroy):
  kubernetes_namespace.n8n → time_sleep.wait_for_aks_drain → helm_release.n8n

Destroy order:
  1. helm_release.n8n              ← Helm uninstalls; pods scale to 0 inside the release
  2. time_sleep.wait_for_aks_drain ← destroy_duration pause (default 120 s) for the
                                     asynchronous Azure Files CIFS detach to finish
  3. kubernetes_namespace.n8n      ← namespace + PVC/PV/Secret cleanup (no more SMB locks)
```

The full module dependency graph then drives the rest of the teardown:

1. `kubernetes_ingress_v1.n8n` is deleted; AGIC reconciles the Application Gateway to remove the listener / backend pool.
2. `helm_release.n8n` uninstalls. The chart's `wait = true, atomic = true, cleanup_on_fail = true` settings drive an orderly pod scale-down inside the release.
3. `time_sleep.wait_for_aks_drain` ([`cleanup.tf`](../cleanup.tf)) pauses for `var.aks_destroy_drain_seconds` (default 120 s; range 30..600) — the asynchronous Azure Files CIFS detach finishes during this window so the next steps don't race the SMB lock release.
4. The static PV/PVC/Secret bindings, the AKS workload-identity federated credential, and KEDA's `TriggerAuthentication` are removed.
5. `kubernetes_namespace.n8n` is removed (its `delete` timeout is 5 minutes — see [`n8n.tf`](../n8n.tf) — to absorb any namespace-finalizer cleanup that lingers past the drain gate).
6. `helm_release.keda`, then `kubernetes_namespace.keda`.
7. The `time_sleep.aks_api_warmup` and `time_sleep.n8n_helm_settle` gates are removed from state — both are bootstrap-only and have no destroy-time side effects.
8. `azurerm_application_gateway.n8n`, `azurerm_public_ip.appgw_pip`, then the AKS cluster and the user node pool.
9. Postgres, Redis (private endpoint then cache), the two private DNS zones and their VNet links.
10. Key Vault, the Storage Account + Files share, and the user-assigned identities.
11. The module-owned resource group (`<friendly_name_prefix>-n8n-rg`) is removed last.

A clean destroy completes in 15–25 minutes. If it stalls beyond that, drop into the troubleshooting recipes below — destruction is not idempotent in the AGIC + Azure Files combination, so blind retries can compound the problem.

### Tuning `var.aks_destroy_drain_seconds`

The default 120 s suits the module's default Azure Files share quota (100 GiB) and a multi-main + worker pool of ≤6 pods. Bump it when:

- You raised `var.storage_share_quota_gb` to >50 GiB (more open-handles to flush during detach).
- You scaled `var.n8n_main_replicas` and / or KEDA worker pools beyond their defaults — every additional pod adds ~5–10 s of CIFS detach to the cumulative window.
- You see the Helm uninstall succeed but a follow-up `Files share is mounted` error on `azurerm_storage_account.n8n` deletion.

The ceiling (600 s) matches the legacy bash drain's outer wait-loop. If you need more than 600 s, the underlying problem is usually a workload outside the n8n namespace mounting the same share — see "Storage account destroy fails with `Files share is mounted`" below.

## Troubleshooting

### `helm_release.n8n` hangs on Azure Files volume detach

**Symptom:** `terraform destroy` stalls at:

```
helm_release.n8n: Still destroying... [id=n8n, 5m elapsed]
helm_release.n8n: Still destroying... [id=n8n, 10m elapsed]
…
Error: context deadline exceeded
```

…and `kubectl -n n8n get pods` shows pods stuck in `Terminating` for the full duration.

**Cause:** Azure Files SMB volumes have a multi-minute detach delay per pod when the share is still busy. The chart-side `wait = true, atomic = true, cleanup_on_fail = true` and a 600 s `timeout` already drive an orderly pod scale-down inside the Helm release; the destroy-time `time_sleep.wait_for_aks_drain` gate then pauses (default 120 s) so the Azure-side CIFS detach completes before the namespace + PVC are removed. The hang shows up when the share has more open handles than 120 s of detach can flush — most often after raising `var.storage_share_quota_gb` substantially or scaling out `var.n8n_main_replicas` beyond the default.

**Fix:** Bump `var.aks_destroy_drain_seconds` (range 30..600) and re-run destroy:

```hcl
# terraform.tfvars or your tfvars file of choice
aks_destroy_drain_seconds = 300
```

```bash
terraform destroy
```

If the share is still locked after 600 s, the holder is almost certainly outside the n8n namespace — see "Storage account destroy fails with `Files share is mounted`" below for a recipe to identify and unmount it. As a last-resort manual unblock, run the same scale-to-zero you'd run before any disruptive cluster operation:

```bash
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing
kubectl scale deployment --all -n "$NS" --replicas=0 --timeout=60s
kubectl get pods -n "$NS" -o name | xargs -r -n1 kubectl delete -n "$NS" --force --grace-period=0
kubectl wait --for=delete pods --all -n "$NS" --timeout=2m

terraform destroy
```

### `helm_release.n8n` is wedged in a half-uninstalled state

**Symptom:** A previous `terraform destroy` partially uninstalled the release; subsequent destroys fail with `release: not found` on some resources and `release in unexpected state` on others.

**Cause:** Helm's release secret (`sh.helm.release.v1.n8n.v1`) survives a partial uninstall when SMB-locked pods block the chart's PVC removal mid-uninstall.

**Fix:**

```bash
# Confirm the release exists and is in a half-uninstalled state.
helm -n "$NS" list --all
helm -n "$NS" status n8n

# Bypass Helm hooks/PVCs and force-uninstall.
helm -n "$NS" uninstall n8n --no-hooks --ignore-not-found

# Drop the release secret(s) explicitly if `helm uninstall` says "not found"
# but `kubectl get secret -n "$NS" -l owner=helm` still lists them.
kubectl -n "$NS" delete secret -l owner=helm --field-selector type=helm.sh/release.v1

# Now retry terraform destroy.
terraform destroy
```

### Namespace stuck in `Terminating`

**Symptom:** `kubernetes_namespace.n8n` does not get destroyed; `kubectl get namespace n8n` shows it stuck in `Terminating` for more than 2 minutes.

**Cause:** Custom resources in the namespace (TriggerAuthentication from KEDA, leftover ScaledObjects, or the ingress finalizer that AGIC adds) carry finalizers from controllers that have already been uninstalled.

**Fix:** Strip finalizers from every resource left in the namespace:

```bash
kubectl api-resources --verbs=list --namespaced -o name | while read RESOURCE; do
  kubectl get "$RESOURCE" -n "$NS" \
    -o jsonpath='{range .items[?(@.metadata.finalizers)]}{@.kind}/{@.metadata.name}{"\n"}{end}' \
    2>/dev/null | while read OBJ; do
    [ -n "$OBJ" ] || continue
    NAME=$(echo "$OBJ" | cut -d/ -f2)
    kubectl patch "$RESOURCE/$NAME" -n "$NS" --type=merge \
      -p '{"metadata":{"finalizers":null}}'
  done
done
```

If the namespace itself carries a `kubernetes` finalizer (rare, but possible after a forcibly-removed cluster), strip it directly:

```bash
kubectl get namespace "$NS" -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/${NS}/finalize" -f -
```

Then re-run `terraform destroy`.

### `azurerm_application_gateway.n8n` hangs on frontend IP release

**Symptom:** `terraform destroy` stalls on `azurerm_application_gateway.n8n` for 10–20 minutes, sometimes failing with:

```
Error: deleting Application Gateway: ... PublicIPAddressCannotBeDeleted: Public IP address ... is associated with frontend IP configuration
```

**Cause:** AGIC reconciles the App Gateway in the background. If the Ingress was deleted in the same destroy run, AGIC may have already removed the listener but not yet released the frontend IP configuration before Terraform tries to delete the gateway, leaving the public IP `azurerm_public_ip.appgw_pip` orphaned.

**Fix:** Force-detach the public IP from the App Gateway, then retry:

```bash
APPGW_NAME="${CLUSTER%-aks}-n8n-appgw"   # default name shape, see ingress.tf
PIP_NAME="${CLUSTER%-aks}-n8n-appgw-pip" # default name shape, see ingress.tf

# 1. Confirm the App Gateway and PIP both exist
az network application-gateway show -g "$RG" -n "$APPGW_NAME" --query name -o tsv
az network public-ip show -g "$RG" -n "$PIP_NAME" --query ipAddress -o tsv

# 2. Delete the App Gateway directly (skips Terraform's grace period)
az network application-gateway delete -g "$RG" -n "$APPGW_NAME"

# 3. Delete the orphan public IP
az network public-ip delete -g "$RG" -n "$PIP_NAME"

# 4. Drop both from state so destroy doesn't re-try them
terraform state rm 'azurerm_application_gateway.n8n'
terraform state rm 'azurerm_public_ip.appgw_pip'

# 5. Re-run terraform destroy for the remaining resources
terraform destroy
```

### Postgres Flexible Server destroy fails with `subnet is in use by`

**Symptom:** `azurerm_postgresql_flexible_server.n8n` fails to delete with a `SubnetInUse` or `DelegatedSubnetInUse` error.

**Cause:** Azure occasionally retains the VNet-injection plumbing (a hidden `Microsoft.DBforPostgreSQL/flexibleServers` resource on the postgres subnet) for up to 15 minutes after server deletion. If you are tearing down the example's network RG (which owns the postgres subnet) in the same run, Terraform tries to delete the subnet before Azure has released its claim.

**Fix:** Wait 15 minutes and retry, or force the subnet's delegation cleanup:

```bash
SUBNET_ID=$(terraform output -raw postgres_subnet_id 2>/dev/null \
  || echo "/subscriptions/${SUB}/resourceGroups/.../subnets/postgres")

# Drop the subnet's delegation (forces the hidden Microsoft.DBforPostgreSQL/flexibleServers entry to release)
SUBNET_RG=$(echo "$SUBNET_ID" | awk -F/ '{print $5}')
VNET=$(echo "$SUBNET_ID" | awk -F/ '{print $9}')
SUBNET=$(echo "$SUBNET_ID" | awk -F/ '{print $11}')

az network vnet subnet update \
  --resource-group "$SUBNET_RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET" \
  --remove delegations

terraform destroy
```

### Private DNS zone destroy fails with `link is in use`

**Symptom:** `azurerm_private_dns_zone.postgres` (or `.redis`) fails to delete with `Cannot delete the resource because there are virtual network links associated with it`.

**Cause:** The VNet link (`azurerm_private_dns_zone_virtual_network_link.{postgres,redis}`) was already destroyed but Azure has not yet propagated the unlink. Terraform retries the zone delete and hits the in-use error before the propagation finishes.

**Fix:** Wait 5–10 minutes and retry. If retries keep failing, list the zone's links and delete any stragglers:

```bash
az network private-dns link vnet list \
  --resource-group "$RG" \
  --zone-name privatelink.postgres.database.azure.com \
  --query '[].name' -o tsv | while read LINK; do
  echo "Deleting orphan link $LINK..."
  az network private-dns link vnet delete \
    --resource-group "$RG" \
    --zone-name privatelink.postgres.database.azure.com \
    --name "$LINK" --yes
done

terraform destroy
```

Repeat for `privatelink.redis.cache.windows.net` if Redis hits the same error.

### Key Vault destroy fails with `purge protection`

**Symptom:** `azurerm_key_vault.n8n` fails to delete, or destroy succeeds but a re-apply hits `vault name is already taken`.

**Cause:** Azure Key Vault soft-delete keeps a deleted vault recoverable for 7–90 days. When `purge_protection_enabled = true` is set on the vault (the module sets `false` by default — but a Phase 2 hardening story may have flipped it), Azure refuses purge for the retention period.

**Fix:** When the module-owned KV uses the default (`purge_protection_enabled = false`), purge it directly:

```bash
KV_NAME=$(terraform state show azurerm_key_vault.n8n 2>/dev/null | awk '/^ +name +=/ {print $3; exit}' | tr -d '"')
az keyvault purge --name "$KV_NAME" --location "$(az group show -g "$RG" --query location -o tsv)"
```

If `purge_protection_enabled = true`, the vault must wait out the soft-delete retention before its name can be reused. Pick a different `friendly_name_prefix` for the next deployment, or wait.

### Storage account destroy fails with `Files share is mounted`

**Symptom:** `azurerm_storage_account.n8n` fails to delete with `the specified storage account is currently in use`.

**Cause:** A pod or process outside the n8n namespace still has the SMB share mounted. The module's `time_sleep.wait_for_aks_drain` gate only absorbs the asynchronous detach window for n8n-namespace pods (which Helm uninstall scales to zero); if a caller has mounted the share into a different namespace or onto a host outside the cluster, the SMB lock stays even after the gate expires.

**Fix:** Identify the holder and unmount, then retry destroy:

```bash
# Inside the cluster — find any pod with a CIFS volume from the storage account
kubectl get pods --all-namespaces -o json \
  | jq -r '.items[] | select(.spec.volumes[]?.azureFile) | "\(.metadata.namespace)/\(.metadata.name)"'

# Outside the cluster — list explicit SMB mounts on the apply host (Linux)
mount -t cifs | grep "$STORAGE_ACCOUNT_NAME" || true
```

Once nothing is holding the share, retry `terraform destroy`.

### Removing stuck resources from Terraform state

If a resource was already deleted out of band (e.g. via the Azure portal or `az` CLI in a recovery sequence above) and Terraform cannot refresh it:

```bash
# List all resources in state
terraform state list

# Remove a specific resource from state (does NOT delete the actual resource)
terraform state rm <resource_address>

# Example: remove an App Gateway and its PIP after a manual `az network ...delete`
terraform state rm 'azurerm_application_gateway.n8n'
terraform state rm 'azurerm_public_ip.appgw_pip'
```

After removing the orphans, re-run `terraform destroy` for the remaining resources.

## After destroy

Confirm the module-owned resource group is gone (cleans up everything the module created in Azure):

```bash
az group exists --name "$RG"   # should print "false"
```

If the example created its own network RG (`${prefix}-n8n-network-rg`), verify it is also removed:

```bash
az group exists --name "${RG%-n8n-rg}-n8n-network-rg"
```

NS records at your domain registrar do **not** get cleaned up by `terraform destroy` — if you used `public_dns_zone_name`, remove the four NS records you added during onboarding to avoid leaving a stale delegation pointing at deleted Azure NS servers (someone could re-create the zone in their tenant under the same name and serve traffic from your delegation).
