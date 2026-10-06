# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Root contract skeleton (align-azure-with-aws-capabilities, section 1) ──
# This file establishes the single-module naming, networking, domain,
# certificate, and license inputs the `single-module-deployment` capability
# requires — see the spec scenario "Deploy from the root": a caller supplies
# the resource group, VNet, subnet, domain, certificate, and license inputs
# to one root module block.
#
# The variables below are ported verbatim (same names, types, defaults, and
# validation) from `modules/infra/variables.tf` and
# `modules/workload/variables.tf` so downstream sections (2 onward) can move
# each submodule's resources into root concern files without a variable
# rename. AKS sizing, PostgreSQL, Redis, Storage, Application Gateway, and
# n8n runtime inputs are added by their respective task sections (2–12) —
# adding them all here up front would defeat the "implement one task
# section per iteration" workflow this change follows.

# ── Core inputs ──────────────────────────────────────────────────────────
variable "location" {
  description = "Azure region to deploy into (e.g. eastus, westeurope, australiaeast). Must match the region the azurerm provider is configured for."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+[a-z0-9]*$", var.location))
    error_message = "Value must be a valid Azure region in the short-name format (lowercase letters and digits, no spaces or dashes — e.g. eastus, westeurope, australiaeast)."
  }
}

variable "resource_group_name" {
  description = "Name of an existing Azure resource group all resources this module creates land in. The module does NOT create the resource group — the caller provisions it (or supplies one) so its lifecycle is decoupled from this module."
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

# ── BYO networking ────────────────────────────────────────────────────────
# The module does not create a VNet. The caller supplies a pre-existing VNet
# and five pre-configured subnets, each scoped to its workload (delegations,
# network-policy flags). See `examples/small/` (section 13) for an
# AVM-based reference VNet.

variable "vnet_id" {
  description = "Resource ID of the VNet n8n will deploy into. The module creates `privatelink.postgres.database.azure.com` and Redis / Blob private DNS zones and links them to this VNet so managed services resolve to private IPs. Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/virtualNetworks/.+$", var.vnet_id))
    error_message = "vnet_id must be a fully qualified Azure resource ID for a virtual network (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>)."
  }
}

variable "aks_subnet_id" {
  description = "Resource ID of the subnet the AKS node pool attaches to (Azure CNI). Sized to fit the node-count ceiling plus pod IPs (CNI consumes one IP per pod). No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.aks_subnet_id))
    error_message = "aks_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

# ── AKS sizing, version, and hardening ────────────────────────────────────
# Ported from `modules/infra/variables.tf` (section 2 moves the AKS cluster
# itself from that submodule into root `aks.tf`), plus three HVD-inspired
# additions the two-tier module never had: availability zones, API
# authorized IP ranges, and a configurable node-pool upgrade surge (see
# design.md decision 2 and the `autoscaling-and-capacity` spec's "Production
# AKS controls" requirement).

variable "aks_kubernetes_version" {
  description = "Kubernetes version for the AKS cluster (e.g. 1.35, 1.35.6). Must be a version Azure currently supports on the standard plan in the target region — check with `az aks get-versions --location <region>` and the AKS support-plan matrix at https://learn.microsoft.com/azure/aks/supported-kubernetes-versions. Defaults to 1.35; bump deliberately. Versions outside the standard support window are LTS-only and require a Premium-tier cluster to provision."
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.aks_kubernetes_version))
    error_message = "aks_kubernetes_version must be a Kubernetes version like 1.35 or 1.35.6."
  }
}

variable "aks_sku_tier" {
  description = "SKU tier for the AKS cluster: \"Free\", \"Standard\", or \"Premium\". The Free tier has no financially backed SLA for the API server; production deployments generally want \"Standard\". \"Premium\" is a prerequisite for AKS Long Term Support, but this module does not set the cluster's support_plan, so selecting \"Premium\" alone does not enroll the cluster in Long Term Support. Changing the tier on an existing cluster is an in-place update, but the AKS API server can be unavailable for up to about a minute while it runs, so change it in its own apply (see docs/troubleshooting.md). Has no effect when create_aks = false; an existing caller-managed cluster's tier is left as-is."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be one of: Free, Standard, Premium."
  }
}

variable "aks_node_vm_size" {
  description = "Azure VM SKU for both AKS node pools (for example Standard_D4s_v7 or Standard_D8s_v5). The capacity diagnostic models reviewed Dsv4, Dsv5, and Dsv7 SKUs and stays silent for valid SKUs outside that map. Standard_D4s_v7 provides 4 vCPU and 16 GB per node."
  type        = string
  default     = "Standard_D4s_v4"
  nullable    = false

  validation {
    condition     = can(regex("^Standard_[A-Z][A-Za-z0-9_]+$", var.aks_node_vm_size))
    error_message = "aks_node_vm_size must be a valid Azure VM SKU name (e.g. Standard_D4s_v4, Standard_D8s_v4)."
  }
}

variable "aks_node_count_min" {
  description = "Minimum number of nodes in the AKS default node pool. The cluster autoscaler will not scale below this, and Terraform sets this as the pool's initial node count at creation only — see `aks_node_count_max`'s ignore_changes note. Floor of 2 keeps the multi-main topology (≥2 main pods, ≥1 worker, ≥2 webhook processors) schedulable across single-node failures."
  type        = number
  default     = 2

  validation {
    condition     = var.aks_node_count_min >= 1
    error_message = "aks_node_count_min must be at least 1."
  }
}

variable "aks_node_count_max" {
  description = "Maximum nodes in each of the system and user AKS node pools. The cluster autoscaler will not scale either pool above this value. The advisory capacity model counts both pools, or only the user pool when `aks_system_pool_critical_addons_only = true` taints the system pool against n8n pods, then subtracts AKS reservations and system workload requests. Terraform ignores each pool's live node count after creation so plans do not revert autoscaler-owned scale-out."
  type        = number
  default     = 6
  nullable    = false

  validation {
    condition     = var.aks_node_count_max >= 1
    error_message = "aks_node_count_max must be at least 1."
  }
}

variable "aks_availability_zones" {
  description = "Availability zones the AKS default node pool and user node pool spread across (e.g. [\"1\", \"2\", \"3\"]). Set to [] to deploy into a region without zone support (e.g. some smaller Azure regions). Zonal placement survives a single-zone outage without waiting for the cluster autoscaler to reschedule pods into a healthy zone."
  type        = list(string)
  default     = ["1", "2", "3"]

  validation {
    condition     = alltrue([for z in var.aks_availability_zones : can(regex("^[1-9][0-9]*$", z))])
    error_message = "aks_availability_zones must be a list of numeric zone identifiers as strings (e.g. [\"1\", \"2\", \"3\"]), or an empty list for regions without zone support."
  }
}

variable "aks_api_authorized_ip_ranges" {
  description = "IPv4 CIDR ranges allowed to reach the AKS API server's public endpoint (e.g. [\"203.0.113.0/24\"]). Empty list (the default) leaves the API server publicly reachable from any address — set this on any production cluster. Azure always allows traffic that originates from inside the cluster's own VNet, so this list only needs to cover operator/CI networks."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.aks_api_authorized_ip_ranges : can(cidrnetmask(r))])
    error_message = "aks_api_authorized_ip_ranges must be a list of valid IPv4 CIDR ranges (e.g. [\"203.0.113.0/24\"])."
  }
}

variable "aks_node_upgrade_max_surge" {
  description = "`max_surge` for the AKS default and user node pools' rolling upgrade (e.g. \"10%\" or \"1\"). Controls how many extra nodes AKS provisions above the pool's current count while draining nodes during a Kubernetes-version or node-image upgrade. Higher values upgrade faster but briefly cost more; lower values upgrade slower with less spare capacity."
  type        = string
  default     = "10%"

  validation {
    condition     = can(regex("^[1-9][0-9]*%?$", var.aks_node_upgrade_max_surge))
    error_message = "aks_node_upgrade_max_surge must be a positive integer optionally suffixed with '%' (e.g. \"10%\" or \"1\")."
  }
}

variable "aks_api_warmup_seconds" {
  description = "Seconds to wait after `azurerm_kubernetes_cluster.n8n` reports success before downstream Kubernetes-/Helm-provider resources are created. Azure reports the AKS resource as `Succeeded` before /healthz is consistently green; the kubernetes/helm providers' built-in retry handles any transient 503s after the gate. Default 90 s covers the typical AKS post-provision warm-up. Operators on cold regions or capacity-constrained subscriptions can extend this; the floor (30 s) is below which the providers' retry budget alone is insufficient, the ceiling (600 s) matches the legacy probe's 10-minute upper bound."
  type        = number
  default     = 90

  validation {
    condition     = var.aks_api_warmup_seconds >= 30 && var.aks_api_warmup_seconds <= 600
    error_message = "aks_api_warmup_seconds must be between 30 and 600 (inclusive)."
  }
}

variable "aks_node_os_disk_size_gb" {
  description = "OS-disk size (GiB) for both module-managed AKS node pools (system and user). Null (the default) leaves sizing to the provider/Azure default for the selected VM size. Changing this on an existing pool cycles its nodes via AzureRM's rotation mechanism, which does not cordon or drain workloads automatically \u2014 plan a maintenance window and confirm node/subnet/quota headroom before changing an existing cluster's value. Has no effect when create_aks = false; the existing cluster's disk sizing is unmanaged by this module."
  type        = number
  default     = null

  validation {
    condition     = var.aks_node_os_disk_size_gb == null ? true : (var.aks_node_os_disk_size_gb == floor(var.aks_node_os_disk_size_gb) && var.aks_node_os_disk_size_gb > 0)
    error_message = "aks_node_os_disk_size_gb must be null or a positive whole number of GiB."
  }
}

variable "aks_system_pool_critical_addons_only" {
  description = "When true, sets `only_critical_addons_enabled = true` on the system default_node_pool, applying the CriticalAddonsOnly=true:NoSchedule taint. Default false preserves today's behavior where n8n, KEDA, and the Redis exporter can schedule on the system pool alongside CoreDNS, konnectivity, and metrics-server. Nothing this module installs (n8n, KEDA, the Redis exporter) sets a nodeSelector or toleration, so turning this on moves all of it onto the n8nuser pool, and the advisory capacity check then counts only that pool. AKS-managed add-ons (CoreDNS, metrics-server, the CSI controllers, and the AGIC add-on used when create_ingress = true) carry their own CriticalAddonsOnly toleration, so module-managed ingress stays supported. Changing this on an existing cluster rotates the system pool through its temporary_name_for_rotation (systemtemp); nodes are recreated, not updated in place. Before changing it, size aks_node_count_min/aks_node_count_max (which apply to both pools) so n8nuser alone can hold the workload, in a separate apply, and confirm subnet IP and vCPU quota headroom for the temporary pool and the user-pool scale-out. Has no effect when create_aks = false; the existing cluster's system-pool taint is unmanaged by this module."
  type        = bool
  default     = false
  nullable    = false

  # no validation: a plain bool needs no additional constraint.
}

# Consumed by database.tf (section 3).
variable "postgres_subnet_id" {
  description = "Resource ID of the subnet the PostgreSQL Flexible Server is injected into. Must be delegated to `Microsoft.DBforPostgreSQL/flexibleServers` and contain no other workloads (Flexible Server consumes the entire subnet). Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.postgres_subnet_id))
    error_message = "postgres_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

# ── PostgreSQL topologies (align-azure-with-aws-capabilities section 3) ──
# Ported from `modules/infra/variables.tf` (`pg_sku_name`, `pg_storage_mb`,
# `pg_version`, `pg_enable_high_availability`, `pg_admin_username`) plus new
# reliability inputs from design.md decision 4 (backup retention,
# geo-redundant backup, maintenance window, zone selection) and the
# `create_database` / `postgres_external_*` toggle that gates the managed
# path, mirroring the AWS sibling's `create_database` / `db_host` /
# `db_password` shape in `database.tf`.

variable "create_database" {
  description = "When true (the default), the module creates and manages a private PostgreSQL Flexible Server. Set to false to use an external PostgreSQL endpoint — `postgres_external_host`, `postgres_external_username`, and `postgres_external_password` must then be supplied. Kept as a static boolean rather than `postgres_external_host == null` because `count` expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
}

variable "pg_sku_name" {
  description = "Azure PostgreSQL Flexible Server SKU (e.g. B_Standard_B1ms for dev, GP_Standard_D2s_v3 for production). Format: `<tier>_Standard_<family>` where tier is B (Burstable), GP (General Purpose), or MO (Memory Optimized). Burstable does NOT support zone-redundant HA — set `pg_enable_high_availability = false` when using B_*. Ignored when `create_database = false`."
  type        = string
  default     = "GP_Standard_D2s_v3"

  validation {
    condition     = can(regex("^(B|GP|MO)_Standard_[A-Z][A-Za-z0-9_]+$", var.pg_sku_name))
    error_message = "pg_sku_name must follow Azure Flexible Server format <tier>_Standard_<family> where tier is B, GP, or MO (e.g. B_Standard_B1ms, GP_Standard_D2s_v3, MO_Standard_E4s_v3)."
  }
}

variable "pg_storage_mb" {
  description = "Allocated storage for the PostgreSQL Flexible Server in MB. Azure minimum is 32768 (32 GB). Storage can be grown but not shrunk in place — size for projected growth. Ignored when `create_database = false`."
  type        = number
  default     = 32768

  validation {
    condition     = var.pg_storage_mb >= 32768
    error_message = "pg_storage_mb must be at least 32768 (32 GB) — Azure Flexible Server minimum."
  }
}

variable "pg_storage_auto_grow_enabled" {
  description = "Enable storage autogrow on the PostgreSQL Flexible Server so it automatically doubles disk space as usage approaches the limit, which helps keep the server from going read-only when full. Azure does not autogrow across the 4,096 GiB boundary: a server that reaches it must be resized manually, which is an offline operation. Autogrow only grows storage, it never shrinks it. After autogrow fires, raise pg_storage_mb to at least the new live size before the next apply: Terraform's plan reads the grown live value back and diffs it against the still-lower pg_storage_mb, and Azure Database for PostgreSQL Flexible Server cannot shrink storage_mb in place, so a stale pg_storage_mb plans to DESTROY AND RECREATE the entire server (data loss), not a clean apply failure. pg_storage_drift_guard_enabled = true can turn that into a precondition failure, but only when its data source is read at plan time (see that input). Review every plan for a PostgreSQL replace action and hold an existing caller-owned CanNotDelete management lock on the server, with lifecycle.prevent_destroy on the lock resource itself (docs/deletion-safety.md). Default false to keep current behavior. Ignored when `create_database = false`."
  type        = bool
  default     = false
  nullable    = false

  # no validation: a plain bool needs no extra check.
}

variable "pg_storage_drift_guard_enabled" {
  description = "When true, the module reads the module-managed PostgreSQL Flexible Server's actual live storage_mb via a data source and fails with a precondition error if pg_storage_mb is less than that live value. Best-effort early warning, not a deletion control: it only protects a plan in which the data source is read at plan time. Terraform defers the read to apply when it depends on objects with pending changes (most commonly a `depends_on` on the calling `module` block); the plan can then proceed without resolving the precondition, and Terraform may destroy the old server before it evaluates the create-side precondition. Review plans for a PostgreSQL replace action or this data source showing (known after apply), and hold an existing caller-owned CanNotDelete management lock on the server, with lifecycle.prevent_destroy on the lock resource itself (docs/deletion-safety.md). Without this, Azure Database for PostgreSQL Flexible Server cannot shrink storage_mb in place: after pg_storage_auto_grow_enabled has grown the live server past what pg_storage_mb still declares, azurerm plans to destroy and recreate the entire server (data loss) instead of failing cleanly. Ignored when `create_database = false`. The data source is read whenever this is true, independent of the current value of pg_storage_auto_grow_enabled: Azure never shrinks storage, so a server that already auto-grew keeps its larger live storage_mb even after autogrow is later turned back off, and the guard must still catch that stale pg_storage_mb. Leave this false on the apply that first creates the server: the data source has nothing to read yet, and enabling it from the start would fail that create. Enable it on the next apply once the server exists, and leave it enabled for ongoing drift protection. Caveat: the data source looks up the server by the CURRENT friendly_name_prefix and resource_group_name, not by any stored prior identity, so it cannot tell the guard is protecting a server that is about to move. Set this to false for any apply that also changes friendly_name_prefix or resource_group_name, since the lookup would otherwise target the new coordinates, find nothing there yet, and fail with a 404 instead of the intended precondition failure. Re-enable it on a later apply once the server has settled at its new name or resource group. The same not-found error occurs whenever the lookup runs after the server was deleted outside Terraform, including a `terraform destroy` refresh once the server is already gone (for example after a partially completed destroy). A plan-time lookup blocks the plan; a deferred one fails during apply. Set this to false to recover."
  type        = bool
  default     = false
  nullable    = false

  # no validation: a plain bool needs no extra check.
}

variable "pg_version" {
  description = "PostgreSQL major version (e.g. 14, 15, 16). 16 is the current GA on Azure Flexible Server. Major-version upgrades are not in-place — see Azure docs for the upgrade workflow. Ignored when `create_database = false`."
  type        = string
  default     = "16"

  validation {
    condition     = can(regex("^[0-9]+$", var.pg_version))
    error_message = "pg_version must be a PostgreSQL major version number (e.g. 14, 15, 16)."
  }
}

variable "pg_enable_high_availability" {
  description = "Enable zone-redundant HA on the PostgreSQL Flexible Server (synchronous standby in a different availability zone). Requires a non-Burstable SKU (GP_* or MO_*) — Burstable does NOT support HA. Adds a ~2× cost premium. Ignored when `create_database = false`."
  type        = bool
  default     = false

  validation {
    condition     = !(var.pg_enable_high_availability && startswith(var.pg_sku_name, "B_"))
    error_message = "pg_enable_high_availability = true requires a non-Burstable pg_sku_name (GP_* or MO_*); the Burstable tier (B_*) does not support zone-redundant HA."
  }
}

variable "pg_admin_username" {
  description = "PostgreSQL administrator (login role) name. Surfaced to n8n via `local.postgres_connection`. Azure Flexible Server reserves a small set of names (`azure_superuser`, `azure_pg_admin`, `admin`, `administrator`, `root`, `guest`, `public`) — the validation below blocks them. Default 'n8n' matches the legacy umbrella module's hardcoded login. Ignored when `create_database = false`."
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

variable "pg_backup_retention_days" {
  description = "Number of days to retain automated PostgreSQL Flexible Server backups. Azure enforces a range of 7–35 days for Flexible Server (unlike RDS, Azure does not allow disabling backups). Ignored when `create_database = false`."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.pg_backup_retention_days >= 7 && var.pg_backup_retention_days <= 35
    error_message = "pg_backup_retention_days must be between 7 and 35 (inclusive) — Azure Flexible Server does not support disabling backups."
  }
}

variable "pg_geo_redundant_backup_enabled" {
  description = "When true, replicate PostgreSQL Flexible Server backups to the Azure-paired region for the module's location, so a regional outage does not also destroy backup data. Adds a cost premium; cannot be changed after server creation without a snapshot/restore into a new server. Ignored when `create_database = false`."
  type        = bool
  default     = false

  # no validation: a plain bool needs no extra check.
}

variable "pg_maintenance_window" {
  description = "Optional custom maintenance window for the PostgreSQL Flexible Server (day_of_week: 0=Sunday..6=Saturday, start_hour: 0-23, start_minute: 0-59). Azure applies mandatory servicing (security patches) during this window. `null` (the default) leaves Azure's system-assigned window in place. Ignored when `create_database = false`."
  type = object({
    day_of_week  = number
    start_hour   = number
    start_minute = number
  })
  default = null

  validation {
    condition = var.pg_maintenance_window == null || (
      var.pg_maintenance_window.day_of_week >= 0 && var.pg_maintenance_window.day_of_week <= 6 &&
      var.pg_maintenance_window.start_hour >= 0 && var.pg_maintenance_window.start_hour <= 23 &&
      var.pg_maintenance_window.start_minute >= 0 && var.pg_maintenance_window.start_minute <= 59
    )
    error_message = "pg_maintenance_window.day_of_week must be 0-6, start_hour must be 0-23, and start_minute must be 0-59."
  }
}

variable "pg_primary_zone" {
  description = "Availability zone the PostgreSQL Flexible Server's primary instance is created in (e.g. \"1\", \"2\", \"3\"). `null` (the default) leaves Azure to pick a zone at create time. Terraform ignores drift on this attribute after creation — Azure only allows changing it as part of an HA failover, not a plain apply. Ignored when `create_database = false`."
  type        = string
  default     = null

  validation {
    condition     = var.pg_primary_zone == null || can(regex("^[1-9][0-9]*$", var.pg_primary_zone))
    error_message = "pg_primary_zone must be null or a numeric zone identifier as a string (e.g. \"1\", \"2\", \"3\")."
  }
}

variable "pg_standby_zone" {
  description = "Availability zone the PostgreSQL Flexible Server's HA standby instance is created in (e.g. \"1\", \"2\", \"3\"). Only meaningful when `pg_enable_high_availability = true`; must differ from `pg_primary_zone` — Azure requires the standby to sit in a different zone than the primary for zone-redundant HA to provide any resilience. `null` (the default) leaves Azure to pick a standby zone at create time. Ignored when `create_database = false`."
  type        = string
  default     = null

  validation {
    condition     = var.pg_standby_zone == null || can(regex("^[1-9][0-9]*$", var.pg_standby_zone))
    error_message = "pg_standby_zone must be null or a numeric zone identifier as a string (e.g. \"1\", \"2\", \"3\")."
  }

  validation {
    condition     = !(var.pg_enable_high_availability && var.pg_standby_zone != null && var.pg_primary_zone != null && var.pg_standby_zone == var.pg_primary_zone)
    error_message = "pg_standby_zone must differ from pg_primary_zone when pg_enable_high_availability is true and both are set — Azure requires the HA standby to sit in a different zone than the primary."
  }
}

# ── External PostgreSQL endpoint (create_database = false) ───────────────
# Mirrors the AWS sibling's `db_host` / `db_password` external-database
# contract, extended with the full connection contract
# `managed-service-topologies`'s "Use external PostgreSQL" scenario
# requires: host, database, username, password, port, and TLS (`ssl_mode`).

variable "postgres_external_host" {
  description = "External PostgreSQL host. Required when `create_database = false`. Ignored otherwise. Use this to point n8n at an existing Flexible Server, a server in a different subscription, or any PostgreSQL-compatible endpoint."
  type        = string
  default     = null

  validation {
    condition     = var.create_database || var.postgres_external_host != null
    error_message = "postgres_external_host is required when create_database = false."
  }
}

variable "postgres_external_port" {
  description = "External PostgreSQL port. Ignored when `create_database = true` (the module-managed server always uses 5432)."
  type        = number
  default     = 5432

  validation {
    condition     = var.postgres_external_port > 0 && var.postgres_external_port <= 65535
    error_message = "postgres_external_port must be between 1 and 65535."
  }
}

variable "postgres_external_database" {
  description = "External PostgreSQL database name n8n connects to. Ignored when `create_database = true` (the module-managed database is always named `n8n`)."
  type        = string
  default     = "n8n"

  validation {
    condition     = length(var.postgres_external_database) > 0
    error_message = "postgres_external_database must be non-empty."
  }
}

variable "postgres_external_username" {
  description = "Username for the external PostgreSQL endpoint specified by `postgres_external_host`. Required when `create_database = false`. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_database || var.postgres_external_username != null
    error_message = "postgres_external_username is required when create_database = false."
  }
}

