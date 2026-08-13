## Context

See `proposal.md` for motivation. The root currently creates AKS, one user pool, the n8n workload identity, Blob infrastructure, the `n8n` and `keda` namespaces, all workload Secrets, KEDA, and the webhook HPA. PostgreSQL, Redis, and ingress already have create switches. Kubernetes and Helm providers are configured by callers from the module's AKS outputs, so an existing-cluster path must avoid provider cycles and preserve plan-known resource counts.

The behavioral reference is `terraform-aws-n8n` commit `3081ecf`. Azure differs materially: AKS provides its own node autoscaler and AGIC addon, KEDA is the only Helm-installed infrastructure controller, and n8n's Azure Key Vault external-secrets integration has no secure keyless workload-identity path in the pinned application. Parity therefore means the same ownership outcomes, not identical AWS variable names or resources.

## Goals / Non-Goals

**Goals:**

- Make every supported ownership decision explicit and plan-known.
- Preserve the current greenfield behavior through defaults.
- Keep one root call usable for mixed module-managed and customer-managed deployments.
- Make KEDA installation separately composable through a public controllers submodule.
- Keep workload credentials out of Terraform when caller-managed Kubernetes Secret references are selected.
- Keep all automated acceptance checks offline.

**Non-Goals:**

- Preserve Terraform state addresses across this pre-release refactor.
- Import existing resources into module ownership.
- Read customer-managed Azure resources through data sources to certify their security posture.
- Add customer-managed workload identities, AGIC on existing AKS, Azure Key Vault external-secret provisioning, CSI drivers, or AWS-shaped features without Azure equivalents.
- Perform live Azure qualification in this change.

## Decisions

### 1. Use literal ownership booleans

Add `create_aks`, `create_blob_storage`, `create_namespace`, and `n8n_webhook_hpa_enabled`, plus `install_keda`. All default to `true`, are non-nullable, and directly control `count` or `for_each`.

Do not infer ownership from whether an existing-resource input is null. A caller can pass an apply-time unknown resource attribute into any string input, which would make a derived `count` unknown. Literal booleans keep the graph plannable.

Each layer follows three rules:

1. The switch defaults to module ownership.
2. Existing-resource references and prerequisite attestations are required when the switch is false.
3. Hard failures cover incomplete selected contracts; `check` blocks warn about ignored references or non-default tuning on the unselected path.

### 2. Resolve one effective AKS object

When `create_aks = true`, the existing cluster and node-pool resources remain the source. When false, read `existing_aks_cluster_name` and `existing_aks_resource_group_name` through `data.azurerm_kubernetes_cluster`. Central locals select the effective cluster ID, name, OIDC issuer, and kubeconfig.

The data source is necessary because workload federation needs the OIDC issuer and root outputs need connection material. It is the exception to the general rule against inspecting customer-managed resources, and it reads identity coordinates rather than attempting a security audit.

Gate the cluster, user pool, warm-up sleep, AGIC-dependent identities and role assignments, and all AKS-only diagnostics. Require `existing_aks_cluster_prerequisites_confirmed = true` to attest:

- OIDC issuer and workload identity are enabled.
- Supported Kubernetes API and provider access are available.
- Schedulable capacity and node autoscaling are managed by the caller.
- The applying principal can create required federated credentials and Kubernetes objects.
- The selected namespace, service accounts, releases, and cluster-scoped KEDA objects do not conflict.

Existing AKS requires `create_ingress = false`. Supporting module-managed Application Gateway and AGIC against an arbitrary shared AKS cluster would require independently managing or adopting the addon identity and its role assignments, which is excluded.

Provider wiring in customer-managed examples targets the stand-in AKS resource or data source directly, not `module.n8n.aks_kube_config`, so `depends_on` edges do not create a cycle.

### 3. Keep the n8n workload identity module-owned

Even on existing AKS and existing Blob, the root continues to create the n8n user-assigned identity and federated credential. This gives the module a stable identity for chart annotations and avoids requiring callers to duplicate the federation subject contract.

For module-managed Blob, keep the current container-scoped `Storage Blob Data Contributor` assignment. For customer-managed Blob with automatic authentication, apply the same role to `existing_blob_container_id`. For connection-string or account-key compatibility modes, omit the role assignment because n8n does not use workload identity for Blob access.

A fully customer-managed workload identity is a future capability, not part of this parity pass.

### 4. Treat Blob creation and Blob integration separately

`create_blob_storage = false` skips the storage account, container, private DNS zone and link, private endpoint, and lifecycle policy. Require:

- `existing_blob_storage_account_name`
- `existing_blob_container_name`
- `existing_blob_container_id`
- `existing_blob_endpoint`
- `existing_blob_prerequisites_confirmed`

The effective Blob local chooses managed resource attributes or these references. The root does not query the supplied account or container. The attestation covers private endpoint and DNS reachability, disabled public access where required, encryption, retention ownership, and compatibility with the selected credential mode.

The container ID is separate from account and container names because the role-assignment scope must be known without a data-source lookup. This also supports a container in another resource group or subscription when provider permissions permit the role grant.

### 5. Represent credential references as typed objects

Add optional objects with `name` and `key` for:

- `n8n_license_key_secret_ref`
- `n8n_encryption_key_secret_ref`
- `postgres_password_secret_ref`
- `redis_password_secret_ref`

Each object is mutually exclusive with its corresponding literal or generated source. Secret resources receive `count` gates. Helm values and the KEDA TriggerAuthentication reference effective Secret names and keys directly. Terraform never reads caller-managed Secret data.

