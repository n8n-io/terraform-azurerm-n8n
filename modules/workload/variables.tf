# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Naming and tags ───────────────────────────────────────────────────────────
# Cross-cutting inputs every Phase 5 sub-story consumes. `friendly_name_prefix`
# embeds in chart-side resource names (e.g. the federated identity credential)
# and the `Name` tag on any taggable resource the workload tier may surface;
# `common_tags` flows through to taggable resources via `local.common_tags`
# (defined in locals.tf). Subsequent stories (US-022 / US-023) layer
# resource-specific inputs on top of this skeleton.

variable "friendly_name_prefix" {
  description = "Short, lowercase name prefix used in workload-tier resource names (e.g. the federated identity credential's `name` attribute) and as the value of the `Name` tag on any taggable resource. 2–12 characters, lowercase alphanumeric only — matches the `modules/infra/` constraint so a single prefix flows from the umbrella example through both submodules without rename."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must be 2–12 characters of lowercase letters and digits (no dashes, underscores, or uppercase) — matches modules/infra/'s constraint."
  }
}

variable "common_tags" {
  description = "Additional tags merged onto any taggable resource this module may surface (chart-side Kubernetes resources are not Azure-taggable; the input is reserved for tag-bearing resources US-022/US-023 might introduce). Combined with the module's built-in `ManagedBy = terraform` and `Project = n8n` tags via `local.common_tags`."
  type        = map(string)
  default     = {}

  # no validation: arbitrary string→string tag map; per-tag length and
  # per-resource tag-count limits are enforced at apply by the destination
  # platform if/when a taggable resource is added.
}

# ── Cross-tier glue from modules/infra/ (AKS / Postgres / Redis / Storage) ────
# Every value below mirrors a `modules/infra/` output (US-015..US-018) one-to-one.
# The umbrella example (US-025) wires `module.workload`'s inputs to
# `module.infra`'s outputs in a single mechanical pass — keep variable names
# in lockstep with the source-side output names so the wiring stays trivial
# to audit. Sensitive inputs match the source-side `sensitive = true`
# annotation on the producing output.

# Surfaced as part of the documented contract so umbrella examples mirror
# `modules/infra/.aks_cluster_name` one-to-one. No workload-tier resource
# consumes the cluster name today (the kubernetes / helm / kubectl providers
# are configured against the cluster's kubeconfig, not its name).
# tflint-ignore: terraform_unused_declarations
variable "aks_cluster_name" {
  description = "Name of the AKS cluster the workload tier deploys into. Sourced from `modules/infra/.aks_cluster_name`. Surfaced for diagnostic / annotation use (e.g. setting `cluster-name` on chart-rendered Pod / Deployment labels) and for callers that prefer `data.azurerm_kubernetes_cluster.<name>` lookups in providers.tf over the explicit `aks_kube_config` output."
  type        = string

  validation {
    condition     = length(var.aks_cluster_name) > 0
    error_message = "aks_cluster_name must be non-empty."
  }
}

# The federated identity credential lives in `modules/infra/iam.tf` (decision
# documented in US-023 progress notes — the credential is azurerm-tier and
# this submodule has no `azurerm` provider). Kept here as a contract input
# so umbrella examples mirror infra outputs one-to-one even though the
# workload tier doesn't consume the URL directly.
# tflint-ignore: terraform_unused_declarations
variable "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster, sourced from `modules/infra/.aks_oidc_issuer_url`. Consumed by the federated identity credential (US-023) that binds the n8n Kubernetes service account to the n8n_workload UAMI so n8n pods authenticate to Azure services without static credentials."
  type        = string

  validation {
    condition     = can(regex("^https://", var.aks_oidc_issuer_url))
    error_message = "aks_oidc_issuer_url must be an https URL (e.g. https://oidc.prod-aks.azure.com/...)."
  }
}

variable "postgres_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL Flexible Server. Sourced from `modules/infra/.postgres_fqdn`. Resolves to the server's private IP from inside the VNet. Consumed by US-023 when it builds the n8n database connection string (writes the `DB_POSTGRESDB_HOST` env var on the chart-rendered Deployments)."
  type        = string

  validation {
    condition     = length(var.postgres_fqdn) > 0
    error_message = "postgres_fqdn must be non-empty."
  }
}