variable "postgres_external_password" {
  description = "Password for the external PostgreSQL endpoint specified by `postgres_external_host`. Required when `create_database = false`, unless `postgres_password_secret_ref` is set instead. Ignored when `create_database = true` (the module generates a random password for its managed Flexible Server)."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.create_database ? true : ((var.postgres_external_password != null) != (var.postgres_password_secret_ref != null))
    error_message = "Set exactly one of postgres_external_password or postgres_password_secret_ref when create_database = false."
  }
}

variable "postgres_external_ssl_mode" {
  description = "TLS mode for the external PostgreSQL connection (`disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`). Ignored when `create_database = true` (use `postgres_managed_ssl_mode` instead)."
  type        = string
  default     = "require"

  validation {
    condition     = contains(["disable", "allow", "prefer", "require", "verify-ca", "verify-full"], var.postgres_external_ssl_mode)
    error_message = "postgres_external_ssl_mode must be one of: disable, allow, prefer, require, verify-ca, verify-full."
  }
}

variable "postgres_managed_ssl_mode" {
  description = "TLS mode for the module-managed PostgreSQL Flexible Server connection (`require`, `verify-ca`, `verify-full`). Ignored when `create_database = false` (use `postgres_external_ssl_mode` instead). Azure Database for PostgreSQL Flexible Server enforces TLS on every connection, so `disable`, `allow`, and `prefer` are rejected here, unlike on the external path. `verify-ca` and `verify-full` behave the same: n8n's PostgreSQL driver checks both the certificate chain and the server hostname in either mode. Both need a trusted CA: supply one with `postgres_ssl_ca_pem` unless the pod image's default trust store already trusts Microsoft's root CAs. See `docs/postgresql-tls.md`."
  type        = string
  default     = "require"

  validation {
    condition     = contains(["require", "verify-ca", "verify-full"], var.postgres_managed_ssl_mode)
    error_message = "postgres_managed_ssl_mode must be one of: require, verify-ca, verify-full."
  }
}

variable "postgres_ssl_ca_pem" {
  description = "PEM-encoded CA certificate bundle to trust for the PostgreSQL connection, covering both the managed and external database paths. When set and the effective `ssl_mode` (`postgres_managed_ssl_mode` or `postgres_external_ssl_mode`) is `verify-ca` or `verify-full`, the module stores it in a dedicated Kubernetes Secret, mounts it read-only at `/etc/n8n/postgres-ssl-ca` on main, worker, and webhook-processor pods, and points `DB_POSTGRESDB_SSL_CA_FILE` at the mounted file. Needed for `verify-ca`/`verify-full` unless the pod image's default trust store already trusts the server's issuing CA (for Azure Database for PostgreSQL Flexible Server, Microsoft recommends trusting both current roots: DigiCert Global Root G2 and Microsoft RSA Root CA 2017). In every other mode (`disable`, `allow`, `prefer`, `require`) the module ignores it and a plan-time warning fires. While set, `n8n_extra_volumes` may not use the volume name `postgres-ssl-ca` and `n8n_extra_volume_mounts` may not use the mount path `/etc/n8n/postgres-ssl-ca`. See `docs/postgresql-tls.md`."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.postgres_ssl_ca_pem == null ? true : length(trimspace(var.postgres_ssl_ca_pem)) > 0
    error_message = "postgres_ssl_ca_pem must be null or a non-empty PEM-encoded CA bundle."
  }

  validation {
    condition = var.postgres_ssl_ca_pem == null || alltrue([
      for volume in var.n8n_extra_volumes : volume.name != "postgres-ssl-ca"
    ])
    error_message = "postgres_ssl_ca_pem reserves the volume name \"postgres-ssl-ca\". Rename or remove the conflicting n8n_extra_volumes entry."
  }

  validation {
    condition = var.postgres_ssl_ca_pem == null || alltrue([
      for mount in var.n8n_extra_volume_mounts : mount.mount_path != "/etc/n8n/postgres-ssl-ca"
    ])
    error_message = "postgres_ssl_ca_pem reserves the mount path \"/etc/n8n/postgres-ssl-ca\". Move or remove the conflicting n8n_extra_volume_mounts entry."
  }
}

variable "postgres_pool_size" {
  description = "Number of TypeORM connection pool slots per n8n pod (writes `DB_POSTGRESDB_POOL_SIZE`). Applies to both the managed and external database paths. Each main, worker, and webhook-processor pod lazily opens up to this many connections against the same shared process pool used by application traffic and the health-check ping (see `postgres_ping_timeout_ms`) — it is not one permanently open connection per workflow. Budget the aggregate ceiling (pool_size * effective main + worker + webhook replica counts) against the database's or PgBouncer's own maximum-connection limit, not a fixed per-workflow ratio."
  type        = number
  default     = 10

  validation {
    condition     = var.postgres_pool_size >= 1
    error_message = "postgres_pool_size must be at least 1."
  }
}

variable "postgres_connection_timeout_ms" {
  description = "Milliseconds n8n waits to acquire a connection from the pool before failing (writes `DB_POSTGRESDB_CONNECTION_TIMEOUT`). Applies to both the managed and external database paths. Null (default) omits the environment variable and retains n8n's own pinned default (20000 ms). Zero disables the acquisition timeout entirely. This bounds pool-acquisition time alongside `postgres_ping_timeout_ms` — whichever active timeout expires first determines how long acquisition can take; raising this value does not resolve pool saturation, it only delays detection of it."
  type        = number
  default     = null

  validation {
    condition     = var.postgres_connection_timeout_ms == null ? true : (var.postgres_connection_timeout_ms == floor(var.postgres_connection_timeout_ms) && var.postgres_connection_timeout_ms >= 0 && var.postgres_connection_timeout_ms <= 2147483647)
    error_message = "postgres_connection_timeout_ms must be null or a whole number from 0 through 2147483647."
  }
}

variable "postgres_ping_timeout_ms" {
  description = "Milliseconds n8n waits for a database health-check ping to respond before marking the connection down (writes `DB_PING_TIMEOUT_MS`). Applies to both the managed and external database paths. Null (default) omits the environment variable and retains n8n's own pinned default (5000 ms). The ping acquires a connection from the same pool as application traffic, so this timeout and `postgres_connection_timeout_ms` both bound acquisition; whichever is active and shorter determines how long a stalled ping can take before failing."
  type        = number
  default     = null

  validation {
    condition     = var.postgres_ping_timeout_ms == null ? true : var.postgres_ping_timeout_ms > 0
    error_message = "postgres_ping_timeout_ms must be null or a positive number."
  }
}

variable "postgres_ping_interval_seconds" {
  description = "Seconds between database health-check pings (writes `DB_PING_INTERVAL_SECONDS`). Applies to both the managed and external database paths. Null (default) omits the environment variable and retains n8n's own pinned default (2 seconds)."
  type        = number
  default     = null

  validation {
    condition     = var.postgres_ping_interval_seconds == null ? true : var.postgres_ping_interval_seconds > 0
    error_message = "postgres_ping_interval_seconds must be null or a positive number."
  }
}

variable "postgres_ping_max_failures_before_recovery" {
  description = "Number of consecutive failed health-check pings before n8n begins pool-recovery handling (writes `DB_PING_MAX_FAILURES_BEFORE_RECOVERY`). Applies to both the managed and external database paths. Null (default) omits the environment variable and retains n8n's own pinned default (3). Raising this threshold does not stop the first failed ping from marking the connection down; it only changes when pool recovery starts."
  type        = number
  default     = null

  validation {
    condition     = var.postgres_ping_max_failures_before_recovery == null ? true : (var.postgres_ping_max_failures_before_recovery == floor(var.postgres_ping_max_failures_before_recovery) && var.postgres_ping_max_failures_before_recovery >= 1)
    error_message = "postgres_ping_max_failures_before_recovery must be null or a whole number of at least 1."
  }
}

variable "redis_subnet_id" {
  description = "Resource ID of the subnet the Azure Managed Redis private endpoint attaches to. Must have `private_endpoint_network_policies` disabled (Azure refuses to create a private endpoint when network policies are enforced on the subnet). No subnet delegation required. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.redis_subnet_id))
    error_message = "redis_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

# ── Redis topologies (align-azure-with-aws-capabilities section 4) ───────
# Mirrors the `create_database` / `postgres_external_*` shape (section 3)
# already established: `create_redis` gates the managed Azure Managed Redis
# path in redis.tf, and `redis_external_*` supplies the complete contract
# for an external Redis endpoint when it is false.

variable "create_redis" {
  description = "When true (the default), the module creates and manages a private Azure Managed Redis instance. Set to false to use an external Redis endpoint — `redis_external_host`, `redis_external_username` is optional, and `redis_external_password` must then be supplied. Kept as a static boolean rather than `redis_external_host == null` because `count` expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
}

variable "redis_sku_name" {
  description = "Azure Managed Redis SKU. Restricted to the SKUs documented at 25 GB or smaller — the size ceiling for the `NoCluster` clustering policy this module always uses (https://learn.microsoft.com/en-us/azure/redis/architecture#cluster-policies). Larger SKUs (`Balanced_B50` and up, `ComputeOptimized_X50` and up, `MemoryOptimized_M50` and up, all `FlashOptimized_*`) only support `OSSCluster` or `EnterpriseCluster` and are not offered here. Ignored when `create_redis = false`."
  type        = string
  default     = "Balanced_B1"

  validation {
    condition = contains([
      "Balanced_B0", "Balanced_B1", "Balanced_B3", "Balanced_B5", "Balanced_B10", "Balanced_B20",
      "ComputeOptimized_X3", "ComputeOptimized_X5", "ComputeOptimized_X10", "ComputeOptimized_X20",
      "MemoryOptimized_M10", "MemoryOptimized_M20",
    ], var.redis_sku_name)
    error_message = "redis_sku_name must be one of the Azure Managed Redis SKUs documented at 25 GB or smaller, the size ceiling for the NoCluster clustering policy this module uses: Balanced_B0, Balanced_B1, Balanced_B3, Balanced_B5, Balanced_B10, Balanced_B20, ComputeOptimized_X3, ComputeOptimized_X5, ComputeOptimized_X10, ComputeOptimized_X20, MemoryOptimized_M10, MemoryOptimized_M20. Larger SKUs support OSSCluster or EnterpriseCluster but not NoCluster."
  }
}

variable "redis_high_availability_enabled" {
  description = "Enable high availability (zone/replica redundancy) for the module-managed Azure Managed Redis instance. Changing this forces replacement of the instance (an Azure constraint on `high_availability_enabled`), which destroys and recreates the queue backend — drain the n8n queue before flipping this on a live deployment. Ignored when `create_redis = false`."
  type        = bool
  default     = false
}

variable "redis_eviction_policy" {
  description = "Redis eviction policy for the module-managed Azure Managed Redis instance's default_database. Defaults to NoEviction: n8n's Bull queue keys can carry a TTL, so any eviction policy other than NoEviction (including the azurerm provider's own VolatileLRU default) can silently drop in-flight queue jobs under memory pressure instead of rejecting the write with an OOM error. The azurerm provider changes this in place on the existing database, without replacing the instance. Deployments created before this input existed move from VolatileLRU to NoEviction on their next apply, so a full Redis then rejects writes instead of evicting keys; set VolatileLRU to keep the previous behavior. See docs/redis.md -> \"Eviction policy\". Ignored when `create_redis = false`; configure eviction on an external Redis yourself."
  type        = string
  default     = "NoEviction"

  validation {
    condition = contains([
      "AllKeysLFU", "AllKeysLRU", "AllKeysRandom",
      "VolatileLFU", "VolatileLRU", "VolatileRandom", "VolatileTTL",
      "NoEviction",
    ], var.redis_eviction_policy)
    error_message = "redis_eviction_policy must be one of the Azure Managed Redis eviction policies: AllKeysLFU, AllKeysLRU, AllKeysRandom, VolatileLFU, VolatileLRU, VolatileRandom, VolatileTTL, NoEviction."
  }
}

variable "redis_external_host" {
  description = "External Redis host. Required when `create_redis = false`. Ignored otherwise. Use this to point n8n and KEDA at an existing Redis deployment, a managed Redis in a different subscription, or any Redis-compatible endpoint."
  type        = string
  default     = null

  validation {
    condition     = var.create_redis || var.redis_external_host != null
    error_message = "redis_external_host is required when create_redis = false."
  }
}

variable "redis_external_port" {
  description = "External Redis port. Ignored when `create_redis = true` (the module-managed instance's port is read from the Managed Redis database resource)."
  type        = number
  default     = 6380

  validation {
    condition     = var.redis_external_port > 0 && var.redis_external_port <= 65535
    error_message = "redis_external_port must be between 1 and 65535."
  }
}

variable "redis_external_tls_enabled" {
  description = "Whether the external Redis endpoint requires TLS. Ignored when `create_redis = true` (the module-managed instance always uses `client_protocol = \"Encrypted\"`)."
  type        = bool
  default     = true
}

variable "redis_external_username" {
  description = "Username for the external Redis endpoint specified by `redis_external_host`, for deployments that use Redis 6+ ACL-based auth (`AUTH <username> <password>`). Optional — leave `null` for legacy `AUTH <password>`-only endpoints. Ignored when `create_redis = true` (the module-managed instance uses access-key authentication, which has no username)."
  type        = string
  default     = null
}

variable "redis_external_password" {
  description = "Password for the external Redis endpoint specified by `redis_external_host`. Optional — leave `null` to point at an unauthenticated external Redis (e.g. one that relies on network-level isolation instead of AUTH), or set `redis_password_secret_ref` instead. Ignored when `create_redis = true` (the module reads the generated primary access key from its managed Azure Managed Redis instance)."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = !(var.redis_external_password != null && var.redis_password_secret_ref != null)
    error_message = "Set at most one of redis_external_password or redis_password_secret_ref."
  }
}

# ── Private Azure Blob storage ───────────────────────────────────────────

variable "azure_blob_container_name" {
  description = "Name of the private Blob container used by n8n binary data and, when enabled, Azure execution-data storage. The default `n8n-data` is shared by both Azure storage features. Changing it does not migrate or backfill objects from the old container."
  type        = string
  default     = "n8n-data"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$", var.azure_blob_container_name))
    error_message = "azure_blob_container_name must be 3 to 63 lowercase letters, digits, or hyphens, starting and ending with a letter or digit."
  }
}

variable "azure_blob_connection_string" {
  description = "Optional Azure Blob connection string compatibility credential. Leave null (the default) to use AKS workload identity and DefaultAzureCredential. Mutually exclusive with azure_blob_account_key. Marked sensitive, but it still resides in Terraform state and is rendered into every n8n pod environment while an Azure storage mode is active or retained."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.azure_blob_connection_string == null ? true : trimspace(var.azure_blob_connection_string) != ""
    error_message = "azure_blob_connection_string must be null or a non-empty connection string."
  }
}

variable "azure_blob_account_key" {
  description = "Optional Azure Storage account key compatibility credential. Leave null (the default) to use AKS workload identity and DefaultAzureCredential. Mutually exclusive with azure_blob_connection_string. Marked sensitive, but it still resides in Terraform state and is rendered into every n8n pod environment while an Azure storage mode is active or retained."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.azure_blob_account_key == null ? true : trimspace(var.azure_blob_account_key) != ""
    error_message = "azure_blob_account_key must be null or a non-empty account key."
  }

  validation {
    condition     = var.azure_blob_account_key == null ? true : var.azure_blob_connection_string == null
    error_message = "Set at most one of azure_blob_account_key or azure_blob_connection_string. Leave both null to use managed identity and DefaultAzureCredential."
  }
}

variable "azure_blob_endpoint" {
  description = "Optional custom Azure Blob service endpoint, including scheme (for example `https://account.blob.core.usgovcloudapi.net`). Leave null to use the module-managed storage account's primary Blob endpoint. Endpoint support is a compatibility hook and does not certify the module for sovereign clouds. Marked sensitive to keep private custom hostnames out of plan output."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.azure_blob_endpoint == null ? true : can(regex("^https://[^[:space:]]+/$", var.azure_blob_endpoint))
    error_message = "azure_blob_endpoint must be null or an HTTPS service endpoint ending in `/` with no whitespace (for example https://account.blob.core.windows.net/)."
  }
}

variable "azure_blob_binary_retention_days" {
  description = "Optional number of days after last modification before Azure deletes blobs from a binary-only managed container. Null (the default) creates no lifecycle rule. The module omits the rule and warns when azure_blob_container_stores_execution_data is true because n8n owns execution-data pruning and broad Azure expiry can delete bundles n8n still references."
  type        = number
  default     = null

  validation {
    condition = var.azure_blob_binary_retention_days == null ? true : (
      var.azure_blob_binary_retention_days >= 1 &&
      var.azure_blob_binary_retention_days <= 99999 &&
      var.azure_blob_binary_retention_days == floor(var.azure_blob_binary_retention_days)
    )
    error_message = "azure_blob_binary_retention_days must be null or a whole number between 1 and 99999."
  }
}

