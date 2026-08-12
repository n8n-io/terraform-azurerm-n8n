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
  default     = "Standard_D2s_v7"

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
  description = "n8n Enterprise license activation key."
  type        = string
  sensitive   = true

  validation {
    condition     = trimspace(var.n8n_license_key) != "" && var.n8n_license_key != "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
    error_message = "n8n_license_key must contain a real n8n Enterprise license key, not the example placeholder."
  }
}

# no validation: Azure validates tag limits at apply time.
variable "common_tags" {
  description = "Additional Azure tags applied to example and module resources."
  type        = map(string)
  default     = {}
}
