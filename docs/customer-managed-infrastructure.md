# Customer-managed infrastructure

This module defaults to creating and managing every layer of the n8n stack:
AKS, Blob storage, the n8n namespace, workload Secrets, KEDA, and the
webhook-processor HPA. Platform teams that already run one or more of these
layers on shared or separately managed infrastructure can hand ownership of
each layer to the caller instead, one layer at a time.

This document describes the ownership convention shared across every layer,
the exact reference and attestation contract for each one, how to compose
`modules/controllers` directly, provider wiring for a caller-owned AKS
cluster, the AWS-only capabilities this module intentionally excludes, and
the rule against treating any data-source lookup as a security audit.

## The ownership convention

Every independently customer-manageable layer follows the same three rules:

1. **A non-nullable `create_*` or `install_*` switch defaults to `true`.**
   Module ownership is the default for every layer — a caller who sets no new
   input gets exactly the resources this module created before modularity was
   added.
2. **Setting the switch to `false` requires explicit references.** Each
   layer's `existing_*` input(s) and, where Terraform cannot verify the
   layer's operational state itself, a `*_prerequisites_confirmed`
   attestation become required only when the switch is `false`. Terraform
   fails the plan if a required reference or attestation is missing.
3. **Ownership is never inferred from a nullable reference.** A caller could
   pass an apply-time-unknown resource attribute into an `existing_*` input
   (for example a cluster name from a resource created in the same apply),
   which would make a derived `count` unknown and break the plan. Every gate
   is therefore a literal boolean, never `existing_x != null`.

A non-failing `check` block backs every layer in the opposite direction: if a
caller supplies an `existing_*` reference or a layer-specific tuning input
while the corresponding switch stays at its default `true`, Terraform emits a
warning identifying the ignored input and the switch that would select it.
This catches a caller who flipped on a reference but forgot the matching
switch, without blocking their plan.

## Layer by layer

### AKS cluster (`create_aks`)

| Input | Required when `create_aks = false` |
|---|---|
| `existing_aks_cluster_name` | yes |
| `existing_aks_resource_group_name` | yes |
| `existing_aks_cluster_prerequisites_confirmed` | yes (must be `true`) |

Setting `existing_aks_cluster_prerequisites_confirmed = true` attests that:

- The cluster has the **OIDC issuer and workload identity enabled** — the
  module's n8n workload identity federation depends on this.
- **Schedulable capacity and node autoscaling are managed by the caller.**
  The module's advisory AKS capacity diagnostic only runs on the
  module-managed path; it has nothing to model on an existing cluster.
- **Supported Kubernetes API and provider access are available** to the
  identity running `terraform apply`.
- **The applying principal can create required federated credentials and
  Kubernetes objects** — the n8n workload identity's federated credential,
  the n8n namespace (unless that too is caller-managed), Secrets, and the
  Helm release.
- **The selected namespace, service accounts, releases, and cluster-scoped
  KEDA objects do not conflict** with anything already running on the shared
  cluster.

