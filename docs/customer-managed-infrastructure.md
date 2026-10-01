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
`administrator_password_wo` argument (Terraform >= 1.11, azurerm >= 4.21,
both already required by this module's `versions.tf`) instead of generating
one with `random_password.postgres_admin`. Feed the actual value in through
`postgres_admin_password_wo` — an `ephemeral` module variable, so Terraform
never writes it to a plan or state file — and increment
`postgres_admin_password_wo_version` whenever you rotate it; Terraform only
re-applies a write-only value when its version number changes.

Because the value never touches state, the module also cannot copy it into a
Kubernetes Secret the way it does on the default path. `postgres_password_write_only
= true` therefore also requires `postgres_password_secret_ref`: you must
populate that Secret yourself, outside Terraform, with the same password you
passed to `postgres_admin_password_wo` — for example, syncing an Azure Key
Vault secret into the cluster with the Key Vault CSI driver or an External
Secrets Operator `ExternalSecret`. The module never reads that Secret's
value, so nothing checks the two stay in sync; a mismatch surfaces as a
PostgreSQL authentication failure on the next pod restart, not a Terraform
error. The `postgres_admin_password` output is `null` on this path for the
same reason it never has the value to expose.

Typical source for `postgres_admin_password_wo`: an `ephemeral
"azurerm_key_vault_secret"` block (or your own ephemeral/ephemeral-adjacent
source) in the **calling** root module, read from the same Key Vault secret
your Kubernetes Secret syncs from, so both stay in lockstep by construction
rather than by manual bookkeeping.

**Upgrading an existing deployment onto this path replaces the server's
password out of band of Terraform's own change detection.** Flipping
`postgres_password_write_only` from `false` to `true` moves the server from
`administrator_password` to `administrator_password_wo`; azurerm applies
this as a password update, not a resource replacement, but every existing
session's cached credential still points at the old password until you
update the Kubernetes Secret and roll the n8n pods. Plan a maintenance
window: apply with the new write-only value, confirm the Secret you manage
carries the same password, then restart the `n8n-main`, `n8n-worker`, and
`n8n-webhook-processor` deployments, and any `n8n_worker_pools` deployments
(`kubectl rollout restart deployment -l app.kubernetes.io/component=worker-group -n <namespace>`),
so they pick up the refreshed Secret.

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