# no validation: a plain bool needs no extra check.
variable "azure_blob_container_stores_execution_data" {
  description = "Whether the managed Blob container stores current or historical n8n execution-data bundles. Set true before selecting Azure execution-data storage so the module omits binary lifecycle expiry. Keep it true after switching execution writes away from Azure until all retained Azure bundles have been pruned or migrated. n8n owns execution-data pruning; current object paths cannot scope an Azure lifecycle filter to binary objects without also reaching execution bundles."
  type        = bool
  default     = false
}

variable "storage_account_replication_type" {
  description = "Replication type for the module-managed StorageV2 account used by Azure Blob: LRS, ZRS, GRS, RAGRS, GZRS, or RAGZRS. The default LRS minimizes cost; production deployments that need zone or regional durability should select a replication type available in their Azure region."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.storage_account_replication_type)
    error_message = "storage_account_replication_type must be one of: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "blob_delete_retention_days" {
  description = "Optional soft-delete retention window, in days, for the module-managed Blob storage account (blob_properties.delete_retention_policy and container_delete_retention_policy). Null (the default) renders no blob_properties block, so a freshly created account keeps soft delete disabled, matching the account's behavior before this input existed: a deleted blob or container is immediately unrecoverable, closer to AWS S3's force_destroy = true than false, since Azure Blob has no separate force_destroy-style guard on terraform destroy. Setting a value is a one-way switch from Terraform's side: azurerm treats blob_properties as Optional+Computed, so changing this back to null after an apply plans no change and soft delete stays enabled at the last applied window; disable it out of band (az storage account blob-service-properties update --enable-delete-retention false --enable-container-delete-retention false) if that is what you want. This is the nearest Azure analog to AWS's s3_force_destroy (port-aws-050-enhancements); see docs/deletion-safety.md for how the AWS RDS deletion-time controls map onto PostgreSQL Flexible Server. Ignored when create_blob_storage = false."
  type        = number
  default     = null

  validation {
    condition     = var.blob_delete_retention_days == null || (var.blob_delete_retention_days >= 1 && var.blob_delete_retention_days <= 365 && var.blob_delete_retention_days == floor(var.blob_delete_retention_days))
    error_message = "blob_delete_retention_days must be a whole number from 1 through 365 (the Azure Blob soft-delete retention bounds), or null to leave soft delete disabled."
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

# ── Application Gateway ingress ──────────────────────────────────────────

variable "create_ingress" {
  description = "Create the module-managed Application Gateway, AGIC addon integration, Kubernetes Ingress, and eligible application DNS records. True by default. Set false for caller-owned routing such as split public-webhook and internal-admin gateways; AKS, n8n Services, and service-discovery outputs remain available. Must be false when create_aks = false — the module cannot manage the AGIC addon or Application Gateway on an AKS cluster it does not own."
  type        = bool
  default     = true

  validation {
    condition     = var.create_aks || !var.create_ingress
    error_message = "create_ingress must be false when create_aks = false. The module cannot manage AGIC or Application Gateway on an existing AKS cluster; route the exported n8n service coordinates through an existing ingress controller instead."
  }
}

variable "appgw_frontend_mode" {
  description = "Frontend exposure for the module-managed Application Gateway: public creates a static Standard public IP, while internal creates only a dynamically allocated private frontend in appgw_subnet_id. Ignored when create_ingress is false."
  type        = string
  default     = "public"
  nullable    = false

  validation {
    condition     = contains(["public", "internal"], var.appgw_frontend_mode)
    error_message = "appgw_frontend_mode must be either public or internal."
  }
}

variable "appgw_sku_name" {
  description = "Application Gateway v2 SKU. WAF_v2 creates or attaches a WAF policy; Standard_v2 omits WAF. v1 SKUs are unsupported. Ignored when create_ingress is false."
  type        = string
  default     = "WAF_v2"
  nullable    = false

  validation {
    condition     = contains(["WAF_v2", "Standard_v2"], var.appgw_sku_name)
    error_message = "appgw_sku_name must be one of: WAF_v2, Standard_v2."
  }
}

variable "appgw_capacity" {
  description = "Fixed Application Gateway instance count used when appgw_autoscaling_enabled is false. Azure Application Gateway v2 supports 1 through 125 instances. Ignored when autoscaling or create_ingress is disabled."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.appgw_capacity >= 1 && var.appgw_capacity <= 125 && var.appgw_capacity == floor(var.appgw_capacity)
    error_message = "appgw_capacity must be a whole number between 1 and 125."
  }
}

variable "appgw_autoscaling_enabled" {
  description = "Use Application Gateway autoscaling instead of fixed appgw_capacity. The autoscaler remains within appgw_autoscale_min_capacity and appgw_autoscale_max_capacity. Ignored when create_ingress is false."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

variable "appgw_autoscale_min_capacity" {
  description = "Minimum Application Gateway instances when autoscaling is enabled. Azure permits zero for scale-to-zero, but the default of 2 keeps redundant warm capacity. Ignored when autoscaling or create_ingress is disabled."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.appgw_autoscale_min_capacity >= 0 && var.appgw_autoscale_min_capacity <= 125 && var.appgw_autoscale_min_capacity == floor(var.appgw_autoscale_min_capacity)
    error_message = "appgw_autoscale_min_capacity must be a whole number between 0 and 125."
  }

  validation {
    condition     = var.appgw_autoscale_min_capacity > var.appgw_autoscale_max_capacity ? false : true
    error_message = "appgw_autoscale_min_capacity must not exceed appgw_autoscale_max_capacity."
  }
}

variable "appgw_autoscale_max_capacity" {
  description = "Maximum Application Gateway instances when autoscaling is enabled. Ignored when autoscaling or create_ingress is disabled."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.appgw_autoscale_max_capacity >= 2 && var.appgw_autoscale_max_capacity <= 125 && var.appgw_autoscale_max_capacity == floor(var.appgw_autoscale_max_capacity)
    error_message = "appgw_autoscale_max_capacity must be a whole number between 2 and 125."
  }
}

variable "appgw_ssl_policy" {
  description = "Predefined Application Gateway TLS policy for HTTPS listeners. The default AppGwSslPolicy20220101S requires TLS 1.2 or later and uses the stricter curated cipher set. Ignored when create_ingress is false."
  type        = string
  default     = "AppGwSslPolicy20220101S"
  nullable    = false

  validation {
    condition     = contains(["AppGwSslPolicy20220101", "AppGwSslPolicy20220101S"], var.appgw_ssl_policy)
    error_message = "appgw_ssl_policy must be AppGwSslPolicy20220101 or the stricter AppGwSslPolicy20220101S. Both require TLS 1.2 or later."
  }
}

variable "appgw_waf_mode" {
  description = "Mode for the module-managed WAF_v2 policy: Detection logs rule matches, while Prevention blocks them. Ignored for Standard_v2, caller-supplied appgw_waf_policy_id, or disabled ingress."
  type        = string
  default     = "Detection"
  nullable    = false

  validation {
    condition     = contains(["Detection", "Prevention"], var.appgw_waf_mode)
    error_message = "appgw_waf_mode must be either Detection or Prevention."
  }
}

variable "appgw_waf_policy_id" {
  description = "Optional resource ID of an existing Application Gateway WAF policy. When null with WAF_v2, the module creates an OWASP 3.2 policy using appgw_waf_mode. Supplying an ID delegates rule and mode management to the caller. Must remain null with Standard_v2."
  type        = string
  default     = null

  validation {
    condition = var.appgw_waf_policy_id == null ? true : can(regex(
      "^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/applicationGatewayWebApplicationFirewallPolicies/.+$",
      var.appgw_waf_policy_id,
    ))
    error_message = "appgw_waf_policy_id must be null or a fully qualified Application Gateway WAF policy resource ID."
  }

  validation {
    condition     = var.appgw_waf_policy_id == null ? true : var.appgw_sku_name == "WAF_v2"
    error_message = "appgw_waf_policy_id requires appgw_sku_name = WAF_v2."
  }
}

variable "appgw_allowed_inbound_cidrs" {
  description = "IPv4 network CIDRs allowed to reach ports 80 and 443 on the module-managed Application Gateway subnet. Empty allows Internet traffic. Restrictions cover the editor and every webhook path, so third-party webhooks outside the list will fail. GatewayManager control traffic and AzureLoadBalancer health probes remain explicitly allowed. Ignored when create_ingress is false."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for cidr in var.appgw_allowed_inbound_cidrs :
      can(cidrnetmask(cidr)) ? !strcontains(cidr, ":") : false
    ])
    error_message = "Every appgw_allowed_inbound_cidrs entry must be a valid IPv4 CIDR block, such as 203.0.113.0/24 or 198.51.100.7/32."
  }

  validation {
    condition = alltrue([
      for cidr in var.appgw_allowed_inbound_cidrs :
      can(cidrhost(cidr, 0)) ? cidrhost(cidr, 0) == split("/", cidr)[0] : false
    ])
    error_message = "Every appgw_allowed_inbound_cidrs entry must use the network address of its block. Use /32 for one IPv4 address."
  }
}

variable "ingress_annotations" {
  description = "Additional annotations for the module-managed AGIC Ingress, merged over module defaults. Use this for AGIC features such as rewrite rule sets. Overrides of module-owned TLS, frontend, backend, draining, timeout, or affinity annotations emit a warning because the caller value wins. Ignored when create_ingress is false."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition     = alltrue([for key, value in var.ingress_annotations : trimspace(key) != "" && trimspace(value) != ""])
    error_message = "ingress_annotations keys and values must be non-empty strings."
  }
}

# ── Application DNS ──────────────────────────────────────────────────────
# Supply at most one Azure DNS zone ID. The selected zone must match the
# Application Gateway frontend type and contain the canonical and additional
# hosts. Record targets are derived from the matching managed frontend, so no
# caller-supplied IP can drift from the gateway.

variable "create_public_dns_record" {
  description = "Create public Azure DNS A records for every managed ingress host. Requires create_ingress = true, appgw_frontend_mode = public, and public_dns_zone_id. Mutually exclusive with create_private_dns_record. The explicit toggle remains plan-known when public_dns_zone_id comes from an Azure DNS zone created in the caller's same apply."
  type        = bool
  default     = false

  validation {
    condition     = var.create_public_dns_record ? !var.create_private_dns_record : true
    error_message = "Set at most one of create_public_dns_record or create_private_dns_record."
  }
}

variable "create_private_dns_record" {
  description = "Create private Azure DNS A records for every managed ingress host. Requires create_ingress = true, appgw_frontend_mode = internal, and private_dns_zone_id. Mutually exclusive with create_public_dns_record. The explicit toggle remains plan-known when private_dns_zone_id comes from an Azure private DNS zone created in the caller's same apply."
  type        = bool
  default     = false

  # no validation: pairing, mutual-exclusion, and frontend validation live on
  # the corresponding zone ID and create_public_dns_record declarations.
}

variable "public_dns_zone_id" {
  description = "Resource ID of an existing public Azure DNS zone used when create_public_dns_record is true. The module creates one A record for n8n_domain and every n8n_additional_domains entry, targeting the managed static public IP. Every hostname must be the zone apex or a subdomain of this zone. Leave null when public DNS is caller-owned."
  type        = string
  default     = null

  validation {
    condition     = var.public_dns_zone_id == null ? true : can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/dnsZones/[^/]+$", var.public_dns_zone_id))
    error_message = "public_dns_zone_id must be null or a fully qualified public Azure DNS zone resource ID."
  }

  validation {
    condition     = var.create_public_dns_record ? var.public_dns_zone_id != null : var.public_dns_zone_id == null
    error_message = "Set public_dns_zone_id if and only if create_public_dns_record is true."
  }

  validation {
    condition     = var.public_dns_zone_id == null ? true : var.appgw_frontend_mode == "public"
    error_message = "create_public_dns_record requires appgw_frontend_mode = public so records have a public Application Gateway target."
  }

  validation {
    condition = var.public_dns_zone_id == null ? true : alltrue([
      for domain in concat([var.n8n_domain], var.n8n_additional_domains) :
      lower(domain) == lower(reverse(split("/", var.public_dns_zone_id))[0]) ||
      endswith(lower(domain), ".${lower(reverse(split("/", var.public_dns_zone_id))[0])}")
    ])
    error_message = "n8n_domain and every n8n_additional_domains entry must be the public DNS zone apex or a subdomain of public_dns_zone_id."
  }
}

variable "private_dns_zone_id" {
  description = "Resource ID of an existing private Azure DNS zone used when create_private_dns_record is true. The module creates one A record for n8n_domain and every n8n_additional_domains entry, targeting the managed private frontend IP. Every hostname must be the zone apex or a subdomain of this zone. Leave null when private DNS is caller-owned."
  type        = string
  default     = null

  validation {
    condition     = var.private_dns_zone_id == null ? true : can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Network/privateDnsZones/[^/]+$", var.private_dns_zone_id))
    error_message = "private_dns_zone_id must be null or a fully qualified private Azure DNS zone resource ID."
  }

  validation {
    condition     = var.create_private_dns_record ? var.private_dns_zone_id != null : var.private_dns_zone_id == null
    error_message = "Set private_dns_zone_id if and only if create_private_dns_record is true."
  }

  validation {
    condition     = var.private_dns_zone_id == null ? true : var.appgw_frontend_mode == "internal"
    error_message = "create_private_dns_record requires appgw_frontend_mode = internal so records have a private Application Gateway target."
  }

  validation {
    condition = var.private_dns_zone_id == null ? true : alltrue([
      for domain in concat([var.n8n_domain], var.n8n_additional_domains) :
      lower(domain) == lower(reverse(split("/", var.private_dns_zone_id))[0]) ||
      endswith(lower(domain), ".${lower(reverse(split("/", var.private_dns_zone_id))[0])}")
    ])
    error_message = "n8n_domain and every n8n_additional_domains entry must be the private DNS zone apex or a subdomain of private_dns_zone_id."
  }
}

# ── Binary and execution-data storage modes ───────────────────────────────

variable "n8n_binary_data_storage_mode" {
  description = "Where n8n writes new binary data. `azure` (the default) writes to the private module-managed Blob container and requires the separate `feat:binaryDataAz` Enterprise entitlement. `database` stores binary data in PostgreSQL and is the durable queue-mode fallback when that entitlement is unavailable. 0.1.0 does not support the inline-memory `default` mode or a shared-filesystem mode. Changing this value does not move existing objects; n8n reads each object from the backend recorded in its ID, so when moving writes from azure to database set azure_blob_retain_read_access = true until the Azure objects expire or are migrated."
  type        = string
  default     = "azure"
  nullable    = false

  validation {
    condition     = contains(["database", "azure"], var.n8n_binary_data_storage_mode)
    error_message = "n8n_binary_data_storage_mode must be either database or azure. 0.1.0 does not support the inline-memory default mode or filesystem."
  }
}

variable "azure_blob_retain_read_access" {
  description = "Keep the Azure Blob connection settings and the workload identity's Blob role assignment in place when neither n8n_binary_data_storage_mode nor n8n_execution_data_storage_mode is azure, so n8n can still read objects it wrote to Azure before writes moved to database. n8n selects the backend per object from the ID it stored, so no n8n-side mode list is needed. Leave false for a deployment that never wrote to Azure; clearing it while retained Azure objects are still referenced makes them unreadable."
  type        = bool
  default     = false
  nullable    = false

  # no validation: a plain bool needs no additional constraint.
}

# Tombstone: read only by its own validation, which is the point. Delete this
# variable, the ignore, and its two tests in the release after next.
# tflint-ignore: terraform_unused_declarations
variable "n8n_available_binary_data_modes" {
  description = "Removed after 0.1.0. Must stay null; kept for one release only so a configuration that still sets it fails with migration guidance instead of a bare \"Unsupported argument\" error. n8n 2.x never reads N8N_AVAILABLE_BINARY_DATA_MODES, which this input rendered. If the list contained azure and neither n8n_binary_data_storage_mode nor n8n_execution_data_storage_mode is azure, set azure_blob_retain_read_access = true in the same change, or the Azure connection (and, with workload-identity authentication, the Blob role assignment) is removed and n8n can no longer read the retained Azure objects."
  type        = list(string)
  default     = null

  validation {
    condition     = var.n8n_available_binary_data_modes == null
    error_message = "n8n_available_binary_data_modes was removed after 0.1.0: n8n 2.x never reads N8N_AVAILABLE_BINARY_DATA_MODES. Delete the argument. If it contained \"azure\" and neither n8n_binary_data_storage_mode nor n8n_execution_data_storage_mode is \"azure\", also set azure_blob_retain_read_access = true, or n8n loses access to the objects it wrote to Azure. See the CHANGELOG and docs/data-storage.md."
  }
}

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n writes each new execution bundle. `database` (the default) keeps data in PostgreSQL. `azure` writes to the managed Blob container, requires azure_blob_container_stores_execution_data = true, and requires the separate `feat:executionDataAz` Enterprise entitlement. 0.1.0 does not support a shared-filesystem mode. Mode changes do not backfill data; n8n records each execution's backend and continues reading historical data while that backend and its credentials remain available."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = contains(["database", "azure"], var.n8n_execution_data_storage_mode)
    error_message = "n8n_execution_data_storage_mode must be either database or azure. 0.1.0 does not support filesystem."
  }

  validation {
    condition     = var.n8n_execution_data_storage_mode == "azure" ? var.azure_blob_container_stores_execution_data : true
    error_message = "n8n_execution_data_storage_mode = azure requires azure_blob_container_stores_execution_data = true so the module cannot apply binary lifecycle expiry to execution bundles that n8n still references."
  }
}

variable "private_endpoint_subnet_id" {
  description = "Resource ID of the subnet additional private endpoints (Storage Account, Key Vault) attach to. Must have `private_endpoint_network_policies` disabled (Azure refuses to create a private endpoint when network policies are enforced on the subnet). May be the same as `redis_subnet_id` when callers prefer to consolidate all PEs onto a single subnet, but a dedicated subnet keeps blast-radius smaller. Format: /subscriptions/<sub>/.../subnets/<name>."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/.+/subnets/.+$", var.private_endpoint_subnet_id))
    error_message = "private_endpoint_subnet_id must be a fully qualified Azure subnet resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>)."
  }
}

# ── Controllers and base n8n release ─────────────────────────────────────

variable "keda_chart_version" {
  description = "KEDA Helm chart version from the official kedacore repository. Pinning the controller keeps the CRD shape used by the root kubectl_manifest deterministic."
  type        = string
  default     = "2.15.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-.+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be a semantic version such as 2.15.0 or 2.15.0-rc1."
  }
}

variable "n8n_chart_version" {
  description = "n8n Helm chart version from oci://ghcr.io/n8n-io/n8n-helm-chart. The default 1.14.0 matches the AWS sibling's pin. Functional changes since 1.11.0 that reach this module: the worker Deployment no longer renders spec.replicas once KEDA owns it (chart #201; this module always enables KEDA for workers, so the ScaledObject is the sole owner, and the first upgrade from an older chart resets the worker count to 1, terminating any surplus worker pods, until the HPA restores the floor), main pods lose the task-runner sidecar in queue mode because n8n offloads manual executions to workers (chart #179), and keda.worker.pause / pausedReplicaCount are usable (added in chart 1.12.0 by #177, reliable only from 1.13.0; see n8n_worker_keda_pause). Inert here: the chart's image.tag default moving from a floating stable tag to its appVersion (this module always sets n8n_image_tag), the webhook-processor KEDA pause (this module scales webhook processors with its own HPA in scaling.tf, not the chart's ScaledObject), and 1.14.0's WEBHOOK_URL to N8N_WEBHOOK_URL rename (chart #184), S3-only N8N_AVAILABLE_BINARY_DATA_MODES removal (chart #185), and aggregated values-validation errors (chart #209): this module sets neither webhook.url nor ingress nor s3 and renders its own N8N_WEBHOOK_URL."
  type        = string
  default     = "1.14.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-.+)?$", var.n8n_chart_version))
    error_message = "n8n_chart_version must be a semantic version such as 1.10.0 or 1.10.0-rc1."
  }
}

