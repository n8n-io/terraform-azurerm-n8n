# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Core inputs ───────────────────────────────────────────────────────────────
# Region, naming, tags. Subsequent Phase 5 stories (US-015..US-019) layer
# resource-specific inputs on top of this skeleton — keep this file
# organised by concern (one section per related group of vars).

variable "location" {
  description = "Azure region to deploy into (e.g. eastus, westeurope, australiaeast). Must match the region the azurerm provider is configured for."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[a-z0-9]*$", var.location))
    error_message = "Value must be a valid Azure region in the short-name format (lowercase letters and digits, no spaces or dashes — e.g. eastus, westeurope, australiaeast)."
  }
}

variable "resource_group_name" {
  description = "Name of an existing Azure resource group all IaaS resources this submodule creates land in. The submodule does NOT create the resource group — the caller provisions it (or supplies one) so the lifecycle is decoupled from any single Phase 5 submodule."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._()-]{1,90}$", var.resource_group_name))
    error_message = "resource_group_name must be 1–90 characters of letters, digits, '.', '_', '(', ')', or '-' (Azure resource-group naming rules)."
  }
}

variable "friendly_name_prefix" {
  description = "Short, lowercase name prefix used in every resource name and as the value of the `Name` tag (e.g. `n8nprod`, `n8ndev`). 2–12 characters, lowercase alphanumeric only — Azure storage-account names cap at 24 chars and must be alnum-lowercase, so this prefix is the binding constraint."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must be 2–12 characters of lowercase letters and digits (no dashes, underscores, or uppercase) — Azure storage-account naming is the binding constraint."
  }
}

variable "common_tags" {
  description = "Additional Azure tags merged onto every taggable resource this module creates. Combined with the module's built-in `ManagedBy = terraform` and `Project = n8n` tags via `local.common_tags`."
  type        = map(string)
  default     = {}

  # no validation: arbitrary string→string tag map; Azure's per-tag length
  # and per-resource tag-count limits are enforced by the platform at apply.
}

# ── BYO networking ────────────────────────────────────────────────────────────
# This submodule does not create a VNet. The caller supplies a pre-existing
# VNet and five pre-configured subnets, each scoped to its workload
# (delegations, network-policy flags). Subsequent stories (US-016 / US-017)
# create the privatelink.postgres.database.azure.com /
# privatelink.redis.cache.windows.net private DNS zones and link them to
# `var.vnet_id` so the PostgreSQL Flexible Server and the Redis private
# endpoint resolve to private IPs. See `examples/complete/` for an
# AVM-based reference VNet.

variable "vnet_id" {
  description = "Resource ID of the VNet n8n will deploy into. The module creates `privatelink.postgres.database.azure.com` and `privatelink.redis.cache.windows.net` private DNS zones and links them to this VNet so that the PostgreSQL Flexible Server and the Redis private endpoint resolve to private IPs. Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/virtualNetworks/.+$", var.vnet_id))
    error_message = "vnet_id must be a fully qualified Azure resource ID for a virtual network (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>)."
  }
}

