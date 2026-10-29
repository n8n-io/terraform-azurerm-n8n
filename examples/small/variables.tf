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
  default     = "n8nsmall"

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
  description = "Azure VM SKU for both AKS node pools. Confirm regional and zonal availability for the selected subscription before applying."
  type        = string
  default     = "Standard_D2s_v5"

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

# no validation: a plain bool. nullable = false makes an explicit null fall back
# to the default (true).
variable "aks_node_pools_follow_cluster_version" {
  description = "Passed through to the root module's aks_node_pools_follow_cluster_version. True (the default) makes a Kubernetes version change upgrade the control plane and then both node pools in the same apply, a surge upgrade that drains every node. Set false to upgrade only the control plane from Terraform and upgrade the pools out of band with `az aks nodepool upgrade`; switching to false plans no change. See docs/troubleshooting.md in the repository root."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Leave null only when n8n_license_cert_secret_ref supplies an offline license certificate instead; the root module requires exactly one license credential."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.n8n_license_key == null || (trimspace(coalesce(var.n8n_license_key, "x")) != "" && var.n8n_license_key != "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY")
    error_message = "n8n_license_key must contain a real n8n Enterprise license key, not the example placeholder."
  }
}

# no validation: the root module validates the Secret name and key format and
# the one-license-credential rule.
variable "n8n_license_cert_secret_ref" {
  description = "Optional caller-managed Kubernetes Secret (name and key) in the n8n namespace holding a base64-encoded offline license certificate, passed through to the root module's n8n_license_cert_secret_ref. Set n8n_license_key = null when using it. Null (the default) keeps the license-key path. See the root README, \"Offline license activation\"."
  type = object({
    name = string
    key  = string
  })
  default = null
}

# no validation: the root module rejects reserved and duplicate names.
variable "n8n_extra_env" {
  description = "Additional non-secret environment variables for every n8n application container, passed through to the root module's n8n_extra_env. Empty (the default) adds none. For example, pin N8N_INSTANCE_ID here so an offline license certificate matches the deployment's instance ID."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false
}

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum main replicas passed through to the root module's n8n_main_hpa_min_replicas, the sole topology selector. The default of 2 keeps this example on multi-main. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); other selected features, such as Azure Blob binary/execution-data entitlements, still require their own license grants and are not affected by this setting."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_min_replicas >= 1 && var.n8n_main_hpa_min_replicas == floor(var.n8n_main_hpa_min_replicas)
    error_message = "n8n_main_hpa_min_replicas must be a whole number of at least 1."
  }
}

variable "n8n_image_tag" {
  description = "n8n application image tag, passed straight through to the root module's n8n_image_tag. Null (the default) sends no tag, so the chart's own default runs: its appVersion (2.43.5 at the module's default chart 1.16.0), which moves only when the module's n8n_chart_version moves, so upgrading the module can also upgrade n8n across its database migrations. Pin a concrete version (for example \"2.42.4\") in production to upgrade n8n deliberately; see [docs/upgrading-n8n.md](../../docs/upgrading-n8n.md)."
  type        = string
  default     = null

  validation {
    # Keep in sync with the module root's n8n_image_tag format validation.
    condition     = var.n8n_image_tag == null || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9._-]+)?$", var.n8n_image_tag))
    error_message = "n8n_image_tag must be null or start with a semantic application version such as 2.42.4 or 2.42.4-custom."
  }
}

variable "pg_backup_retention_days" {
  description = "Number of days to retain automated PostgreSQL Flexible Server backups, passed through to the root module's pg_backup_retention_days. The default of 7 matches this example's documented sizing (Azure enforces 7-35 days for Flexible Server; it cannot disable backups)."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.pg_backup_retention_days >= 7 && var.pg_backup_retention_days <= 35
    error_message = "pg_backup_retention_days must be between 7 and 35 (inclusive) — Azure Flexible Server does not support disabling backups."
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

variable "partner_id" {
  description = "Azure Customer Usage Attribution (CUA) tracking ID for the azurerm provider's partner_id, which Microsoft documents as the Terraform route. Defaults to n8n's Microsoft-issued tracking GUID; set to null to opt out, which sends no partner_id and falls back to the ARM_PARTNER_ID environment variable. Accepts `<guid>`, `pid-<guid>`, or `pid-<guid>-partnercenter`."
  type        = string
  default     = "f1198e81-0323-4ce9-9753-ed1a8c596b19"

  validation {
    condition     = var.partner_id == null ? true : can(regex("(?i)^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|pid-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(-partnercenter)?)$", var.partner_id))
    error_message = "partner_id must be null, a GUID, `pid-<guid>`, or `pid-<guid>-partnercenter`."
  }
}

# no validation: Azure validates tag limits at apply time.
variable "common_tags" {
  description = "Additional Azure tags applied to example and module resources."
  type        = map(string)
  default     = {}
}
