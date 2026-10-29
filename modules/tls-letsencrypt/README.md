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
    Certificates Officer in RBAC mode, or `Get`, `Import`, and
    `Update` on certificates in legacy access-policy mode). `Update` is
    what applies tag changes to an existing certificate. `terraform
    destroy` also needs `Delete`, plus `Purge` when the `azurerm`
    provider purges soft-deleted certificates on destroy (its default)
    and the vault does not have purge protection enabled. If a
    soft-deleted certificate with the same name exists, creating it
    again also needs `Recover`, because the provider recovers
    soft-deleted certificates by default.
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
  runtime needs read access to the vault's secrets. This submodule does
  not grant it. Either set the root module's `app_gateway_keyvault_id` to
  the vault ID together with
  `app_gateway_keyvault_role_assignment_enabled = true`, which grants
  `Key Vault Secrets User` on the vault, or grant the role yourself. In a
  legacy access-policy vault, give the identity `Get` on secrets instead.

## Usage

```hcl
module "tls_letsencrypt" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-letsencrypt?ref=0.2.0"

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
  source = "github.com/n8n-io/terraform-azurerm-n8n?ref=0.2.0"

  app_gateway_tls_cert_secret_id = module.tls_letsencrypt.app_gateway_tls_cert_secret_id

  # ... remaining root-module inputs
}
```

## Inputs

| Name | Description | Type | Default |
| ---- | ----------- | ---- | ------- |
| `acme_email` | Email address registered with Let's Encrypt for issuance and renewal notifications. | `string` | n/a (required) |
| `domain_name` | Canonical fully qualified domain name. Becomes the certificate's CN. Must be the `dns_zone_name` apex or a subdomain of it. At most 64 characters. | `string` | n/a (required) |
| `subject_alternative_names` | Additional fully qualified domain names on the certificate. Normalized to lowercase, unique, not repeating `domain_name`, and inside `dns_zone_name`. | `list(string)` | `[]` |
| `dns_zone_name` | Caller-owned Azure DNS zone used for the DNS-01 challenge. | `string` | n/a (required) |
| `dns_zone_resource_group_name` | Resource group containing `dns_zone_name`. | `string` | n/a (required) |
| `key_vault_id` | Resource ID of the caller-owned Key Vault the issued PFX is imported into. | `string` | n/a (required) |
| `friendly_name_prefix` | Lowercase alphanumeric prefix, 2 to 12 characters. The certificate is named `<friendly_name_prefix>-n8n-tls`. | `string` | n/a (required) |
| `common_tags` | Tags merged onto the Key Vault certificate, on top of the baseline `ManagedBy = terraform` and `Project = n8n` tags. Caller values win, except `Name`, which is always the certificate name. The merged map must stay within Key Vault's limit of 15 tags. | `map(string)` | `{}` |

## Outputs

| Name | Description |
| ---- | ----------- |
| `app_gateway_tls_cert_secret_id` | Versioned Key Vault Secret URI of the imported certificate (PFX). Pass it to the root module's `app_gateway_tls_cert_secret_id` input. Sensitive. |
| `certificate_domain_names` | Normalized set of domain names the certificate covers: `domain_name` plus every `subject_alternative_names` entry. |

## Tags and renewal

The certificate carries `ManagedBy = terraform`, `Project = n8n`,
`var.common_tags` merged on top, and `Name = <friendly_name_prefix>-n8n-tls`.
Key Vault allows at most 15 tags per certificate, so `common_tags` can
add at most 12 keys beyond the three the module sets. A larger map fails
at plan.

A tag-only change updates the certificate in place. It does not create
a new certificate version, so the versioned Secret URI stays the same.

