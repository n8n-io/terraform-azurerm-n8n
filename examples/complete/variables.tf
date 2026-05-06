# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

variable "location" {
  description = "Azure region to deploy into (e.g. eastus, westeurope, australiaeast). Flowed into both `module.infra` and the example-owned resource groups, VNet, DNS zone, and shared Key Vault."
  type        = string
  default     = "eastus"
}

variable "friendly_name_prefix" {
  description = "Lowercase prefix used in every resource name. 2–12 alnum-lowercase chars (Azure storage-account naming is the binding constraint). Flowed verbatim into `module.infra` and `module.workload` so the same prefix appears across both tiers."
  type        = string
  default     = "n8nlab"
}

variable "n8n_domain" {
  description = "Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must be a subdomain of (or equal to) var.public_dns_zone_name — the example creates an Azure DNS zone with that name and the example's `azurerm_dns_a_record.n8n` writes the A-record for n8n_domain into it pointing at `module.infra.appgw_public_ip_address`."
  type        = string
}

variable "public_dns_zone_name" {
  description = "Name of the public Azure DNS zone the example creates (e.g. example.com). var.n8n_domain must resolve inside this zone. After the first apply, copy the zone's name-server records (terraform output -json public_dns_zone_name_servers) into your registrar so the world can resolve n8n_domain to the App Gateway public IP — Terraform alone cannot delegate NS upstream."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Flowed into `module.workload` as the chart's `n8n.encryption.licenseActivationKey` value."
  type        = string
  sensitive   = true
}

variable "common_tags" {
  description = "Additional Azure tags applied to the example's resource groups, VNet, DNS zone, shared Key Vault, AND merged into `local.common_tags` inside both `module.infra` and `module.workload`."
  type        = map(string)
  default     = {}
}
