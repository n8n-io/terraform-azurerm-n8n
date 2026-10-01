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

### Delivering secrets from Azure Key Vault

This module never reads Key Vault values into Terraform, and it never
creates a Key Vault. Two opt-in AKS add-ons integrate with a caller-owned Key
Vault. The Key Vault Secrets Provider add-on lets a caller sync Key Vault
objects into the same Kubernetes Secrets the `*_secret_ref` inputs above
already read, without adding any static credential to Terraform state. The
KMS add-on is unrelated to secret delivery: it encrypts etcd at rest with a
caller-owned Key Vault key.

**Key Vault Secrets Provider add-on (`aks_key_vault_secrets_provider_enabled`).**
When `true` and `create_aks = true`, this module enables the AKS-managed
Secrets Store CSI driver add-on
(`azurerm_kubernetes_cluster.n8n[0].key_vault_secrets_provider`) with
autorotation on. The add-on creates and manages its own identity; this
module only optionally grants that identity `Key Vault Secrets User` on a
caller-named vault **using Azure RBAC** when both
`aks_key_vault_secrets_provider_role_assignment_enabled = true` and
`aks_key_vault_secrets_provider_keyvault_id` are set. `Key Vault Secrets
User` only authorizes reads under Azure RBAC; on an access-policy vault this
role assignment leaves the identity unauthorized, so grant access through an
access policy instead. When the toggle is `false` (default), grant that
identity access out-of-band instead (for example a vault in RBAC mode with
your own `azurerm_role_assignment`).
`aks_key_vault_secrets_provider_secret_rotation_interval` controls the
autorotation poll interval (default `2m`, matching the AKS default).

With the add-on enabled, mount a `SecretProviderClass` (a Kubernetes CRD this
module does not manage) that references the vault objects to sync, and set
its `secretObjects` field to project them into a Kubernetes Secret matching
the name and keys one of the `*_secret_ref` inputs expects. For
`n8n_encryption_key_secret_ref`, that Secret must carry all four keys —
`N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, and `N8N_PROTOCOL` — so the
`SecretProviderClass` needs vault objects for all four. **Never point
autorotation at the `N8N_ENCRYPTION_KEY` vault object.** n8n cannot rotate
its encryption key in place: changing it makes every credential already
stored in n8n's database permanently unrecoverable. When
`n8n_encryption_key_secret_ref` is set (as in this scenario), the
`n8n_encryption_key` output is `null` and the "Back up the n8n encryption
key" upgrade step's `terraform output -raw n8n_encryption_key` command
does not apply; back up the key from wherever the caller-managed Secret's
contents originated instead, see [Post-deployment
setup](./post-deployment.md#capture-the-n8n-encryption-key). A rotated
vault secret, like a lost backup, silently bricks the deployment on the
next sync.
Keep that vault object a static value. `N8N_HOST`, `N8N_PORT`, and
`N8N_PROTOCOL` have no such restriction and can be plain Key Vault secrets
holding static values or genuinely rotated ones. For rotation, restart
every n8n workload that consumes this Secret; the chart provides these
keys as environment variables, which running pods do not refresh when CSI
autorotation updates the Secret's content.
See [Microsoft's Secrets Store CSI Driver
documentation](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver)
for the `SecretProviderClass` schema. External Secrets Operator is an
equally valid alternative sync mechanism; this module does not install it,
but the same target-Secret contract applies regardless of which syncer a
caller chooses.

**KMS etcd encryption (`aks_kms_key_vault_key_id`).** Set this input (a Key
Vault key identifier) and `create_aks = true` to enable AKS's Key Management
Service etcd encryption
(`azurerm_kubernetes_cluster.n8n[0].key_management_service`) using a
caller-owned Key Vault key instead of Microsoft's platform-managed key.
`aks_kms_key_vault_network_access` selects `"Public"` (default) or
`"Private"` vault network access.

Azure's KMS feature rejects a `SystemAssigned` cluster identity outright
(`Azure Key Vault KMS feature does not support cluster identity type
"SystemAssigned"`), so setting either `aks_kms_role_assignment_enabled` or
`aks_kms_key_vault_key_id` switches the cluster's
identity block from this module's default `SystemAssigned` to a dedicated
`UserAssigned` identity (`azurerm_user_assigned_identity.aks_cluster`) that
this module creates and manages for you. On an already-running cluster this
identity-type switch is applied in place by `terraform apply` (confirmed
live, no cluster replacement). Azure also requires that identity to already
hold `Key Vault Crypto User` on the vault **before** KMS can be enabled —
not `Key Vault Crypto Service Encryption User`, which only carries the
wrap/unwrap data actions and was live-confirmed (on a brand-new cluster,
with no identity-type switch in play) to fail AKS's own
`AzureKeyVaultKmsValidateIdentityPermissionCustomerError` identity-
permission validation, which checks specifically for encrypt/decrypt.
`Key Vault Crypto User` is also the role Microsoft's own AKS KMS
documentation grants for this scenario. This ordering hazard is not
limited to a brand-new cluster:
within a single
`terraform apply`, Terraform has no way to guarantee the role assignment
finishes before the cluster's `key_management_service` block is added,
whether the cluster is being created for the first time or already exists
and is only now gaining the role assignment. Enabling KMS therefore always
takes **two applies** whenever this module manages the role assignment and
the grant does not already exist. This also grants the role through an
`azurerm_role_assignment`, an Azure RBAC grant that only takes effect on a
vault using the Azure RBAC permission model, exactly like the `Key Vault
Secrets User` grant above: on an access-policy vault, the first apply
below silently creates a no-op role assignment, and the second apply still
fails AKS's KMS identity-permission validation, the exact failed-state
scenario this section steers callers away from. Grant `Key Vault Crypto
User` through an access policy instead on an access-policy vault (see
`examples/medium`, whose vault uses RBAC and so never exercises this
path):

1. First apply: set `aks_kms_role_assignment_enabled = true` and
   `aks_kms_key_vault_id` to the vault, but leave `aks_kms_key_vault_key_id =
   null`. This grants the identity the role (creating the cluster too, on a
   first-time deployment).
2. Second apply: set `aks_kms_key_vault_key_id`. AKS enables KMS as an
   update against the now-authorized identity.

Skipping the first apply, or granting the role out-of-band before either
apply against a pre-existing identity, also works. Setting both
`aks_kms_role_assignment_enabled = true` and `aks_kms_key_vault_key_id`
together in the same apply is only safe when the role assignment is already
known, from a prior apply, to exist.

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
- **AWS KMS controls on Storage and PostgreSQL.** Azure Storage and
  PostgreSQL Flexible Server encrypt data at rest by default without an
  equivalent caller-supplied CMK control surface in this module. (AKS etcd
  encryption with a caller-owned Key Vault key is supported — see
  `aks_kms_key_vault_key_id` in [Delivering secrets from Azure Key
  Vault](#delivering-secrets-from-azure-key-vault).)
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