When Let's Encrypt renews the certificate and the tags do not change in
the same apply, the `azurerm` provider imports the new PFX as a new
certificate version without sending tags. Upstream reports that Key
Vault then leaves the new version untagged
([hashicorp/terraform-provider-azurerm#28004](https://github.com/hashicorp/terraform-provider-azurerm/issues/28004)).
In that case the next `terraform plan` shows the tags as drift, and the
next apply restores them. If the tags also change in the same apply,
the provider sends them after the import. The renewal itself is not
affected. A forced re-issue on a live Let's Encrypt staging run (acme
3.2.1, azurerm 4.81.0) showed exactly this: the new version had no tags,
the next plan showed them as drift, the next apply restored them without
another version, and the plan after that was clean.

The same forced re-issue showed that the module's
`app_gateway_tls_cert_secret_id` output is one apply behind a new
certificate: for the in-place update of the Key Vault certificate, the
`azurerm` provider plans `secret_id` and `version` as unchanged, so after
the apply that imported the new version the output still pointed at the
previous version, and only the next apply changed it. An Application
Gateway wired to this output keeps serving the previous certificate until
that second apply.

A forced re-issue (`-replace`, `taint`, or any change that replaces
`acme_certificate.n8n`) revokes the previous certificate when it destroys
it (`revoke_certificate_on_destroy` defaults to `true`), so the gateway
serves a revoked certificate until the second apply. A renewal triggered
by `min_days_remaining` updates `acme_certificate.n8n` in place and does
not revoke the previous certificate. It goes through the same Key Vault
in-place update, so expect the same one-apply lag, but that path has not
been verified live. The lag comes from how the `azurerm` provider plans
the Key Vault certificate, not from the acme provider, so the 3.x bump
did not change it.

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

## Upgrading from acme provider 2.x

This submodule requires `vancluever/acme` `~> 3.0` (it required `~> 2.16`
before). New deployments, and deployments already applied with a 3.x
provider, need nothing beyond `terraform init -upgrade`.

If the certificate in your state was issued with a 2.x provider, do not
widen your constraint to `~> 3.0` straight away: `terraform init -upgrade`
would then select the latest release, `3.2.1`. acme `3.1.1` and later
dropped the state migration that renames the stored `key_type` from
`2048` to `RSA2048`, so the next plan shows `key_type = "2048" ->
"RSA2048"` followed by `# forces replacement`. Applying that plan revokes
the current certificate first (`revoke_certificate_on_destroy` defaults to
`true`), then orders a new one, which counts against Let's Encrypt's limit
of 5 certificates per exact set of names per 7 days. It also imports a new
Key Vault certificate version; the module output (and so the Application
Gateway listener) follows that version on the next apply, not the same one
(see "Tags and renewal").

`3.0.0`, `3.0.1`, and `3.1.0` still carry the migration, and one apply
with any one of them is enough. The steps below use `3.1.0`:

1. In the calling root's `required_providers`, pin
   `acme = { source = "vancluever/acme", version = "3.1.0" }` (replacing
   any `2.x` constraint).
2. Run `terraform init -upgrade`, then `terraform plan`. Expect `No
   changes` or in-place updates only (a live run from 2.48.3 to 3.1.0
   planned `No changes`). Stop if the plan replaces `acme_certificate.n8n`.
3. Run `terraform apply`, even if the plan said `No changes`: this
   rewrites the stored certificate in the 3.x format (`key_type` becomes
   `RSA2048`) without ordering a new one, unless renewal was already due
   (`min_days_remaining`, 30 days by default). Skipping it leaves `2048`
   in state, and the next step would plan the replacement described above.
   If this apply did renew the certificate (the apply output shows the
   Key Vault certificate changing), the module output and the Application
   Gateway listener still point at the previous version until a further
   apply (see "Tags and renewal"): run `terraform apply` once more, and
   confirm the listener serves the new certificate, before you treat the
   upgrade as complete.
4. Only now widen the pin to `~> 3.0` (or remove it), run `terraform init
   -upgrade`, and run `terraform plan`. It should show no change to
   `acme_certificate.n8n`.

The `provider "acme"` block above is unchanged in 3.x. The 3.0 release
moved the provider to lego v5, which removed the deprecated `azure`
DNS-01 provider; this submodule uses its replacement, `azuredns`, whose
configuration did not change.

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