variable "n8n_helm_timeout" {
  description = "Seconds Terraform waits for the n8n Helm release to converge. Increase this for large deployments whose rolling update cannot finish within the 600-second default."
  type        = number
  default     = 600

  validation {
    condition     = var.n8n_helm_timeout >= 60 && var.n8n_helm_timeout == floor(var.n8n_helm_timeout)
    error_message = "n8n_helm_timeout must be a whole number of at least 60 seconds."
  }
}

variable "n8n_image_tag" {
  description = "Pinned n8n application version used by the main, worker, webhook-processor, and task-runner images. Azure Blob binary and execution-data modes require n8n 2.29.0 or later. Environment-managed log streaming requires n8n 2.19.0 or later. n8n_worker_pools (early alpha) requires n8n 2.39.0 or later. The default 2.35.0 includes the Azure container-scoped credential startup probe fix."
  type        = string
  default     = "2.35.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9._-]+)?$", var.n8n_image_tag))
    error_message = "n8n_image_tag must start with a semantic application version such as 2.35.0 or 2.35.0-custom."
  }

  validation {
    condition = !can(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)) ? true : (
      local.n8n_azure_storage_enabled ? (
        tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[0]) > 2 ? true : (
          tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[0]) == 2 ? (
            tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[1]) >= 29
          ) : false
        )
      ) : true
    )
    error_message = "n8n_image_tag must be 2.29.0 or later when a binary or execution-data mode is azure or azure_blob_retain_read_access is true."
  }

  validation {
    condition = !can(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)) ? true : (
      var.n8n_log_streaming_managed_by_env ? (
        tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[0]) > 2 ? true : (
          tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[0]) == 2 ? (
            tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[1]) >= 19
          ) : false
        )
      ) : true
    )
    error_message = "n8n_log_streaming_managed_by_env requires n8n_image_tag 2.19.0 or later."
  }

  validation {
    # Worker pools (worker-pools.tf, EARLY ALPHA). A hard stop like the two
    # floors above rather than an advisory check: an older image accepts and
    # ignores N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME, so pool
    # workers come up healthy while consuming the default queue and every
    # pool queue stays empty. Not a no-op, but wrong capacity.
    condition = !can(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)) ? true : (
      length(var.n8n_worker_pools) > 0 ? (
        tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[0]) > 2 ? true : (
          tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[0]) == 2 ? (
            tonumber(regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag)[1]) >= local.n8n_worker_pools_min_n8n_minor
          ) : false
        )
      ) : true
    )
    error_message = "n8n_worker_pools requires n8n_image_tag 2.${local.n8n_worker_pools_min_n8n_minor}.0 or later, the first n8n release that reads N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME. Older images accept both variables and ignore them: mains never route to a pool and pool workers consume the default queue, so the pods come up healthy while every pool queue stays empty. Pin n8n_image_tag to 2.${local.n8n_worker_pools_min_n8n_minor}.0 or later, or remove the pools."
  }
}

variable "n8n_image_repository" {
  description = "Optional container image repository for every n8n application pod, without a tag or digest. Null uses the chart default docker.n8n.io/n8nio/n8n. Use n8n_image_tag for the application tag. Private registries can use existing dockerconfigjson Secrets named by n8n_image_pull_secrets; this module accepts Secret names only and never registry credentials."
  type        = string
  default     = null

  validation {
    condition = var.n8n_image_repository == null ? true : (
      length(var.n8n_image_repository) <= 255 &&
      can(regex("^(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?/)?[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*)*$", var.n8n_image_repository))
    )
    error_message = "n8n_image_repository must be a bare Docker repository reference with no scheme, whitespace, tag, digest, uppercase path component, or empty path component, such as registry.internal:5000/n8n or n8nio/n8n."
  }

  validation {
    condition     = var.n8n_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_image_repository))[0]))
    error_message = "n8n_image_repository must not include a tag or digest because the chart appends n8n_image_tag."
  }
}

variable "n8n_image_pull_secrets" {
  description = "Names of existing kubernetes.io/dockerconfigjson Secrets in the n8n namespace. The module attaches these names to a module-managed service account when a private custom image needs registry authentication. Callers create and rotate the Secrets; registry credentials never enter this module's inputs or Terraform state through this contract."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for name in var.n8n_image_pull_secrets :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", name))
    ])
    error_message = "Every n8n_image_pull_secrets entry must be a DNS-1123 subdomain, such as registry-creds. Pass each Secret name, not its contents."
  }

  validation {
    condition     = alltrue([for name in var.n8n_image_pull_secrets : length(name) <= 253])
    error_message = "Every n8n_image_pull_secrets entry must be 253 characters or fewer."
  }

  validation {
    condition     = alltrue([for name in var.n8n_image_pull_secrets : alltrue([for label in split(".", name) : length(label) <= 63])])
    error_message = "Every dot-separated label in an n8n_image_pull_secrets entry must be 63 characters or fewer. This module-side limit is stricter than the Kubernetes API's own Secret-name check, which caps only the total length at 253 characters."
  }

  validation {
    condition     = length(distinct(var.n8n_image_pull_secrets)) == length(var.n8n_image_pull_secrets)
    error_message = "n8n_image_pull_secrets must not contain duplicate Secret names."
  }
}

variable "n8n_helm_post_install_settle_seconds" {
  description = "Seconds to wait after the n8n Helm release converges before downstream ingress resources reconcile."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_helm_post_install_settle_seconds >= 30 && var.n8n_helm_post_install_settle_seconds <= 600
    error_message = "n8n_helm_post_install_settle_seconds must be between 30 and 600 inclusive."
  }
}

# ── n8n runtime and resource controls ────────────────────────────────────

variable "n8n_timezone" {
  description = "Timezone used by n8n for schedules and date handling, such as UTC, America/New_York, or Europe/London."
  type        = string
  default     = "UTC"

  validation {
    condition     = trimspace(var.n8n_timezone) != "" && !can(regex("[[:space:]]", var.n8n_timezone))
    error_message = "n8n_timezone must be a non-empty timezone name with no whitespace, such as UTC or Europe/London."
  }
}

variable "n8n_log_level" {
  description = "n8n log level written to N8N_LOG_LEVEL."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["silent", "error", "warn", "info", "debug", "verbose"], var.n8n_log_level)
    error_message = "n8n_log_level must be one of: silent, error, warn, info, debug, verbose."
  }
}

variable "n8n_log_output" {
  description = "Comma-separated n8n log destinations written to N8N_LOG_OUTPUT. Each destination must be console or file. This selects destinations, not log format."
  type        = string
  default     = "console"

  validation {
    condition = (
      alltrue([for destination in split(",", var.n8n_log_output) : contains(["console", "file"], trimspace(destination))]) &&
      length(distinct([for destination in split(",", var.n8n_log_output) : trimspace(destination)])) == length(split(",", var.n8n_log_output))
    )
    error_message = "n8n_log_output must be a comma-separated set of console and file with no duplicates, such as console or console,file."
  }
}

# ── Metrics, tracing, and Enterprise log streaming ───────────────────────

variable "n8n_metrics_enabled" {
  description = "Enable n8n's built-in Prometheus endpoint at /metrics on port 5678 for every n8n process. The module sets N8N_METRICS=true but does not install Prometheus, a ServiceMonitor, Grafana, or a log shipper. Disabled by default, in which case the environment variable is omitted."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_otel_enabled" {
  description = "Enable OpenTelemetry workflow and node tracing on main, worker, and webhook processes. The module sets N8N_OTEL_ENABLED=true but does not deploy an OTLP collector or tracing backend. Disabled by default, in which case every N8N_OTEL_* variable is omitted."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_otel_exporter_otlp_endpoint" {
  description = "Optional base URL of the OTLP HTTP collector, such as http://otel-collector.observability.svc.cluster.local:4318. n8n appends /v1/traces. Ignored when n8n_otel_enabled is false."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_otel_exporter_otlp_endpoint == null ? true : can(regex("^https?://[^[:space:]]+[^/]$", var.n8n_otel_exporter_otlp_endpoint))
    error_message = "n8n_otel_exporter_otlp_endpoint must be null or an HTTP(S) base URL with no whitespace or trailing slash; n8n appends /v1/traces."
  }
}

variable "n8n_otel_exporter_otlp_headers" {
  description = "Optional comma-separated key=value headers sent to the OTLP collector. Marked sensitive, but the literal remains in Terraform state and the pod environment because the chart's shared config.extraEnv contract does not support secretKeyRef. Ignored when n8n_otel_enabled is false."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.n8n_otel_exporter_otlp_headers == null ? true : trimspace(var.n8n_otel_exporter_otlp_headers) != ""
    error_message = "n8n_otel_exporter_otlp_headers must be null or a non-empty comma-separated key=value string."
  }
}

variable "n8n_otel_exporter_service_name" {
  description = "Optional OpenTelemetry service.name value used to distinguish this deployment in a shared collector. Null keeps n8n's default. Ignored when n8n_otel_enabled is false."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_otel_exporter_service_name == null ? true : trimspace(var.n8n_otel_exporter_service_name) != ""
    error_message = "n8n_otel_exporter_service_name must be null or a non-empty string."
  }
}

variable "n8n_otel_traces_sample_rate" {
  description = "Optional fraction of traces to export, from 0 through 1. Null keeps n8n's default of 1.0. Ignored when n8n_otel_enabled is false."
  type        = number
  default     = null

  validation {
    condition = var.n8n_otel_traces_sample_rate == null ? true : (
      var.n8n_otel_traces_sample_rate >= 0 && var.n8n_otel_traces_sample_rate <= 1
    )
    error_message = "n8n_otel_traces_sample_rate must be null or between 0 and 1 inclusive."
  }
}

variable "n8n_otel_traces_include_node_spans" {
  description = "Whether to emit a node.execute span for each node. Null keeps n8n's default true. Ignored when n8n_otel_enabled is false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_inject_outbound" {
  description = "Whether supported nodes inject W3C trace context into outbound requests. Null keeps n8n's default true. Ignored when n8n_otel_enabled is false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_production_only" {
  description = "Whether to trace production executions only. Null keeps n8n's default true. Ignored when n8n_otel_enabled is false."
  type        = bool
  default     = null
}

variable "n8n_log_streaming_managed_by_env" {
  description = "Manage Enterprise log-streaming destinations from environment variables. When true, n8n reapplies n8n_log_streaming_destinations on every startup and makes the Log Streaming UI read-only. Requires n8n 2.19.0 or later and the log-streaming Enterprise entitlement. False leaves destinations UI-managed and emits no N8N_LOG_STREAMING_* variables."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_log_streaming_destinations" {
  description = "Typed webhook, syslog, or Sentry log-streaming destinations JSON-encoded into N8N_LOG_STREAMING_DESTINATIONS. Field names match n8n's environment-managed destination schema. Marked sensitive because headers, TLS material, and DSNs can carry credentials, but the rendered JSON remains in Terraform state and pod environments. Ignored when n8n_log_streaming_managed_by_env is false."
  type = list(object({
    type                   = string
    label                  = optional(string)
    enabled                = optional(bool)
    subscribedEvents       = optional(list(string))
    anonymizeAuditMessages = optional(bool)
    circuitBreaker = optional(object({
      maxFailures   = number
      failureWindow = number
    }))
    url          = optional(string)
    method       = optional(string)
    sendQuery    = optional(bool)
    specifyQuery = optional(string)
    queryParameters = optional(object({
      parameters = list(object({ name = string, value = string }))
    }))
    jsonQuery      = optional(string)
    sendHeaders    = optional(bool)
    specifyHeaders = optional(string)
    headerParameters = optional(object({
      parameters = list(object({ name = string, value = string }))
    }))
    jsonHeaders = optional(string)
    host        = optional(string)
    port        = optional(number)
    protocol    = optional(string)
    tlsCa       = optional(string)
    facility    = optional(number)
    app_name    = optional(string)
    dsn         = optional(string)
  }))
  default   = []
  nullable  = false
  sensitive = true

  validation {
    condition     = alltrue([for destination in var.n8n_log_streaming_destinations : contains(["webhook", "syslog", "sentry"], destination.type)])
    error_message = "Every n8n_log_streaming_destinations entry must set type to webhook, syslog, or sentry."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations :
      destination.type == "webhook" ? destination.url != null : (
        destination.type == "syslog" ? destination.host != null : destination.dsn != null
      )
    ])
    error_message = "Webhook destinations require url, syslog destinations require host, and Sentry destinations require dsn."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations :
      destination.url == null ? true : can(regex("^https?://[^[:space:]]+$", destination.url))
    ])
    error_message = "Every webhook destination url must be an HTTP(S) URL with no whitespace."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations :
      destination.method == null ? true : contains(["GET", "POST", "PUT"], destination.method)
    ])
    error_message = "Every webhook destination method must be GET, POST, or PUT."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations :
      destination.protocol == null ? true : contains(["udp", "tcp", "tls"], destination.protocol)
    ])
    error_message = "Every syslog destination protocol must be udp, tcp, or tls."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations :
      destination.port == null ? true : destination.port >= 1 && destination.port <= 65535 && destination.port == floor(destination.port)
    ])
    error_message = "Every syslog destination port must be a whole number between 1 and 65535."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations :
      destination.facility == null ? true : contains(concat([0, 1, 3, 13, 14], range(16, 24)), destination.facility)
    ])
    error_message = "Every syslog destination facility must be one of 0, 1, 3, 13, 14, or 16 through 23."
  }

  validation {
    condition = alltrue([
      for destination in var.n8n_log_streaming_destinations : destination.circuitBreaker == null ? true : (
        destination.circuitBreaker.maxFailures >= 1 &&
        destination.circuitBreaker.maxFailures == floor(destination.circuitBreaker.maxFailures) &&
        destination.circuitBreaker.failureWindow >= 100 &&
        destination.circuitBreaker.failureWindow == floor(destination.circuitBreaker.failureWindow)
      )
    ])
    error_message = "Every circuitBreaker must use a positive whole maxFailures and a whole failureWindow of at least 100 milliseconds."
  }
}

# Kubernetes CPU quantities use decimal cores or millicores. The module keeps
# the accepted input deliberately narrow so malformed values fail before the
# Helm release reaches Kubernetes.
variable "n8n_main_cpu_request" {
  description = "CPU request for each n8n main container, such as 1000m or 1. Included in the advisory capacity model at n8n_main_hpa_max_replicas."
  type        = string
  default     = "1000m"
  nullable    = false

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_main_cpu_request))
    error_message = "n8n_main_cpu_request must be a positive Kubernetes CPU quantity in cores or millicores, such as 1, 0.5, or 500m."
  }
}

variable "n8n_main_cpu_limit" {
  description = "CPU limit for each n8n main container, such as 2000m or 2."
  type        = string
  default     = "2000m"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_main_cpu_limit))
    error_message = "n8n_main_cpu_limit must be a positive Kubernetes CPU quantity in cores or millicores, such as 2, 0.5, or 2000m."
  }
}

variable "n8n_main_memory_request" {
  description = "Memory request for each n8n main container, such as 2Gi or 2048Mi."
  type        = string
  default     = "2Gi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_main_memory_request))
    error_message = "n8n_main_memory_request must be a positive Kubernetes memory quantity, such as 2Gi or 2048Mi."
  }
}

variable "n8n_main_memory_limit" {
  description = "Memory limit for each n8n main container, such as 4Gi or 4096Mi."
  type        = string
  default     = "4Gi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_main_memory_limit))
    error_message = "n8n_main_memory_limit must be a positive Kubernetes memory quantity, such as 4Gi or 4096Mi."
  }
}

variable "n8n_worker_cpu_request" {
  description = "CPU request for each n8n worker container, such as 500m or 0.5. Included in the advisory capacity model at n8n_worker_keda_max_replicas."
  type        = string
  default     = "500m"
  nullable    = false

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_worker_cpu_request))
    error_message = "n8n_worker_cpu_request must be a positive Kubernetes CPU quantity in cores or millicores, such as 0.5 or 500m."
  }
}

variable "n8n_worker_cpu_limit" {
  description = "CPU limit for each n8n worker container, such as 1000m or 1."
  type        = string
  default     = "1000m"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_worker_cpu_limit))
    error_message = "n8n_worker_cpu_limit must be a positive Kubernetes CPU quantity in cores or millicores, such as 1 or 1000m."
  }
}

variable "n8n_worker_memory_request" {
  description = "Memory request for each n8n worker container, such as 1Gi or 1024Mi."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_worker_memory_request))
    error_message = "n8n_worker_memory_request must be a positive Kubernetes memory quantity, such as 1Gi or 1024Mi."
  }
}

variable "n8n_worker_memory_limit" {
  description = "Memory limit for each n8n worker container, such as 2Gi or 2048Mi."
  type        = string
  default     = "2Gi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_worker_memory_limit))
    error_message = "n8n_worker_memory_limit must be a positive Kubernetes memory quantity, such as 2Gi or 2048Mi."
  }
}

variable "n8n_webhook_cpu_request" {
  description = "CPU request for each n8n webhook processor container, such as 300m or 0.3. Included in the advisory capacity model at n8n_webhook_hpa_max_replicas."
  type        = string
  default     = "300m"
  nullable    = false

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_webhook_cpu_request))
    error_message = "n8n_webhook_cpu_request must be a positive Kubernetes CPU quantity in cores or millicores, such as 0.3 or 300m."
  }
}

variable "n8n_webhook_cpu_limit" {
  description = "CPU limit for each n8n webhook processor container, such as 800m or 0.8."
  type        = string
  default     = "800m"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_webhook_cpu_limit))
    error_message = "n8n_webhook_cpu_limit must be a positive Kubernetes CPU quantity in cores or millicores, such as 0.8 or 800m."
  }
}

variable "n8n_webhook_memory_request" {
  description = "Memory request for each n8n webhook processor container, such as 512Mi or 0.5Gi."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_webhook_memory_request))
    error_message = "n8n_webhook_memory_request must be a positive Kubernetes memory quantity, such as 512Mi or 0.5Gi."
  }
}

variable "n8n_webhook_memory_limit" {
  description = "Memory limit for each n8n webhook processor container, such as 1Gi or 1024Mi."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_webhook_memory_limit))
    error_message = "n8n_webhook_memory_limit must be a positive Kubernetes memory quantity, such as 1Gi or 1024Mi."
  }
}

# ── Optional Redis queue metrics exporter (observability.tf) ─────────────
# Bull queue depth is the signal KEDA scales workers on. n8n's built-in
# /metrics gauge for it is not reliable in the multi-main topology every
# example ships (only the leader main reports), so this opt-in exporter
# reads the same effective Redis connection n8n and KEDA already use and
# exposes it, along with standard Redis metrics, for a caller-owned
# Prometheus to scrape. Independent of n8n_metrics_enabled. The module
# installs no Prometheus, ServiceMonitor, or other monitoring backend.

variable "redis_exporter_enabled" {
  description = "When true, create a single-replica Redis queue metrics exporter Deployment and an internal ClusterIP Service on port 9121 in the effective n8n namespace. Independent of n8n_metrics_enabled. The module installs no Prometheus, ServiceMonitor, or other monitoring backend — scraping and discovery remain caller-owned. Disabled by default, in which case neither resource is created."
  type        = bool
  default     = false
  nullable    = false
}

variable "redis_exporter_image" {
  description = "Container image for the optional Redis queue metrics exporter (oliver006/redis_exporter). Pinned by both tag and digest (multi-arch index, resolves on x86_64 and Graviton/ARM nodes alike) so the default IfNotPresent pull policy on the running node can never resolve to a superseded image (port-aws-050-enhancements section 3). Override to use a caller mirror or a different pinned digest. A replacement image must retain the upstream CA bundle for TLS certificate verification and work under UID 59000, which the container always runs as. Any private-registry pull access is the caller's responsibility, the module does not grant the exporter the n8n Azure workload identity. Ignored when redis_exporter_enabled = false."
  type        = string
  default     = "oliver006/redis_exporter:v1.90.0@sha256:a129504e65b87c54f79bc92f1afc403475e8ff646a3d7512de469904ceddf986"
  nullable    = false

  validation {
    condition     = trimspace(var.redis_exporter_image) != "" && !can(regex("\\s", var.redis_exporter_image))
    error_message = "redis_exporter_image must be a non-blank image reference containing no whitespace."
  }
}

