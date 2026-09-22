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

variable "friendly_name_prefix" {
  description = "Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions."
  type        = string
  default     = "n8nsplit"

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must contain 2 to 12 lowercase letters or digits."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for the n8n editor UI and REST API (e.g. n8n.example.com). Served by the internal (admin) Application Gateway, so it resolves to a private address and is reachable only from inside the VNet or over a VPN/peering. This example issues its own lab-grade self-signed certificate for it (main.tf), so replace that with a real certificate before production use."
  type        = string

  validation {
    condition     = can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", var.n8n_domain))
    error_message = "n8n_domain must be a valid fully-qualified domain name."
  }
}

variable "webhook_subdomain" {
  description = "Label prepended to n8n_domain to form the public webhook hostname. With the default and n8n_domain = n8n.example.com, webhooks are served from hooks.n8n.example.com by the internet-facing (webhook) Application Gateway. A separate hostname is required because a DNS name resolves to one gateway's frontend."
  type        = string
  default     = "hooks"

  validation {
    condition     = length(var.webhook_subdomain) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.webhook_subdomain))
    error_message = "webhook_subdomain must be a single lowercase DNS label: letters, digits and hyphens, not starting or ending with a hyphen."
  }
}

variable "create_webhook_waf_policy" {
  description = "Attach a module-managed OWASP 3.2 WAF policy (Detection mode) to the public webhook Application Gateway (WAF_v2 SKU). Set to false to use the cheaper Standard_v2 SKU with no WAF. The admin gateway is private-only and never gets a WAF policy regardless of this setting: rate limiting and managed rule groups only make sense on the endpoint that accepts untrusted internet traffic."
  type        = bool
  default     = true
}

variable "admin_allowed_cidr_blocks" {
  description = "IPv4 CIDR blocks allowed to reach the internal admin Application Gateway, in addition to it already being private (no public IP, private-subnet frontend only). Empty (the default) allows any source that can already route to the VNet. Narrow this to your VPN pool or peered ranges for defense in depth."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.admin_allowed_cidr_blocks : can(cidrnetmask(cidr)) && !strcontains(cidr, ":")])
    error_message = "admin_allowed_cidr_blocks must contain valid IPv4 CIDRs."
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

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.n8n_license_key) != "" && var.n8n_license_key != "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
    error_message = "n8n_license_key must contain a real n8n Enterprise license key, not the example placeholder."
  }
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

variable "pg_backup_retention_days" {
  description = "Number of days to retain automated PostgreSQL Flexible Server backups. Passed through to the root module's pg_backup_retention_days. Azure enforces a range of 7–35 days for Flexible Server (unlike RDS, Azure does not allow disabling backups)."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.pg_backup_retention_days >= 7 && var.pg_backup_retention_days <= 35
    error_message = "pg_backup_retention_days must be between 7 and 35 (inclusive) — Azure Flexible Server does not support disabling backups."
  }
}

variable "blob_delete_retention_days" {
  description = "Optional soft-delete retention window, in days, for the module-managed Blob storage account. Passed through to the root module's blob_delete_retention_days. Null (the default) leaves soft delete disabled."
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
