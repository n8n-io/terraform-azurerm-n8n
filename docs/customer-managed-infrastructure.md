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
`/webhook-test`. See
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
  on the module block defers the module's data source reads to apply time,
  which weakens the plan-time protection of
  `pg_storage_drift_guard_enabled` (see the comment above
  `data.azurerm_postgresql_flexible_server.current` in `database.tf`).
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
behavior below follows from the `hashicorp/azurerm` v4.81.0 source and
Microsoft's documentation. It has not been qualified on a live deployment,
so the length of any interruption is not known. There are two cases.

**Moving to a different zone, such as a central landing-zone zone.** Set the
switch to `false` and pass the new zone ID. The plan destroys the module's
own zone and VNet link, and changes the service's DNS attachment:

- For PostgreSQL, the server's `private_dns_zone_id` is updated in place;
  the server is not replaced.
- For Redis and Blob, the private endpoint itself is kept, but azurerm
  deletes its DNS zone group and creates a new one for the new zone. The
  endpoint's records leave the old zone before they appear in the new one.

Expect the following:

- If the n8n VNet resolves the zone through a direct VNet link, note that a
  VNet cannot be linked to two private DNS zones with the same name
  ([Microsoft Q&A](https://learn.microsoft.com/answers/questions/2283009/a-virtual-network-cannot-be-linked-to-multiple-zon)).
  The link to the new zone can only be created once the module's link is
  deleted, so n8n cannot resolve that service's hostname in between. A new
  PostgreSQL zone with a different name, or resolution through a central
  DNS resolver, avoids this conflict. Schedule a maintenance window either
  way.
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
  module-owned zone and link. The link fails while the VNet is still linked
  to a zone with the same name.

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
| External PostgreSQL password | `postgres_password_secret_ref` | `postgres_external_password` |
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
path** (`create_database = false`) — the module-managed Flexible Server
always generates and manages its own password, and there is no
`postgres_password_secret_ref` equivalent for it. The same is true for Redis:
`redis_password_secret_ref` applies only to `create_redis = false`, because
the module-managed Azure Managed Redis instance always uses its own generated
access key.

**The task-runner authentication token remains module-generated in every
mode.** It has no persistence and authenticates only an in-cluster process to
another in-cluster process, so caller ownership of it does not reduce
Terraform's exposure the way it does for the license key, encryption key, or
database/queue credentials.

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
