# `terraform-azurerm-n8n` — `modules/tls-letsencrypt/`

Issue a TLS certificate via Let's Encrypt's ACME service and import the
resulting PFX bundle into an existing Azure Key Vault. The certificate covers
the canonical `domain_name` plus every optional `subject_alternative_names`
entry. The vault's versioned Secret URI is exposed as
`app_gateway_tls_cert_secret_id`, which the root
[`terraform-azurerm-n8n`](../../README.md) module consumes as
`var.app_gateway_tls_cert_secret_id`.

This submodule keeps the `vancluever/acme` and `hashicorp/tls` providers out
of the root module when a caller supplies an existing certificate — a lighter
`terraform init` and a smaller blast radius for transitive dependency CVEs.

## Pre-requisites

- An Azure DNS zone authoritative for `var.domain_name` and every
  `var.subject_alternative_names` entry, in the resource group named by
  `var.dns_zone_resource_group_name`. The zone is **not** module-managed.
- The principal running `terraform apply` must hold:
  - `DNS Zone Contributor` on the DNS zone (so lego can write the
    DNS-01 validation TXT record).
  - Cert-import rights on the supplied `var.key_vault_id` (Key Vault
    Certificates Officer in RBAC mode, or `Create` / `Import` on
    certificates in legacy access-policy mode).
- Credentials supported by lego's `azuredns` provider on the apply host.
  Service-principal secret authentication uses `AZURE_TENANT_ID`,
  `AZURE_CLIENT_ID`, and `AZURE_CLIENT_SECRET`. Set `AZURE_SUBSCRIPTION_ID`
  to select the subscription containing the zone. The module supplies
  `AZURE_RESOURCE_GROUP` and `AZURE_ZONE_NAME` from its inputs.
- The `azuredns` provider also supports the `DefaultAzureCredential` chain:
  service-principal client secret, service-principal client certificate via
  `AZURE_CLIENT_CERTIFICATE_PATH`, Azure workload identity, and shared Azure
  CLI credentials from `az login`. Azure managed identity is also supported.
  The `azurerm` provider's authentication is independent.
- The App Gateway's user-assigned identity that consumes the cert at
  runtime needs `Get` on certificates and secrets on `key_vault_id` —
  granted by the caller out-of-band (this submodule does not touch
  access policies / RBAC).

## Usage

```hcl
module "tls_letsencrypt" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-letsencrypt?ref=0.1.0"

  acme_email                   = "ops@example.com"
  domain_name                  = "n8n.example.com"
  subject_alternative_names    = ["hooks.example.com", "mcp.example.com"]
  dns_zone_name                = "example.com"
  dns_zone_resource_group_name = "shared-dns-rg"
  key_vault_id                 = azurerm_key_vault.shared.id
  friendly_name_prefix         = "n8nprod"
  common_tags                  = { Environment = "production" }
}

# Wire into the root module:
module "n8n" {
  source = "github.com/n8n-io/terraform-azurerm-n8n?ref=0.1.0"

  app_gateway_tls_cert_secret_id = module.tls_letsencrypt.app_gateway_tls_cert_secret_id

  # ... remaining root-module inputs
}
```

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

## DNS-01 providers

This submodule's `dns_challenge` block always uses the `azuredns` lego
provider (Azure DNS is the only zone type this module composes with). If
your zone is authoritative somewhere else, swap `dns_challenge.provider`
and `config` on the `acme_certificate` resource in your own root — the
submodule's `azurerm_key_vault_certificate` import step stays identical.
The snippets below were distilled from two example roots (`cloudflare` and
`godaddy`) that shipped before the 0.1.0 first release and were removed for
scope; no runnable example in this repository exercises DNS-01 against a
non-Azure zone end to end, so treat these as a starting point, not a tested
path.

### Cloudflare

```hcl
resource "acme_certificate" "n8n" {
  account_key_pem = acme_registration.n8n.account_key_pem
  common_name     = lower(var.n8n_domain)

  dns_challenge {
    provider = "cloudflare"

    config = {
      CF_DNS_API_TOKEN = var.cloudflare_api_token
    }
  }
}
```

The Cloudflare API token needs `Zone:Read` and `DNS:Edit` permission for
the zone. lego writes and cleans up its own validation TXT record; you
still own the final application CNAME/A record separately (e.g. via the
`cloudflare` Terraform provider).

### GoDaddy

```hcl
resource "acme_certificate" "n8n" {
  account_key_pem = acme_registration.n8n.account_key_pem
  common_name     = lower(var.n8n_domain)

  dns_challenge {
    provider = "godaddy"

    config = {
      GODADDY_API_KEY    = var.godaddy_api_key
      GODADDY_API_SECRET = var.godaddy_api_secret
    }
  }
}
```

The GoDaddy API key/secret pair needs DNS write permission on the domain.
As with Cloudflare, lego owns the validation TXT record only — the
application record (e.g. via the `godaddy-dns` Terraform provider) is the
caller's responsibility.
