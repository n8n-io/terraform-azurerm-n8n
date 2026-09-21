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
  default     = "n8ncms"

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must contain 2 to 12 lowercase letters or digits."
  }
}

variable "n8n_domain" {
  description = "Fully-qualified domain name for n8n. This example issues its own lab-grade self-signed certificate for it (main.tf); replace that with a real certificate before production use."
  type        = string

  validation {
    condition     = can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", var.n8n_domain))
    error_message = "n8n_domain must be a valid fully-qualified domain name."
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
  description = "Azure VM SKU for both AKS node pools. Confirm that the selected SKU supports the requested availability zones in the target region."
  type        = string
  default     = "Standard_D4s_v4"

  validation {
    condition     = can(regex("^Standard_[A-Z][A-Za-z0-9_]+$", var.aks_node_vm_size))
    error_message = "aks_node_vm_size must be a valid Azure VM SKU name such as Standard_D4s_v4."
  }
}

variable "aks_availability_zones" {
  description = "Availability zones used by both AKS node pools. Set to an empty list when the selected region or SKU does not support zones."
  type        = list(string)
  default     = ["1", "2", "3"]

  validation {
    condition     = alltrue([for zone in var.aks_availability_zones : can(regex("^[1-9][0-9]*$", zone))])
    error_message = "aks_availability_zones must contain numeric zone identifiers as strings, or be empty."
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
  description = "Number of days to retain automated PostgreSQL Flexible Server backups, passed through to the root module's pg_backup_retention_days. Azure enforces a range of 7–35 days for Flexible Server."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.pg_backup_retention_days >= 7 && var.pg_backup_retention_days <= 35
    error_message = "pg_backup_retention_days must be between 7 and 35 (inclusive); Azure Flexible Server does not support disabling backups."
  }
}

# no validation: Azure validates tag limits at apply time.
variable "common_tags" {
  description = "Additional Azure tags applied to example and module resources."
  type        = map(string)
  default     = {}
}