variable "aks_subnet_id" {
  description = "Resource ID of the subnet the AKS node pool attaches to (Azure CNI). Sized to fit `aks_node_count_max` plus pod IPs (CNI consumes one IP per pod). No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.aks_subnet_id))
    error_message = "aks_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

variable "postgres_subnet_id" {
  description = "Resource ID of the subnet the PostgreSQL Flexible Server is injected into. Must be delegated to `Microsoft.DBforPostgreSQL/flexibleServers` and contain no other workloads (Flexible Server consumes the entire subnet). Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.postgres_subnet_id))
    error_message = "postgres_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

variable "redis_subnet_id" {
  description = "Resource ID of the subnet the Redis Cache private endpoint attaches to. Must have `private_endpoint_network_policies` disabled (Azure refuses to create a private endpoint when network policies are enforced on the subnet). No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.redis_subnet_id))
    error_message = "redis_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

variable "appgw_subnet_id" {
  description = "Resource ID of the subnet the Application Gateway attaches to. Must be dedicated to Application Gateway (no other workloads), with a /24 or larger CIDR per Azure App Gateway sizing guidance. No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.appgw_subnet_id))
    error_message = "appgw_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

# Reserved for additional private-endpoint resources (Storage Account, Key
# Vault) that future stories may add to this submodule. The current resource
# graph attaches PEs only to `redis_subnet_id`; this input is surfaced today
# so umbrella examples can wire it from the same caller-owned subnet without
# a churn diff when the additional PE resources land.
# tflint-ignore: terraform_unused_declarations
variable "private_endpoint_subnet_id" {
  description = "Resource ID of the subnet additional private endpoints (e.g. Storage Account, Key Vault) attach to. Must have `private_endpoint_network_policies` disabled (Azure refuses to create a private endpoint when network policies are enforced on the subnet). No subnet delegation required. May be the same as `redis_subnet_id` when callers prefer to consolidate all PEs onto a single subnet, but a dedicated subnet keeps blast-radius smaller. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.private_endpoint_subnet_id))
    error_message = "private_endpoint_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

# ── AKS sizing & version ──────────────────────────────────────────────────────
# Cluster Kubernetes version, node SKU and autoscaler bounds, plus the
# post-provision API warm-up window. Names mirror the root variables.tf so
# US-025's umbrella example wiring is mechanical (`aks_node_vm_size` is the
# Phase 5 rename of root's `aks_node_sku` — the new name is more idiomatic
# and matches azurerm_kubernetes_cluster's `default_node_pool.vm_size`
# attribute exactly).

variable "aks_kubernetes_version" {
  description = "Kubernetes version for the AKS cluster (e.g. 1.33, 1.33.4). Must be a version Azure currently supports on the standard plan in the target region — check with `az aks get-versions --location <region>` and the AKS support-plan matrix at https://learn.microsoft.com/azure/aks/supported-kubernetes-versions. Defaults to 1.33; bump deliberately. Versions outside the standard support window (e.g. 1.30 in mid-2026) are LTS-only and require a Premium-tier cluster to provision — the 400 `K8sVersionNotSupported` error from the AKS API surfaces with that exact subcode."
  type        = string
  default     = "1.33"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.aks_kubernetes_version))
    error_message = "aks_kubernetes_version must be a Kubernetes version like 1.33 or 1.33.4."
  }
}

variable "aks_node_vm_size" {
  description = "Azure VM SKU for the AKS default node pool (e.g. Standard_D4s_v4, Standard_D8s_v4). Recommended minimum is Standard_D4s_v4 (4 vCPU, 16 GB) — multi-main runs 6+ pods at minimum replicas (~3,600m CPU); smaller SKUs leave no headroom for HPA / KEDA scale-out."
  type        = string
  default     = "Standard_D4s_v4"

  validation {
    condition     = can(regex("^Standard_[A-Z][A-Za-z0-9_]+$", var.aks_node_vm_size))
    error_message = "aks_node_vm_size must be a valid Azure VM SKU name (e.g. Standard_D4s_v4, Standard_D8s_v4)."
  }
}

variable "aks_node_count_min" {
  description = "Minimum number of nodes in the AKS default node pool. The cluster autoscaler will not scale below this. Floor of 2 keeps the multi-main topology (≥2 main pods, ≥1 worker, ≥2 webhook processors) schedulable across single-node failures."
  type        = number
  default     = 2

  validation {
    condition     = var.aks_node_count_min >= 1
    error_message = "aks_node_count_min must be at least 1."
  }
}

variable "aks_node_count_max" {
  description = "Maximum number of nodes in the AKS default node pool. The cluster autoscaler will not scale above this. Sized to absorb webhook bursts (HPA on the webhook-processor Deployment) and worker scale-out (KEDA on Redis queue depth)."
  type        = number
  default     = 6

  validation {
    condition     = var.aks_node_count_max >= 1
    error_message = "aks_node_count_max must be at least 1."
  }
}

variable "aks_api_warmup_seconds" {
  description = "Seconds to wait after `azurerm_kubernetes_cluster.n8n` reports success before downstream Kubernetes-/Helm-provider resources (in modules/workload/) are created. Replaces the legacy `null_resource.wait_for_aks_api` /healthz poll-loop (registry-hardening US-003) with a deterministic `time_sleep`. Azure reports the AKS resource as `Succeeded` before /healthz is consistently green; the kubernetes/helm providers' built-in retry handles any transient 503s after the gate. Default 90 s covers the typical AKS post-provision warm-up. Operators on cold regions or capacity-constrained subscriptions can extend this; the floor (30 s) is below which the providers' retry budget alone is insufficient, the ceiling (600 s) matches the legacy probe's 10-minute upper bound."
  type        = number
  default     = 90

  validation {
    condition     = var.aks_api_warmup_seconds >= 30 && var.aks_api_warmup_seconds <= 600
    error_message = "aks_api_warmup_seconds must be between 30 and 600 (inclusive)."
  }
}

# ── PostgreSQL Flexible Server (US-016) ───────────────────────────────────────
# Sizing, version, HA toggle, and admin username for the private-only
# PostgreSQL Flexible Server. `postgres_subnet_id` already lives in the
# BYO-networking section above. Validation blocks below are mirrored
# verbatim from the root variables.tf so callers migrating from the v1.x
# umbrella module do not have to re-tune these inputs.

variable "pg_sku_name" {
  description = "Azure PostgreSQL Flexible Server SKU (e.g. B_Standard_B1ms for dev, GP_Standard_D2s_v3 for production). Format: `<tier>_Standard_<family>` where tier is B (Burstable), GP (General Purpose), or MO (Memory Optimized). Burstable does NOT support zone-redundant HA — set `pg_enable_high_availability = false` when using B_*."
  type        = string
  default     = "GP_Standard_D2s_v3"

  validation {
    condition     = can(regex("^(B|GP|MO)_Standard_[A-Z][A-Za-z0-9_]+$", var.pg_sku_name))
    error_message = "pg_sku_name must follow Azure Flexible Server format <tier>_Standard_<family> where tier is B, GP, or MO (e.g. B_Standard_B1ms, GP_Standard_D2s_v3, MO_Standard_E4s_v3)."
  }
}

variable "pg_storage_mb" {
  description = "Allocated storage for the PostgreSQL Flexible Server in MB. Azure minimum is 32768 (32 GB). Storage can be grown but not shrunk in place — size for projected growth."
  type        = number
  default     = 32768

  validation {
    condition     = var.pg_storage_mb >= 32768
    error_message = "pg_storage_mb must be at least 32768 (32 GB) — Azure Flexible Server minimum."
  }
}

variable "pg_version" {
  description = "PostgreSQL major version (e.g. 14, 15, 16). 16 is the current GA on Azure Flexible Server. Major-version upgrades are not in-place — see Azure docs for the upgrade workflow."
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^[0-9]+$", var.pg_version))
    error_message = "pg_version must be a PostgreSQL major version number (e.g. 14, 15, 16)."
  }
}

variable "pg_enable_high_availability" {
  description = "Enable zone-redundant HA on the PostgreSQL Flexible Server (synchronous standby in a different availability zone). Requires a non-Burstable SKU (GP_* or MO_*) — Burstable does NOT support HA. Adds a ~2× cost premium."
  type        = bool
  default     = false

  validation {
    condition     = !(var.pg_enable_high_availability && startswith(var.pg_sku_name, "B_"))
    error_message = "pg_enable_high_availability = true requires a non-Burstable pg_sku_name (GP_* or MO_*); the Burstable tier (B_*) does not support zone-redundant HA."
  }
}

variable "pg_admin_username" {
  description = "PostgreSQL administrator (login role) name. Surfaced to n8n via the chart's database-credentials Secret in `modules/workload/` (US-023). Azure Flexible Server reserves a small set of names (`azure_superuser`, `azure_pg_admin`, `admin`, `administrator`, `root`, `guest`, `public`) — the validation below blocks them. Default 'n8n' matches the legacy umbrella module's hardcoded login."
  type        = string
  default     = "n8n"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.pg_admin_username))
    error_message = "pg_admin_username must start with a lowercase letter and contain 1–63 lowercase letters, digits, or underscores."
  }

  validation {
    condition     = !contains(["azure_superuser", "azure_pg_admin", "admin", "administrator", "root", "guest", "public"], lower(var.pg_admin_username))
    error_message = "pg_admin_username must not be a reserved Azure / PostgreSQL role name (azure_superuser, azure_pg_admin, admin, administrator, root, guest, public)."
  }
}