variable "postgres_admin_username" {
  description = "PostgreSQL administrator login (mirrors `modules/infra/.postgres_admin_username` which itself mirrors `modules/infra/var.pg_admin_username`). Marked sensitive because it is half of the database credential pair. Consumed by US-023 when it builds the n8n database-credentials Secret. Default `n8n` matches the legacy umbrella module's hardcoded login — backward-compat for callers migrating from v1.x."
  type        = string
  sensitive   = true
  default     = "n8n"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.postgres_admin_username))
    error_message = "postgres_admin_username must start with a lowercase letter and contain 1–63 lowercase letters, digits, or underscores."
  }
}

variable "postgres_admin_password" {
  description = "PostgreSQL administrator password generated upstream by `random_password.postgres_admin` in `modules/infra/`. Sourced from `modules/infra/.postgres_admin_password`. Consumed by US-023 when it builds the n8n database-credentials Secret. Marked sensitive."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.postgres_admin_password) > 0
    error_message = "postgres_admin_password must be non-empty."
  }
}

variable "postgres_database_name" {
  description = "Name of the PostgreSQL database n8n connects to. Sourced from `modules/infra/.postgres_database_name`. Always `n8n` today (the database name is hardcoded in `modules/infra/database.tf`). Consumed by US-023 when it builds the n8n database connection string (writes the `DB_POSTGRESDB_DATABASE` env var on the chart-rendered Deployments)."
  type        = string

  validation {
    condition     = length(var.postgres_database_name) > 0
    error_message = "postgres_database_name must be non-empty."
  }
}

variable "redis_hostname" {
  description = "Hostname of the Azure Cache for Redis instance. Sourced from `modules/infra/.redis_hostname`. Resolves to the cache's private IP from inside the VNet. Consumed by US-022 (KEDA TriggerAuthentication Secret) and US-023 (n8n queue-backend Secret)."
  type        = string

  validation {
    condition     = length(var.redis_hostname) > 0
    error_message = "redis_hostname must be non-empty."
  }
}

variable "redis_ssl_port" {
  description = "TLS-only port the Azure Cache for Redis listens on. Sourced from `modules/infra/.redis_ssl_port`. Always 6380 today. Consumed by US-023 when it builds the n8n queue-backend connection string."
  type        = number

  validation {
    condition     = var.redis_ssl_port > 0 && var.redis_ssl_port < 65536
    error_message = "redis_ssl_port must be a valid TCP port number (1–65535)."
  }
}

variable "redis_primary_access_key" {
  description = "Primary access key for the Azure Cache for Redis instance — the bearer credential n8n + KEDA use to authenticate. Sourced from `modules/infra/.redis_primary_access_key`. Consumed by US-022 (KEDA TriggerAuthentication Secret) and US-023 (n8n queue-backend Secret). Marked sensitive."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.redis_primary_access_key) > 0
    error_message = "redis_primary_access_key must be non-empty."
  }
}

variable "storage_account_name" {
  description = "Name of the Azure storage account that backs the n8n Azure Files share. Sourced from `modules/infra/.storage_account_name`. Consumed by US-023 when it builds the chart-side `azurefiles-credentials` Kubernetes Secret + the static PersistentVolume referenced by every n8n pod's binary-data mount."
  type        = string

  validation {
    condition     = length(var.storage_account_name) > 0
    error_message = "storage_account_name must be non-empty."
  }
}

variable "storage_account_primary_access_key" {
  description = "Primary access key for the storage account that backs the n8n Azure Files share. Sourced from `modules/infra/.storage_account_primary_access_key`. Consumed by US-023 when it builds the chart-side `azurefiles-credentials` Kubernetes Secret. The workload tier may instead resolve the key at runtime via the `n8n_workload` UAMI's role assignment (granted by `modules/infra/`); the static-key path stays available for callers that prefer the legacy v1.x wiring. Marked sensitive."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.storage_account_primary_access_key) > 0
    error_message = "storage_account_primary_access_key must be non-empty."
  }
}

