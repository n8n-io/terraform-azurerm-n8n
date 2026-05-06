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
  description = "Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must be a subdomain of (or equal to) var.public_dns_zone_name — the example creates an Azure DNS zone with that name and the n8n module writes the A-record for n8n_domain into it. The Let's Encrypt DNS-01 challenge writes its validation TXT record to the same zone."
  type        = string
}

variable "public_dns_zone_name" {
  description = "Name of the public Azure DNS zone the example creates (e.g. example.com). var.n8n_domain must resolve inside this zone. The Let's Encrypt DNS-01 challenge writes its validation TXT record to this zone — the principal resolved from the AZURE_* env vars on the apply host must hold `DNS Zone Contributor` on it. After the first apply, copy the zone's name-server records (terraform output -json public_dns_zone_name_servers) into your registrar so the world can resolve n8n_domain to the App Gateway public IP."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing."
  type        = string
  sensitive   = true
}

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for ACME issuance and renewal notifications. Required — Let's Encrypt rejects ACME registrations without a contact email. Wired into both the modules/tls-letsencrypt submodule (the post-US-012 cert source) AND the root module's inline `tls_mode = letsencrypt` path (today's cert source)."
  type        = string
}

variable "common_tags" {
  description = "Additional Azure tags to apply to the example's resource group, VNet, and shared Key Vault."
  type        = map(string)
  default     = {}
}
