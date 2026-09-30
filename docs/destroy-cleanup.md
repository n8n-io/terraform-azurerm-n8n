# Destroy & cleanup guide

This guide covers how to cleanly tear down the n8n infrastructure with `terraform destroy` and how to recover from the most common partial-destroy hangs (Application Gateway frontend-IP release, namespace finalizers, half-uninstalled Helm release).

Every workaround below is grounded in a real failure mode the prototype hit while iterating on the module — see [`troubleshooting.md`](./troubleshooting.md) for the create-time counterparts.

The destroy order below assumes every layer is module-managed (the defaults). On a customer-managed AKS cluster, namespace, or KEDA installation, `terraform destroy` removes only the resources this module created — it does not, and must not, delete a caller-owned namespace or the caller's own AKS cluster. See [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md) for exactly which resources move outside the module's ownership on each customer-managed path, and note the KEDA `ScaledObject` finalizer hazard documented in [`modules/controllers/README.md`](../modules/controllers/README.md#the-ownership-change-finalizer-hazard) before changing `install_keda` on an already-applied stack.

What `terraform destroy` cannot undo, and which module inputs (if any)
make PostgreSQL or Blob storage deletion recoverable, is covered
separately in [`docs/deletion-safety.md`](./deletion-safety.md); read it
before relying on this module for production destroy protection.

## Before you destroy

Back up everything you cannot regenerate. The encryption key in particular is unrecoverable once state is gone.

```bash
terraform output -raw n8n_encryption_key > /path/to/secret-vault/n8n-encryption-key.txt

# Kubeconfig is not persisted as a Terraform output on the sizing examples;
# regenerate it on demand instead of relying on state as the backup copy.
az aks get-credentials --name "$(terraform output -raw aks_cluster_name)" \
  --resource-group "$(terraform output -raw aks_resource_group)" \
  --file /path/to/secret-vault/kubeconfig-n8n.yaml
```

Set shell variables used throughout this guide so the commands below copy-paste cleanly (run from an `examples/{small,medium,large}` directory, whose outputs include `aks_resource_group`; a caller wiring the root module directly gets the equivalent from its own resource group input):

```bash
CLUSTER=$(terraform output -raw aks_cluster_name)
RG=$(terraform output -raw aks_resource_group)
NS=$(terraform output -raw namespace)            # always "n8n"
SUB=$(az account show --query id -o tsv)
```

`terraform destroy` itself does not call `az` or `kubectl`. Make sure your `azurerm` provider credentials still have permission to delete the resources Terraform created (the same role that succeeded on `apply`); the troubleshooting recipes below need `az login` only when they're invoked manually.

## Standard destroy

```bash
terraform destroy
```

The full module dependency graph drives the teardown order:

1. `kubernetes_ingress_v1.n8n` is deleted; AGIC reconciles the Application Gateway to remove the listener / backend pool.
2. `helm_release.n8n` uninstalls. The chart's `wait = true, atomic = true, cleanup_on_fail = true` settings drive an orderly pod scale-down inside the release.
3. The `kubernetes_secret.n8n_*` Secrets, the AKS workload-identity federated credential, and KEDA's `TriggerAuthentication` are removed.
4. `kubernetes_namespace.n8n` is removed (its `delete` timeout is 5 minutes — see [`n8n.tf`](../n8n.tf) — to absorb any namespace-finalizer cleanup that lingers).
5. `module.controllers`' Helm release, then its Kubernetes namespace (skipped entirely when `install_keda = false` selected an externally managed KEDA installation).
6. The `time_sleep.aks_api_warmup` and `time_sleep.n8n_helm_settle` gates are removed from state — both are bootstrap-only and have no destroy-time side effects.
7. `azurerm_application_gateway.n8n`, `azurerm_public_ip.appgw`, then the AKS cluster and the user node pool.
8. Postgres, Redis (private endpoint then Managed Redis instance), the private DNS zones and their VNet links.
9. The Storage Account and Blob container, and the user-assigned identities.
10. The caller-owned resource group (`var.resource_group_name` — this module does not create one) is removed last by whichever caller-side resource created it, e.g. the sizing example's `azurerm_resource_group.n8n`.

A clean destroy completes in 15–25 minutes. If it stalls beyond that, drop into the troubleshooting recipes below — destruction is not idempotent in the AGIC combination, so blind retries can compound the problem.

## Troubleshooting

### `helm_release.n8n` is wedged in a half-uninstalled state

**Symptom:** A previous `terraform destroy` partially uninstalled the release; subsequent destroys fail with `release: not found` on some resources and `release in unexpected state` on others.

**Cause:** Helm's release secret (`sh.helm.release.v1.n8n.v1`) survives a partial uninstall when a stuck pod blocks the chart's removal mid-uninstall.

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

```text
Error: deleting Application Gateway: ... PublicIPAddressCannotBeDeleted: Public IP address ... is associated with frontend IP configuration
```

**Cause:** AGIC reconciles the App Gateway in the background. If the Ingress was deleted in the same destroy run, AGIC may have already removed the listener but not yet released the frontend IP configuration before Terraform tries to delete the gateway, leaving the public IP `azurerm_public_ip.appgw` orphaned.

**Fix:** Force-detach the public IP from the App Gateway, then retry:

```bash
APPGW_NAME="<friendly_name_prefix>-appgw"     # local.app_gateway_name, see locals.tf
PIP_NAME="<friendly_name_prefix>-appgw-pip"   # local.appgw_pip_name, see locals.tf

# 1. Confirm the App Gateway and PIP both exist
az network application-gateway show -g "$RG" -n "$APPGW_NAME" --query name -o tsv
az network public-ip show -g "$RG" -n "$PIP_NAME" --query ipAddress -o tsv

# 2. Delete the App Gateway directly (skips Terraform's grace period)
az network application-gateway delete -g "$RG" -n "$APPGW_NAME"

# 3. Delete the orphan public IP
az network public-ip delete -g "$RG" -n "$PIP_NAME"

# 4. Drop both from state so destroy doesn't re-try them
terraform state rm 'module.n8n.azurerm_application_gateway.n8n[0]'
terraform state rm 'module.n8n.azurerm_public_ip.appgw[0]'

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

**Caller-supplied zones:** none of the above applies when
`postgres_private_dns_zone_id`, `redis_private_dns_zone_id`, or
`blob_private_dns_zone_id` is set. The module never creates or destroys a
caller-supplied zone or its VNet link, so `terraform destroy` leaves them
and their links untouched regardless of what happens to the rest of the
n8n deployment.

### Key Vault destroy fails with `purge protection`

**Symptom:** `azurerm_key_vault.n8n` fails to delete, or destroy succeeds but a re-apply hits `vault name is already taken`.

**Cause:** Azure Key Vault soft-delete keeps a deleted vault recoverable for 7–90 days. When `purge_protection_enabled = true` is set on the vault (the module sets `false` by default — but a Phase 2 hardening story may have flipped it), Azure refuses purge for the retention period.

**Fix:** When the module-owned KV uses the default (`purge_protection_enabled = false`), purge it directly:

```bash
KV_NAME=$(terraform state show azurerm_key_vault.n8n 2>/dev/null | awk '/^ +name +=/ {print $3; exit}' | tr -d '"')
az keyvault purge --name "$KV_NAME" --location "$(az group show -g "$RG" --query location -o tsv)"
```

If `purge_protection_enabled = true`, the vault must wait out the soft-delete retention before its name can be reused. Pick a different `friendly_name_prefix` for the next deployment, or wait.

### Removing stuck resources from Terraform state

If a resource was already deleted out of band (e.g. via the Azure portal or `az` CLI in a recovery sequence above) and Terraform cannot refresh it:

```bash
# List all resources in state
terraform state list

# Remove a specific resource from state (does NOT delete the actual resource)
terraform state rm <resource_address>

# Example: remove an App Gateway and its PIP after a manual `az network ...delete`
terraform state rm 'module.n8n.azurerm_application_gateway.n8n[0]'
terraform state rm 'module.n8n.azurerm_public_ip.appgw[0]'
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