# ── Workload autoscaling ─────────────────────────────────────────────────
# Main and webhook pods scale on CPU. Workers scale on Redis queue depth.
# Each minimum also becomes the matching Helm deployment replica count so an
# upgrade at the autoscaler floor does not briefly scale the workload down.

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum main replicas for the CPU HPA and the Helm deployment floor. A minimum of 1 selects single-main queue mode (no feat:multipleMainInstances requirement); a minimum of 2 or more selects multi-main, the default."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_min_replicas >= 1 && var.n8n_main_hpa_min_replicas == floor(var.n8n_main_hpa_min_replicas)
    error_message = "n8n_main_hpa_min_replicas must be a whole number of at least 1."
  }

  # Terraform 1.9 cross-variable validation uses a conditional expression so
  # only the comparison branch controls this independent input contract.
  validation {
    condition     = var.n8n_main_hpa_min_replicas > var.n8n_main_hpa_max_replicas ? false : true
    error_message = "n8n_main_hpa_min_replicas must not exceed n8n_main_hpa_max_replicas."
  }
}

variable "n8n_main_hpa_max_replicas" {
  description = "Maximum main replicas for the CPU HPA. The default of 6 participates in the AKS capacity diagnostic with the main CPU request. A higher value remains valid in single-main mode (n8n_main_hpa_min_replicas = 1) but has no effect there — the effective ceiling clamps to 1."
  type        = number
  default     = 6
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_max_replicas >= 1 && var.n8n_main_hpa_max_replicas == floor(var.n8n_main_hpa_max_replicas)
    error_message = "n8n_main_hpa_max_replicas must be a whole number of at least 1."
  }
}

variable "n8n_main_hpa_cpu_threshold" {
  description = "Target average CPU utilization percentage for the main HPA."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_cpu_threshold >= 1 && var.n8n_main_hpa_cpu_threshold <= 100 && var.n8n_main_hpa_cpu_threshold == floor(var.n8n_main_hpa_cpu_threshold)
    error_message = "n8n_main_hpa_cpu_threshold must be a whole percentage between 1 and 100."
  }
}

variable "n8n_webhook_hpa_min_replicas" {
  description = "Minimum webhook-processor replicas for the CPU HPA and the Helm deployment floor. The default of 2 keeps a warm, redundant webhook path."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas >= 1 && var.n8n_webhook_hpa_min_replicas == floor(var.n8n_webhook_hpa_min_replicas)
    error_message = "n8n_webhook_hpa_min_replicas must be a positive whole number."
  }

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas > var.n8n_webhook_hpa_max_replicas ? false : true
    error_message = "n8n_webhook_hpa_min_replicas must not exceed n8n_webhook_hpa_max_replicas."
  }
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum webhook-processor replicas for the CPU HPA. The default of 8 participates in the AKS capacity diagnostic."
  type        = number
  default     = 8
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_max_replicas >= 1 && var.n8n_webhook_hpa_max_replicas == floor(var.n8n_webhook_hpa_max_replicas)
    error_message = "n8n_webhook_hpa_max_replicas must be a positive whole number."
  }
}

variable "n8n_webhook_hpa_cpu_threshold" {
  description = "Target average CPU utilization percentage for the webhook-processor HPA."
  type        = number
  default     = 65
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_cpu_threshold >= 1 && var.n8n_webhook_hpa_cpu_threshold <= 100 && var.n8n_webhook_hpa_cpu_threshold == floor(var.n8n_webhook_hpa_cpu_threshold)
    error_message = "n8n_webhook_hpa_cpu_threshold must be a whole percentage between 1 and 100."
  }
}

variable "n8n_webhook_hpa_scale_up_stabilization_window_seconds" {
  description = "Seconds the webhook HPA looks back before scaling up. Zero preserves Kubernetes' immediate scale-up default. Raise this to absorb short startup CPU spikes."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition = (
      var.n8n_webhook_hpa_scale_up_stabilization_window_seconds >= 0 &&
      var.n8n_webhook_hpa_scale_up_stabilization_window_seconds <= 3600 &&
      var.n8n_webhook_hpa_scale_up_stabilization_window_seconds == floor(var.n8n_webhook_hpa_scale_up_stabilization_window_seconds)
    )
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds must be a whole number between 0 and 3600."
  }
}

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum worker replicas for the KEDA ScaledObject. On chart 1.13.0 and later the chart leaves the worker Deployment's spec.replicas to KEDA, so this sets only the autoscaler floor; older charts also render it as spec.replicas on every Helm upgrade. The default of 1 keeps one queue consumer warm when Redis has no waiting jobs."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_min_replicas >= 1 && var.n8n_worker_keda_min_replicas == floor(var.n8n_worker_keda_min_replicas)
    error_message = "n8n_worker_keda_min_replicas must be a positive whole number."
  }

  validation {
    condition     = var.n8n_worker_keda_min_replicas > var.n8n_worker_keda_max_replicas ? false : true
    error_message = "n8n_worker_keda_min_replicas must not exceed n8n_worker_keda_max_replicas."
  }
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may request from Redis queue depth. The default of 10 participates in the AKS capacity diagnostic with worker and task-runner CPU requests."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_max_replicas >= 1 && var.n8n_worker_keda_max_replicas == floor(var.n8n_worker_keda_max_replicas)
    error_message = "n8n_worker_keda_max_replicas must be a positive whole number."
  }
}

variable "n8n_worker_keda_pause" {
  description = "Pause KEDA autoscaling of the chart's worker Deployment (sets autoscaling.keda.sh/paused on the worker ScaledObject). While paused, workers hold their current replica count, or n8n_worker_keda_paused_replica_count when that is set. Use for maintenance windows and migrations. Pause freezes scaling, not processing: held workers keep consuming jobs, and jobs only wait in Redis without default-worker consumers once n8n_worker_keda_paused_replica_count = 0 has reconciled and the workers have terminated. Applies to the chart's default worker Deployment only: n8n_worker_pools pools have their own ScaledObjects and keep scaling on their own queues. Requires n8n_chart_version 1.13.0 or later; a plan-time warning fires otherwise, because older charts ignore the key or overwrite the held count on the next Helm upgrade. Webhook processors have no equivalent here because this module scales them with its own HPA (scaling.tf), not a KEDA ScaledObject. tests/scripts/smoke-test.sh skips the worker-floor assertion while this is true, and the worker-dependent checks while paused at 0."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_worker_keda_paused_replica_count" {
  description = "Replica count the worker Deployment holds while n8n_worker_keda_pause is true (sets autoscaling.keda.sh/paused-replicas). 0 scales workers to zero, for example to stop consuming jobs while they wait in Redis ahead of a migration. Null freezes workers at whatever count they have when paused. Ignored, with a plan-time warning, when n8n_worker_keda_pause is false."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_worker_keda_paused_replica_count == null ? true : (var.n8n_worker_keda_paused_replica_count >= 0 && var.n8n_worker_keda_paused_replica_count == floor(var.n8n_worker_keda_paused_replica_count))
    error_message = "n8n_worker_keda_paused_replica_count must be a whole number of 0 or more, or null to freeze workers at their current count."
  }
}

variable "n8n_worker_keda_jobs_per_replica" {
  description = "Waiting or active Redis jobs per worker replica used as the KEDA scaling target. KEDA takes the maximum desired replica count from the bull:jobs:wait and bull:jobs:active triggers."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_jobs_per_replica >= 1 && var.n8n_worker_keda_jobs_per_replica == floor(var.n8n_worker_keda_jobs_per_replica)
    error_message = "n8n_worker_keda_jobs_per_replica must be a positive whole number."
  }
}

variable "n8n_worker_concurrency" {
  description = "Number of jobs each worker pod can process simultaneously."
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_worker_concurrency >= 1 && var.n8n_worker_concurrency == floor(var.n8n_worker_concurrency)
    error_message = "n8n_worker_concurrency must be a whole number of at least 1."
  }
}

# Bull worker timing controls (port-aws-040-enhancements section 4). Each
# input maps to one chart-native redis.worker.* field (values.schema.json),
# which the pinned chart renders as QUEUE_WORKER_LOCK_DURATION,
# QUEUE_WORKER_LOCK_RENEW_TIME, and QUEUE_WORKER_STALLED_INTERVAL. Null
# preserves the chart's own pinned defaults (60000, 10000, 30000 ms). The
# chart schema rejects a value below 1000 or a stalled interval of zero, and
# n8n v2 no longer honors QUEUE_WORKER_MAX_STALLED_COUNT as a runtime control,
# so neither is exposed here.
variable "n8n_queue_worker_lock_duration" {
  description = "Milliseconds a worker holds a job lease before Bull considers it stalled (writes chart value redis.worker.lockDuration, rendered as QUEUE_WORKER_LOCK_DURATION). Null (default) omits the value and retains the chart's pinned default (60000 ms). Must be a whole number of at least 1000 when set. The effective lock-renewal time (n8n_queue_worker_lock_renew_time) must remain strictly below the effective value of this input."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_lock_duration == null ? true : (var.n8n_queue_worker_lock_duration == floor(var.n8n_queue_worker_lock_duration) && var.n8n_queue_worker_lock_duration >= 1000)
    error_message = "n8n_queue_worker_lock_duration must be null or a whole number of at least 1000 milliseconds."
  }
}

variable "n8n_queue_worker_lock_renew_time" {
  description = "Milliseconds between a worker's lock-renewal heartbeats for a job it is processing (writes chart value redis.worker.lockRenewTime, rendered as QUEUE_WORKER_LOCK_RENEW_TIME). Null (default) omits the value and retains the chart's pinned default (10000 ms). Must be a whole number of at least 1000 when set, and strictly below the effective lock duration (n8n_queue_worker_lock_duration, pinned default 60000 ms when both are null) — a renewal interval at or above the lock duration lets the lease expire before it is renewed."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_lock_renew_time == null ? true : (var.n8n_queue_worker_lock_renew_time == floor(var.n8n_queue_worker_lock_renew_time) && var.n8n_queue_worker_lock_renew_time >= 1000)
    error_message = "n8n_queue_worker_lock_renew_time must be null or a whole number of at least 1000 milliseconds."
  }

  validation {
    condition     = coalesce(var.n8n_queue_worker_lock_renew_time, 10000) < coalesce(var.n8n_queue_worker_lock_duration, 60000)
    error_message = "The effective n8n_queue_worker_lock_renew_time must be strictly below the effective n8n_queue_worker_lock_duration (pinned defaults 10000 and 60000 ms apply when either is null)."
  }
}

variable "n8n_queue_worker_stalled_interval" {
  description = "Milliseconds between Bull's checks for stalled jobs (writes chart value redis.worker.stalledInterval, rendered as QUEUE_WORKER_STALLED_INTERVAL). Null (default) omits the value and retains the chart's pinned default (30000 ms). Must be a whole number of at least 1000 when set; the pinned chart schema rejects zero, so stall checking cannot be disabled through this input."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_stalled_interval == null ? true : (var.n8n_queue_worker_stalled_interval == floor(var.n8n_queue_worker_stalled_interval) && var.n8n_queue_worker_stalled_interval >= 1000)
    error_message = "n8n_queue_worker_stalled_interval must be null or a whole number of at least 1000 milliseconds."
  }
}

variable "n8n_graceful_shutdown_timeout" {
  description = "Seconds n8n gives in-flight executions to finish after it receives SIGTERM, before it exits on its own. Maps to the chart's redis.worker.timeout value (N8N_GRACEFUL_SHUTDOWN_TIMEOUT on every main, worker, and webhook-processor container). Null (default) sends no override, and the chart keeps rendering its own default of 30 seconds. Set the value here: n8n_extra_env, n8n_worker_extra_env, and a worker pool's extra_env all reject this name at plan time, because the chart always renders its own entry for it and a caller duplicate would silently replace that entry. n8n_termination_grace_period is a hard ceiling. Kubernetes starts that countdown when termination begins: the preStop hook (n8n_prestop_sleep) runs inside it, and SIGTERM follows the hook. So this value plus n8n_prestop_sleep must stay strictly below n8n_termination_grace_period, or SIGKILL cuts n8n's shutdown short. An explicit value that breaks this rule fails validation. When this input is null, the same rule applied to the chart's default only raises a warning (check.graceful_shutdown_fits_grace_period), so existing configurations keep planning."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_graceful_shutdown_timeout == null ? true : var.n8n_graceful_shutdown_timeout >= 1
    error_message = "n8n_graceful_shutdown_timeout must be at least 1 second, or null to use the chart's own default (30s). The chart's values.schema.json enforces a minimum of 1 on redis.worker.timeout, so zero or negative values are rejected during Helm schema validation."
  }

  validation {
    condition     = var.n8n_graceful_shutdown_timeout == null ? true : var.n8n_graceful_shutdown_timeout == floor(var.n8n_graceful_shutdown_timeout)
    error_message = "n8n_graceful_shutdown_timeout must be a whole number of seconds, so this value is rejected at plan time. The chart's values.schema.json declares redis.worker.timeout as {\"type\": \"integer\"}, so a fractional value that slipped past this check would only fail later, during Helm schema validation at apply time."
  }

  # Explicit values only. The null case (chart default) is a warning in
  # check.graceful_shutdown_fits_grace_period (n8n.tf): making it a hard error
  # would fail configurations that planned before this input existed, such as
  # n8n_prestop_sleep = 30 with the default 60-second grace period.
  validation {
    condition     = var.n8n_graceful_shutdown_timeout == null ? true : var.n8n_graceful_shutdown_timeout + var.n8n_prestop_sleep < var.n8n_termination_grace_period
    error_message = "n8n_graceful_shutdown_timeout plus n8n_prestop_sleep must stay strictly below n8n_termination_grace_period. Kubernetes starts the terminationGracePeriodSeconds countdown when it invokes preStop, not after preStop finishes, so a sum equal to the ceiling leaves n8n's own shutdown handler no margin before SIGKILL."
  }
}

variable "n8n_execution_timeout" {
  description = "Default execution timeout in seconds. Set to -1 to disable the timeout."
  type        = number
  default     = 7200

  validation {
    condition     = (var.n8n_execution_timeout == -1 || var.n8n_execution_timeout >= 1) && var.n8n_execution_timeout == floor(var.n8n_execution_timeout)
    error_message = "n8n_execution_timeout must be -1 or a positive whole number of seconds."
  }
}

variable "n8n_execution_timeout_max" {
  description = "Maximum execution timeout users can configure in seconds. Set to -1 to disable the maximum."
  type        = number
  default     = 7200

  validation {
    condition     = (var.n8n_execution_timeout_max == -1 || var.n8n_execution_timeout_max >= 1) && var.n8n_execution_timeout_max == floor(var.n8n_execution_timeout_max)
    error_message = "n8n_execution_timeout_max must be -1 or a positive whole number of seconds."
  }
}

variable "n8n_execution_concurrency_limit" {
  description = "Maximum concurrent production executions. Set to -1 to disable the limit."
  type        = number
  default     = 100

  validation {
    condition     = (var.n8n_execution_concurrency_limit == -1 || var.n8n_execution_concurrency_limit >= 1) && var.n8n_execution_concurrency_limit == floor(var.n8n_execution_concurrency_limit)
    error_message = "n8n_execution_concurrency_limit must be -1 or a positive whole number."
  }
}

# Execution-save policy controls (port-aws-040-enhancements section 5). Each
# input maps to one chart-native executions.data.* field, which the pinned
# chart renders as EXECUTIONS_DATA_SAVE_ON_SUCCESS, EXECUTIONS_DATA_SAVE_ON_ERROR,
# EXECUTIONS_DATA_SAVE_ON_PROGRESS, and EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS
# on main and worker application containers. Workflow-level save-policy
# overrides continue to take precedence over these deployment-wide defaults.
# The existing broad "EXECUTIONS_" managed-prefix guard already reserves
# these four raw environment variable names in var.n8n_extra_env.
variable "n8n_executions_data_save_on_success" {
  description = "Whether to save execution data for successful workflow executions (writes chart value executions.data.saveOnSuccess, rendered as EXECUTIONS_DATA_SAVE_ON_SUCCESS). Must be \"all\" or \"none\". Workflow-level settings can override this default per workflow. An explicit null falls back to the default."
  type        = string
  default     = "all"
  nullable    = false

  validation {
    condition     = contains(["all", "none"], var.n8n_executions_data_save_on_success)
    error_message = "n8n_executions_data_save_on_success must be \"all\" or \"none\"."
  }
}

variable "n8n_executions_data_save_on_error" {
  description = "Whether to save execution data for failed workflow executions (writes chart value executions.data.saveOnError, rendered as EXECUTIONS_DATA_SAVE_ON_ERROR). Must be \"all\" or \"none\". Workflow-level settings can override this default per workflow. An explicit null falls back to the default."
  type        = string
  default     = "all"
  nullable    = false

  validation {
    condition     = contains(["all", "none"], var.n8n_executions_data_save_on_error)
    error_message = "n8n_executions_data_save_on_error must be \"all\" or \"none\"."
  }
}

variable "n8n_executions_data_save_on_progress" {
  description = "Whether to save incremental execution progress as a workflow runs (writes chart value executions.data.saveOnProgress, rendered as EXECUTIONS_DATA_SAVE_ON_PROGRESS). Enabling this increases database writes per execution. Workflow-level settings can override this default per workflow. An explicit null falls back to the default."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_executions_data_save_manual_executions" {
  description = "Whether to save execution data for manually triggered workflow executions (writes chart value executions.data.saveManualExecutions, rendered as EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS). An explicit null falls back to the default."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_pruning_max_age" {
  description = "Maximum age of execution records to retain in hours."
  type        = number
  default     = 336

  validation {
    condition     = var.n8n_pruning_max_age >= 1 && var.n8n_pruning_max_age == floor(var.n8n_pruning_max_age)
    error_message = "n8n_pruning_max_age must be a positive whole number of hours."
  }
}

variable "n8n_pruning_max_count" {
  description = "Maximum number of execution records to retain. Set to 0 for no count limit."
  type        = number
  default     = 10000

  validation {
    condition     = var.n8n_pruning_max_count >= 0 && var.n8n_pruning_max_count == floor(var.n8n_pruning_max_count)
    error_message = "n8n_pruning_max_count must be a non-negative whole number."
  }
}

# Optional application heap ceiling (port-aws-040-enhancements section 6).
# Null leaves n8n/Node's own default in place and keeps any caller-supplied
# NODE_OPTIONS in n8n_extra_env valid. When set, it is the only source of a
# heap-related NODE_OPTIONS entry, so a caller NODE_OPTIONS entry becomes a
# conflict rather than something Kubernetes could silently override via
# last-wins env ordering.
variable "n8n_node_max_old_space_size_mb" {
  description = "Optional V8 old-space heap ceiling in mebibytes for the main, worker, and webhook-processor application containers, rendered as NODE_OPTIONS=--max-old-space-size=<value>. Null (default) emits no heap-related NODE_OPTIONS and leaves any caller-supplied NODE_OPTIONS in n8n_extra_env in place. Must be a whole number of at least 256 when set. Size against the smallest application container's memory limit, leaving headroom beyond the heap for non-heap process memory; do not treat a larger value as a fix for a memory leak. Task-runner sidecars are not covered by this input."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_node_max_old_space_size_mb == null ? true : (var.n8n_node_max_old_space_size_mb == floor(var.n8n_node_max_old_space_size_mb) && var.n8n_node_max_old_space_size_mb >= 256)
    error_message = "n8n_node_max_old_space_size_mb must be null or a whole number of at least 256 mebibytes."
  }

  validation {
    condition = var.n8n_node_max_old_space_size_mb == null ? true : alltrue([
      for env in var.n8n_extra_env : env.name != "NODE_OPTIONS"
    ])
    error_message = "n8n_node_max_old_space_size_mb conflicts with a NODE_OPTIONS entry in n8n_extra_env. Remove the escape-hatch entry and let this dedicated input set the heap flag, or leave this input null to keep using n8n_extra_env for NODE_OPTIONS."
  }
}

