# Upgrading to the azurerm 5.x provider

This module now requires `hashicorp/azurerm` `>= 5.5.0, < 6.0.0` (the
tracked lock files resolve `5.9.0`). It previously required
`>= 4.39.0, < 5.0.0`. This page covers what changed, what a caller has to
change, what `terraform plan` should show on an existing deployment, and a
step-by-step checklist for upgrading a live `examples/small` deployment in
place.

There is no release that works with both majors. The root module now uses
arguments that 4.x does not accept (`private_dns_zone_id` on the private DNS
VNet links and A record, `node_provisioning_profile` on AKS,
`public_network_access` on the storage account), and 5.x removed the 4.x
argument names it replaces. Move the module and the provider in one change.
The two TLS helpers (`modules/tls-letsencrypt`, `modules/tls-self-signed`)
only use `azurerm_key_vault_certificate`, which did not change, so they
accept `>= 4.0, < 6.0.0`.

The floor is `5.5.0` because that release added
`azurerm_storage_account.public_network_access`. It also includes the
`5.1.0` state migration for `azurerm_storage_container` IDs. Containers this
module created were always addressed by `storage_account_id`, so they do not
depend on that migration, but containers you created by
`storage_account_name` do.

## What changed in the module

| Resource | Change | Why | Effect on an existing deployment |
| --- | --- | --- | --- |
| `azurerm_private_dns_zone_virtual_network_link` (`postgres`, `redis`, `blob`) | `private_dns_zone_id = azurerm_private_dns_zone.<x>[0].id` replaces `resource_group_name` and `private_dns_zone_name` | 5.0 removed the name arguments | None after a refresh. The argument forces replacement, see [Plan shape](#plan-shape-on-an-existing-deployment). |
| `azurerm_private_dns_a_record.n8n` | `private_dns_zone_id` replaces `zone_name` and `resource_group_name`. The module rebuilds the ID in the form records created by 4.x already carry: the provider's own subscription ID (from `azurerm_client_config`) when the zone ID's subscription matches it ignoring case, the zone ID's resource group segment, and the zone name lowercased. | 5.0 removed the name arguments | None after a refresh, when the zone is in the provider's subscription. |
| `azurerm_kubernetes_cluster.n8n` | `node_provisioning_profile { mode = "Manual" }` | 5.0 made the block required | None, or one in-place update if Azure never reported the profile. Never a replacement. |
| `azurerm_storage_account.n8n` | `public_network_access = "Disabled"` replaces `public_network_access_enabled = false` | Deprecated in 5.5.0, removed in 6.0 | None after a refresh. |
| `azurerm_postgresql_flexible_server.n8n` | `storage_type` added to `lifecycle.ignore_changes` | 5.4.0 added `storage_type` as a ForceNew argument defaulting to `Premium_LRS`, with no state migration, and stores it only when the API returns one | Prevents a replacement (which destroys the database) when the stored value is empty. |
| `azurerm_web_application_firewall_policy.appgw` | `file_upload_enforcement = false` pinned | 4.x sent `false` when the argument was unset. 5.x still does, but the 5.0 upgrade guide documents a `true` default the code does not implement yet. | None. A later provider release can no longer start enforcing `file_upload_limit_in_mb` on existing gateways. |

The examples apply the same changes to the resources they own, and also:

- Their subnets use a `service_endpoint { service = "Microsoft.Storage" }`
  block instead of `service_endpoints = ["Microsoft.Storage"]`, which 5.0
  removed.
- Their `azurerm` provider block lists `resource_providers_to_register`,
  because 5.0 registers no resource providers by default (see below).
- `examples/large` and `examples/customer-managed-everything` also ignore
  `storage_type` on the PostgreSQL servers they own, and
  `examples/split-ingress` pins `file_upload_enforcement` on its own WAF
  policy.

## What a caller has to change

1. **Provider constraint.** Allow 5.x in your root, for example
   `version = ">= 5.5.0, < 6.0.0"`, then run `terraform init -upgrade`.
   `-upgrade` also moves every other provider to the newest version its
   constraint allows. To move only azurerm, delete the
   `registry.terraform.io/hashicorp/azurerm` block from
   `.terraform.lock.hcl` and run `terraform init` without `-upgrade`.
2. **Resource provider registration.** azurerm 5.x registers no Azure
   resource providers by default (`resource_provider_registrations` now
   defaults to `none`; 4.x registered about 60). A subscription that already
   ran this module has every provider it needs registered. On a fresh
   subscription, either list the ones this module uses, as the examples do:

   ```hcl
   provider "azurerm" {
     resource_providers_to_register = [
       "Microsoft.Authorization",
       "Microsoft.Cache",
       "Microsoft.Compute",
       "Microsoft.ContainerService",
       "Microsoft.DBforPostgreSQL",
       "Microsoft.KeyVault",
       "Microsoft.ManagedIdentity",
       "Microsoft.Network",
       "Microsoft.Storage",
     ]
     features {}
   }
   ```

   or set `resource_provider_registrations = "legacy"` to keep the 4.x
   behavior. Registering a provider needs the
   `Microsoft.Resources/subscriptions/providers/register/action`
   permission. Without registration, the first apply fails with
   `MissingSubscriptionRegistration`.
3. **Other provider-block changes.** `skip_provider_registration` was
   removed. The `enhanced_validation` block moved into `features` and is
   now off by default, so an invalid `location` fails at apply instead of
   plan. The `ARM_PROVIDER_ENHANCED_VALIDATION` environment variable was
   removed.
4. **Your own azurerm resources.** Fix them against the
   [5.0 upgrade guide](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide).
   The ones the examples hit are listed above. Also: `azurerm_key_vault`
   now requires `rbac_authorization_enabled` (and dropped
   `enable_rbac_authorization`), `azurerm_storage_container` needs
   `storage_account_id`, and `azurerm_federated_identity_credential` needs
   `user_assigned_identity_id`. If you own an
   `azurerm_postgresql_flexible_server`, add the same
   `ignore_changes = [storage_type]` unless you set `storage_type`
   yourself and have confirmed Azure reports it.
5. **Back up state before the first 5.x apply.** State written by 5.x
   cannot be read back by 4.x (for example, the storage container's schema
   version moves from 1 to 2). Rolling back after an apply means restoring
   that backup, not only reverting the code.

## Plan shape on an existing deployment

Plan with a normal refresh. **Never review the upgrade with
`terraform plan -refresh=false`.** Several of the new arguments are not in
4.x state until a refresh reads them from Azure, so a plan without refresh
shows every private DNS VNet link (and any private DNS A record) as
`must be replaced`, and in-place updates for `public_network_access` and
the subnets' `service_endpoint`. `tests/scripts/preflight-region-check.sh`
plans with `-refresh=false` only to read region and sizing; it never
applies, and those replace actions are not meaningful there.

With a refresh, the expected plan is **no changes**, or one in-place update
of the AKS cluster. Anything that replaces or destroys a resource is not
expected: do not apply it.

| Resource | Expected | Can it plan a replacement? | What to check if it does not match |
| --- | --- | --- | --- |
| `azurerm_private_dns_zone_virtual_network_link` (3 in the module, plus example-owned links) | No changes | Yes: `private_dns_zone_id` is ForceNew and has no state migration. After a refresh the provider rebuilds it from the link's own ID, which matches the zone's `id` unless the link was imported with different resource-group casing. | Compare the planned `private_dns_zone_id` with the one in the refreshed state, character by character. |
| `azurerm_private_dns_a_record.n8n` (only with `create_private_dns_record = true`) | No changes | Yes, same mechanism. 4.x always wrote records into the provider's subscription, whatever `private_dns_zone_id` said. The module sends the provider's subscription string when the zone ID's subscription matches it ignoring case, so casing alone cannot replace a record. A zone ID naming a different subscription now targets that subscription, which replaces records 4.x wrote into the provider's subscription. | Check that `private_dns_zone_id` names the provider's subscription, and that the provider's `subscription_id` setting has not changed since the records were created. |
| `azurerm_postgresql_flexible_server` | No changes | Only without `ignore_changes = [storage_type]`, which the module and examples now carry | Run `az postgres flexible-server show -g <rg> -n <server> --query storage.type -o tsv`; `Premium_LRS` means the refreshed state holds the default. |
| `azurerm_kubernetes_cluster.n8n` | No changes, or an in-place update of `node_provisioning_profile` | No. The block is not ForceNew. | The update re-sends the managed cluster, so apply it in a quiet window. A `must be replaced` on AKS points to another cause; stop. |
| `azurerm_kubernetes_cluster_node_pool.n8n_user` | No changes | No | |
| `azurerm_storage_account.n8n` | No changes | No | |
| `azurerm_storage_container.n8n` | No changes (state upgraded silently) | No | |
| `azurerm_web_application_firewall_policy.appgw` | No changes | No | An in-place `true -> false` means Azure had enforcement on, which 4.x never sent. Applying turns it off again. |
| `azurerm_application_gateway.n8n` | No changes | No | `http2_enabled` is set explicitly, so its lost `Computed` flag has no effect. |
| Example subnets (`service_endpoint`) | No changes | No | An in-place `network_identifier` change would mean Azure now returns one for `Microsoft.Storage`. |
| Key Vault, certificates, keys, Managed Redis, private endpoints, public IP, NSG and association, public DNS zone and A records, UAMIs, federated credential, role assignments, resource groups | No changes | No | |

Two more things are normal: refresh may record new resource identity data
for some resources (5.x added Resource Identity support to several types),
which does not show as a change, and the Kubernetes and Helm resources are
unaffected by the azurerm upgrade.

## Live checklist: upgrading `examples/small` in place

The steps below assume an `examples/small` deployment applied with the
previous module version and azurerm 4.x, a populated `terraform.tfvars`, and
`az login` to the deployment's subscription. Addresses use the example's
`module "n8n"` call.

1. **Baseline on the old version.** From `examples/small`, still on the old
   code and lock file, run `terraform plan`. It must show no changes; fix
   any drift first, so the upgrade plan only shows the upgrade.
2. **Back up state:** `terraform state pull > pre-azurerm5.tfstate`.
3. **Record the values the upgrade depends on:**
   - `terraform state show 'module.n8n.azurerm_kubernetes_cluster.n8n[0]' | grep -A3 node_provisioning_profile`:
     expect `mode = "Manual"` and `default_node_pools = "Auto"`. Anything
     else, or no block, predicts the in-place AKS update.
   - `az postgres flexible-server show -g <rg> -n <prefix>-postgres --query storage.type -o tsv`
     (the server name is in the state of
     `module.n8n.azurerm_postgresql_flexible_server.n8n[0]`): expect
     `Premium_LRS`.
   - `terraform state show 'module.n8n.azurerm_web_application_firewall_policy.appgw[0]' | grep file_upload_enforcement`:
     expect `false`.
   - `az provider show -n Microsoft.ContainerService --query registrationState -o tsv`
     (and the other providers listed above): expect `Registered`.
4. **Switch to the new module version** and run `terraform init -upgrade`.
   Confirm `.terraform.lock.hcl` now selects azurerm `5.9.0` (or a later
   5.x).
5. **Plan with refresh and save it:** `terraform plan -out=azurerm5.tfplan`.
6. **Review the actions:**

   ```bash
   terraform show -json azurerm5.tfplan | jq -r '.resource_changes[]
     | select(.change.actions != ["no-op"] and .change.actions != ["read"])
     | "\(.change.actions | join(",")) \(.address)"'
   ```

   Expected output: nothing, or `update module.n8n.azurerm_kubernetes_cluster.n8n[0]`.
   Stop if any line contains `delete` (a replacement shows as
   `delete,create` or `create,delete`), and check the table above.
   In the human-readable plan, `# forces replacement` names the argument.
7. **Apply the saved plan:** `terraform apply azurerm5.tfplan`. Apply it even
   when it is empty, so the state is rewritten in the 5.x schema.
8. **Verify:** `terraform plan` shows no changes, then run
   `../../tests/scripts/smoke-test.sh`.
9. **Rollback**, if needed: before step 7, revert the code and the lock
   file and run `terraform init`; nothing in Azure or the state has changed.
   After step 7, revert the code and the lock file, run `terraform init`,
   then `terraform state push -force pre-azurerm5.tfstate`. Only do this if
   nothing else changed the deployment in between.