variable "storage_share_name" {
  description = "Name of the Azure Files share that backs n8n binary data. Sourced from `modules/infra/.storage_share_name`. Always `n8n-binary-data` today (the share name is hardcoded in `modules/infra/storage.tf`). Consumed by US-023 when it builds the chart-side PersistentVolume mount."
  type        = string

  validation {
    condition     = length(var.storage_share_name) > 0
    error_message = "storage_share_name must be non-empty."
  }
}

variable "n8n_workload_uami_client_id" {
  description = "Client ID of the n8n workload user-assigned identity. Sourced from `modules/infra/.n8n_workload_uami_client_id`. Consumed by US-023 to (a) bind a Kubernetes-side federated identity credential to the AKS OIDC issuer + n8n service account, and (b) annotate the n8n service account with `azure.workload.identity/client-id`. Marked sensitive per the `modules/infra/` source-side annotation."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Fa-f0-9-]{32,}$", var.n8n_workload_uami_client_id))
    error_message = "n8n_workload_uami_client_id must look like a UUID / GUID (32+ hex / hyphen characters)."
  }
}

# ── Cross-tier glue from modules/infra/ (App Gateway / Key Vault) ─────────────
# `key_vault_id`, `n8n_domain`, `app_gateway_id`, and
# `app_gateway_tls_cert_secret_id` come from `modules/infra/.key_vault_id` /
# `module.infra.<input>` re-exports / `modules/infra/.app_gateway_id` /
# `modules/infra/var.app_gateway_tls_cert_secret_id` respectively. The TLS
# secret URI is duplicated here (rather than re-derived from `key_vault_id`)
# so the umbrella example can wire it directly from one of the two
# `modules/tls-*` submodules' outputs without round-tripping through
# `modules/infra/`.

variable "n8n_domain" {
  description = "Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Mirrors `modules/infra/var.n8n_domain` — the App Gateway terminates TLS for this hostname and AGIC writes the matching `host:` rule on the chart's Ingress object. Consumed by US-023 when it renders the chart's Ingress and the AGIC `appgw-ssl-certificate` annotation."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.n8n_domain))
    error_message = "n8n_domain must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }
}

# Surfaced as part of the documented contract so umbrella examples mirror
# `modules/infra/.app_gateway_id` one-to-one. AGIC binds to the gateway
# implicitly via the `kubernetes.io/ingress.class = "azure-application-gateway"`
# annotation on the chart's Ingress (see `n8n.tf`); no resource here reads
# the gateway resource ID directly.
# tflint-ignore: terraform_unused_declarations
variable "app_gateway_id" {
  description = "Resource ID of the Application Gateway. Sourced from `modules/infra/.app_gateway_id`. Surfaced for diagnostic use and as a forward-reference input that subsequent stories may consume when extending the Ingress / AGIC annotation surface. Validated as an Azure resource ID for early misuse detection."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/applicationGateways/.+$", var.app_gateway_id))
    error_message = "app_gateway_id must be a fully qualified Azure Application Gateway resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/applicationGateways/<name>)."
  }
}

# The chart-rendered Ingress sets the AGIC annotation `appgw-ssl-certificate`
# to the cert NAME (`appgw-ssl-cert`), not to the Key Vault Secret URI; the
# URI itself is read by `modules/infra/`'s App Gateway listener at apply
# time. Surfaced here for contract symmetry with infra so umbrella examples
# wire both tiers from the same `module.tls.app_gateway_tls_cert_secret_id`
# output.
# tflint-ignore: terraform_unused_declarations
variable "app_gateway_tls_cert_secret_id" {
  description = "Versioned Azure Key Vault Secret URI for the App Gateway listener's TLS certificate (e.g. `https://<vault>.vault.azure.net/secrets/<cert>/<version>`). Mirrors `modules/infra/var.app_gateway_tls_cert_secret_id`. Consumed by US-023 when it sets the chart-rendered Ingress's `appgw-ssl-certificate` annotation so AGIC binds the gateway listener to the same cert this submodule and `modules/infra/` agree on."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.vault\\.azure\\.net/secrets/[^/]+(/[a-f0-9]+)?$", var.app_gateway_tls_cert_secret_id))
    error_message = "app_gateway_tls_cert_secret_id must be a Key Vault Secret URI (e.g. https://<vault>.vault.azure.net/secrets/<cert>/<version> — version segment optional)."
  }
}