variable "n8n_termination_grace_period" {
  description = "Seconds Kubernetes waits after SIGTERM before force-killing an n8n pod. Workers need at least 60 seconds to finish in-flight executions."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_termination_grace_period >= 60 && var.n8n_termination_grace_period == floor(var.n8n_termination_grace_period)
    error_message = "n8n_termination_grace_period must be a whole number of at least 60 seconds."
  }
}

variable "n8n_prestop_sleep" {
  description = "Seconds each n8n pod waits in its preStop hook so ingress can drain before SIGTERM."
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_prestop_sleep >= 10 && var.n8n_prestop_sleep == floor(var.n8n_prestop_sleep)
    error_message = "n8n_prestop_sleep must be a whole number of at least 10 seconds."
  }
}

variable "n8n_task_runners_enabled" {
  description = "Enable task-runner sidecars for isolated JavaScript and Python code execution. The advisory capacity model adds the runner CPU request to every main and worker replica when enabled."
  type        = bool
  default     = true
  nullable    = false

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_task_runner_image_tag" {
  description = "Optional image tag for the n8nio/runners sidecar. Null inherits n8n_image_tag. Set this to the underlying n8n version when a custom application image uses a suffixed tag, such as n8n_image_tag = \"2.35.0-custom\" with n8n_task_runner_image_tag = \"2.35.0\", so the runner image exists and its protocol matches the application."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be null or a valid Docker tag with no whitespace, such as 2.35.0."
  }
}

variable "n8n_task_runner_cpu_request" {
  description = "CPU request for each task-runner sidecar, such as 200m or 0.2. Included in the advisory capacity model for every worker replica when task runners are enabled, and for every main replica only when n8n_chart_version is not one of the upstream charts verified to place runners on workers alone (1.12.0, 1.13.0, and 1.14.0, n8n-hosting #179): on those, queue-mode main pods carry no sidecar because n8n offloads manual executions to workers, so the main ceiling is not multiplied by this."
  type        = string
  default     = "200m"
  nullable    = false

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_task_runner_cpu_request))
    error_message = "n8n_task_runner_cpu_request must be a positive Kubernetes CPU quantity in cores or millicores, such as 0.2 or 200m."
  }
}

variable "n8n_task_runner_cpu_limit" {
  description = "CPU limit for each task-runner sidecar, such as 1 or 1000m."
  type        = string
  default     = "1"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*m|[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)$", var.n8n_task_runner_cpu_limit))
    error_message = "n8n_task_runner_cpu_limit must be a positive Kubernetes CPU quantity in cores or millicores, such as 1 or 1000m."
  }
}

variable "n8n_task_runner_memory_request" {
  description = "Memory request for each task-runner sidecar, such as 512Mi or 0.5Gi."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_task_runner_memory_request))
    error_message = "n8n_task_runner_memory_request must be a positive Kubernetes memory quantity, such as 512Mi or 0.5Gi."
  }
}

variable "n8n_task_runner_memory_limit" {
  description = "Memory limit for each task-runner sidecar, such as 1Gi or 1024Mi."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^(?:[1-9][0-9]*(?:\\.[0-9]+)?|0\\.[0-9]*[1-9][0-9]*)(?:[EPTGMK]i?|[eE][+-]?[0-9]+)?$", var.n8n_task_runner_memory_limit))
    error_message = "n8n_task_runner_memory_limit must be a positive Kubernetes memory quantity, such as 1Gi or 1024Mi."
  }
}

variable "n8n_task_runner_auto_shutdown_timeout" {
  description = "Seconds of inactivity before the task-runner process shuts down. Set to 0 to disable auto-shutdown."
  type        = number
  default     = 15

  validation {
    condition     = var.n8n_task_runner_auto_shutdown_timeout >= 0 && var.n8n_task_runner_auto_shutdown_timeout == floor(var.n8n_task_runner_auto_shutdown_timeout)
    error_message = "n8n_task_runner_auto_shutdown_timeout must be a non-negative whole number of seconds."
  }
}

variable "n8n_task_runner_request_timeout" {
  description = "Seconds n8n waits for a task runner to accept a Code node task."
  type        = number
  default     = 300

  validation {
    condition     = var.n8n_task_runner_request_timeout >= 1 && var.n8n_task_runner_request_timeout == floor(var.n8n_task_runner_request_timeout)
    error_message = "n8n_task_runner_request_timeout must be a positive whole number of seconds."
  }
}

variable "n8n_task_runner_python_enabled" {
  description = "Enable the native Python task runner."
  type        = bool
  default     = true

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_templates_enabled" {
  description = "Enable n8n workflow templates and template suggestions. False writes N8N_TEMPLATES_ENABLED=false to every n8n pod."
  type        = bool
  default     = true

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_task_runner_custom_config" {
  description = <<-EOT
    Existing Kubernetes ConfigMap containing a custom task-runner launcher
    configuration file (allow-lists additional packages beyond the runner
    image's default n8n-task-runners.json). config_map_name is the
    ConfigMap's name in the effective n8n namespace; config_map_key defaults
    to "n8n-task-runners.json". The selected key replaces
    /etc/n8n-task-runners.json in the worker task-runner sidecars using a
    file subPath. Main pods carry that sidecar only on charts older than
    1.12.0, and webhook processors never do. The module neither creates nor reads the ConfigMap, so
    its contents never enter this module's Helm values or state, and Helm
    does not roll pods when only the ConfigMap's payload changes: derive the
    complete file from the matching n8nio/runners image tag and manually
    restart the worker deployments (and n8n-main on charts older than
    1.12.0) after every rotation. Requires
    n8n_task_runners_enabled = true. Null keeps the runner image's own
    default configuration file.
  EOT

  type = object({
    config_map_name = string
    config_map_key  = optional(string, "n8n-task-runners.json")
  })
  default = null

  validation {
    condition = (
      var.n8n_task_runner_custom_config == null ? true :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", var.n8n_task_runner_custom_config.config_map_name))
      && length(var.n8n_task_runner_custom_config.config_map_name) <= 253
    )
    error_message = "n8n_task_runner_custom_config.config_map_name must be a DNS-1123 subdomain of 253 characters or fewer, which is what Kubernetes requires of a ConfigMap name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, with no empty label (e.g. \"n8n-task-runner-config\")."
  }

  validation {
    condition = (
      var.n8n_task_runner_custom_config == null ? true :
      can(regex("^[-._a-zA-Z0-9]+$", var.n8n_task_runner_custom_config.config_map_key))
      && length(var.n8n_task_runner_custom_config.config_map_key) <= 253
      && !contains([".", ".."], var.n8n_task_runner_custom_config.config_map_key)
      && !startswith(var.n8n_task_runner_custom_config.config_map_key, "..")
    )
    error_message = "n8n_task_runner_custom_config.config_map_key must be a valid ConfigMap key of 253 characters or fewer: alphanumerics, '-', '_' and '.' only, and not \".\", \"..\" or a name starting with \"..\"."
  }

  validation {
    condition     = var.n8n_task_runner_custom_config == null ? true : var.n8n_task_runners_enabled
    error_message = "n8n_task_runner_custom_config requires n8n_task_runners_enabled = true. Enable task runners or clear this input."
  }
}

variable "n8n_dns_config" {
  description = <<-EOT
    Optional pod DNS configuration (Kubernetes PodDNSConfig) applied to main,
    worker, and webhook-processor pods. Null attributes are stripped before
    rendering; a null input or an effectively empty object (all three
    attributes null or empty) omits the chart's dnsConfig block entirely.
    dnsPolicy and cluster DNS resources are unaffected. nameservers accepts
    at most 3 plain IPv4/IPv6 addresses (no hostnames, ports, or CIDR
    prefixes). searches accepts at most 32 domain names totaling at most
    2048 characters once joined with single spaces. options entries need a
    nonblank name and an optional string value (e.g. { name = "ndots",
    value = "1" } or { name = "edns0" }); an "ndots" option's value must be
    a whole number from 0 through 15. Lowering ndots changes when relative
    names use the search suffixes, so verify AKS private DNS and in-cluster
    name resolution still work with the chosen setting before relying on it.
    This module's limits (32 search domains, 2048 joined characters) match
    current Kubernetes' own PodDNSConfig validation; older caller-managed
    clusters, or resolvers built against glibc's traditional resolv.conf
    limits (6 search domains, 256 characters), may enforce tighter effective
    limits than this module validates against, so verify pod DNS resolution
    on the target cluster after setting a large searches list.
  EOT

  type = object({
    nameservers = optional(list(string))
    searches    = optional(list(string))
    options = optional(list(object({
      name  = string
      value = optional(string)
    })))
  })
  default = null

  validation {
    condition = (
      var.n8n_dns_config == null || var.n8n_dns_config.nameservers == null ? true : (
        length(var.n8n_dns_config.nameservers) <= 3 &&
        alltrue([
          for ns in var.n8n_dns_config.nameservers :
          !strcontains(ns, "/") && (can(cidrhost("${ns}/32", 0)) || can(cidrhost("${ns}/128", 0)))
        ])
      )
    )
    error_message = "n8n_dns_config.nameservers must contain at most 3 plain IPv4 or IPv6 addresses, with no hostnames, ports, or CIDR prefixes."
  }

  validation {
    condition = (
      var.n8n_dns_config == null || var.n8n_dns_config.searches == null ? true :
      length(var.n8n_dns_config.searches) <= 32
    )
    error_message = "n8n_dns_config.searches must contain at most 32 search domains."
  }

  validation {
    condition = (
      var.n8n_dns_config == null || var.n8n_dns_config.searches == null ? true :
      length(join(" ", var.n8n_dns_config.searches)) <= 2048
    )
    error_message = "n8n_dns_config.searches must total at most 2048 characters once joined with single spaces."
  }

  validation {
    condition = (
      var.n8n_dns_config == null || var.n8n_dns_config.searches == null ? true :
      alltrue([
        for s in var.n8n_dns_config.searches :
        can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\\.?$", s))
      ])
    )
    error_message = "n8n_dns_config.searches entries must be valid DNS search names (alphanumerics, hyphens, and dots, with no empty label)."
  }

  validation {
    condition = (
      var.n8n_dns_config == null || var.n8n_dns_config.options == null ? true :
      alltrue([for opt in var.n8n_dns_config.options : trimspace(opt.name) != ""])
    )
    error_message = "n8n_dns_config.options entries must have a nonblank name."
  }

  validation {
    condition = (
      var.n8n_dns_config == null || var.n8n_dns_config.options == null ? true :
      alltrue([
        for opt in var.n8n_dns_config.options :
        opt.name != "ndots" ? true : (
          opt.value != null &&
          can(tonumber(opt.value)) &&
          tonumber(opt.value) == floor(tonumber(opt.value)) &&
          tonumber(opt.value) >= 0 &&
          tonumber(opt.value) <= 15
        )
      ])
    )
    error_message = "n8n_dns_config.options' ndots value must be a whole number from 0 through 15, supplied as a string."
  }
}

variable "n8n_personalization_enabled" {
  description = "Enable n8n personalization questions and recommendations. False writes N8N_PERSONALIZATION_ENABLED=false to every n8n pod."
  type        = bool
  default     = true

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_reinstall_missing_packages" {
  description = "Reinstall database-recorded community packages that are missing from a pod's local filesystem at startup. This applies to every n8n pod family."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_community_packages_prevent_loading" {
  description = "Prevent installed community packages from loading at runtime without uninstalling them."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

variable "n8n_community_packages_registry" {
  description = "Optional HTTP or HTTPS npm registry used for community-package installation. Null leaves n8n on its public registry default. Custom registries require the matching Enterprise entitlement."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_community_packages_registry == null ? true : can(regex("^https?://[A-Za-z0-9._~-]+(:[0-9]+)?(/[^[:space:]]*)?$", var.n8n_community_packages_registry))
    error_message = "n8n_community_packages_registry must be null or an HTTP(S) registry URL with a host and no whitespace, such as https://npm.internal.example.com."
  }
}

variable "n8n_license_detach_floating_on_shutdown" {
  description = "Whether n8n main pods detach their floating license on shutdown. The default false prevents a leader shutdown from invalidating the shared certificate and crash-looping replacement mains in this multi-main topology."
  type        = bool
  default     = false

  # no validation: a plain bool needs no additional constraint.
}

# ── Custom images, extensions, volumes, and environment ─────────────────

variable "n8n_custom_extensions_path" {
  description = "Optional canonical absolute path that every n8n application container scans for custom nodes, such as /opt/n8n-nodes. A custom image or an extra volume mount must put content at this path. Only one path is supported because n8n's semicolon-separated paths overwrite one another under the CUSTOM package key. The path must stay outside /home/node/.n8n, which the chart shadows on main pods."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : can(regex("^/[^[:space:];]*$", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be one absolute path with no whitespace or semicolon, such as /opt/n8n-nodes. Multiple semicolon-delimited paths are not supported."
  }

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : !can(regex("//|/\\.\\.?(/|$)", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be canonical, with no repeated slash or `.` or `..` path component."
  }

  validation {
    condition = var.n8n_custom_extensions_path == null ? true : !(
      var.n8n_custom_extensions_path == "/home/node/.n8n" ||
      startswith(var.n8n_custom_extensions_path, "/home/node/.n8n/")
    )
    error_message = "n8n_custom_extensions_path must not be /home/node/.n8n or a path beneath it because the chart shadows that directory on main pods."
  }
}

variable "n8n_extra_volumes" {
  description = "Typed volumes added to every main, worker, and webhook-processor pod. Each entry must select exactly one ConfigMap, Secret, or persistent volume claim source. Pair each volume with n8n_extra_volume_mounts. default_mode is an octal string such as 0644 so Terraform does not reinterpret it as decimal."
  type = list(object({
    name = string
    config_map = optional(object({
      name         = string
      default_mode = optional(string)
    }))
    secret = optional(object({
      secret_name  = string
      default_mode = optional(string)
    }))
    persistent_volume_claim = optional(object({
      claim_name = string
      read_only  = optional(bool)
    }))
  }))
  default = []

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", volume.name)) && length(volume.name) <= 63
    ])
    error_message = "Every n8n_extra_volumes name must be a DNS-1123 label of at most 63 characters."
  }

  validation {
    condition     = length(distinct([for volume in var.n8n_extra_volumes : volume.name])) == length(var.n8n_extra_volumes)
    error_message = "n8n_extra_volumes names must be unique."
  }

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      !contains(["data", "task-runner-config", "n8n-azure-files"], volume.name)
    ])
    error_message = "n8n_extra_volumes must not use chart or module-reserved names: data, task-runner-config, or n8n-azure-files."
  }

  validation {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      length([for source in [volume.config_map, volume.secret, volume.persistent_volume_claim] : source if source != null]) == 1
    ])
    error_message = "Every n8n_extra_volumes entry must set exactly one of config_map, secret, or persistent_volume_claim."
  }

  validation {
    condition = alltrue([
      for mode in concat(
        [for volume in var.n8n_extra_volumes : volume.config_map.default_mode if volume.config_map != null],
        [for volume in var.n8n_extra_volumes : volume.secret.default_mode if volume.secret != null],
      ) : mode == null ? true : can(regex("^0?[0-7]{3}$", mode))
    ])
    error_message = "Every default_mode in n8n_extra_volumes must be a three-digit octal string with an optional leading zero, such as 0644 or 755."
  }
}

variable "n8n_extra_volume_mounts" {
  description = "Mounts for n8n_extra_volumes on every main, worker, and webhook-processor application container. Each name must match a declared volume. read_only defaults to true. Task-runner sidecars do not receive these mounts."
  type = list(object({
    name       = string
    mount_path = string
    sub_path   = optional(string)
    read_only  = optional(bool, true)
  }))
  default = []

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      contains([for volume in var.n8n_extra_volumes : volume.name], mount.name)
    ])
    error_message = "Every n8n_extra_volume_mounts name must match a volume declared in n8n_extra_volumes."
  }

  validation {
    condition = alltrue([
      for mount in var.n8n_extra_volume_mounts :
      can(regex("^/[^[:space:]]*$", mount.mount_path)) &&
      !can(regex("//|/\\.\\.?(/|$)", mount.mount_path)) &&
      !endswith(mount.mount_path, "/")
    ])
    error_message = "Every n8n_extra_volume_mounts mount_path must be a canonical absolute path with no whitespace, repeated slash, `.` or `..` component, or trailing slash."
  }

  validation {
    condition     = alltrue([for mount in var.n8n_extra_volume_mounts : mount.mount_path != "/home/node/.n8n"])
    error_message = "n8n_extra_volume_mounts must not mount at /home/node/.n8n because the chart already mounts its main-pod data volume there."
  }

  validation {
    condition     = length(distinct([for mount in var.n8n_extra_volume_mounts : mount.mount_path])) == length(var.n8n_extra_volume_mounts)
    error_message = "n8n_extra_volume_mounts mount_path values must be unique."
  }
}

variable "n8n_extra_env" {
  description = "Additional non-secret environment variables applied to every main, worker, and webhook-processor application container. Entries render in Helm values and Terraform state. Duplicate names and module or chart-reserved connection, identity, storage, license, runner, and topology names are rejected. Deprecated n8n variables that n8n ignores and warns about on every start (N8N_AVAILABLE_BINARY_DATA_MODES) are rejected too, with their own error. Use dedicated module inputs for reserved variables and mounted Secrets for credentials."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for env in var.n8n_extra_env : env.name != "" && env.name == trimspace(env.name)])
    error_message = "Every n8n_extra_env name must be non-empty and have no leading or trailing whitespace."
  }

  validation {
    condition     = length(distinct([for env in var.n8n_extra_env : env.name])) == length(var.n8n_extra_env)
    error_message = "n8n_extra_env must not contain duplicate names."
  }

  validation {
    condition     = !anytrue([for e in var.n8n_extra_env : contains(local.n8n_deprecated_env_names, e.name)])
    error_message = "n8n_extra_env must not set deprecated n8n variables (${join(", ", local.n8n_deprecated_env_names)}). n8n ignores them and logs a deprecation warning on every start; remove the entry."
  }

  validation {
    condition = alltrue([
      for env in var.n8n_extra_env : !(
        contains(local.n8n_managed_env_names, env.name) ||
        anytrue([for prefix in local.n8n_managed_env_prefixes : startswith(env.name, prefix)])
      )
    ])
    error_message = "n8n_extra_env must not set module or chart-reserved names. Reserved prefixes: ${join(", ", local.n8n_managed_env_prefixes)}. Reserved exact names: ${join(", ", local.n8n_managed_env_names)}. Use the dedicated module input instead."
  }
}

variable "n8n_worker_extra_env" {
  description = "Additional non-secret environment variables applied only to worker containers (chart queueMode.workerExtraEnv). Use for worker-specific tuning that must not affect main or webhook-processor pods; use n8n_extra_env for values that should apply everywhere. This reaches every worker, the chart's own unlabelled deployment and each n8n_worker_pools pool alike, because they render from one shared pod template; a pool's own extra_env is applied after this and wins on a repeated name. Set it here for tuning that should apply pool-wide, and on the pool for tuning that should not. Entries render in Helm values and Terraform state. Duplicate names and module or chart-reserved connection, identity, storage, license, runner, and topology names are rejected, including N8N_WORKER_POOL_NAME: pool membership is owned by n8n_worker_pools, which also builds the queue and the KEDA scaler that go with it. The deprecated names n8n_extra_env rejects (N8N_AVAILABLE_BINARY_DATA_MODES) are rejected here too."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for env in var.n8n_worker_extra_env : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", env.name))])
    error_message = "Every n8n_worker_extra_env name must be a valid environment-variable identifier (letters, digits, underscore; must not start with a digit)."
  }

  validation {
    condition     = length(distinct([for env in var.n8n_worker_extra_env : env.name])) == length(var.n8n_worker_extra_env)
    error_message = "n8n_worker_extra_env must not contain duplicate names."
  }

  validation {
    condition     = !anytrue([for e in var.n8n_worker_extra_env : contains(local.n8n_deprecated_env_names, e.name)])
    error_message = "n8n_worker_extra_env must not set deprecated n8n variables (${join(", ", local.n8n_deprecated_env_names)}). n8n ignores them and logs a deprecation warning on every start; remove the entry."
  }

  validation {
    condition = alltrue([
      for env in var.n8n_worker_extra_env : !(
        contains(local.n8n_managed_env_names, env.name) ||
        anytrue([for prefix in local.n8n_managed_env_prefixes : startswith(env.name, prefix)])
      )
    ])
    error_message = "n8n_worker_extra_env must not set module or chart-reserved names. Reserved prefixes: ${join(", ", local.n8n_managed_env_prefixes)}. Reserved exact names: ${join(", ", local.n8n_managed_env_names)}. Use the dedicated module input instead."
  }
}

