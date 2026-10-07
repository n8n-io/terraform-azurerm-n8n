# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

variable "location" {
  description = "Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there."
  type        = string
  default     = "eastus"

  validation {
    condition     = can(regex("^[a-z]+[a-z0-9]*$", var.location))
    error_message = "location must use an Azure short name such as eastus or westeurope."
  }
}

variable "resource_group_location" {
  description = "Optional Azure metadata location for both resource groups. Defaults to location. Set this only when moving regional resources while retaining existing resource groups and global DNS zones."
  type        = string
  default     = null

  validation {
    condition     = var.resource_group_location == null || can(regex("^[a-z]+[a-z0-9]*$", var.resource_group_location))
    error_message = "resource_group_location must use an Azure short name such as eastus or westeurope."
  }
}

variable "friendly_name_prefix" {
  description = "Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions."
  type        = string
  default     = "n8nwpool"

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must contain 2 to 12 lowercase letters or digits."
  }
}

variable "n8n_domain" {
  description = "Canonical fully-qualified domain for n8n. It must be the Azure DNS zone apex or a subdomain of public_dns_zone_name."
  type        = string

  validation {
    condition     = can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", var.n8n_domain))
    error_message = "n8n_domain must be a valid fully-qualified domain name."
  }
}

variable "public_dns_zone_name" {
  description = "Public Azure DNS zone created by this example. Delegate its output name servers at the domain registrar."
  type        = string

  validation {
    condition = (
      lower(var.n8n_domain) == lower(var.public_dns_zone_name) ||
      endswith(lower(var.n8n_domain), ".${lower(var.public_dns_zone_name)}")
    )
    error_message = "n8n_domain must be the public_dns_zone_name apex or one of its subdomains."
  }
}

variable "aks_api_authorized_ip_ranges" {
  description = "Operator and CI IPv4 CIDRs allowed to reach the public AKS API. Empty leaves it unrestricted and is not recommended for production."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.aks_api_authorized_ip_ranges : can(cidrnetmask(cidr)) && !strcontains(cidr, ":")])
    error_message = "aks_api_authorized_ip_ranges must contain valid IPv4 CIDRs."
  }
}

variable "aks_node_vm_size" {
  description = "Azure VM SKU for both AKS node pools. Defaults larger than examples/small's Standard_D2s_v5 because the three worker pools below add their own CPU ceilings on top of the main/worker/webhook ceilings; see the arithmetic on local.tier.aks_node_count_max in main.tf. Confirm regional and zonal availability for the selected subscription before applying."
  type        = string
  default     = "Standard_D4s_v5"

  validation {
    condition     = can(regex("^Standard_[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*$", var.aks_node_vm_size))
    error_message = "aks_node_vm_size must be a valid Azure Standard VM SKU name."
  }
}

variable "aks_availability_zones" {
  description = "Availability zones used by both AKS node pools. Restrict this list when the selected VM SKU is unavailable in one or more regional zones."
  type        = list(string)
  default     = ["1", "2", "3"]

  validation {
    condition     = alltrue([for zone in var.aks_availability_zones : can(regex("^[1-9][0-9]*$", zone))])
    error_message = "aks_availability_zones must contain numeric Azure zone identifiers, or be empty for a non-zonal deployment."
  }
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Worker pools need the feat:workerPools entitlement on top of whatever else the deployment uses."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.n8n_license_key) != "" && var.n8n_license_key != "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
    error_message = "n8n_license_key must contain a real n8n Enterprise license key, not the example placeholder."
  }
}

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum main replicas passed through to the root module's n8n_main_hpa_min_replicas, the sole topology selector. The default of 2 keeps this example on multi-main, which needs feat:multipleMainInstances on top of feat:workerPools. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); worker pools still need feat:workerPools either way."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_min_replicas >= 1 && var.n8n_main_hpa_min_replicas == floor(var.n8n_main_hpa_min_replicas)
    error_message = "n8n_main_hpa_min_replicas must be a whole number of at least 1."
  }
}

variable "pg_backup_retention_days" {
  description = "Number of days to retain automated PostgreSQL Flexible Server backups, passed through to the root module's pg_backup_retention_days. The default of 7 matches this example's documented sizing (Azure enforces 7-35 days for Flexible Server; it cannot disable backups)."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.pg_backup_retention_days >= 7 && var.pg_backup_retention_days <= 35
    error_message = "pg_backup_retention_days must be between 7 and 35 (inclusive); Azure Flexible Server does not support disabling backups."
  }
}

variable "blob_delete_retention_days" {
  description = "Optional soft-delete retention window, in days, passed through to the root module's blob_delete_retention_days. Null (the default) leaves Blob soft delete disabled, this example's current behavior."
  type        = number
  default     = null

  validation {
    condition     = var.blob_delete_retention_days == null || (var.blob_delete_retention_days >= 1 && var.blob_delete_retention_days <= 365 && var.blob_delete_retention_days == floor(var.blob_delete_retention_days))
    error_message = "blob_delete_retention_days must be a whole number from 1 through 365 (the Azure Blob soft-delete retention bounds), or null to leave soft delete disabled."
  }
}

