# `terraform-azurerm-n8n` — `modules/workload/`

Kubernetes-side workload that runs on top of the IaaS layer provisioned by
sibling [`modules/infra/`](../infra/). This submodule owns (registry-hardening
US-021..US-024):

- The KEDA Helm release (`oci://ghcr.io/kedacore/charts/keda` or the
  prototype's pinned chart, US-022).
- The n8n Helm release (`oci://ghcr.io/n8n-io/n8n-helm-chart`, US-023) —
  n8n's official multi-main chart, same as the AKS prototype and the AWS
  sibling.
- The `n8n` and `keda` Kubernetes namespaces, plus the chart-side
  Secrets the n8n chart consumes (database credentials, Redis credentials,
  Azure Files credentials, n8n Enterprise license key).
- The n8n `Ingress` object the AKS-managed AGIC reconciles into App
  Gateway listeners / pools / rules.
- The `HorizontalPodAutoscaler` for the webhook-processor the chart does
  not own.
- (Cross-tier) The matching `azurerm_federated_identity_credential.n8n_workload`
  resource that binds the chart-rendered `n8n-enterprise` ServiceAccount
  to the `n8n_workload` UAMI lives in
  [`modules/infra/iam.tf`](../infra/iam.tf), not in this submodule. The
  PRD US-023 AC's literal text ("moved into modules/workload/iam.tf")
  was relaxed in favour of the chart-only consumer posture documented
  below — the credential is an `azurerm`-tier resource and adding the
  `azurerm` provider here would break the architectural split.
  See `modules/infra/iam.tf` for the resource and the cross-reference
  comment that documents the literal-string lockstep with this
  submodule's `local.n8n_namespace`.
- The KEDA `TriggerAuthentication` CR wiring the chart's `ScaledObject`
  to the Redis primary access key — installed via
  `gavinbunney/kubectl_manifest` (registry-hardening US-007 took the
  R3.2 fall-back because the n8n-io chart at the pinned `var.n8n_chart_version`
  default does not expose first-class `keda.triggerAuthentication.*`
  values nor `extraManifests` / `extraObjects` hooks).

The IaaS layer (AKS, Postgres, Redis, Storage, App Gateway, IAM) lives in
the sibling [`modules/infra/`](../infra/) submodule (US-014..US-020). The
root [`terraform-azurerm-n8n`](../../README.md) module's `examples/complete/`
(US-025) wires both submodules together end-to-end.

## Why a separate workload submodule?

The Phase 5 split mirrors the
[`terraform-azurerm-terraform-enterprise-hvd`](https://github.com/hashicorp/terraform-azurerm-terraform-enterprise-hvd)
HashiCorp Validated Design's posture: the IaaS layer pins a single Azure
provider tree (`azurerm`, plus `random` for resource-name suffixing); the
workload layer pulls the kubernetes / helm / kubectl provider tree on top.

Keeping the kubernetes / helm / kubectl providers out of `modules/infra/`
means callers who only need the IaaS piece (e.g. building a fleet of AKS
clusters and wiring n8n into them later from a separate state file) get a
lean `terraform init` without pulling Kubernetes provider releases. It
also gives the registry-readiness audit a clean module boundary to point
at when explaining the chart-only consumer's posture.

## Pre-requisites

- A live AKS cluster with OIDC issuer + workload identity enabled
  (provided by `modules/infra/` via `var.aks_oidc_issuer_url` and
  `var.aks_cluster_name`).
- A running PostgreSQL Flexible Server reachable from inside the VNet
  via the `privatelink.postgres.database.azure.com` private DNS zone
  (provided by `modules/infra/` via `var.postgres_*` outputs).
- A running Azure Cache for Redis reachable from inside the VNet via
  the `privatelink.redis.cache.windows.net` private DNS zone (provided
  by `modules/infra/` via `var.redis_*` outputs).
- An Azure Files share reachable from inside the VNet (provided by
  `modules/infra/` via `var.storage_*` outputs).
- An Application Gateway with WAF_v2 / Standard_v2 SKU and a Key Vault
  Secret URI for its TLS cert (provided by `modules/infra/` via
  `var.app_gateway_id`, `var.app_gateway_tls_cert_secret_id`, and
  optionally `var.key_vault_id`).
- A populated n8n Enterprise license key (`var.n8n_license_key`).
- The kubernetes / helm / kubectl providers configured against the AKS
  cluster's `kube_config` (typically wired in the umbrella example's
  `providers.tf` from `module.infra.aks_kube_config`).

## Status

**R5.2d** (registry-hardening US-024) is in place — the outputs contract
is finalised and this README publishes the auto-generated terraform-docs
table below. The submodule now owns:

- The `keda` namespace + the KEDA Helm release (`controllers.tf`,
  US-022).
- The KEDA `TriggerAuthentication` CR rendered via
  `gavinbunney/kubectl_manifest` so the chart's worker `ScaledObject`
  authenticates to Redis (`keda.tf`, US-022). The CR's
  `secretTargetRef.name` reads `local.n8n_redis_secret_name`; the
  matching `kubernetes_secret.n8n_redis` lands at the same name in
  `n8n.tf` (US-023) without a body rewrite. `depends_on` extended in
  US-023 to add `kubernetes_secret.n8n_redis`.
- The webhook-processor `HorizontalPodAutoscaler` the chart suppresses
  when KEDA is on (`scaling.tf`, US-022). `depends_on` extended in
  US-023 to add `kubernetes_namespace.n8n` + `helm_release.n8n` so the
  HPA's `scale_target_ref` resolves on first apply.
- The `n8n` namespace, the four chart-consumed Secrets (DB password,
  Redis access key, license key, encryption key), the
  `n8n-azurefiles-credentials` Secret + static `PersistentVolume` /
  `PersistentVolumeClaim` pair binding the pre-existing Azure Files
  share into the cluster (`n8n.tf`, US-023).
- The `helm_release.n8n` chart install (multi-main + queue mode +
  webhook-processor isolation) plus the `time_sleep.n8n_helm_settle`
  post-install gate that gates AGIC reconciliation of the Ingress
  (`n8n.tf`, US-023). Replaces the legacy
  `null_resource.post_deploy_restart` from registry-hardening US-002.
- The `kubernetes_ingress_v1.n8n` AGIC-managed Ingress that translates
  into App Gateway listeners / pools / rules (`n8n.tf`, US-023).
- The destroy-time `time_sleep.wait_for_aks_drain` gate that absorbs
  the asynchronous Azure Files CIFS detach window between
  `helm_release.n8n` uninstall and namespace delete (`cleanup.tf`,
  US-023). Replaces the legacy `null_resource.drain_n8n_pods` from
  registry-hardening US-005.

The five-provider posture
(`kubernetes`, `helm`, `random`, `time`, `kubectl`) declared in
`versions.tf` carries through unchanged. The chart-only consumer
posture is preserved by leaving the matching
`azurerm_federated_identity_credential.n8n_workload` resource (which
binds the chart-rendered `n8n-enterprise` ServiceAccount to the
`n8n_workload` UAMI) in [`modules/infra/iam.tf`](../infra/iam.tf)
rather than introducing an `azurerm` provider here. The credential's
only Kubernetes-side metadata is two literal strings (the namespace
"n8n" and the SA name "n8n-enterprise"), so no actual cross-tier
resource reference is needed.

The accompanying `tests/defaults.tftest.hcl` runs the four plan-mode
resource-group assertions (skeleton, KEDA, n8n, scaling), 13 `rejects_*`
validation runs, and one `output_contract_complete` apply-mode run that
locks in the outputs contract surface — all under `mock_provider` for
the five providers above, with no live Kubernetes or Azure credentials
needed.

## Outputs contract

The auto-generated block below lists every input variable + output
this submodule contracts against. The four outputs (`n8n_url`,
`n8n_namespace`, `n8n_helm_release_name`, `n8n_helm_release_revision`)
are consumed by the umbrella example (US-025) and operator runbooks;
the `output_contract_complete` apply-mode run in
`tests/defaults.tftest.hcl` asserts each one resolves to a non-null
value at apply time.

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 2.12 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.12 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.keda](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.n8n](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.keda_trigger_authentication](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.webhook_processor](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_ingress_v1.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace.keda](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_persistent_volume_claim_v1.n8n_files](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.n8n_files](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret.n8n_db](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_encryption_key](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_files_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_license](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_task_runners](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [random_password.n8n_encryption_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.n8n_task_runners_token](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.n8n_helm_settle](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.wait_for_aks_drain](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_cluster_name"></a> [aks\_cluster\_name](#input\_aks\_cluster\_name) | Name of the AKS cluster the workload tier deploys into. Sourced from `modules/infra/.aks_cluster_name`. Surfaced for diagnostic / annotation use (e.g. setting `cluster-name` on chart-rendered Pod / Deployment labels) and for callers that prefer `data.azurerm_kubernetes_cluster.<name>` lookups in providers.tf over the explicit `aks_kube_config` output. | `string` | n/a | yes |
| <a name="input_aks_destroy_drain_seconds"></a> [aks\_destroy\_drain\_seconds](#input\_aks\_destroy\_drain\_seconds) | Seconds to pause between `helm_release.n8n` uninstall and `kubernetes_namespace.n8n` delete during `terraform destroy`. Replaces the legacy `null_resource.drain_n8n_pods` apply-host bash drain (registry-hardening US-005) with a deterministic `time_sleep.wait_for_aks_drain` whose `destroy_duration` absorbs the asynchronous Azure Files CIFS detach window. The helm provider's `wait = true, atomic = true, cleanup_on_fail = true` semantics already drive pod scale-down inside the release; this gate only waits out the Azure-side share detach. Default 120 s covers the typical detach for a single share; operators with larger shares (>50 GiB) or many concurrent pods may want to bump this. Floor 30 s (below which CIFS detach is rarely complete); ceiling 600 s (matches the legacy bash drain's 24×5 s wait-loop upper bound). | `number` | `120` | no |
| <a name="input_aks_oidc_issuer_url"></a> [aks\_oidc\_issuer\_url](#input\_aks\_oidc\_issuer\_url) | OIDC issuer URL for the AKS cluster, sourced from `modules/infra/.aks_oidc_issuer_url`. Consumed by the federated identity credential (US-023) that binds the n8n Kubernetes service account to the n8n\_workload UAMI so n8n pods authenticate to Azure services without static credentials. | `string` | n/a | yes |
| <a name="input_app_gateway_id"></a> [app\_gateway\_id](#input\_app\_gateway\_id) | Resource ID of the Application Gateway. Sourced from `modules/infra/.app_gateway_id`. Surfaced for diagnostic use and as a forward-reference input that subsequent stories may consume when extending the Ingress / AGIC annotation surface. Validated as an Azure resource ID for early misuse detection. | `string` | n/a | yes |
| <a name="input_app_gateway_tls_cert_secret_id"></a> [app\_gateway\_tls\_cert\_secret\_id](#input\_app\_gateway\_tls\_cert\_secret\_id) | Versioned Azure Key Vault Secret URI for the App Gateway listener's TLS certificate (e.g. `https://<vault>.vault.azure.net/secrets/<cert>/<version>`). Mirrors `modules/infra/var.app_gateway_tls_cert_secret_id`. Consumed by US-023 when it sets the chart-rendered Ingress's `appgw-ssl-certificate` annotation so AGIC binds the gateway listener to the same cert this submodule and `modules/infra/` agree on. | `string` | n/a | yes |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional tags merged onto any taggable resource this module may surface (chart-side Kubernetes resources are not Azure-taggable; the input is reserved for tag-bearing resources US-022/US-023 might introduce). Combined with the module's built-in `ManagedBy = terraform` and `Project = n8n` tags via `local.common_tags`. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Short, lowercase name prefix used in workload-tier resource names (e.g. the federated identity credential's `name` attribute) and as the value of the `Name` tag on any taggable resource. 2–12 characters, lowercase alphanumeric only — matches the `modules/infra/` constraint so a single prefix flows from the umbrella example through both submodules without rename. | `string` | n/a | yes |
| <a name="input_keda_chart_version"></a> [keda\_chart\_version](#input\_keda\_chart\_version) | Pin for the KEDA Helm chart from https://kedacore.github.io/charts (e.g. 2.15.0). Pinning a version keeps plans deterministic across CI and prevents an unattended apply from picking up a breaking KEDA release. Bump deliberately. Mirrors `var.keda_chart_version` from the root module. | `string` | `"2.15.0"` | no |
| <a name="input_key_vault_id"></a> [key\_vault\_id](#input\_key\_vault\_id) | Resource ID of the Key Vault holding the App Gateway TLS cert. Sourced from `modules/infra/.key_vault_id` (which is itself a passthrough of `modules/infra/var.app_gateway_keyvault_id`). May be null when the caller did NOT supply a vault — the legacy module-owned `azurerm_key_vault.n8n` was removed in registry-hardening US-012, so the workload tier never owns a vault either. Surfaced for diagnostic use; subsequent stories may consume it when extending the chart's secret-references surface. | `string` | `null` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | Pin for the n8n Helm chart (e.g. 1.4.0). The module uses the OCI chart `oci://ghcr.io/n8n-io/n8n-helm-chart` (n8n's official multi-main chart, same as the AKS prototype and the AWS sibling) — wired in US-023's `helm_release.n8n`. | `string` | `"1.4.0"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Mirrors `modules/infra/var.n8n_domain` — the App Gateway terminates TLS for this hostname and AGIC writes the matching `host:` rule on the chart's Ingress object. Consumed by US-023 when it renders the chart's Ingress and the AGIC `appgw-ssl-certificate` annotation. | `string` | n/a | yes |
| <a name="input_n8n_helm_post_install_settle_seconds"></a> [n8n\_helm\_post\_install\_settle\_seconds](#input\_n8n\_helm\_post\_install\_settle\_seconds) | Seconds to wait after `helm_release.n8n` reports success before downstream Kubernetes resources (`kubernetes_ingress_v1.n8n`) are created. Gives AGIC a chance to reconcile the Ingress against a fully-converged main deployment rather than one that is still rolling. Default 60 s (matches the legacy `null_resource.post_deploy_restart` window that registry-hardening US-002 retired). Floor 30 s (catches the migration-finish window from the original prototype); ceiling 600 s (matches `helm_release.n8n.timeout`). | `number` | `60` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Marked sensitive — keep out of plan output and Git history; supply via environment variable (TF\_VAR\_n8n\_license\_key) or a secret-managed terraform.tfvars. The placeholder sentinel `REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY` is rejected by the validation block below (mirrors the root module). | `string` | n/a | yes |
| <a name="input_n8n_main_replicas"></a> [n8n\_main\_replicas](#input\_n8n\_main\_replicas) | Number of n8n main pods. Multi-main mode requires ≥2 — single-main is not supported by this module's topology. The chart's Redis-based leader election (`multiMain.setup`) plus `helm_release.n8n` running with `wait = true, atomic = true, timeout = 600` together absorb the multi-main migration race that the legacy `null_resource.post_deploy_restart` workaround papered over (removed in registry-hardening US-002). | `number` | `2` | no |
| <a name="input_n8n_task_runners_enabled"></a> [n8n\_task\_runners\_enabled](#input\_n8n\_task\_runners\_enabled) | Enable the chart-rendered task-runner sidecar on n8n main + worker pods. Required for Code-node execution (JavaScript and Python). Default true — the sidecar's resource requests are modest (100 m / 256 Mi) and the AKS node-pool sizing in modules/infra/aks.tf assumes the sidecar is on. Set to false only when Code-node execution is intentionally disabled. | `bool` | `true` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Maximum replicas for the n8n webhook-processor HPA. Sized for expected webhook burst rate; the AKS node-pool max (`modules/infra/var.aks_node_count_max`) must be large enough to absorb both this HPA's scale-out AND the worker KEDA scale-out. Mirrors `var.n8n_webhook_hpa_max_replicas` from the root module. | `number` | `50` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Ceiling for the worker KEDA `ScaledObject`. Sized for expected peak burst; the AKS node-pool max (`modules/infra/var.aks_node_count_max`) must absorb both this AND the webhook-processor HPA's scale-out together. Default 20 mirrors the n8n chart's stock value. | `number` | `20` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Floor for the worker KEDA `ScaledObject`. Matches the `queueMode.workerReplicaCount` chart default (2) so the deployment never collapses below the multi-main parity baseline. Lower to 1 only for low-cost dev environments where queue stalls are acceptable. | `number` | `2` | no |
| <a name="input_n8n_worker_keda_target_list_length"></a> [n8n\_worker\_keda\_target\_list\_length](#input\_n8n\_worker\_keda\_target\_list\_length) | Target queue depth (length of the `bull:jobs:wait` Redis list) per worker replica. KEDA computes the desired replica count as ceil(queue\_depth / target). Default 5 — lower for snappier scale-out (more replicas at low load), higher for cost-conscious deployments (fewer replicas, deeper queues). | `number` | `5` | no |
| <a name="input_n8n_workload_uami_client_id"></a> [n8n\_workload\_uami\_client\_id](#input\_n8n\_workload\_uami\_client\_id) | Client ID of the n8n workload user-assigned identity. Sourced from `modules/infra/.n8n_workload_uami_client_id`. Consumed by US-023 to (a) bind a Kubernetes-side federated identity credential to the AKS OIDC issuer + n8n service account, and (b) annotate the n8n service account with `azure.workload.identity/client-id`. Marked sensitive per the `modules/infra/` source-side annotation. | `string` | n/a | yes |
| <a name="input_postgres_admin_password"></a> [postgres\_admin\_password](#input\_postgres\_admin\_password) | PostgreSQL administrator password generated upstream by `random_password.postgres_admin` in `modules/infra/`. Sourced from `modules/infra/.postgres_admin_password`. Consumed by US-023 when it builds the n8n database-credentials Secret. Marked sensitive. | `string` | n/a | yes |
| <a name="input_postgres_admin_username"></a> [postgres\_admin\_username](#input\_postgres\_admin\_username) | PostgreSQL administrator login (mirrors `modules/infra/.postgres_admin_username` which itself mirrors `modules/infra/var.pg_admin_username`). Marked sensitive because it is half of the database credential pair. Consumed by US-023 when it builds the n8n database-credentials Secret. Default `n8n` matches the legacy umbrella module's hardcoded login — backward-compat for callers migrating from v1.x. | `string` | `"n8n"` | no |
| <a name="input_postgres_database_name"></a> [postgres\_database\_name](#input\_postgres\_database\_name) | Name of the PostgreSQL database n8n connects to. Sourced from `modules/infra/.postgres_database_name`. Always `n8n` today (the database name is hardcoded in `modules/infra/database.tf`). Consumed by US-023 when it builds the n8n database connection string (writes the `DB_POSTGRESDB_DATABASE` env var on the chart-rendered Deployments). | `string` | n/a | yes |
| <a name="input_postgres_fqdn"></a> [postgres\_fqdn](#input\_postgres\_fqdn) | Fully qualified domain name of the PostgreSQL Flexible Server. Sourced from `modules/infra/.postgres_fqdn`. Resolves to the server's private IP from inside the VNet. Consumed by US-023 when it builds the n8n database connection string (writes the `DB_POSTGRESDB_HOST` env var on the chart-rendered Deployments). | `string` | n/a | yes |
| <a name="input_redis_hostname"></a> [redis\_hostname](#input\_redis\_hostname) | Hostname of the Azure Cache for Redis instance. Sourced from `modules/infra/.redis_hostname`. Resolves to the cache's private IP from inside the VNet. Consumed by US-022 (KEDA TriggerAuthentication Secret) and US-023 (n8n queue-backend Secret). | `string` | n/a | yes |
| <a name="input_redis_primary_access_key"></a> [redis\_primary\_access\_key](#input\_redis\_primary\_access\_key) | Primary access key for the Azure Cache for Redis instance — the bearer credential n8n + KEDA use to authenticate. Sourced from `modules/infra/.redis_primary_access_key`. Consumed by US-022 (KEDA TriggerAuthentication Secret) and US-023 (n8n queue-backend Secret). Marked sensitive. | `string` | n/a | yes |
| <a name="input_redis_ssl_port"></a> [redis\_ssl\_port](#input\_redis\_ssl\_port) | TLS-only port the Azure Cache for Redis listens on. Sourced from `modules/infra/.redis_ssl_port`. Always 6380 today. Consumed by US-023 when it builds the n8n queue-backend connection string. | `number` | n/a | yes |
| <a name="input_storage_account_name"></a> [storage\_account\_name](#input\_storage\_account\_name) | Name of the Azure storage account that backs the n8n Azure Files share. Sourced from `modules/infra/.storage_account_name`. Consumed by US-023 when it builds the chart-side `azurefiles-credentials` Kubernetes Secret + the static PersistentVolume referenced by every n8n pod's binary-data mount. | `string` | n/a | yes |
| <a name="input_storage_account_primary_access_key"></a> [storage\_account\_primary\_access\_key](#input\_storage\_account\_primary\_access\_key) | Primary access key for the storage account that backs the n8n Azure Files share. Sourced from `modules/infra/.storage_account_primary_access_key`. Consumed by US-023 when it builds the chart-side `azurefiles-credentials` Kubernetes Secret. The workload tier may instead resolve the key at runtime via the `n8n_workload` UAMI's role assignment (granted by `modules/infra/`); the static-key path stays available for callers that prefer the legacy v1.x wiring. Marked sensitive. | `string` | n/a | yes |
| <a name="input_storage_share_name"></a> [storage\_share\_name](#input\_storage\_share\_name) | Name of the Azure Files share that backs n8n binary data. Sourced from `modules/infra/.storage_share_name`. Always `n8n-binary-data` today (the share name is hardcoded in `modules/infra/storage.tf`). Consumed by US-023 when it builds the chart-side PersistentVolume mount. | `string` | n/a | yes |
| <a name="input_storage_share_quota_gb"></a> [storage\_share\_quota\_gb](#input\_storage\_share\_quota\_gb) | Storage capacity to declare on the chart-side `PersistentVolume` + `PersistentVolumeClaim` pair that binds the pre-existing Azure Files share into the cluster. Must match `modules/infra/var.storage_share_quota_gb` (the Azure-side quota) so the share's capacity and the cluster-side claim's requested storage stay aligned. The Azure-side default is 100 GB; raise this value AND the infra-side quota together when scaling the binary-data store. Range mirrors the Azure Files Standard tier 1–5120 GB span. | `number` | `100` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_n8n_helm_release_name"></a> [n8n\_helm\_release\_name](#output\_n8n\_helm\_release\_name) | Name of the n8n Helm release (always 'n8n' under the current chart pin). Surfaced for parity with operator runbooks that reference `helm status n8n -n n8n` / `helm history n8n -n n8n`. |
| <a name="output_n8n_helm_release_revision"></a> [n8n\_helm\_release\_revision](#output\_n8n\_helm\_release\_revision) | Revision number of the most recent successful `helm_release.n8n` install/upgrade. Increments on every chart upgrade; useful for callers that gate post-apply reconciliation steps on the release having actually rolled forward. |
| <a name="output_n8n_namespace"></a> [n8n\_namespace](#output\_n8n\_namespace) | Name of the Kubernetes namespace the n8n chart runs in (mirrors local.n8n\_namespace). Surfaced for operators wiring post-apply tooling (kubectl scripts, smoke tests, helm CLI runbooks) that need to scope queries to the n8n namespace without hardcoding the literal. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | Public HTTPS URL of the n8n web UI, computed from var.n8n\_domain. Convenience for callers that wire post-apply smoke tests / curl gates against the deployment without re-deriving the scheme + hostname themselves. |
<!-- END_TF_DOCS -->

## Provider configuration

The caller is responsible for configuring every provider this submodule
consumes. The umbrella example (US-025) wires them from
`module.infra.aks_kube_config`. Drop the following blocks into your
`providers.tf` (alongside the existing `provider "azurerm" { features {} }`
that `modules/infra/` consumes):

```hcl
provider "kubernetes" {
  host                   = module.infra.aks_kube_config.host
  client_certificate     = base64decode(module.infra.aks_kube_config.client_certificate)
  client_key             = base64decode(module.infra.aks_kube_config.client_key)
  cluster_ca_certificate = base64decode(module.infra.aks_kube_config.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.infra.aks_kube_config.host
    client_certificate     = base64decode(module.infra.aks_kube_config.client_certificate)
    client_key             = base64decode(module.infra.aks_kube_config.client_key)
    cluster_ca_certificate = base64decode(module.infra.aks_kube_config.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = module.infra.aks_kube_config.host
  client_certificate     = base64decode(module.infra.aks_kube_config.client_certificate)
  client_key             = base64decode(module.infra.aks_kube_config.client_key)
  cluster_ca_certificate = base64decode(module.infra.aks_kube_config.cluster_ca_certificate)
  load_config_file       = false
}

provider "random" {}

provider "time" {}
```

## Testing

```sh
terraform init
terraform fmt -check -recursive
terraform validate
terraform test
```

All three pass against the mocked providers without any live Kubernetes
or Azure credentials.