# ── Redis Cache (US-017) ──────────────────────────────────────────────────────
# Sizing inputs for the private-only Azure Cache for Redis. `redis_subnet_id`
# (private endpoint NIC) already lives in the BYO-networking section above.
# Validation blocks below are mirrored verbatim from the root variables.tf so
# callers migrating from the v1.x umbrella module do not have to re-tune
# these inputs. `redis_sku_name` is the Phase 5 RENAME of root's `redis_sku`
# — the new name matches `azurerm_redis_cache.sku_name` exactly (same shape
# decision as US-015's `aks_node_sku` → `aks_node_vm_size` rename).

variable "redis_sku_name" {
  description = "Azure Redis Cache SKU. `Standard` is two-node replicated (suitable for production). `Premium` adds VNet injection (the module uses a private endpoint instead), data persistence, clustering, and zone redundancy. Basic is excluded — the module always uses a private endpoint, which Basic does not support."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.redis_sku_name)
    error_message = "redis_sku_name must be one of: Standard, Premium. Basic is excluded because the module always uses a private endpoint, which Basic does not support."
  }
}

variable "redis_family" {
  description = "Azure Redis Cache family. `C` = Basic/Standard tier (default). `P` = Premium tier. Must be consistent with `redis_sku_name`: Standard ⇒ C, Premium ⇒ P."
  type        = string
  default     = "C"

  validation {
    condition     = contains(["C", "P"], var.redis_family)
    error_message = "redis_family must be one of: C (Basic/Standard), P (Premium)."
  }
}

