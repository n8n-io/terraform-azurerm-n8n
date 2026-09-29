# `terraform-azurerm-n8n` — `modules/tls-self-signed/`

Issue a self-signed TLS certificate inside an existing Azure Key Vault
with Key Vault's own `Self` issuer. Key Vault generates the key pair,
signs the certificate, and stores it as a PFX
(`application/x-pkcs12`) secret. The certificate's versioned Secret URI is
exposed as `app_gateway_tls_cert_secret_id`, which the root
[`terraform-azurerm-n8n`](../../README.md) module consumes as
`var.app_gateway_tls_cert_secret_id`.

This submodule keeps certificate-specific behavior out of the root
module when a caller supplies an existing certificate. Its only provider
is `azurerm`, and the private key never passes through Terraform.

> **Self-signed mode is intended for lab / internal-only use.** Browsers
> will warn on the cert (it has no chain of trust). Production
> deployments should use the sibling
> [`modules/tls-letsencrypt/`](../tls-letsencrypt/) submodule or supply
> an existing Key Vault certificate directly to the root module's
> `var.app_gateway_tls_cert_secret_id` input.

## Pre-requisites

- The principal running `terraform apply` must be able to create
  certificates on the supplied `var.key_vault_id` (Key Vault Certificates
  Officer in RBAC mode, or `Create`, `Get`, and `Import` on certificates
  plus `Get` and `Set` on secrets in legacy access-policy mode).
- The App Gateway's user-assigned identity that consumes the cert at
  runtime needs read access to the vault's secrets. This submodule does
  not grant it. Either set the root module's `app_gateway_keyvault_id` to
  the vault ID together with
  `app_gateway_keyvault_role_assignment_enabled = true`, which grants
  `Key Vault Secrets User` on the vault, or grant the role yourself.

No external credentials beyond the standard `azurerm` provider auth are
required. Unlike the Let's Encrypt sibling, self-signed mode never
contacts an external CA.

## Usage

```hcl
module "tls_self_signed" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-self-signed?ref=0.1.0"

  domain_name          = "n8n.example.com"
  key_vault_id         = azurerm_key_vault.shared.id
  friendly_name_prefix = "n8nlab"
  common_tags          = { Environment = "lab" }

  # Optional. Whole months, 1 to 120. Defaults to 12.
  # validity_in_months = 3
}

# Wire into the root module:
module "n8n" {
  source = "github.com/n8n-io/terraform-azurerm-n8n?ref=0.1.0"

  app_gateway_tls_cert_secret_id               = module.tls_self_signed.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id                      = azurerm_key_vault.shared.id
  app_gateway_keyvault_role_assignment_enabled = true

  # ... remaining root-module inputs
}
```

## Validity and renewal

Key Vault's certificate policy takes a validity in whole months, and
`validity_in_months` is passed to it unchanged. The variable accepts whole
numbers from 1 to 120 (10 years); anything else fails at plan.

Key Vault's `AutoRenew` lifetime action issues a new certificate version
once 80% of the validity window has elapsed (about 73 days before expiry on
a 1-year cert). Terraform takes no part in the renewal. The App Gateway
listener is pinned to a versioned Secret URI, so it keeps serving the old
version until the next `terraform apply` updates the listener. See
[`docs/tls-rotation.md`](../../docs/tls-rotation.md#rotate-via-modulestls-self-signed)
for how to force a rotation.

## Provider configuration

This submodule declares `required_providers` for `azurerm` only.
Provider configuration is the caller's job — the submodule does not
include any `provider {}` blocks. A minimal caller `providers.tf`:

```hcl
provider "azurerm" {
  features {}
}
```
