# `terraform-azurerm-n8n` — `modules/tls-self-signed/`

Generate a self-signed TLS certificate with `hashicorp/tls` and import the
PEM bundle into an existing Azure Key Vault. The vault's versioned Secret
URI is exposed as `app_gateway_tls_cert_secret_id`, which the root
[`terraform-azurerm-n8n`](../../README.md) module consumes as
`var.app_gateway_tls_cert_secret_id` (Phase 4 R4.3 / US-012).

This submodule exists so the root module no longer pulls the
`hashicorp/tls` provider when the consumer is on the production-majority
`custom_pfx` path — a lighter `terraform init` and a smaller blast radius
for transitive dependency CVEs.

> **Self-signed mode is intended for lab / internal-only use.** Browsers
> will warn on the cert (it has no chain of trust). Production
> deployments should use the sibling
> [`modules/tls-letsencrypt/`](../tls-letsencrypt/) submodule or supply
> a BYO PFX directly to the root module's
> `var.app_gateway_tls_cert_secret_id` input.

## Pre-requisites

- The principal running `terraform apply` must hold cert-import rights
  on the supplied `var.key_vault_id` (Key Vault Certificates Officer in
  RBAC mode, or `Create` / `Import` on certificates in legacy
  access-policy mode).
- The App Gateway's user-assigned identity that consumes the cert at
  runtime needs `Get` on certificates and secrets on `key_vault_id` —
  granted by the caller out-of-band (this submodule does not touch
  access policies / RBAC).

No external credentials beyond the standard `azurerm` provider auth are
required — unlike the Let's Encrypt sibling, self-signed mode never
contacts an external CA.

## Usage

```hcl
module "tls_self_signed" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-self-signed?ref=v2.0.0"

  domain_name          = "n8n.example.com"
  key_vault_id         = azurerm_key_vault.shared.id
  friendly_name_prefix = "n8nlab"
  common_tags          = { Environment = "lab" }

  # Optional — defaults to 8760 (1 year)
  # validity_period_hours = 720  # 30 days
}

# Wire into the root module (US-012):
module "n8n" {
  source = "github.com/n8n-io/terraform-azurerm-n8n?ref=v2.0.0"

  app_gateway_tls_cert_secret_id = module.tls_self_signed.app_gateway_tls_cert_secret_id

  # ... remaining root-module inputs
}
```

A complete runnable example lives at
[`examples/complete-self-signed/`](../../examples/complete-self-signed/)
(US-011).

## Renewal

`hashicorp/tls` auto-renews via Terraform when the cert is within 30
days of expiry (`early_renewal_hours = 720`). Re-running
`terraform apply` inside that window regenerates the key + cert and
re-imports them into Key Vault under a new secret version; the App
Gateway picks up the new versioned URI on its next apply.

## Provider configuration

This submodule declares `required_providers` for `azurerm` and `tls`.
Provider configuration is the caller's job — the submodule does not
include any `provider {}` blocks. A minimal caller `providers.tf`:

```hcl
provider "azurerm" {
  features {}
}

provider "tls" {}
```