variable "redis_capacity" {
  description = "Azure Redis Cache capacity (size). For family C: 0–6 (250 MB → 53 GB). For family P: 1–5 (6 GB → 120 GB). The default 1 = 1 GB on the Standard SKU — sized for queue-mode metadata, not n8n binary data (which goes to Azure Files)."
  type        = number
  default     = 1

  validation {
    condition     = var.redis_capacity >= 0 && var.redis_capacity <= 6
    error_message = "redis_capacity must be between 0 and 6 (family-specific bounds enforced by Azure at apply)."
  }
}

# ── Storage Account / Azure Files share (US-018) ──────────────────────────────
# Sizing inputs for the Azure Files share that backs n8n binary data. The
# storage account name is `local.storage_account_name` (≤24 chars,
# alnum-lowercase, embeds `var.friendly_name_prefix`); only the share quota
# and account replication type are caller-tunable. Hardened defaults
# (`https_traffic_only_enabled = true`, `min_tls_version = "TLS1_2"`,
# `account_kind = "StorageV2"`, `account_tier = "Standard"`) are hardcoded
# inside `storage.tf` — the security posture is non-negotiable, surfacing
# trade-offs as a code-review concern instead of a runtime knob (same pattern
# US-016 / US-017 used for Postgres / Redis private-only posture).

variable "storage_account_replication_type" {
  description = "Azure storage account replication type (`LRS` = locally-redundant, `ZRS` = zone-redundant, `GRS` = geo-redundant, `RAGRS` = read-access geo-redundant, `GZRS` = geo-zone-redundant, `RAGZRS` = read-access geo-zone-redundant). Default `LRS` matches the legacy umbrella module's hardcoded value — backward-compatible for callers migrating from v1.x. Production deployments seeking cross-region disaster recovery should set `GZRS` or `RAGZRS`; the cost premium is ~2× LRS but the share survives a single-region outage."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.storage_account_replication_type)
    error_message = "storage_account_replication_type must be one of: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "storage_share_quota_gb" {
  description = "Quota for the Azure Files share that backs n8n binary data, in GB. Azure Files Standard tier supports 1–5120 GB per share; raise this for production workloads with large attachments. The default 100 GB is sized for typical workflow attachments without bloating the storage-account bill."
  type        = number
  default     = 100

  validation {
    condition     = var.storage_share_quota_gb >= 1 && var.storage_share_quota_gb <= 5120
    error_message = "storage_share_quota_gb must be between 1 and 5120 GB (Azure Files Standard tier limits)."
  }
}