# The upstream Helm chart renders exactly one worker Deployment and exposes
# worker-only env solely through queueMode.workerExtraEnv, so it can express at
# most a single pool. Anything beyond that has to be built outside the chart,
# which is what n8n_worker_pools does: one Deployment and one KEDA ScaledObject
# per entry, alongside the chart's own unlabelled worker deployment.

variable "n8n_worker_pools" {
  description = "EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE: tracks n8n's own worker pools feature and the chart support for it, both alpha upstream. Labelled worker pools to run beside the chart's own unlabelled worker deployment. Each entry becomes one queueMode.workerGroups entry in the Helm release, which renders one Deployment (identical to the chart's worker pods but carrying N8N_WORKER_POOL_NAME) and one KEDA ScaledObject watching that pool's own `jobs-<name>` queue, so a pool autoscales on its own backlog rather than the default queue's. Requires an n8n_chart_version whose chart supports queueMode.workerGroups: that feature (n8n-io/n8n-hosting#189) is merged to the chart's preview/worker-pools branch but not released to a numbered chart version, and an older chart accepts the key and renders nothing for it, so a precondition on the Helm release fails the plan for every numbered chart version (only a prerelease, taken at the caller's word, passes). Also requires n8n_image_tag 2.39.0 or later (validated on that variable). Each pool's KEDA ScaledObject authenticates to Redis through the same TriggerAuthentication the default worker's scaler uses. An official preview build can be published from that branch's Preview chart GitHub Action (n8n-io/n8n-hosting#191) to oci://ghcr.io/n8n-io/n8n-helm-chart, the chart repository this module hardcodes (there is no repository override), at a version such as 1.11.0-preview.workerpools.1, which is what to pin in n8n_chart_version. See examples/worker-pools/README.md for the exact command and a private-mirror fallback. A pool's extra_env is rejected at plan time for the same module-managed and deprecated names as n8n_worker_extra_env, and for N8N_WORKER_POOL_NAME, which the pool's name owns."
  type = list(object({
    name         = string
    min_replicas = optional(number, 1)
    max_replicas = optional(number, 5)

    # Null inherits the module-wide worker setting of the same name.
    concurrency    = optional(number, null)
    cpu_request    = optional(string, null)
    cpu_limit      = optional(string, null)
    memory_request = optional(string, null)
    memory_limit   = optional(string, null)

    # Extra env for this pool's workers only, on top of what every worker gets.
    extra_env = optional(list(object({
      name  = string
      value = string
    })), [])
  }))
  default  = []
  nullable = false

  validation {
    # 43, not the chart schema's 53: helm_release.n8n fixes the release name to
    # "n8n", so the chart names the pool's ScaledObject n8n-worker-<name> and
    # fails the render when that exceeds KEDA's 54-character cap. The schema's
    # 53 only holds for a release name short enough to leave room, which this
    # module's is not.
    condition     = alltrue([for p in var.n8n_worker_pools : can(regex("^[a-z0-9]([a-z0-9-]{0,41}[a-z0-9])?$", p.name))])
    error_message = "Each n8n_worker_pools name must be 1-43 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit. Uppercase and underscores are rejected by n8n's own schema (for example \"ITop\" or \"sec_team\" are invalid; use \"itop\" and \"sec-team\"). This is enforced here because n8n only logs a warning for a bad name and then starts the worker on the default queue anyway, so the pod reports healthy while serving the wrong jobs. The 43-character ceiling comes from KEDA: the chart names the pool's ScaledObject n8n-worker-<name>, KEDA caps that at 54 characters (it doubles as a label value and as part of the generated HPA's name), and the chart fails the render past it. A value that passes here but not there fails at apply instead of at plan."
  }

  validation {
    condition     = alltrue([for p in var.n8n_worker_pools : p.name != "default"])
    error_message = "\"default\" is not a usable n8n_worker_pools name. A pool called \"default\" would listen to a queue literally named `jobs-default`, which is a separate queue from the unlabelled default `jobs` queue and would not receive the work you expect. The chart's own worker deployment already serves the default queue; size it with n8n_worker_keda_min_replicas and n8n_worker_keda_max_replicas instead."
  }

  validation {
    condition     = length(distinct([for p in var.n8n_worker_pools : p.name])) == length(var.n8n_worker_pools)
    error_message = "n8n_worker_pools contains duplicate pool names. Each pool maps to one Deployment and one queue, so a repeated name would collide on both."
  }

  validation {
    condition     = alltrue([for p in var.n8n_worker_pools : p.min_replicas <= p.max_replicas])
    error_message = "Each n8n_worker_pools entry must have min_replicas <= max_replicas; KEDA rejects a ScaledObject whose minReplicaCount is above its maxReplicaCount."
  }

  validation {
    condition = alltrue([
      for p in var.n8n_worker_pools :
      p.min_replicas == floor(p.min_replicas) && p.min_replicas >= 0 &&
      p.max_replicas == floor(p.max_replicas) && p.max_replicas >= 1
    ])
    error_message = "Each n8n_worker_pools entry needs whole-number replica bounds, with min_replicas >= 0 and max_replicas >= 1. KEDA scales a pool to zero natively, so 0 is a valid floor. A job routed to a parked pool waits on that pool's queue and KEDA scales it up, measured at 0 to 1 within one 15-second polling interval; it does not fall back to the default queue. The one caveat is bootstrap: n8n only offers a pool for assignment while at least one of its workers is registered, so a brand-new pool declared at 0 cannot be assigned to any project and therefore never receives work. Start a new pool at min_replicas = 1, assign its projects, then lower it to 0; the assignment is stored and outlives the pods."
  }

  validation {
    condition     = alltrue([for p in var.n8n_worker_pools : p.concurrency == null ? true : (p.concurrency == floor(p.concurrency) && p.concurrency >= 1)])
    error_message = "n8n_worker_pools concurrency must be a whole number of concurrent jobs, 1 or greater, or null to inherit n8n_worker_concurrency."
  }

  validation {
    condition = !anytrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : contains(local.n8n_deprecated_env_names, e.name)
      ]
    ]))
    error_message = "n8n_worker_pools extra_env must not set deprecated n8n variables (${join(", ", local.n8n_deprecated_env_names)}). n8n ignores them and logs a deprecation warning on every start; remove the entry."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : !(
          contains(local.n8n_managed_env_names, e.name) ||
          anytrue([for pre in local.n8n_managed_env_prefixes : startswith(e.name, pre)]) ||
          e.name == "N8N_WORKER_POOL_NAME"
        )
      ]
    ]))
    error_message = "n8n_worker_pools extra_env must not set module-managed variables, and must not set N8N_WORKER_POOL_NAME: that name is owned by the pool's own `name` attribute, and overriding it would put the pool's workers on a different queue than the one this module creates a scaler for."
  }

  validation {
    # Same grammar the module-wide n8n_worker_cpu_* inputs enforce, for the same
    # reason and then one more. A pool quantity scaling.tf cannot read makes
    # local.n8n_cpu_requests_readable false, and that local gates the whole peak
    # figure, so one unparseable pool silences
    # check.autoscaling_maxima_fit_aks_capacity for main, worker and
    # webhook too, not only for the pool that carries it.
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for q in [p.cpu_request, p.cpu_limit] :
        q == null ? true : can(regex("^[0-9]+(\\.[0-9]+)?m?$", q))
      ]
    ]))
    error_message = "Each n8n_worker_pools cpu_request and cpu_limit must be a CPU quantity: a plain number of cores (\"1\", \"0.5\") or millicores with an m suffix (\"1000m\"), or null to inherit n8n_worker_cpu_request / n8n_worker_cpu_limit. Memory suffixes (Mi, Gi), units (\"1 core\"), and whitespace are not accepted, because the node-capacity model in scaling.tf reads these and a quantity it cannot parse silences the capacity check for the whole release."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for q in [p.memory_request, p.memory_limit] :
        q == null ? true : can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$", q))
      ]
    ]))
    error_message = "Each n8n_worker_pools memory_request and memory_limit must be a memory quantity: a number with an optional Kubernetes suffix (\"512Mi\", \"2Gi\", \"1G\", or plain bytes), or null to inherit n8n_worker_memory_request / n8n_worker_memory_limit. \"GB\"/\"MB\", whitespace, and CPU-style m suffixes are not accepted. Prefer the binary suffixes (Mi, Gi): 2G is 2,000,000,000 bytes while 2Gi is 2,147,483,648."
  }

  validation {
    # The same check n8n_extra_env and n8n_worker_extra_env make on their own
    # lists, applied per pool so the three inputs behave alike. The padded case
    # matters as much as the empty one: a name like " N8N_ENCRYPTION_KEY " is not
    # an exact match for anything in local.n8n_managed_env_names, so it slips
    # past the reserved-name guard below and past the duplicate check, then
    # renders as a distinct env var Kubernetes rejects at apply.
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : e.name != "" && e.name == trimspace(e.name)
      ]
    ]))
    error_message = "n8n_worker_pools extra_env entries must each have a non-empty name with no leading or trailing whitespace. A padded name would bypass the duplicate and module-managed guards while rendering as a distinct, ignored env var."
  }

  validation {
    condition = alltrue([
      for p in var.n8n_worker_pools :
      length(distinct([for e in p.extra_env : e.name])) == length(p.extra_env)
    ])
    error_message = "An n8n_worker_pools entry has duplicate extra_env names. Within one pool each variable may be set once; a repeat is silently dropped by the last-wins merge rather than reported."
  }

  validation {
    # Same C_IDENTIFIER rule n8n_worker_extra_env enforces, for the same reason:
    # an invalid name is caught by the API server when the pod template is
    # admitted, which surfaces as a failed Helm release rather than a bad input.
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", e.name))
      ]
    ]))
    error_message = "Each n8n_worker_pools extra_env name must be a valid Kubernetes environment variable name: letters, digits and underscores only, not starting with a digit (for example N8N_LOG_LEVEL). Hyphens, dots and leading digits are rejected by the API server when the pod template is admitted."
  }
}

# no validation: a plain bool needs no extra check.
variable "n8n_worker_pools_chart_verified" {
  description = "Attests that n8n_chart_version, whatever repository it resolves from, renders queueMode.workerGroups. Only consulted when n8n_worker_pools is non-empty and n8n_chart_version is a numbered release; a prerelease version (one with a SemVer 2 \"-\" segment) is already taken at your word from the version string itself and needs no extra input. This exists for the one case a hyphen can't cover: a private mirror serving a numbered version you have already built with the feature (n8n-io/n8n-hosting#189) baked in, so you would rather not tag your own build as a prerelease. Setting this to true is a one-time promise, not an automated guarantee: nothing re-checks it if n8n_chart_version later changes to point at a different, unverified chart, so treat a bump to this variable's pinned version with the same scrutiny as setting this flag the first time. Leave it false once n8n-io/n8n-hosting#189 merges to main and a real numbered floor replaces this guard entirely (n8n-io/terraform-aws-n8n#125 tracks that; track the Azure equivalent as it is opened)."
  type        = bool
  default     = false
  nullable    = false
}

# ── Credential overwrites ────────────────────────────────────────────────

variable "n8n_credentials_overwrite_secret_ref" {
  description = <<-EOT
    Existing Kubernetes Secret containing n8n credential overwrite JSON. The
    module mounts only the selected key, read-only, at
    /etc/n8n/credentials-overwrite/<key> on main, worker, and webhook-processor
    pods and sets CREDENTIALS_OVERWRITE_DATA_FILE to that path. name is the
    Secret's name in var.n8n_namespace; key defaults to
    "credentials-overwrite.json". The module accepts only this reference and
    never reads the JSON, so the payload does not enter this module's Helm values
    or managed resources. If Terraform creates the Secret, its payload can still
    enter the caller's state.

    n8n reads the file at startup. Updating the caller-managed Secret does not
    roll pods, and the module cannot add a content checksum without reading the
    payload into state. After each rotation, manually restart n8n-main,
    n8n-worker, and n8n-webhook-processor. CREDENTIALS_OVERWRITE_PERSISTENCE is
    intentionally outside this file-based feature.

    When this input is set, n8n_extra_env may not set
    CREDENTIALS_OVERWRITE_DATA or CREDENTIALS_OVERWRITE_DATA_FILE,
    n8n_extra_volumes may not use the reserved name "credentials-overwrite",
    and n8n_extra_volume_mounts may not use the reserved mount path
    "/etc/n8n/credentials-overwrite". Null preserves the escape-hatch behavior
    and rendered Helm values from before this input existed.
  EOT

  type = object({
    name = string
    key  = optional(string, "credentials-overwrite.json")
  })
  default = null

  validation {
    condition = (
      var.n8n_credentials_overwrite_secret_ref == null ? true :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", var.n8n_credentials_overwrite_secret_ref.name))
      && length(var.n8n_credentials_overwrite_secret_ref.name) <= 253
    )
    error_message = "n8n_credentials_overwrite_secret_ref.name must be a DNS-1123 subdomain of 253 characters or fewer, which is what Kubernetes requires of a Secret name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, with no empty label (e.g. \"n8n-credentials-overwrite\")."
  }

  validation {
    condition = (
      var.n8n_credentials_overwrite_secret_ref == null ? true :
      can(regex("^[-._a-zA-Z0-9]+$", var.n8n_credentials_overwrite_secret_ref.key))
      && length(var.n8n_credentials_overwrite_secret_ref.key) <= 253
      && !contains([".", ".."], var.n8n_credentials_overwrite_secret_ref.key)
      && !startswith(var.n8n_credentials_overwrite_secret_ref.key, "..")
    )
    error_message = "n8n_credentials_overwrite_secret_ref.key must be a valid Secret key of 253 characters or fewer: alphanumerics, '-', '_' and '.' only, and not \".\", \"..\" or a name starting with \"..\"."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null ? true : alltrue([
      for env in var.n8n_extra_env :
      !contains(["CREDENTIALS_OVERWRITE_DATA", "CREDENTIALS_OVERWRITE_DATA_FILE"], env.name)
    ])
    error_message = "n8n_credentials_overwrite_secret_ref conflicts with CREDENTIALS_OVERWRITE_DATA or CREDENTIALS_OVERWRITE_DATA_FILE in n8n_extra_env. Remove the escape-hatch entry and let the dedicated input set the file path."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null ? true : alltrue([
      for env in var.n8n_worker_extra_env :
      !contains(["CREDENTIALS_OVERWRITE_DATA", "CREDENTIALS_OVERWRITE_DATA_FILE"], env.name)
    ])
    error_message = "n8n_credentials_overwrite_secret_ref conflicts with CREDENTIALS_OVERWRITE_DATA or CREDENTIALS_OVERWRITE_DATA_FILE in n8n_worker_extra_env. Remove the escape-hatch entry and let the dedicated input set the file path."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null ? true : alltrue(flatten([
      for pool in var.n8n_worker_pools : [
        for env in pool.extra_env :
        !contains(["CREDENTIALS_OVERWRITE_DATA", "CREDENTIALS_OVERWRITE_DATA_FILE"], env.name)
      ]
    ]))
    error_message = "n8n_credentials_overwrite_secret_ref conflicts with CREDENTIALS_OVERWRITE_DATA or CREDENTIALS_OVERWRITE_DATA_FILE in an n8n_worker_pools entry's extra_env. Remove the escape-hatch entry and let the dedicated input set the file path."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null ? true : alltrue([
      for volume in var.n8n_extra_volumes : volume.name != "credentials-overwrite"
    ])
    error_message = "n8n_credentials_overwrite_secret_ref reserves the volume name \"credentials-overwrite\". Rename or remove the conflicting n8n_extra_volumes entry."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null ? true : alltrue([
      for mount in var.n8n_extra_volume_mounts : mount.mount_path != "/etc/n8n/credentials-overwrite"
    ])
    error_message = "n8n_credentials_overwrite_secret_ref reserves the mount path \"/etc/n8n/credentials-overwrite\". Move or remove the conflicting n8n_extra_volume_mounts entry."
  }
}

# ── n8n domain, certificate, and license ─────────────────────────────────
# The remaining inputs the single-module-deployment spec's "Deploy from the
# root" scenario calls out: domain, certificate, and license. Application
# Gateway sizing/mode inputs are added in section 11; the DNS record path is
# added in section 12; n8n runtime controls are added in section 7 onward.

variable "n8n_domain" {
  description = "Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must match the CN/SAN on the TLS certificate the App Gateway terminates with. The chart's Ingress object writes the matching `host:` rule and n8n's `N8N_HOST` from this value. n8n_domain is also always the canonical editor identity: it renders as `N8N_EDITOR_BASE_URL` and, unless n8n_webhook_url overrides it, as `N8N_WEBHOOK_URL` too."
  type        = string

  validation {
    condition     = length(var.n8n_domain) <= 253 && can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", var.n8n_domain))
    error_message = "Value must be a valid fully qualified domain name with DNS labels of at most 63 characters and no empty labels or leading or trailing hyphens (e.g. n8n.example.com)."
  }
}

variable "n8n_webhook_url" {
  description = "Optional override for the base URL n8n advertises as N8N_WEBHOOK_URL (port-aws-040-enhancements section 11 / design.md decision 8). Null retains https://<n8n_domain>, the same value used for N8N_EDITOR_BASE_URL. Set this only when webhook traffic is advertised on a different host, port, or base path than the editor UI — for example examples/split-ingress, where a public gateway terminates webhook traffic on a separate hostname from the private admin gateway. Must be an absolute HTTPS base URL with a host, no embedded credentials, whitespace, query string, or fragment, and a valid optional port (1-65535); a supplied path or trailing slash is preserved as-is. For an n8n_image_tag older than 2.30.0, which does not read N8N_WEBHOOK_URL, the module also renders the same value as the legacy WEBHOOK_URL. Editor identity (N8N_EDITOR_BASE_URL), N8N_HOST, and the internal service protocol/port are independent of this value. This input only changes what n8n advertises: it does not create a DNS record, certificate, listener, or additional route by itself — the caller remains responsible for routing the advertised host."
  type        = string
  default     = null

  validation {
    condition = var.n8n_webhook_url == null ? true : can(regex(
      "^https://[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?(/[^\\s?#@]*)?$",
      var.n8n_webhook_url
    ))
    error_message = "n8n_webhook_url must be null or an absolute HTTPS base URL with a valid host, no embedded credentials, whitespace, query string, or fragment, and a valid optional port between 1 and 65535."
  }
}

variable "n8n_additional_domains" {
  description = "Additional fully-qualified hostnames routed by the module-managed Ingress. Names are normalized to lowercase and receive the same five webhook routes plus the main catch-all as n8n_domain. n8n_domain remains canonical for N8N_HOST and the editor URL, and supplies the default N8N_WEBHOOK_URL unless n8n_webhook_url overrides it. The supplied Key Vault certificate must cover every name."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for domain in var.n8n_additional_domains :
      length(domain) <= 253 && can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", domain))
    ])
    error_message = "Every n8n_additional_domains entry must be a valid fully qualified domain name with DNS labels of at most 63 characters and no empty labels or leading or trailing hyphens."
  }

  validation {
    condition     = !contains([for domain in var.n8n_additional_domains : lower(domain)], lower(var.n8n_domain))
    error_message = "n8n_domain must not be repeated in n8n_additional_domains."
  }

  validation {
    condition     = length(distinct([for domain in var.n8n_additional_domains : lower(domain)])) == length(var.n8n_additional_domains)
    error_message = "n8n_additional_domains must not contain case-insensitive duplicates."
  }
}

