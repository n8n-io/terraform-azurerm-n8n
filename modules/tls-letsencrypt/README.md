# `terraform-azurerm-n8n` — `modules/tls-letsencrypt/`

Issue a TLS certificate via Let's Encrypt's ACME service and import the
resulting PFX bundle into an existing Azure Key Vault. The vault's
versioned Secret URI is exposed as `app_gateway_tls_cert_secret_id`,
which the root [`terraform-azurerm-n8n`](../../README.md) module consumes
as `var.app_gateway_tls_cert_secret_id` (Phase 4 R4.3 / US-012).

This submodule exists so the root module no longer pulls the
`vancluever/acme` and `hashicorp/tls` providers when the consumer is on
the production-majority `custom_pfx` path — a lighter `terraform init`
and a smaller blast radius for transitive dependency CVEs.

## Pre-requisites

- An Azure DNS zone authoritative for `var.domain_name`, in the
  resource group named by `var.dns_zone_resource_group_name`. The zone
  is **not** module-managed — this submodule expects it to exist.
- The principal running `terraform apply` must hold:
  - `DNS Zone Contributor` on the DNS zone (so lego can write the
    DNS-01 validation TXT record).
  - Cert-import rights on the supplied `var.key_vault_id` (Key Vault
    Certificates Officer in RBAC mode, or `Create` / `Import` on
    certificates in legacy access-policy mode).
- Standard `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET`
  / `AZURE_SUBSCRIPTION_ID` env vars (or `DefaultAzureCredential`) on
  the apply host — the lego library reads these directly to perform
  the DNS-01 challenge. The `azurerm` provider's auth shape is
  independent.
- The App Gateway's user-assigned identity that consumes the cert at
  runtime needs `Get` on certificates and secrets on `key_vault_id` —
  granted by the caller out-of-band (this submodule does not touch
  access policies / RBAC).

## Usage

```hcl
module "tls_letsencrypt" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-letsencrypt?ref=v2.0.0"

  acme_email                   = "ops@example.com"
  domain_name                  = "n8n.example.com"
  dns_zone_name                = "example.com"
  dns_zone_resource_group_name = "shared-dns-rg"
  key_vault_id                 = azurerm_key_vault.shared.id
  friendly_name_prefix         = "n8nprod"
  common_tags                  = { Environment = "production" }
}

# Wire into the root module (US-012):
module "n8n" {
  source = "github.com/n8n-io/terraform-azurerm-n8n?ref=v2.0.0"

  app_gateway_tls_cert_secret_id = module.tls_letsencrypt.app_gateway_tls_cert_secret_id

  # ... remaining root-module inputs
}
```

A complete runnable example lives at
[`examples/complete-letsencrypt/`](../../examples/complete-letsencrypt/)
(US-011).

## Provider configuration

This submodule declares `required_providers` for `azurerm`, `acme`, and
`tls`. Provider configuration is the caller's job — the submodule does
not include any `provider {}` blocks. A minimal caller `providers.tf`:

```hcl
provider "azurerm" {
  features {}
}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"  # Production
  # server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"  # Staging — recommended for first-apply rehearsals
}

provider "tls" {}
```

Use the staging ACME server for rehearsals — Let's Encrypt's production
endpoint enforces a [duplicate-certificate rate
limit](https://letsencrypt.org/docs/rate-limits/) of 5 per 7 days per
exact set of FQDNs, easy to exhaust during iteration.