# Surfaced as a contract symmetry input mirroring `modules/infra/.key_vault_id`.
# No workload-tier resource reads the vault directly — the App Gateway TLS
# cert URI flows into modules/infra/ where the listener consumes it; no
# chart-side Secret references the vault.
# tflint-ignore: terraform_unused_declarations
variable "key_vault_id" {
  description = "Resource ID of the Key Vault holding the App Gateway TLS cert. Sourced from `modules/infra/.key_vault_id` (which is itself a passthrough of `modules/infra/var.app_gateway_keyvault_id`). May be null when the caller did NOT supply a vault — the legacy module-owned `azurerm_key_vault.n8n` was removed in registry-hardening US-012, so the workload tier never owns a vault either. Surfaced for diagnostic use; subsequent stories may consume it when extending the chart's secret-references surface."
  type        = string
  default     = null

  validation {
    condition     = var.key_vault_id == null || can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.KeyVault/vaults/.+$", var.key_vault_id))
    error_message = "key_vault_id must be null or a fully qualified Azure Key Vault resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>)."
  }
}

# ── n8n Helm chart ────────────────────────────────────────────────────────────
# License key, multi-main replica count, and the chart-version pin. Multi-main
# requires ≥2 main pods. The chart's Redis-based leader election
# (`multiMain.setup`) plus `helm_release.n8n` running with `wait = true,
# atomic = true, timeout = 600` together absorb the multi-main migration race
# the legacy `null_resource.post_deploy_restart` workaround papered over
# (removed in registry-hardening US-002). Subsequent stories (US-023) layer in
# the chart values that reference these inputs.

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Marked sensitive — keep out of plan output and Git history; supply via environment variable (TF_VAR_n8n_license_key) or a secret-managed terraform.tfvars. The placeholder sentinel `REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY` is rejected by the validation block below (mirrors the root module)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.n8n_license_key) > 0 && var.n8n_license_key != "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
    error_message = "n8n_license_key must be set to a real license key — the placeholder value from terraform.tfvars.example is not accepted. Get a key at https://n8n.io/pricing."
  }
}

variable "n8n_main_replicas" {
  description = "Number of n8n main pods. Multi-main mode requires ≥2 — single-main is not supported by this module's topology. The chart's Redis-based leader election (`multiMain.setup`) plus `helm_release.n8n` running with `wait = true, atomic = true, timeout = 600` together absorb the multi-main migration race that the legacy `null_resource.post_deploy_restart` workaround papered over (removed in registry-hardening US-002)."
  type        = number
  default     = 2

  validation {
    condition     = var.n8n_main_replicas >= 2
    error_message = "n8n_main_replicas must be at least 2 (multi-main topology). Single-main is not supported by this module."
  }
}

variable "n8n_chart_version" {
  description = "Pin for the n8n Helm chart (e.g. 1.4.0). The module uses the OCI chart `oci://ghcr.io/n8n-io/n8n-helm-chart` (n8n's official multi-main chart, same as the AKS prototype and the AWS sibling) — wired in US-023's `helm_release.n8n`."
  type        = string
  default     = "1.4.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-.+)?$", var.n8n_chart_version))
    error_message = "n8n_chart_version must be a semantic version like 1.4.0 or 1.4.0-rc1."
  }
}

# ── KEDA + autoscaling (US-022) ───────────────────────────────────────────────
# KEDA chart pin (the controller workers + the TriggerAuthentication resolve
# against this version's CRD shape) and the webhook-processor HPA's upper
# bound. The chart skips its bundled webhook HPA when KEDA is on; this
# submodule owns the HPA directly. min_replicas (=2) and the CPU utilization
# target (=70%) are topology floors hardcoded in scaling.tf — see comments
# there for rationale. Only the upper bound is caller-tunable.