Terraform cannot verify any of these conditions itself. The module reads the
existing cluster's OIDC issuer and connection coordinates through
`data.azurerm_kubernetes_cluster.existing` — this is a targeted identity
lookup needed for workload federation and kubeconfig outputs, not a security
audit of the cluster (see [Data sources are not a security
audit](#data-sources-are-not-a-security-audit) below).

`create_aks = false` **requires `create_ingress = false`.** This module
cannot manage the AGIC addon, or the identities and role assignments AGIC
needs, on a cluster it does not own. Route the exported `n8n_service_name` /
`n8n_webhook_service_name` / `n8n_webhook_path_prefixes` /
`n8n_test_webhook_path_prefixes` outputs through a caller-owned ingress
instead. Declare the test-mode prefixes (main Service) before the production
webhook prefixes (webhook processors): Application Gateway matches string
prefixes in declared order, so `/webhook*` would otherwise capture
`/webhook-test`. Also configure session affinity to the main Service
(`appgw.ingress.kubernetes.io/cookie-based-affinity` on AGIC), match the
module's 300 s request timeout and 30 s connection draining (AGIC defaults to
30 s and no draining), and set `n8n_proxy_hops` to the number of proxies on
the client's path that add an `X-Forwarded-For` entry. See
[`docs/ingress-options.md`](./ingress-options.md) for the full routing
contract, the settings to review, and the alternatives to Application
Gateway v2 with AGIC. See
[`examples/customer-managed-cluster`](../examples/customer-managed-cluster/)
for a caller-installed AGIC on the same cluster used as the AKS stand-in.

The module still creates the n8n user-assigned workload identity and its
federated credential even on an existing cluster — see [The n8n workload
identity stays module-owned](#the-n8n-workload-identity-stays-module-owned)
below.

### Blob storage (`create_blob_storage`)

| Input | Required when `create_blob_storage = false` |
|---|---|
| `existing_blob_storage_account_name` | yes |
| `existing_blob_container_name` | yes |
| `existing_blob_container_id` | yes |
| `existing_blob_endpoint` | yes |
| `existing_blob_prerequisites_confirmed` | yes (must be `true`) |

Setting `existing_blob_prerequisites_confirmed = true` attests that the
account and container have **private networking and DNS resolution,
encryption at rest, and retention** configured outside this module, and that
they are **compatible with the selected credential mode**
(`azure_blob_connection_string` / `azure_blob_account_key` /
`azure_blob_endpoint` override, or automatic workload-identity
authentication).

`existing_blob_container_id` is a separate input from the account and
container names because the workload role-assignment scope must be known at
plan time without a data-source lookup, and because the container may live in
a different resource group or subscription than `var.resource_group_name` —
the applying identity needs role-assignment permission at that scope.

The module never inspects a customer-managed storage account or container
through a data source. See [Data sources are not a security
audit](#data-sources-are-not-a-security-audit).

A caller-managed Blob container is independent of Enterprise storage
entitlements: `feat:binaryDataAz` / `feat:executionDataAz` still gate the
Azure binary/execution-data modes regardless of who owns the container. A
Business license without those entitlements should keep
`n8n_binary_data_storage_mode` / `n8n_execution_data_storage_mode` on
`database` even when `create_blob_storage = false` — see
[`docs/data-storage.md`](./data-storage.md#new-deployment-without-azure-storage-entitlements-business-license).

### Caller-supplied private DNS zones

On the managed paths, the module creates its own private DNS zone and VNet
link for PostgreSQL, Redis, and Blob storage. Many enterprise Azure landing
zones instead keep these zones in a central connectivity subscription,
often under an Azure Policy `DeployIfNotExists` assignment. A VNet cannot be
linked to two private DNS zones with the same name, so a second zone in the
n8n resource group either fails to link or resolves differently than the
central one. Each service can therefore use a caller-owned zone instead:

| Service | Switch | Zone ID input | Accepted zone names |
|---|---|---|---|
| PostgreSQL Flexible Server (`create_database = true`) | `create_postgres_private_dns_zone` | `postgres_private_dns_zone_id` | Any name ending in `.postgres.database.azure.com` |
| Azure Managed Redis private endpoint (`create_redis = true`) | `create_redis_private_dns_zone` | `redis_private_dns_zone_id` | `privatelink.redis.azure.net` |
| Blob storage private endpoint (`create_blob_storage = true`) | `create_blob_private_dns_zone` | `blob_private_dns_zone_id` | `privatelink.blob.core.windows.net` |

The inputs follow [the ownership convention](#the-ownership-convention):

- Each switch defaults to `true`, which keeps the module-owned zone.
- Setting a switch to `false` requires the matching zone ID. The module then
  creates neither that zone nor its VNet link, and attaches the server or
  private endpoint to the supplied zone. The three services are independent.
- Because ownership follows the switch, the zone ID may be computed, for
  example from a zone created in the same configuration as the module call.
- A zone ID supplied while its switch is `true`, or either input changed
  while the matching `create_database`, `create_redis`, or
  `create_blob_storage` is `false`, has no effect. A `check` block warns
  about it without failing the plan, so you can stage the inputs before a
  cutover.
- Zone names are compared case-insensitively.

For PostgreSQL, Azure accepts any zone whose name ends in
`.postgres.database.azure.com`, for example
`privatelink.postgres.database.azure.com` or
`n8n.private.postgres.database.azure.com`. The zone name must not be the
server's own FQDN, `<friendly_name_prefix>-postgres.postgres.database.azure.com`.
Azure rejects that during provisioning, so a precondition on the server
fails the plan instead, or the apply if the zone ID is only known then. See
[Azure Database for PostgreSQL: use a private DNS zone](https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private#use-a-private-dns-zone).

#### What you own when you supply a zone

- **Name resolution from the n8n VNet.** Link the zone to `var.vnet_id`, or
  resolve it through your central DNS design. If the VNet uses custom DNS
  servers, they must forward these names to Azure DNS (`168.63.129.16`),
  for example through an Azure DNS Private Resolver in the hub. The module
  never creates a VNet link into a zone it does not own.
- **Link ordering.** Azure does not check for a VNet link when it creates
  the Flexible Server, and the private endpoints register their records in
  the zone either way. The n8n pods, however, can only resolve the hostnames
  once the link exists. If the link is created in the same configuration as
  the module call, create it in an earlier apply, or add it to the module
  block's `depends_on`. While the link has pending changes, a `depends_on`
  on the module block defers the module's data source reads to apply time.
  That weakens the plan-time protection of `pg_storage_drift_guard_enabled`
  (see the comment above `data.azurerm_postgresql_flexible_server.current`
  in `database.tf`), and with `create_ingress = true` it replaces the two
  AGIC `Reader` role assignments, whose scope comes from
  `data.azurerm_resource_group.n8n`. A live test that created the zones and
  links in the same apply without `depends_on` resolved correctly once the
  apply finished, so prefer an earlier apply over `depends_on`.
- **Permissions.** The identity running Terraform must be allowed to write
  records into the zone. Microsoft's
  [private endpoint permission troubleshooting guide](https://learn.microsoft.com/troubleshoot/azure/private-link/troubleshoot-private-endpoint-permission-denied)
  names **Private DNS Zone Contributor**, scoped to the zone or to its
  resource group, as the least-privilege built-in role. If you use a custom
  role, check that guide for the actions it needs. A new role assignment can
  take several minutes to take effect.
- **PostgreSQL zone in another subscription.** That subscription must also
  have the `Microsoft.DBforPostgreSQL` resource provider registered.
  Otherwise the server deployment does not complete.
- **Locks.** A `ReadOnly` or `CanNotDelete` lock on the PostgreSQL zone or
  its record sets can stop the server from updating its DNS records,
  including during a high-availability failover. Microsoft advises against
  these locks when high availability is enabled.

#### Azure Policy `DeployIfNotExists` remediation

Landing-zone policies of this kind usually target private endpoints, so
they affect the Redis and Blob endpoints, not the PostgreSQL Flexible
Server, which uses a delegated subnet instead of a private endpoint.

The module manages each endpoint's `private_dns_zone_group` block, including
its name and zone ID. A private endpoint holds a single zone group, and
Terraform reads it back on every refresh. If a policy remediation changes
the zone group, the next plan shows a diff and the next apply deletes and
recreates the group with the module's settings, so the policy and Terraform
can keep overwriting each other. To avoid that, do one of the following:

- Check the policy's existence condition and deployment against the zone
  group the module creates (the zone ID you pass, and the group name in
  `redis.tf` or `storage.tf`), so that a remediation finds nothing to
  change. Pointing at the same zone is necessary but may not be enough, for
  example if the policy also expects a specific group name.
- Exempt the n8n private endpoints from the policy assignment.

Do not add `ignore_changes` for the zone group as a workaround. It would
hide a real misconfiguration as well.

#### Adopting a caller-supplied zone on an existing deployment

Plan this change in its own apply, save and review the plan before
applying, and back up the n8n encryption key and the database first. The
behavior below follows from the `hashicorp/azurerm` v4.81.0 source,
Microsoft's documentation, and one live test of `examples/small` that moved
all three services to caller-owned zones with the same names and back
again. Timings from that test are a guide, not a guarantee. There are two
cases.

**Moving to a different zone, such as a central landing-zone zone.** Set the
switch to `false` and pass the new zone ID. The plan destroys the module's
own zone and VNet link, and changes the service's DNS attachment:

- For PostgreSQL, the server's `private_dns_zone_id` is updated in place;
  the server is not replaced.
- For Redis and Blob, the private endpoint itself is kept, but azurerm
  deletes its DNS zone group and creates a new one for the new zone. The
  endpoint's records leave the old zone before they appear in the new one.

Expect the following:

- **Expect a name-resolution outage of a few minutes per service.** In the
  live test it lasted about 3 minutes per service when moving to the
  caller-owned zones, and about 4 minutes when moving back. It starts when
  Terraform begins deleting the module's VNet link, and ends only once the
  server or private endpoint has written its record into the new zone.
  Terraform switches the server and the endpoints' zone groups after it has
  destroyed the old zone, so the outage includes the link deletion (more
  than 2 minutes in the test). Schedule a maintenance window.
- **During the outage, Redis and Blob first resolve to their public IP
  addresses**, then to nothing. Public network access is disabled on both,
  so n8n sees connection failures, not only lookup errors. PostgreSQL does
  not resolve at all. In the test, n8n logged database lookup and ping
  failures, but no pod restarted and the editor stayed reachable.
- If the n8n VNet resolves the zone through a direct VNet link, note that a
  VNet cannot be linked to two private DNS zones with the same name
  ([Microsoft Q&A](https://learn.microsoft.com/answers/questions/2283009/a-virtual-network-cannot-be-linked-to-multiple-zon)).
  Azure rejects the new link while the old same-named link is still
  active. If both changes are in one apply, Terraform does not order the
  old link's deletion before the new link's creation; they are independent
  resources. In the live test the deletion started first and Azure accepted
  the new link while the old one was still being deleted, in both
  directions, but that order is not guaranteed. If the new link fails with
  the conflict, run `terraform apply` again once the old link is gone; the
  outage lasts until that second apply finishes. To avoid the race
  entirely, remove the old link in one apply and create the new one in the
  next, which keeps the service unresolvable for the time between the two
  applies. A new PostgreSQL zone with a different name, or resolution
  through a central DNS resolver, avoids the conflict altogether.
- After the change, check from an n8n pod that the service's hostname
  resolves to its private IP address and that n8n can connect, not only that
  the new zone contains the record.
- Azure currently does not allow changing the private DNS zone of a
  PostgreSQL Flexible Server that has high availability enabled. With
  `pg_enable_high_availability = true`, the apply fails. Either keep
  `create_postgres_private_dns_zone = true` for that server, or use three
  separate, completed applies: turn high availability off, change the
  zone, then turn high availability back on. Turning it back on creates a
  new standby.
- Rolling back to `create_*_private_dns_zone = true` creates a new
  module-owned zone and link, with the same kind of outage and the same
  link conflict in reverse: the module's new link fails while the caller's
  same-named link is still active. Remove the caller's link in the same
  apply and re-run the apply if the module's link loses the race, or remove
  it in an earlier apply, as described above.

**Handing the module's existing zone over to central management.** If you
pass the ID of the zone the module already created, the plan destroys that
zone and its link, because the module no longer owns them. Move them out of
the module's state first:

1. Stop all other Terraform runs against this state and, if it is a
   different one, the state of the configuration that will own the zone.
2. Back up both states, for example with `terraform state pull > backup.tfstate`.
3. Add `azurerm_private_dns_zone` and
   `azurerm_private_dns_zone_virtual_network_link` resources to the
   configuration that will own the zone, with arguments matching the
   existing resources (same name, resource group, VNet, and tags), so that
   its plan shows no changes after the move.
4. Move the two resources out of this module's state:
   - If the owning configuration uses the same state, move them to its
     addresses, adjusting `module.n8n` to your module call name:

     ```bash
     terraform state mv 'module.n8n.azurerm_private_dns_zone.postgres[0]' \
       'azurerm_private_dns_zone.postgres'
     terraform state mv 'module.n8n.azurerm_private_dns_zone_virtual_network_link.postgres[0]' \
       'azurerm_private_dns_zone_virtual_network_link.postgres'
     ```

   - If it uses a different state, run `terraform state rm` for both
     addresses here, then import both resources into the other
     configuration, for example with `import` blocks so the import shows up
     in a reviewed plan.
5. Set the switch to `false` and pass the same zone ID. Plan both
   configurations. Neither plan may delete or replace the zone or the VNet
   link, and the server's or endpoint's zone ID must stay the same.

Replace `postgres` with `redis` or `blob` for the other services. To roll
back, restore the state backups, or reverse the moves (`terraform state mv`
back to the module addresses, or `state rm` in the other configuration and
re-import at the module addresses) while runs are still stopped. The zone
stays in `var.resource_group_name`. Moving it to another resource group or
subscription is an Azure operation outside this module.

### The n8n workload identity stays module-owned

Even when `create_aks = false` and/or `create_blob_storage = false`, the
module always creates the n8n user-assigned managed identity and its
federated credential. This gives the Helm chart a stable identity to
annotate the n8n ServiceAccount with and avoids requiring every caller to
duplicate the federation subject contract.

For **module-managed Blob** (`create_blob_storage = true`), the workload
identity keeps its existing container-scoped `Storage Blob Data Contributor`
role assignment. For **customer-managed Blob with automatic authentication**
selected, the module grants that same role, scoped to
`existing_blob_container_id`. For the **connection-string or account-key
compatibility credential modes**, the module omits the role assignment
entirely — n8n does not use workload identity for Blob access under those
modes.

A fully customer-managed n8n workload identity (the caller supplies their
own identity and federation instead of the module creating one) is not
supported in this release.

### Kubernetes namespace (`create_namespace`)

| Input | Required when `create_namespace = false` |
|---|---|
| `n8n_namespace` | already required — used as the caller-provided existing namespace name |

`create_namespace = false` skips only the `kubernetes_namespace.n8n`
resource. Every other namespaced resource and output routes through an
effective-namespace local rather than the managed resource's address, and
the module never issues a delete against a namespace it did not create.

### Webhook-processor HPA (`n8n_webhook_hpa_enabled`)

| Input | Required when `n8n_webhook_hpa_enabled = false` |
|---|---|
| none | — |

`n8n_webhook_hpa_enabled = false` skips only the
`kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook` resource. The Helm
release still sets the webhook-processor replica count to
`n8n_webhook_hpa_min_replicas` so a caller who takes over scaling starts from
a stable, non-zero deployment, and every webhook service-discovery output
remains available regardless of who owns the HPA.

### KEDA (`install_keda`)

| Input | Required when `install_keda = false` |
|---|---|
| `existing_keda_prerequisites_confirmed` | yes (must be `true`) |

`install_keda = false` skips only the controllers submodule's own namespace
and Helm release. It does **not** skip the chart-rendered worker
`ScaledObject` or the root's `kubectl_manifest.keda_trigger_authentication` —
those are n8n-instance configuration, not cluster-controller installation,
and still need somewhere to run.

Setting `existing_keda_prerequisites_confirmed = true` attests that KEDA and
its CRDs (including `TriggerAuthentication`) are **already installed and
ready** in `keda_namespace`, either through a direct call to
`modules/controllers` elsewhere in the same or a different root, or through
another process entirely. Terraform cannot verify CRD readiness at plan
time — this is a plan-time attestation, not a runtime check.

`keda_chart_repository` overrides the KEDA chart's Helm repository URL when
`install_keda = true`, for clusters that mirror the `kedacore` charts into a
private ChartMuseum or ACR Helm registry instead of reaching
`https://kedacore.github.io/charts` directly.

### Kubernetes Secret references

Five inputs support a caller-managed Kubernetes Secret reference. The four
credential references replace a Terraform-managed value and use
`object({ name = string, key = string })`:

| Data | Secret-ref input | Conflicts with |
|---|---|---|
| n8n license key | `n8n_license_key_secret_ref` | `n8n_license_key` |
| n8n encryption key | `n8n_encryption_key_secret_ref` | `n8n_encryption_key` |
| PostgreSQL password (external database, or the managed server with `postgres_password_write_only = true`) | `postgres_password_secret_ref` | `postgres_external_password` |
| External Redis password | `redis_password_secret_ref` | `redis_external_password` |
| n8n credential overwrite JSON | `n8n_credentials_overwrite_secret_ref` | `CREDENTIALS_OVERWRITE_DATA` or `CREDENTIALS_OVERWRITE_DATA_FILE` in `n8n_extra_env`; the reserved volume name `credentials-overwrite`; the reserved mount path `/etc/n8n/credentials-overwrite` |

`n8n_credentials_overwrite_secret_ref` uses
`object({ name = string, key = optional(string, "credentials-overwrite.json") })`.
The module projects only the selected key into a read-only volume on every n8n
application pod and sets `CREDENTIALS_OVERWRITE_DATA_FILE` to the mounted file.
n8n reads the file at startup. Restart the `n8n-main`, `n8n-worker`, and
`n8n-webhook-processor` deployments after the Secret payload changes.

The module never reads a caller-managed Secret's value into Terraform. It
renders only the Secret's **name and key** into the Helm chart's values (and,
for the Redis password, into the KEDA `TriggerAuthentication` as well) —
Terraform state never contains the underlying credential.

When the module creates the n8n namespace, its `n8n_namespace` output depends
on the namespace resource. A caller-managed Secret that uses this output as
its namespace therefore waits for the namespace. Passing that Secret's name
into one of the references above then makes the n8n Helm release wait for the
Secret. This ordering supports a cold deployment in one `terraform apply`.

`n8n_encryption_key_secret_ref` has one shape difference worth calling out:
the chart's `secretRefs.existingSecret` contract expects **one Secret with
four keys** — `N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, and
`N8N_PROTOCOL` — not just the encryption key by itself, and the chart
hardcodes the key name `N8N_ENCRYPTION_KEY` (the `key` field on the object
must be exactly that string). `n8n_license_key_secret_ref` has no such
restriction; its `key` field can be any name the caller's Secret uses.

Because Terraform never reads the encryption-key Secret's value, the
`n8n_encryption_key` output is explicitly `null` whenever
`n8n_encryption_key_secret_ref` is set. Back up that key outside Terraform —
see [Post-deployment setup](./post-deployment.md#capture-the-n8n-encryption-key).

The **PostgreSQL password reference applies only to the external database
path** (`create_database = false`), with one exception: setting
`postgres_password_write_only = true` on the managed path
(`create_database = true`) also requires and honors
`postgres_password_secret_ref`, because the module cannot copy a write-only
value into a Secret it manages itself. Outside that opt-in, the
module-managed Flexible Server always generates and manages its own
password, and there is no `postgres_password_secret_ref` equivalent for it.
The same is true for Redis: `redis_password_secret_ref` applies only to
`create_redis = false`, because the module-managed Azure Managed Redis
instance always uses its own generated access key, and no write-only path
exists for it — see "Secrets that remain in Terraform state" below.

**The task-runner authentication token remains module-generated in every
mode.** It has no persistence and authenticates only an in-cluster process to
another in-cluster process, so caller ownership of it does not reduce
Terraform's exposure the way it does for the license key, encryption key, or
database/queue credentials.

## Secrets that remain in Terraform state

Every credential this module generates or reads for a **module-managed**
resource is, by default, stored in Terraform state: state is where Terraform
keeps every attribute of every resource it manages, including ones marked
`sensitive`. This is separate from the Kubernetes Secret question above —
`sensitive` and a Secret-ref both control what a caller *sees* in CLI output
or hands to a workload; neither removes the value from the state file
itself. Encrypt remote state and restrict who can read it (`terraform state
pull`, the backend's own access controls) regardless of which options below
you use. [`examples/customer-managed-everything`](../examples/customer-managed-everything/)
demonstrates the combination that keeps the most credentials out of this
module's state, by pointing every data-service input at caller-managed
resources instead.

On the default, fully module-managed path, the following land in state:

| Credential | Where it lands | Opt out with |
|---|---|---|
| PostgreSQL administrator password | `random_password.postgres_admin`'s `result`, `azurerm_postgresql_flexible_server.n8n`'s `administrator_password`, `kubernetes_secret.n8n_db`, the `postgres_admin_password` output | `postgres_password_write_only = true` (below), or `create_database = false` with `postgres_password_secret_ref` |
| Redis access key | `azurerm_managed_redis.n8n`'s `default_database[0].primary_access_key`, `kubernetes_secret.n8n_redis`, the `redis_primary_access_key` output | `create_redis = false` with `redis_password_secret_ref` pointing at a Secret you manage; `redis_external_password` still lands in `kubernetes_secret.n8n_redis` and does not opt out of state. No equivalent exists for the managed path (see below) |
| n8n encryption key | `random_password.n8n_encryption_key`'s `result`, `kubernetes_secret.n8n_encryption_key`, the `n8n_encryption_key` output | `n8n_encryption_key_secret_ref` (module never reads the Secret's value) |
| Task-runner authentication token | `random_password.n8n_task_runners_token`'s `result`, `kubernetes_secret.n8n_task_runners` | none — this token is always module-generated (see above) |
| n8n license key | `var.n8n_license_key`, `kubernetes_secret.n8n_license` | `n8n_license_key_secret_ref` (module never reads the Secret's value) |

### PostgreSQL write-only password (`postgres_password_write_only`)

Setting `postgres_password_write_only = true` (with `create_database = true`)
writes the administrator password through
`azurerm_postgresql_flexible_server.n8n`'s write-only
`administrator_password_wo` argument instead of generating one with
`random_password.postgres_admin`. This needs Terraform >= 1.11 and azurerm
>= 4.39.0, both already required by this module's `versions.tf`. Feed the
actual value in through `postgres_admin_password_wo`, an `ephemeral` module
variable, so this module never writes it to a plan or state file. Increment
`postgres_admin_password_wo_version` whenever you rotate it: Terraform only
re-applies a write-only value when its version number changes.

The value must meet the Flexible Server password rules: 8 to 128
characters, from at least three of uppercase letters, lowercase letters,
digits, and non-alphanumeric characters. The module checks this at plan
time. Azure also rejects a password that contains the login name
(`pg_admin_username`); the module does not check that.

Because the value never touches state, the module also cannot copy it into
a Kubernetes Secret the way it does on the default path.
`postgres_password_write_only = true` therefore also requires
`postgres_password_secret_ref`. You populate that Secret yourself, outside
Terraform, with the same password you pass to `postgres_admin_password_wo`.
For example, sync an Azure Key Vault secret into the cluster with the Key
Vault CSI driver or an External Secrets Operator `ExternalSecret`. The
Secret must not be named `n8n-db-secret`: that is the module-managed Secret,
and the module rejects the name on this path because the same apply
destroys it. The module never reads your Secret's value, so nothing checks
that the two stay in sync. A mismatch surfaces as a PostgreSQL
authentication failure when a pod opens a new connection, not as a
Terraform error. The `postgres_admin_password` output is `null` on this
path, because the module never has the value to expose. Terraform does not
store null outputs, so a root output that re-exports it (such as
`postgres_password` in the examples) reports "Output not found" from
`terraform output` instead of printing `null`.

While `postgres_password_write_only = true`, **every** plan and apply needs
`postgres_admin_password_wo`, not only the ones that change the password.
Without it, the plan fails with `Invalid value for variable`. Supply the
current value each time, and change it only together with a
`postgres_admin_password_wo_version` bump. Terraform does not compare a
write-only value with the previous one, so a different value without a
version bump plans no change.

#### Keeping the password out of the calling root too

`postgres_admin_password_wo` keeps the value out of **this module's** plan
and state. It stays out of the **calling root's** plan and state only if
that root passes an ephemeral value too:

- Use an `ephemeral "azurerm_key_vault_secret"` block, or an ephemeral input
  variable (`ephemeral = true`), in the calling root.
- A non-ephemeral root input variable is saved in the caller's plan file.
- A `data "azurerm_key_vault_secret"` read, or a Kubernetes Secret the
  calling root manages with Terraform, stores the value in that root's
  state.

Read the ephemeral value from the same Key Vault secret your Kubernetes
Secret syncs from. A shared source does not make the sync instant: confirm
that the intended version reached the Kubernetes Secret before you restart
n8n.

#### Switching an existing deployment to the write-only password

Setting `postgres_password_write_only = true` from the first apply of a new
deployment needs no special steps. On an existing deployment, the apply
that turns it on does three things at once:

- `azurerm_postgresql_flexible_server.n8n` moves from
  `administrator_password` to `administrator_password_wo`. azurerm sends
  the write-only value as an in-place password update, not a replacement.
- `random_password.postgres_admin[0]` and `kubernetes_secret.n8n_db[0]`
  are destroyed, before the Helm upgrade runs. After this apply, Terraform
  no longer knows the old password.
- The chart's `database.passwordSecret` value changes from `n8n-db-secret`
  to your Secret. This is a Helm values change, so `helm_release.n8n` rolls
  the `n8n-main`, `n8n-worker`, `n8n-webhook-processor`, and any
  `n8n_worker_pools` Deployments during the same apply.

If you pass a **new** password in that apply, the server credential changes
while pods that still use `n8n-db-secret` are running, and a failed Helm
upgrade cannot undo the change on the server. To avoid that, switch over
with the server's **current** password first, so the credential does not
change during the switch, and rotate in a separate apply:

1. While `postgres_password_write_only` is still `false`, read the current
   password from the module's `postgres_admin_password` output. The output
   name in your root depends on how your root re-exports it; the examples
   in this repository export it as `postgres_password`
   (`terraform output -raw postgres_password`). Do not run this where the
   terminal is recorded or logged.
2. Store that same password in your own source (for example the Key Vault
   secret), and create a Kubernetes Secret holding it in the n8n namespace
   (`n8n_namespace`, default `n8n`). Use any name except `n8n-db-secret`.
   Confirm the Secret contains the value before you continue. Keep this
   source version unchanged until the switch is complete.
3. Set `postgres_password_write_only = true`, `postgres_admin_password_wo`
   to that same current password (from your ephemeral source), and
   `postgres_password_secret_ref` to the new Secret. Save a plan
   (`terraform plan -out=tfplan`), review it (`terraform show tfplan`), and
   get it approved before you apply. Expect
   `random_password.postgres_admin[0]` and `kubernetes_secret.n8n_db[0]` to
   be destroyed, an in-place update on
   `azurerm_postgresql_flexible_server.n8n`, an in-place update on
   `helm_release.n8n`, and no replacement. Then apply that plan
   (`terraform apply tfplan`). Ephemeral values are not stored in a saved
   plan file, so the apply reads `postgres_admin_password_wo` again; make
   sure it resolves to the same value. Protect and then delete the plan
   file: it can contain the old password from state. The pods roll onto a Secret that holds the password the server
   already accepts.
4. Confirm that n8n reconnects to PostgreSQL before you continue.
5. The old password is still readable in earlier state versions, saved
   plans, and backups of either. Rotate it once on the new path, as
   described in the next section.

If the Helm upgrade in step 3 fails, `atomic = true` rolls the release back
to the previous pod template, which references `n8n-db-secret`. That Secret
was already destroyed, so new and restarted pods fail with
`CreateContainerConfigError`. The server still accepts the current
password, so recover by recreating `n8n-db-secret` from your Secret, then
fixing the cause of the failure and running a freshly reviewed plan and
apply again:

```bash
kubectl -n <namespace> get secret <secret-name> -o json \
  | jq --arg key '<key>' \
      '{apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: "n8n-db-secret", namespace: .metadata.namespace},
        data: {password: .data[$key]}}' \
  | kubectl apply -f -
```

Terraform does not manage this recreated Secret. Delete it after the apply
succeeds and n8n has reconnected.

The module cannot detect "existing server, switching to write-only" at plan
time, because that depends on what is already running. Follow these steps
by hand, in a maintenance window.

#### Rotating the password

Rotating changes no Helm values: the chart still points at the same Secret
name and key. n8n reads the password from an environment variable when a
pod starts, so neither the Secret update nor the apply restarts n8n. Until
the pods restart, every new PostgreSQL connection they open uses the old
password and fails.

1. Pass the new value as `postgres_admin_password_wo`, increment
   `postgres_admin_password_wo_version`, and save a plan
   (`terraform plan -out=tfplan`). Review it (`terraform show tfplan`) and
   get it approved: expect an in-place update on
   `azurerm_postgresql_flexible_server.n8n` only. If your Kubernetes Secret
   syncs from the same source that feeds `postgres_admin_password_wo`, read
   the new value for this plan from a separate, staged secret or version,
   so the live sync source does not change before step 2.
2. Put the new password in your source and in the Kubernetes Secret
   referenced by `postgres_password_secret_ref`. Confirm the Secret holds
   the new value.
3. Apply the reviewed plan: `terraform apply tfplan`. Supply the same new
   value for `postgres_admin_password_wo`, because ephemeral values are not
   stored in the plan file.
4. Restart every n8n Deployment so the pods read the new value:

   ```bash
   kubectl -n <namespace> rollout restart deployment \
     -l app.kubernetes.io/instance=n8n
   ```

   The label selects `n8n-main`, `n8n-worker`, `n8n-webhook-processor`, and
   any `n8n_worker_pools` Deployments.
5. Confirm that n8n reconnects.

Run steps 2 to 4 back to back. A pod that restarts between steps 2 and 3
for any other reason (a node replacement, an out-of-memory kill) reads the
new password while the server still has the old one, and cannot connect.

If n8n does not reconnect, first check that the cause is a password
mismatch: the n8n pod logs show a PostgreSQL authentication failure for
`pg_admin_username`. Then set the server credential to the value in the
Secret and restart the Deployments again. The commands below read the
password from the Secret into a request file that only you can read, so it
never appears in shell history or in process arguments. They stop before
calling Azure if the Secret or its key is missing or empty, and remove the
request file on every exit path:

```bash
(
  set +x
  set -euo pipefail
  umask 077
  REQ=$(mktemp)
  trap 'rm -f "$REQ"' EXIT
  kubectl -n <namespace> get secret <secret-name> -o json \
    | jq -e --arg key '<key>' '
        (.data[$key] // "" | @base64d) as $pw
        | if ($pw | length) == 0 then error("Secret key missing or empty")
          else {properties: {administratorLoginPassword: $pw}} end' > "$REQ"
  az rest --method patch \
    --url "<postgres_server_id>?api-version=2024-08-01" \
    --body "@$REQ" >/dev/null
)
```

`<postgres_server_id>` is the module's `postgres_server_id` output. After
the reset, make sure the value your root passes as
`postgres_admin_password_wo` matches the Secret again, so the next
rotation starts from a consistent state.

#### Switching back to the generated password

Setting `postgres_password_write_only` back to `false` is a password
rotation, not a no-op. The validations require you to remove
`postgres_admin_password_wo` and `postgres_password_secret_ref` in the same
change. The apply then:

- Creates a new `random_password.postgres_admin[0]` and sends it to the
  server through `administrator_password`.
- Recreates `kubernetes_secret.n8n_db` (`n8n-db-secret`) with that
  password.
- Changes `database.passwordSecret` back to `n8n-db-secret`, which rolls
  the n8n Deployments during the same apply.
- Stores the password in plain text in Terraform state again.

The credential changes on the server before the pods roll. Save, review,
and apply a plan file as in the switch-over steps, do it in a maintenance
window, and confirm n8n reconnects. Keep your own
Secret and its source version until then.

If the Helm upgrade fails, `atomic = true` rolls the release back to pods
that read your Secret, which still holds the previous password, while the
server already has the generated one. `n8n-db-secret` already holds the
generated password, so the fastest recovery is to fix the cause of the
failure and run a freshly reviewed plan and apply again. Restoring an earlier Terraform state or
rolling Helm back does not restore the previous database password. After
the switch succeeds, you can delete your own Secret.

### Redis access key (no write-only path)

Azure Managed Redis's `primary_access_key` is a **computed** attribute this
module reads back from `azurerm_managed_redis.n8n`, not a value the module
chooses or generates — there is no argument on that resource to redirect
through a write-only path the way `administrator_password_wo` works for
PostgreSQL. The access key remains in Terraform state on the managed path
(`create_redis = true`) regardless of any other option in this document.

The only way to remove it is to stop authenticating with an access key at
all. Microsoft Entra ID authentication for Azure Managed Redis would do
that, but n8n's Redis client does not yet support Entra ID authentication
for its queue/cache connection, so this module does not expose it. Track
n8n's Redis client support before revisiting this. Until then, treat
encrypted, access-restricted remote state as the mitigation for this
credential, the same as for the n8n encryption key and task-runner token
above.

## Direct controller composition

`modules/controllers` installs KEDA and is directly callable outside the
root module — see [its README](../modules/controllers/README.md) for the
full input/output contract, the provider-wiring requirement, and the
ownership-change finalizer hazard.

The root module calls this submodule unconditionally; `install_keda`
controls only whether the submodule's own resources exist, so the root's
call shape is identical on both paths. A caller who installs KEDA separately
— for example, sharing one KEDA installation across several n8n root module
calls — invokes `modules/controllers` directly and sets `install_keda =
false` on every n8n call that shares it. Every resource that depends on
KEDA's CRDs (a `TriggerAuthentication`, a `ScaledObject`, or this module's own
`kubectl_manifest.keda_trigger_authentication`) needs an explicit `depends_on
= [module.controllers]` — Terraform cannot infer that ordering from data flow
alone, because CRD-backed resources don't reference any output the
submodule produces. See [`examples/customer-managed-everything`](../examples/customer-managed-everything/)
for a direct call ordered ahead of the root module.

## Provider wiring for an existing AKS cluster

When `create_aks = true` (the default), the caller configures the
`kubernetes` / `helm` / `kubectl` providers against **this module's own**
`aks_kube_config` output, because the module itself creates the cluster those
providers need to reach.

When `create_aks = false`, wire those providers against the **caller's own**
resource or data source for the existing cluster — never against
`module.n8n.aks_kube_config` in that mode. Because the cluster already exists
outside this module's apply, there is no ordering dependency to preserve, and
routing through the module's output would add a needless indirection. See
[`examples/customer-managed-cluster/providers.tf`](../examples/customer-managed-cluster/providers.tf)
for the concrete wiring against a caller-owned `azurerm_kubernetes_cluster`
resource.

## Data sources are not a security audit

The only customer-managed Azure resource this module reads through a data
source is the existing AKS cluster
(`data.azurerm_kubernetes_cluster.existing`), and only to obtain identity
coordinates (OIDC issuer, kubeconfig) the module's own workload federation
and outputs need. This module does not, and will not, add a data source that
inspects a customer-managed resource's configuration in order to validate or
enforce that resource's security posture — for example, it will never assert
that a caller-supplied Blob container has public access disabled by reading
its properties back through Terraform.

Every `*_prerequisites_confirmed` attestation exists because Terraform
cannot verify the underlying condition, not because the module chose not to
check. Treat each attestation exactly as it is written; setting it to `true`
without meeting its stated conditions produces a plan that "succeeds" while
leaving the module's actual runtime assumptions unmet.

## Excluded AWS-only capabilities

This module's customer-managed surface intentionally does not mirror every
input `terraform-aws-n8n` exposes. The following AWS-shaped capabilities
have no secure Azure-native equivalent in this architecture and are not
planned for a future parity pass without one:

- **Keyless n8n Azure Key Vault external secrets.** n8n's own Azure Key
  Vault external-secrets integration is caller-configured and uses a client
  secret, not this module's Blob workload identity or App Gateway identity —
  see [`docs/azure-key-vault-external-secrets.md`](./azure-key-vault-external-secrets.md).
  There is no keyless (workload-identity-based) path in the pinned n8n
  application version.
- **IAM permission boundaries.** Azure's role-based access control model has
  no direct equivalent to an AWS IAM permission boundary, and this module
  does not attempt to approximate one with Azure Policy or scoped custom
  roles.
- **AWS KMS controls.** Azure Storage and PostgreSQL Flexible Server encrypt
  data at rest by default without an equivalent caller-supplied CMK control
  surface in this module.
- **RDS snapshot restoration.** PostgreSQL Flexible Server's backup/restore
  model is caller-operated outside Terraform; this module does not expose a
  restore-from-snapshot input.
- **EBS CSI ownership.** AKS has no EBS-equivalent CSI driver surface for
  this module to own or delegate — Azure Disk/Files CSI drivers are cluster
  add-ons managed independently of this module.

## Upgrading a pre-release deployment

This modularity change is a **pre-release refactor that changes resource
addresses**. It landed before the first tagged release (`0.1.0`), so it ships
no `moved` blocks. The address changes fall into two groups, which behave
differently on upgrade:

- **Resources that gained `count` stay put.** AKS, its node pool, and the API
  warm-up gate (behind `create_aks`); the storage account, container, private
  DNS zone, VNet link, private endpoint, and lifecycle policy (behind
  `create_blob_storage`); the n8n namespace (behind `create_namespace`); and
  the webhook HPA (behind `n8n_webhook_hpa_enabled`) moved from an unindexed
  address to `[0]`. When `count` is added to an existing resource, Terraform
  automatically moves the existing object to instance `0`, so these
  resources are not recreated because of the address change alone.
- **KEDA moved into a submodule.** KEDA's namespace and Helm release moved
  from `kubernetes_namespace.keda` and `helm_release.keda` to
  `module.controllers.kubernetes_namespace.keda[0]` and
  `module.controllers.helm_release.keda[0]`. Terraform does not infer moves
  across module boundaries, so without intervention the plan destroys the old
  KEDA installation and creates a new one.

Before upgrading a pre-release test deployment past this change:

1. **Review the plan carefully.** Confirm that the `[0]` resources above show
   as moves, not replacements. A replacement there has a different cause,
   such as another changed argument, and needs its own review.
2. **Move the KEDA state instead of recreating it.** Run the equivalent of
   the following from your root, adjusting the `module.n8n` prefix to your
   own module call name, then re-run `terraform plan`:

   ```bash
   terraform state mv 'module.n8n.kubernetes_namespace.keda' \
     'module.n8n.module.controllers.kubernetes_namespace.keda[0]'
   terraform state mv 'module.n8n.helm_release.keda' \
     'module.n8n.module.controllers.helm_release.keda[0]'
   ```

   If you let the plan destroy and recreate KEDA instead, expect worker
   autoscaling to stop while KEDA is absent. Removing the KEDA release can
   also remove its CRDs and the `ScaledObject` and `TriggerAuthentication`
   resources that use them. Check that they exist again after the apply.
3. **Back up the n8n encryption key** with
   `terraform output -raw n8n_encryption_key` before applying. Losing it
   makes every credential already stored in n8n's database permanently
   unrecoverable.
4. **Back up durable data.** Take a PostgreSQL backup and, if you use Azure
   execution or binary storage, back up the container's contents. You need
   both if the plan replaces the database or the storage account for any
   reason.
5. **Recreate if the plan is not clean.** If the plan still replaces AKS,
   Blob storage, or the database after the steps above and you cannot
   explain why, apply against a fresh deployment instead. Restore the
   PostgreSQL backup and reuse the backed-up encryption key.
6. **Roll back by returning to the previous commit.** There is no
   state-address rollback automation. Moving state back needs the reverse
   `terraform state mv` commands.

From `0.1.0` onward, a change that moves resource addresses must follow the
module's normal state-compatibility policy (`moved` blocks or an equivalent
no-op upgrade path) instead of relying on caller-side state moves or
backup/recreate.