# ── Application Gateway + Key Vault (US-019) ──────────────────────────────────
# Sizing for the v2 Application Gateway, the n8n-domain hostname the gateway
# terminates, and the BYO Key Vault holding the App Gateway listener cert.
# `appgw_subnet_id` (the gateway's dedicated subnet) already lives in the
# BYO-networking section above. `appgw_sku_name` is the Phase 5 RENAME of
# root's `app_gateway_sku` — the new name matches `azurerm_application_gateway.sku.name`
# exactly (same shape decision as US-015's `aks_node_sku` → `aks_node_vm_size`
# rename and US-017's `redis_sku` → `redis_sku_name` rename). `appgw_capacity`
# is NEW — root hardcoded `capacity = 2` inline; surfacing it as an input
# lets callers ramp horizontally for higher RPS without forking the submodule.
#
# `app_gateway_tls_cert_secret_id` and `app_gateway_keyvault_id` mirror the
# root variables verbatim — registry-hardening US-012 (Phase 4 R4.3) replaced
# the legacy `var.tls_mode` (`self_signed` / `letsencrypt` / `custom_pfx`)
# surface with this single BYO-secret contract: the caller provisions the
# cert (typically via one of the two `modules/tls-*` submodules) and supplies
# the resulting Key Vault Secret URI here. This submodule consumes the URI
# verbatim in the App Gateway `ssl_certificate.key_vault_secret_id` block.

# `n8n_domain` is surfaced as part of the submodule's documented contract
# (the Ingress / WEBHOOK_URL / N8N_HOST consumers live in `modules/workload/`,
# which reads its own `var.n8n_domain`). The infra submodule's outputs
# reference it in description text so umbrella examples that wire it through
# get the same name in both tiers — keeping the per-tier surface symmetric
# without forcing this submodule to declare an azurerm DNS resource.
# tflint-ignore: terraform_unused_declarations
variable "n8n_domain" {
  description = "Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must match the CN/SAN on the TLS certificate the App Gateway terminates with. Surfaced through to `modules/workload/` (US-023) so the chart's Ingress object writes the matching `host:` rule + AGIC's `appgw-ssl-certificate` annotation."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.n8n_domain))
    error_message = "Value must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }
}

variable "appgw_sku_name" {
  description = "Application Gateway v2 SKU. `WAF_v2` enables the OWASP-3.2 ruleset in detection mode (logs only, no blocking); `Standard_v2` skips WAF entirely. WAF_v2 is the recommended default; switch to Standard_v2 only when WAF licensing is undesirable. Phase 2 work will expose firewall_mode (Detection vs Prevention) and a BYO firewall_policy_id."
  type        = string
  default     = "WAF_v2"

  validation {
    condition     = contains(["WAF_v2", "Standard_v2"], var.appgw_sku_name)
    error_message = "appgw_sku_name must be one of: WAF_v2, Standard_v2. v1 SKUs are not supported."
  }
}

variable "appgw_capacity" {
  description = "Number of compute units to allocate for the Application Gateway (manual scaling). Range 1–125 per Azure App Gateway v2 quota. Default 2 keeps a baseline of redundancy without over-provisioning; raise this for higher RPS or larger SSL throughput. Autoscaling (`autoscale_configuration`) is out of scope for this submodule today."
  type        = number
  default     = 2

  validation {
    condition     = var.appgw_capacity >= 1 && var.appgw_capacity <= 125
    error_message = "appgw_capacity must be between 1 and 125 (Azure App Gateway v2 quota)."
  }
}