variable "keda_chart_version" {
  description = "Pin for the KEDA Helm chart from https://kedacore.github.io/charts (e.g. 2.15.0). Pinning a version keeps plans deterministic across CI and prevents an unattended apply from picking up a breaking KEDA release. Bump deliberately. Mirrors `var.keda_chart_version` from the root module."
  type        = string
  default     = "2.15.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-.+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be a semantic version like 2.15.0 or 2.15.0-rc1."
  }
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum replicas for the n8n webhook-processor HPA. Sized for expected webhook burst rate; the AKS node-pool max (`modules/infra/var.aks_node_count_max`) must be large enough to absorb both this HPA's scale-out AND the worker KEDA scale-out. Mirrors `var.n8n_webhook_hpa_max_replicas` from the root module."
  type        = number
  default     = 50

  validation {
    condition     = var.n8n_webhook_hpa_max_replicas >= 2
    error_message = "n8n_webhook_hpa_max_replicas must be at least 2 (matches the hardcoded min_replicas floor in scaling.tf)."
  }
}

# ── Worker KEDA ScaledObject (chart-rendered, queue-depth driven) ───────────────
# The n8n chart's worker `ScaledObject` (`templates/scaledobject-worker.
# yaml`) is opt-in via `keda.enabled = true` in chart values. We always
# enable it because the workload tier already installs KEDA (controllers.
# tf) and the matching `TriggerAuthentication` CR (keda.tf) — disabling it
# would leave both as dead weight. The three knobs below let operators
# tune the worker autoscaler without overriding the chart-values block in
# n8n.tf.

variable "n8n_worker_keda_min_replicas" {
  description = "Floor for the worker KEDA `ScaledObject`. Matches the `queueMode.workerReplicaCount` chart default (2) so the deployment never collapses below the multi-main parity baseline. Lower to 1 only for low-cost dev environments where queue stalls are acceptable."
  type        = number
  default     = 2

  validation {
    condition     = var.n8n_worker_keda_min_replicas >= 1
    error_message = "n8n_worker_keda_min_replicas must be at least 1."
  }
}

variable "n8n_worker_keda_max_replicas" {
  description = "Ceiling for the worker KEDA `ScaledObject`. Sized for expected peak burst; the AKS node-pool max (`modules/infra/var.aks_node_count_max`) must absorb both this AND the webhook-processor HPA's scale-out together. Default 20 mirrors the n8n chart's stock value."
  type        = number
  default     = 20

  validation {
    condition     = var.n8n_worker_keda_max_replicas >= 1
    error_message = "n8n_worker_keda_max_replicas must be at least 1."
  }
}

variable "n8n_worker_keda_target_list_length" {
  description = "Target queue depth (length of the `bull:jobs:wait` Redis list) per worker replica. KEDA computes the desired replica count as ceil(queue_depth / target). Default 5 — lower for snappier scale-out (more replicas at low load), higher for cost-conscious deployments (fewer replicas, deeper queues)."
  type        = number
  default     = 5

  validation {
    condition     = var.n8n_worker_keda_target_list_length >= 1
    error_message = "n8n_worker_keda_target_list_length must be at least 1 (a target of 0 would make KEDA scale infinitely)."
  }
}

# ── Task runner sidecar (chart-rendered) ────────────────────────────────────────────────
# When enabled (default), the n8n chart adds an `n8nio/runners` sidecar to
# main + worker pods that executes user-provided JavaScript (always) and
# Python (the chart pin enables `nativePythonRunner = true`) Code-node
# code in an isolated process. The sidecar authenticates against the n8n
# main process's task-broker via a shared secret — this submodule
# generates one with `random_password.n8n_task_runners_token` and mounts
# it via the chart's `taskRunners.authToken.existingSecret` hook. Disable
# only if the deployment must NOT execute Code nodes (e.g. tenants that
# only run pre-built workflow nodes); chart-side webhook ingress + queue
# routing keep working without the sidecar.
variable "n8n_task_runners_enabled" {
  description = "Enable the chart-rendered task-runner sidecar on n8n main + worker pods. Required for Code-node execution (JavaScript and Python). Default true — the sidecar's resource requests are modest (100 m / 256 Mi) and the AKS node-pool sizing in modules/infra/aks.tf assumes the sidecar is on. Set to false only when Code-node execution is intentionally disabled."
  type        = bool
  default     = true

  # no validation: bool toggle, single literal value sufficient.
}