variable "app_gateway_tls_cert_secret_id" {
  description = "Versioned Azure Key Vault Secret URI for the App Gateway listener's TLS certificate (e.g. `https://<vault>.vault.azure.net/secrets/<cert>/<version>`). Required — the caller is responsible for provisioning the cert and importing it into a Key Vault. The `modules/tls-letsencrypt/` and `modules/tls-self-signed/` submodules expose this exact value as their `app_gateway_tls_cert_secret_id` output; callers with an existing PKI / DigiCert / Sectigo cert can supply the secret URI directly. Pair with `var.app_gateway_keyvault_id` so this module grants the App Gateway UAMI `Key Vault Secrets User` on the vault holding the cert; alternatively grant the UAMI access out-of-band."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.vault\\.azure\\.net/secrets/[^/]+(/[a-f0-9]+)?$", var.app_gateway_tls_cert_secret_id))
    error_message = "app_gateway_tls_cert_secret_id must be a Key Vault Secret URI (e.g. https://<vault>.vault.azure.net/secrets/<cert>/<version> — version segment optional). Note: this is the *secret* URI returned by `azurerm_key_vault_certificate.<name>.secret_id`, NOT the certificate URI."
  }
}

variable "app_gateway_keyvault_id" {
  description = "Resource ID of the Key Vault holding `var.app_gateway_tls_cert_secret_id`. When `var.app_gateway_keyvault_role_assignment_enabled = true`, this module grants the App Gateway TLS-cert reader UAMI `Key Vault Secrets User` on the supplied vault — the minimum role needed for the gateway to fetch the cert at runtime. When the toggle is false (default), the caller is responsible for granting the UAMI access out-of-band (e.g. via an `access_policy` block on a vault in legacy access-policy mode). May be `null` when the toggle is false."
  type        = string
  default     = null

  validation {
    condition     = var.app_gateway_keyvault_id == null || can(regex("^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.KeyVault/vaults/.+$", var.app_gateway_keyvault_id))
    error_message = "app_gateway_keyvault_id must be null or a fully qualified Azure Key Vault resource ID (e.g. /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>)."
  }

  # Cross-variable validation (Terraform 1.9+): when the role-assignment
  # toggle is on, the vault ID must be supplied.
  validation {
    condition     = !var.app_gateway_keyvault_role_assignment_enabled || var.app_gateway_keyvault_id != null
    error_message = "app_gateway_keyvault_id must be set when app_gateway_keyvault_role_assignment_enabled is true."
  }
}

variable "app_gateway_keyvault_role_assignment_enabled" {
  description = "When true, grant the App Gateway TLS-cert reader UAMI `Key Vault Secrets User` on `var.app_gateway_keyvault_id`. Default false; the caller is then responsible for granting the UAMI access out-of-band. When set to true, `var.app_gateway_keyvault_id` MUST also be supplied. The toggle is isolated from `var.app_gateway_keyvault_id` so the section 12 role-assignment count is plan-time-known even when the ID is a same-plan-built resource attribute (e.g. `azurerm_key_vault.shared.id`)."
  type        = bool
  default     = false

  # no validation: a plain bool needs no extra check; the cross-variable
  # validation asserting app_gateway_keyvault_id is non-null when this
  # toggle is true lives on app_gateway_keyvault_id above.
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Leave null when n8n_license_key_secret_ref selects a caller-managed Kubernetes Secret instead — exactly one of the two must be set. Marked sensitive — keep out of plan output and Git history; supply via environment variable (TF_VAR_n8n_license_key) or a secret-managed terraform.tfvars. The placeholder sentinel `REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY` is rejected by the validation block below."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = (var.n8n_license_key != null) != (var.n8n_license_key_secret_ref != null)
    error_message = "Set exactly one of n8n_license_key or n8n_license_key_secret_ref."
  }

  validation {
    condition     = var.n8n_license_key == null || (length(var.n8n_license_key) > 0 && var.n8n_license_key != "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY")
    error_message = "n8n_license_key must be set to a real license key — the placeholder value from terraform.tfvars.example is not accepted. Get a key at https://n8n.io/pricing."
  }
}

variable "n8n_encryption_key" {
  description = "Existing n8n encryption key to reuse — e.g. the backed-up key from another n8n installation whose PostgreSQL data this deployment restores. Leave null (the default) to generate a fresh 48-character key. n8n cannot decrypt credentials encrypted under a different key, so any restore of an existing n8n database MUST set this to that database's original key before the first apply. Mutually exclusive with n8n_encryption_key_secret_ref. Marked sensitive — supply via environment variable (TF_VAR_n8n_encryption_key) or a secret-managed terraform.tfvars, and note the value resides in Terraform state either way."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.n8n_encryption_key == null || length(coalesce(var.n8n_encryption_key, "x")) >= 10
    error_message = "n8n_encryption_key must be at least 10 characters when set (n8n self-generated keys are 24+ characters; this module generates 48). Leave it null to have the module generate one."
  }

  validation {
    condition     = !(var.n8n_encryption_key != null && var.n8n_encryption_key_secret_ref != null)
    error_message = "Set at most one of n8n_encryption_key or n8n_encryption_key_secret_ref."
  }
}

# ── Customer-managed infrastructure ownership (add-customer-managed-modularity section 1) ──
# Plan-known switches for every independently customer-manageable layer:
# existing AKS, existing Blob storage, the n8n namespace, the KEDA
# installation, the webhook HPA, and caller-managed Kubernetes Secret
# references for workload credentials. Every switch defaults to module
# ownership so the module's greenfield behavior is unchanged when a caller
# sets none of these inputs. Literal booleans (never inferred from whether an
# existing-resource reference is null) keep every downstream `count`
# expression plan-known — see design.md decision 1. Sections 2–6 gate the
# corresponding resources and wire these references into effective locals;
# this section only establishes the input contract.

variable "create_aks" {
  description = "When true (the default), the module creates and manages the AKS cluster, its node pools, the API warm-up gate, and AGIC/ingress-related cluster identity. Set to false to deploy onto an existing AKS cluster supplied via existing_aks_cluster_name and existing_aks_resource_group_name — existing_aks_cluster_prerequisites_confirmed must then be true, and create_ingress must be false because the module cannot manage AGIC on a cluster it does not own. Kept as a static boolean rather than inferring ownership from a nullable reference because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_aks_cluster_name" {
  description = "Name of an existing AKS cluster to deploy onto. Required when create_aks = false. Ignored when create_aks = true. The module reads this cluster's OIDC issuer and connection coordinates through a data source; it does not create, modify, or manage the cluster itself."
  type        = string
  default     = null

  validation {
    condition     = var.create_aks || var.existing_aks_cluster_name != null
    error_message = "existing_aks_cluster_name is required when create_aks = false."
  }
}

variable "existing_aks_resource_group_name" {
  description = "Resource group of the existing AKS cluster named by existing_aks_cluster_name. Required when create_aks = false. Ignored when create_aks = true. May differ from var.resource_group_name."
  type        = string
  default     = null

  validation {
    condition     = var.create_aks || var.existing_aks_resource_group_name != null
    error_message = "existing_aks_resource_group_name is required when create_aks = false."
  }
}

variable "existing_aks_cluster_prerequisites_confirmed" {
  description = "Attestation required when create_aks = false, confirming that the existing AKS cluster has the OIDC issuer and workload identity enabled, has schedulable capacity and node autoscaling managed by the caller, is reachable with a supported Kubernetes version and provider access, and has no namespace, service account, Helm release, or cluster-scoped KEDA object name that conflicts with this module's resources. Terraform cannot verify any of these conditions itself — setting this to true is the caller's assertion that they are met. Ignored when create_aks = true."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.create_aks || var.existing_aks_cluster_prerequisites_confirmed
    error_message = "existing_aks_cluster_prerequisites_confirmed must be true when create_aks = false."
  }
}

variable "create_blob_storage" {
  description = "When true (the default), the module creates and manages the private Blob storage account, container, private DNS zone and link, private endpoint, and lifecycle policy. Set to false to use an existing Blob storage account and container supplied via existing_blob_storage_account_name, existing_blob_container_name, existing_blob_container_id, and existing_blob_endpoint — existing_blob_prerequisites_confirmed must then be true. The module still grants its n8n workload identity container-scoped data-plane access to the supplied container when automatic authentication is selected. Kept as a static boolean rather than inferring ownership from a nullable reference because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_blob_storage_account_name" {
  description = "Name of an existing Azure Storage account holding the private Blob container n8n uses for binary and execution data. Required when create_blob_storage = false. Ignored when create_blob_storage = true. The module does not create, modify, or inspect this account."
  type        = string
  default     = null

  validation {
    condition     = var.create_blob_storage || var.existing_blob_storage_account_name != null
    error_message = "existing_blob_storage_account_name is required when create_blob_storage = false."
  }

  validation {
    condition     = var.existing_blob_storage_account_name == null ? true : can(regex("^[a-z0-9]{3,24}$", var.existing_blob_storage_account_name))
    error_message = "existing_blob_storage_account_name must be null or a valid Azure Storage account name containing 3-24 lowercase letters or digits."
  }
}

variable "existing_blob_container_name" {
  description = "Name of the existing private Blob container n8n uses for binary and execution data. Required when create_blob_storage = false. Ignored when create_blob_storage = true."
  type        = string
  default     = null

  validation {
    condition     = var.create_blob_storage || var.existing_blob_container_name != null
    error_message = "existing_blob_container_name is required when create_blob_storage = false."
  }

  validation {
    condition = var.existing_blob_container_name == null ? true : (
      can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.existing_blob_container_name)) &&
      !strcontains(var.existing_blob_container_name, "--")
    )
    error_message = "existing_blob_container_name must be null or a valid Azure Blob container name containing 3-63 lowercase letters, digits, or single hyphens, starting and ending with a letter or digit."
  }
}

variable "existing_blob_container_id" {
  description = "Resource ID of the existing Blob container named by existing_blob_container_name, used to scope the n8n workload identity's Storage Blob Data Contributor role assignment when automatic authentication is selected. Required when create_blob_storage = false. Ignored when create_blob_storage = true. Kept separate from the account and container names because the role-assignment scope must be known without a data-source lookup, and it may sit in a different resource group or subscription than var.resource_group_name — the applying identity needs role-assignment permission at this scope."
  type        = string
  default     = null

  validation {
    condition     = var.create_blob_storage || var.existing_blob_container_id != null
    error_message = "existing_blob_container_id is required when create_blob_storage = false."
  }

  validation {
    condition = var.existing_blob_container_id == null ? true : can(regex(
      "^/subscriptions/.+/resourceGroups/.+/providers/Microsoft\\.Storage/storageAccounts/.+/blobServices/default/containers/.+$",
      var.existing_blob_container_id,
    ))
    error_message = "existing_blob_container_id must be null or a fully qualified Azure Blob container resource ID."
  }

  validation {
    condition = var.existing_blob_container_id == null ? true : (
      var.existing_blob_storage_account_name == null || var.existing_blob_container_name == null ? true : try(
        lower(split("/", var.existing_blob_container_id)[8]) == lower(var.existing_blob_storage_account_name) &&
        split("/", var.existing_blob_container_id)[12] == var.existing_blob_container_name,
        false,
      )
    )
    error_message = "existing_blob_container_id must identify the storage account and container supplied by existing_blob_storage_account_name and existing_blob_container_name."
  }
}

variable "existing_blob_endpoint" {
  description = "Blob service endpoint of the existing storage account named by existing_blob_storage_account_name, including scheme (for example https://account.blob.core.windows.net/). Required when create_blob_storage = false. Ignored when create_blob_storage = true."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.create_blob_storage || var.existing_blob_endpoint != null
    error_message = "existing_blob_endpoint is required when create_blob_storage = false."
  }

  validation {
    condition     = var.existing_blob_endpoint == null ? true : can(regex("^https://[^[:space:]]+/$", var.existing_blob_endpoint))
    error_message = "existing_blob_endpoint must be null or an HTTPS service endpoint ending in `/` with no whitespace."
  }
}

variable "existing_blob_prerequisites_confirmed" {
  description = "Attestation required when create_blob_storage = false, confirming that the existing Blob storage account and container have private networking and DNS resolution, encryption at rest, and retention configured outside this module, and are compatible with the selected credential mode. Terraform cannot verify any of these conditions itself — it does not inspect customer-managed Azure resources through data sources — setting this to true is the caller's assertion that they are met. Ignored when create_blob_storage = true."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.create_blob_storage || var.existing_blob_prerequisites_confirmed
    error_message = "existing_blob_prerequisites_confirmed must be true when create_blob_storage = false."
  }
}

variable "create_namespace" {
  description = "When true (the default), the module creates the n8n Kubernetes namespace named by n8n_namespace. Set to false to deploy into an existing namespace the caller already created — the module never deletes a caller-owned namespace. Kept as a static boolean rather than inferring ownership from a nullable reference because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_namespace" {
  description = "Name of the Kubernetes namespace n8n's Secrets, ServiceAccount, and Helm release live in. The module creates this namespace when create_namespace = true (the default); when create_namespace = false, it must already exist and this value is used as-is."
  type        = string
  default     = "n8n"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.n8n_namespace)) && length(var.n8n_namespace) <= 63
    error_message = "n8n_namespace must be a valid Kubernetes namespace name: 1-63 lowercase alphanumeric characters or hyphens, starting and ending with an alphanumeric character."
  }
}

variable "install_keda" {
  description = "When true (the default), the module installs KEDA into the cluster through modules/controllers (namespace plus Helm release). Set to false when KEDA is already installed — either by a direct caller of modules/controllers or by another process — existing_keda_prerequisites_confirmed must then be true. The chart-rendered worker ScaledObject and the root TriggerAuthentication are unaffected by this switch."
  type        = bool
  default     = true
  nullable    = false
}

variable "keda_namespace" {
  description = "Name of the Kubernetes namespace KEDA's operator and CRDs live in. Created when install_keda = true (the default) and this module owns the installation; when install_keda = false, KEDA must already be running in this namespace."
  type        = string
  default     = "keda"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.keda_namespace)) && length(var.keda_namespace) <= 63
    error_message = "keda_namespace must be a valid Kubernetes namespace name: 1-63 lowercase alphanumeric characters or hyphens, starting and ending with an alphanumeric character."
  }
}

variable "existing_keda_prerequisites_confirmed" {
  description = "Attestation required when install_keda = false, confirming that KEDA and its CRDs (including TriggerAuthentication) are already installed and ready in keda_namespace, either by a direct caller of modules/controllers ordered with depends_on or by another process. Terraform cannot verify CRD readiness at plan time — setting this to true is the caller's assertion that it is met. Ignored when install_keda = true."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.install_keda || var.existing_keda_prerequisites_confirmed
    error_message = "existing_keda_prerequisites_confirmed must be true when install_keda = false."
  }
}

variable "keda_chart_repository" {
  description = "Helm chart repository URL for the KEDA chart, passed through to modules/controllers. Override for a private mirror of the kedacore charts (for example an internal ChartMuseum or ACR Helm registry) when the cluster cannot reach the public kedacore.github.io repository."
  type        = string
  default     = "https://kedacore.github.io/charts"
  nullable    = false

  validation {
    condition     = can(regex("^(https|oci)://[^[:space:]]+$", var.keda_chart_repository))
    error_message = "keda_chart_repository must be an https:// or oci:// URL with no whitespace."
  }
}

variable "n8n_webhook_hpa_enabled" {
  description = "When true (the default), the module creates the webhook-processor HPA in scaling.tf. Set to false when a caller manages webhook-processor scaling independently — the chart still sets webhook replicas to n8n_webhook_hpa_min_replicas so the caller has a stable deployment to scale, and every webhook service output remains available."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_license_key_secret_ref" {
  description = "Existing Kubernetes Secret name and key holding the n8n Enterprise license key, for callers who manage this credential outside Terraform. Mutually exclusive with n8n_license_key — exactly one must be set. The module does not read the Secret's value; Terraform renders only the name and key into the n8n chart."
  type = object({
    name = string
    key  = string
  })
  default = null

  validation {
    condition     = var.n8n_license_key_secret_ref == null ? true : (trimspace(var.n8n_license_key_secret_ref.name) != "" && trimspace(var.n8n_license_key_secret_ref.key) != "")
    error_message = "n8n_license_key_secret_ref.name and .key must be non-empty when set."
  }
}

variable "n8n_encryption_key_secret_ref" {
  description = "Existing Kubernetes Secret carrying the n8n encryption key, for callers who manage this credential outside Terraform — for example a key backed up from another n8n installation. Mutually exclusive with n8n_encryption_key. Different in shape from n8n_license_key_secret_ref: the chart's secretRefs.existingSecret (n8n.tf) names one Secret that n8n reads FOUR keys from — N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT, and N8N_PROTOCOL — so this replaces kubernetes_secret.n8n_encryption_key entirely, and your Secret must carry every one of them: N8N_HOST is var.n8n_domain, N8N_PORT is \"5678\", N8N_PROTOCOL is \"http\". key must be exactly \"N8N_ENCRYPTION_KEY\" — the chart hardcodes this key name and honors no override, unlike n8n_license_key_secret_ref's key. When set, the n8n_encryption_key output is null because Terraform does not know the value. The module does not read the Secret's value."
  type = object({
    name = string
    key  = string
  })
  default = null

  validation {
    condition     = var.n8n_encryption_key_secret_ref == null ? true : trimspace(var.n8n_encryption_key_secret_ref.name) != ""
    error_message = "n8n_encryption_key_secret_ref.name must be non-empty when set."
  }

  validation {
    condition     = var.n8n_encryption_key_secret_ref == null ? true : var.n8n_encryption_key_secret_ref.key == "N8N_ENCRYPTION_KEY"
    error_message = "n8n_encryption_key_secret_ref.key must be exactly \"N8N_ENCRYPTION_KEY\". The chart's secretRefs.existingSecret reads this exact key name from the referenced Secret and takes no override."
  }
}

variable "postgres_password_secret_ref" {
  description = "Existing Kubernetes Secret name and key holding the external PostgreSQL password, for callers who manage this credential outside Terraform. Applies only to the external database path (create_database = false) — the module-managed PostgreSQL Flexible Server always generates and manages its own password. Mutually exclusive with postgres_external_password; exactly one must be set when create_database = false. The module does not read the Secret's value."
  type = object({
    name = string
    key  = string
  })
  default = null

  validation {
    condition     = var.postgres_password_secret_ref == null ? true : (trimspace(var.postgres_password_secret_ref.name) != "" && trimspace(var.postgres_password_secret_ref.key) != "")
    error_message = "postgres_password_secret_ref.name and .key must be non-empty when set."
  }

  validation {
    condition     = var.create_database ? var.postgres_password_secret_ref == null : true
    error_message = "postgres_password_secret_ref is ignored when create_database = true; the module always generates and manages the PostgreSQL password for its own server."
  }
}

variable "redis_password_secret_ref" {
  description = "Existing Kubernetes Secret name and key holding the external Redis password, for callers who manage this credential outside Terraform. Applies only to the external Redis path (create_redis = false) — the module-managed Azure Managed Redis instance always uses its own generated access key. Mutually exclusive with redis_external_password. The module does not read the Secret's value."
  type = object({
    name = string
    key  = string
  })
  default = null

  validation {
    condition     = var.redis_password_secret_ref == null ? true : (trimspace(var.redis_password_secret_ref.name) != "" && trimspace(var.redis_password_secret_ref.key) != "")
    error_message = "redis_password_secret_ref.name and .key must be non-empty when set."
  }

  validation {
    condition     = var.create_redis ? var.redis_password_secret_ref == null : true
    error_message = "redis_password_secret_ref is ignored when create_redis = true; the module always uses its managed Azure Managed Redis access key."
  }
}
