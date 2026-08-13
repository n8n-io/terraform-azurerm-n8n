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
  default     = "n8ncmc"

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

variable "aks_node_vm_size" {
  description = "Azure VM SKU for the caller-owned AKS node pool. Confirm regional and zonal availability for the selected subscription before applying."
  type        = string
  default     = "Standard_D2s_v5"

  validation {
    condition     = can(regex("^Standard_[A-Za-z0-9]+(?:_[A-Za-z0-9]+)*$", var.aks_node_vm_size))
    error_message = "aks_node_vm_size must be a valid Azure Standard VM SKU name."
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

# no validation: Azure validates tag limits at apply time.
variable "common_tags" {
  description = "Additional Azure tags applied to example and module resources."
  type        = map(string)
  default     = {}
}
