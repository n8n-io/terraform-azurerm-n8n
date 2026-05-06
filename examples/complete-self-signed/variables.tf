# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

variable "location" {
  description = "Azure region to deploy into (e.g. eastus, westeurope, australiaeast)."
  type        = string
  default     = "eastus"
}

variable "friendly_name_prefix" {
  description = "Lowercase prefix used in every resource name. 2–12 alnum-lowercase chars (Azure storage-account naming is the binding constraint)."
  type        = string
  default     = "n8nlab"
}

variable "n8n_domain" {
  description = "Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must be a subdomain of (or equal to) var.public_dns_zone_name — the example creates an Azure DNS zone with that name and the n8n module writes the A-record for n8n_domain into it. The self-signed cert's CN is set to this same value."
  type        = string
}

variable "public_dns_zone_name" {
  description = "Name of the public Azure DNS zone the example creates (e.g. example.com). var.n8n_domain must resolve inside this zone. After the first apply, copy the zone's name-server records (terraform output -json public_dns_zone_name_servers) into your registrar so the world can resolve n8n_domain to the App Gateway public IP — Terraform alone cannot delegate NS upstream."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing."
  type        = string
  sensitive   = true
}

variable "tls_validity_period_hours" {
  description = "Lifetime of the self-signed certificate the submodule issues, in hours. Defaults to 8760 (1 year). The cert auto-renews via Terraform when within `early_renewal_hours` (30 days) of expiry — re-running terraform apply within that window regenerates the key + cert and re-imports them into the shared Key Vault. Self-signed mode is intended for lab / internal-only use; production deployments should use the sibling `examples/complete-letsencrypt/` example or the BYO `custom_pfx` path on the root module."
  type        = number
  default     = 8760
}

variable "common_tags" {
  description = "Additional Azure tags to apply to the example's resource group, VNet, and shared Key Vault."
  type        = map(string)
  default     = {}
}