Managed PostgreSQL still generates its password and therefore cannot select `postgres_password_secret_ref`. The database reference applies to the external database path. Managed Redis similarly keeps its Azure-generated access key, while `redis_password_secret_ref` applies to external Redis.

Keep the task-runner token generated inside the module. It has no persistence or external-system identity value that benefits from caller ownership.

When `n8n_encryption_key_secret_ref` is selected, the `n8n_encryption_key` output is null because Terraform does not know the value. Its description must state this explicitly.

### 6. Extract only KEDA into `modules/controllers`

Azure has no root-installed equivalents of the AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, or EBS CSI stack. The Azure controllers submodule therefore owns:

- Optional KEDA namespace creation.
- Optional KEDA Helm release.
- KEDA chart repository and version.
- Validated target namespace and Helm lifecycle settings.
- Outputs needed for root tests and direct-call ordering.

The root always instantiates `module.controllers`. `install_keda` controls whether it creates resources. Root `helm_release.n8n` and `kubectl_manifest.keda_trigger_authentication` depend on `module.controllers` so install and destroy ordering are reversed correctly.

Direct callers that install KEDA separately must configure Kubernetes and Helm providers against the cluster directly and place `depends_on = [module.controllers]` on the n8n root call. This avoids the first-apply CRD race and the destroy-time ScaledObject finalizer deadlock.

`keda_trigger_authentication` remains in the root because it is n8n-instance configuration tied to the effective Redis Secret, not a cluster controller.

### 7. Make namespace and autoscaler ownership independent

`create_namespace = false` uses `n8n_namespace` as a caller-provided name and skips only the namespace resource. All other Kubernetes resources refer to an effective namespace local rather than a managed resource address.

`n8n_webhook_hpa_enabled = false` skips only the webhook HPA. Helm still sets webhook replicas to the configured floor so the caller has a stable deployment to scale.

`install_keda = false` skips the KEDA namespace and release but not the n8n TriggerAuthentication or chart-rendered ScaledObject. Require `existing_keda_prerequisites_confirmed = true` because Terraform cannot safely verify CRDs and operator readiness at plan time.

### 8. Suppress managed-cluster capacity assumptions on existing AKS

The CPU capacity diagnostic is meaningful only when the module owns both AKS pools and their maximum counts. Gate it on `create_aks`. Existing-cluster callers attest capacity and receive warnings when non-default AKS tuning inputs are ignored.

The workload autoscaler validation remains active in both modes because it governs n8n's own objects. When webhook HPA ownership is disabled, validate replica floors but do not claim ownership of its maximum behavior.

### 9. Keep customer-managed examples self-contained

Add four examples that own realistic Azure stand-ins outside `module "n8n"`:

- `customer-managed-cluster`: caller-owned AKS, module-managed data and Blob, caller-owned ingress.
- `customer-managed-redis`: caller-owned Redis endpoint and Secret, otherwise managed foundation.
- `customer-managed-storage`: caller-owned private Blob resources, module-owned n8n workload identity and container role grant.
- `customer-managed-everything`: caller-owned AKS, PostgreSQL, Redis, Blob, namespace, workload Secrets, ingress, and webhook HPA, plus direct `modules/controllers` invocation.

Examples must not contain real credentials. Mocked tests assert ownership boundaries and provider ordering. Existing sizing examples remain unchanged except for explicit defaults only where documentation clarity requires them.

### 10. Accept a state-breaking pre-release refactor

Do not add `moved` blocks. Conditional gates change addresses from unindexed resources to `[0]`, and KEDA moves under `module.controllers`. Documentation must say that pre-release deployments can see replacement and should preserve the encryption key and durable data before recreation.

This decision is acceptable only before `0.1.0`. After the first release, future address changes must follow the repository's normal state-compatibility policy.

## Risks / Trade-offs

- [Existing AKS data becomes unknown when an upstream cluster change is pending, causing Kubernetes providers to target incomplete coordinates] -> Document applying upstream cluster changes separately before running the n8n plan and prohibit `-refresh=false` as a workaround.
- [A caller falsely confirms an attestation] -> Make each attestation's exact obligations explicit and avoid claiming that Terraform verified customer-managed security posture.
- [Disabling KEDA on an already applied stack can deadlock on CRD finalizers] -> Document deleting or migrating n8n ScaledObjects before changing ownership, and preserve root-to-controller ordering for normal destroy.
- [Secret-reference combinations create null or sensitivity errors] -> Use explicit selected-source locals and test every literal, generated, and Secret-reference branch with mocked plans.
- [Customer-managed Blob cross-subscription role assignment lacks permission] -> Require the applying identity to have role-assignment permission at the supplied container scope or use a compatibility credential mode.
- [No state migration causes unexpected replacement] -> Mark the change as pre-release breaking, show plan-review and backup steps, and avoid implying no-op upgrades.
- [Four examples increase the CI budget] -> Use plan-only mocked tests, share the existing CI pattern, and enforce the repository's combined five-minute test budget.

## Migration Plan

1. Implement and verify ownership gates and effective locals before extracting KEDA.
2. Extract KEDA into `modules/controllers` and update dependencies.
3. Add credential references, customer-managed Blob integration, and examples.
4. Regenerate documentation and lock files, then run the full offline matrix.
5. Existing pre-release test deployments must back up the n8n encryption key and durable PostgreSQL and Blob data, review the plan, and recreate resources if address changes require it.
6. Rollback means returning to the previous commit and recreating affected pre-release infrastructure from the preserved data and key. No state-address rollback automation is provided.