# ── App Gateway Key Vault role-assignment toggle ─────────────────────────────
# Drives the `count` argument on `data.azurerm_key_vault.byo` and
# `azurerm_role_assignment.appgw_kv_secrets_user` in `keyvault.tf`. Must be
# a literal bool — `count` cannot resolve from values that are unknown at
# plan time, so the prior pattern of count-gating on
# `var.app_gateway_keyvault_id == null` broke the single-apply path when
# callers passed a same-plan-built vault attribute (e.g.
# `azurerm_key_vault.shared.id`, where `id` is computed at apply). The
# explicit boolean isolates the count signal from the (possibly unknown)
# resource ID, restoring the documented single-apply contract.
variable "app_gateway_keyvault_role_assignment_enabled" {
  description = "When true, grant the App Gateway TLS-cert reader UAMI `Key Vault Secrets User` on `var.app_gateway_keyvault_id`. Default false; the caller is then responsible for granting the UAMI access out-of-band (e.g. an `access_policy` on a vault in legacy access-policy mode, or an out-of-band role assignment). When set to true, `var.app_gateway_keyvault_id` MUST also be supplied. The toggle is isolated from `var.app_gateway_keyvault_id` so the `count` it drives is plan-time-known even when the ID is a same-plan-built resource attribute (e.g. `azurerm_key_vault.shared.id`)."
  type        = bool
  default     = false

  # no validation: a plain bool needs no extra check; the cross-variable
  # validation that asserts `app_gateway_keyvault_id` is non-null when this
  # toggle is true lives on `app_gateway_keyvault_id` below.
}

variable "app_gateway_tls_cert_secret_id" {
  description = "Versioned Azure Key Vault Secret URI for the App Gateway listener's TLS certificate (e.g. `https://<vault>.vault.azure.net/secrets/<cert>/<version>`). Required — the caller is responsible for provisioning the cert and importing it into a Key Vault. The two `modules/tls-letsencrypt/` and `modules/tls-self-signed/` submodules expose this exact value as their `app_gateway_tls_cert_secret_id` output; callers with an existing PKI / DigiCert / Sectigo cert can supply the secret URI directly. Pair with `var.app_gateway_keyvault_id` so this submodule grants the App Gateway UAMI `Key Vault Secrets User` on the vault holding the cert; alternatively grant the UAMI access out-of-band. The legacy `var.tls_mode` + per-mode inputs and the module-owned `azurerm_key_vault.n8n` were removed in registry-hardening US-012 (Phase 4 R4.3)."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.vault\\.azure\\.net/secrets/[^/]+(/[a-f0-9]+)?$", var.app_gateway_tls_cert_secret_id))
    error_message = "app_gateway_tls_cert_secret_id must be a Key Vault Secret URI (e.g. https://<vault>.vault.azure.net/secrets/<cert>/<version> — version segment optional). Note: this is the *secret* URI returned by `azurerm_key_vault_certificate.<name>.secret_id`, NOT the certificate URI."
  }
}

variable "app_gateway_keyvault_id" {
  description = "Resource ID of the Key Vault holding `var.app_gateway_tls_cert_secret_id`. When `var.app_gateway_keyvault_role_assignment_enabled = true`, this submodule grants the App Gateway TLS-cert reader UAMI (created in `ingress.tf`) `Key Vault Secrets User` on the supplied vault — the minimum role needed for the gateway to fetch the cert at runtime. When the toggle is false (default), the caller is responsible for granting the UAMI access (e.g. via an `access_policy` block on a vault in legacy access-policy mode, or an out-of-band role assignment). The vault should be in the same tenant as the App Gateway. May be `null` when the toggle is false."
  type        = string
  default     = null

  validation {
    condition     = var.app_gateway_keyvault_id == null || can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.KeyVault/vaults/.+$", var.app_gateway_keyvault_id))
    error_message = "app_gateway_keyvault_id must be null or a fully qualified Azure Key Vault resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>)."
  }

  # Cross-variable validation (Terraform 1.9+): when the role-assignment
  # toggle is on, the vault ID must be supplied. Catches the misuse mode
  # where a caller flips the bool without providing the ID.
  validation {
    condition     = !var.app_gateway_keyvault_role_assignment_enabled || var.app_gateway_keyvault_id != null
    error_message = "app_gateway_keyvault_id must be set when app_gateway_keyvault_role_assignment_enabled is true."
  }
}