# no validation: Azure validates tag limits at apply time.
variable "common_tags" {
  description = "Additional Azure tags applied to example and module resources."
  type        = map(string)
  default     = {}
}

# ── Worker pools ────────────────────────────────────────────────────────────
# The KEDA bounds size the default, unlabelled worker deployment, which keeps
# serving the `jobs` queue for every project that is not pinned to a pool and
# doubles as a control group beside the pools.
#
# n8n_worker_pools is deliberately not a variable here. The pool topology is
# the point of this example, so it is written inline in main.tf's
# local.worker_pools, where it can be read and commented, rather than hidden
# behind a default.

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum worker replicas KEDA keeps running for the default (unlabelled) worker deployment."
  type        = number
  default     = 1
  nullable    = false
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may scale the default (unlabelled) worker deployment to."
  type        = number
  default     = 10
  nullable    = false
}

# ── Chart ─────────────────────────────────────────────────────────────────────
# EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE. n8n_chart_version is required
# here, unlike every other example, because the module's default does not
# render pools. queueMode.workerGroups (n8n-io/n8n-hosting#189) is merged to
# the chart's preview/worker-pools branch but not released; a chart that
# predates it accepts the key and silently renders nothing, so
# N8N_WORKER_POOLS_ENABLED would land on every pod with no pool behind it once
# local.worker_pools is wired into module "n8n". Making the version a required
# input means this example cannot be applied without choosing a chart on
# purpose. Until the release exists, that is an official prerelease build
# published from the branch via n8n-io/n8n-hosting#191's "Preview chart"
# GitHub Action to the default n8n_chart_repository, or a chart built from the
# branch and pushed to a private mirror named by n8n_chart_repository and
# confirmed to render pools with n8n_worker_pools_chart_verified; see
# README.md, "Getting a chart that renders pools".

variable "n8n_chart_repository" {
  description = "Helm chart repository for the n8n chart, passed through to the module's n8n_chart_repository. Override to point this example at a private mirror, e.g. an ACR OCI repository carrying a self-built preview chart."
  type        = string
  default     = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  nullable    = false

  validation {
    # Keep in sync with the module root's n8n_chart_repository validation.
    condition     = can(regex("^(https|oci)://(?:[A-Za-z0-9._~-]+|\\[[0-9A-Fa-f:.]+\\])(?::[0-9]+)?(?:/[^[:space:]]*)?$", var.n8n_chart_repository))
    error_message = "n8n_chart_repository must be an https:// or oci:// URL with a host, an optional port, and no whitespace, such as oci://myregistry.azurecr.io/helm. It must not embed credentials (user:password@): authenticate the Terraform runner to the registry instead."
  }
}

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy, passed to the module's n8n_chart_version. Required by this example because the module default predates queueMode.workerGroups and would render no pools once local.worker_pools is wired in. Pin the first release that carries the feature once it exists, or a prerelease build (e.g. 1.11.0-preview.workerpools.1, published via n8n-io/n8n-hosting's Preview chart GitHub Action) in the meantime."
  type        = string
  nullable    = false

  validation {
    # Keep in sync with the module root's n8n_chart_version validation
    # exactly: a bare major.minor.patch, optionally followed by a hyphen and
    # any suffix. Unlike the AWS sibling module, the root module here does
    # NOT accept a separate "+buildmetadata" suffix with no hyphen (confirmed
    # against variables.tf's own regex): "1.11.0+build.5" is rejected here
    # and at the module, not merely deferred to helm_release.n8n's
    # precondition. A looser regex here would let a value pass this example's
    # validation and still fail one level up.
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-.+)?$", var.n8n_chart_version))
    error_message = "n8n_chart_version must be an exact SemVer version such as \"1.11.0\" or \"1.11.0-preview.workerpools.1\". Helm resolves chart versions literally here, so a range (\">= 1.10\", \"~1.10.0\"), a leading \"v\", or a bare \"+buildmetadata\" suffix with no hyphen is not accepted."
  }
}

variable "n8n_worker_pools_chart_verified" {
  description = "Passed to the module's n8n_worker_pools_chart_verified. Leave false for the documented path, a prerelease build such as 1.11.0-preview.workerpools.1, which the module accepts from the version string alone. Set true only when n8n_chart_version is a numbered build of the feature branch you have confirmed renders queueMode.workerGroups; the module takes that at your word and never re-checks it."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_image_tag" {
  description = "Pinned n8n application version, passed to the module's n8n_image_tag. Defaults to 2.39.0, the first n8n release that reads N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME; an older image accepts both and silently ignores them once local.worker_pools is wired in, so the pods come up healthy with the feature doing nothing. The root module's own default (2.35.0) predates that floor, which is why this example pins its own default rather than leaving the module default in place."
  type        = string
  default     = "2.39.0"
  nullable    = false

  validation {
    # Keep in sync with the module root's n8n_image_tag validation.
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9._-]+)?$", var.n8n_image_tag))
    error_message = "n8n_image_tag must start with a semantic application version such as 2.39.0 or 2.39.0-custom."
  }
}