# ── n8n chart-side persistence (US-023) ───────────────────────────────────────
# Quota for the static `kubernetes_persistent_volume_v1.n8n_files` /
# `kubernetes_persistent_volume_claim_v1.n8n_files` pair this submodule
# binds to the pre-existing Azure Files share (`var.storage_share_name`).
# Mirrors `var.storage_share_quota_gb` in `modules/infra/` so the share's
# Azure-side capacity and the cluster-side PVC's `resources.requests.storage`
# stay in lockstep — a mismatch would cause the chart's binary-data writes
# to silently truncate at the smaller of the two limits.

variable "storage_share_quota_gb" {
  description = "Storage capacity to declare on the chart-side `PersistentVolume` + `PersistentVolumeClaim` pair that binds the pre-existing Azure Files share into the cluster. Must match `modules/infra/var.storage_share_quota_gb` (the Azure-side quota) so the share's capacity and the cluster-side claim's requested storage stay aligned. The Azure-side default is 100 GB; raise this value AND the infra-side quota together when scaling the binary-data store. Range mirrors the Azure Files Standard tier 1–5120 GB span."
  type        = number
  default     = 100

  validation {
    condition     = var.storage_share_quota_gb >= 1 && var.storage_share_quota_gb <= 5120
    error_message = "storage_share_quota_gb must be between 1 and 5120 GB (Azure Files Standard tier limits, mirrored from modules/infra/)."
  }
}

# ── n8n chart-install + destroy gating (US-023) ───────────────────────────────
# Two `time_sleep` knobs that absorb async behaviour the kubernetes / helm
# providers don't natively wait for:
#   - `n8n_helm_post_install_settle_seconds` — pause AFTER `helm_release.n8n`
#     reports success and BEFORE `kubernetes_ingress_v1.n8n` is created so
#     AGIC reconciles the Ingress against a fully-converged Deployment.
#     Replaces the legacy `null_resource.post_deploy_restart`
#     (registry-hardening US-002).
#   - `aks_destroy_drain_seconds` — destroy-only pause BETWEEN
#     `helm_release.n8n` uninstall and `kubernetes_namespace.n8n` delete so
#     Azure Files finishes its asynchronous CIFS detach. Replaces the legacy
#     `null_resource.drain_n8n_pods` (registry-hardening US-005).
# Both default to the same values as the root module's matching vars.

variable "n8n_helm_post_install_settle_seconds" {
  description = "Seconds to wait after `helm_release.n8n` reports success before downstream Kubernetes resources (`kubernetes_ingress_v1.n8n`) are created. Gives AGIC a chance to reconcile the Ingress against a fully-converged main deployment rather than one that is still rolling. Default 60 s (matches the legacy `null_resource.post_deploy_restart` window that registry-hardening US-002 retired). Floor 30 s (catches the migration-finish window from the original prototype); ceiling 600 s (matches `helm_release.n8n.timeout`)."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_helm_post_install_settle_seconds >= 30 && var.n8n_helm_post_install_settle_seconds <= 600
    error_message = "n8n_helm_post_install_settle_seconds must be between 30 and 600 (inclusive)."
  }
}

variable "aks_destroy_drain_seconds" {
  description = "Seconds to pause between `helm_release.n8n` uninstall and `kubernetes_namespace.n8n` delete during `terraform destroy`. Replaces the legacy `null_resource.drain_n8n_pods` apply-host bash drain (registry-hardening US-005) with a deterministic `time_sleep.wait_for_aks_drain` whose `destroy_duration` absorbs the asynchronous Azure Files CIFS detach window. The helm provider's `wait = true, atomic = true, cleanup_on_fail = true` semantics already drive pod scale-down inside the release; this gate only waits out the Azure-side share detach. Default 120 s covers the typical detach for a single share; operators with larger shares (>50 GiB) or many concurrent pods may want to bump this. Floor 30 s (below which CIFS detach is rarely complete); ceiling 600 s (matches the legacy bash drain's 24×5 s wait-loop upper bound)."
  type        = number
  default     = 120

  validation {
    condition     = var.aks_destroy_drain_seconds >= 30 && var.aks_destroy_drain_seconds <= 600
    error_message = "aks_destroy_drain_seconds must be between 30 and 600 (inclusive)."
  }
}
