# terraform-azurerm-n8n

Terraform module for deploying [n8n](https://n8n.io) on Microsoft Azure.

After the registry-hardening Phase-5 split (US-014..US-026), this repository ships **two registry-publishable submodules** rather than a single umbrella:

- [`modules/infra/README.md`](./modules/infra/README.md) — **Tier 1, Azure IaaS.** AKS, PostgreSQL Flexible Server, Redis Cache, Storage Account / Azure Files share, Application Gateway, IAM (UAMIs + role assignments), and the BYO Key Vault role assignment for the App Gateway TLS cert.
- [`modules/workload/README.md`](./modules/workload/README.md) — **Tier 2, Kubernetes workload.** KEDA Helm release, n8n Helm release + namespace + chart-side Secrets, n8n Ingress, post-install settle gate, webhook-processor HPA, KEDA `TriggerAuthentication` CR, destroy-time CIFS-detach gate.

Plus two TLS-cert-issuing submodules:

- [`modules/tls-self-signed/README.md`](./modules/tls-self-signed/README.md) — lab-grade self-signed cert imported into a caller-owned Key Vault.
- [`modules/tls-letsencrypt/README.md`](./modules/tls-letsencrypt/README.md) — production-grade Let's Encrypt cert (DNS-01 via `vancluever/acme`) imported into a caller-owned Key Vault.

Together these provision a production-grade multi-main n8n Enterprise deployment: multiple n8n main pods, dedicated worker pods, external PostgreSQL, Redis behind a private endpoint, Azure Files for shared binary storage, fronted by an Application Gateway with AGIC. An **n8n Enterprise license is required**.

For a ready-to-run end-to-end deployment showing both modules wired together — including the example-owned VNet + 5 subnets, public Azure DNS zone with auto-managed A-record, and the shared Key Vault — see [`examples/complete/`](./examples/complete/).

## Table of contents

- **Submodules** — [`modules/infra/README.md`](./modules/infra/README.md), [`modules/workload/README.md`](./modules/workload/README.md), [`modules/tls-self-signed/README.md`](./modules/tls-self-signed/README.md), [`modules/tls-letsencrypt/README.md`](./modules/tls-letsencrypt/README.md)
- **Examples** — [`examples/complete/`](./examples/complete/), [`examples/complete-letsencrypt/`](./examples/complete-letsencrypt/), [`examples/complete-self-signed/`](./examples/complete-self-signed/)
- **Operator docs** — [`docs/post-deployment.md`](./docs/post-deployment.md), [`docs/destroy-cleanup.md`](./docs/destroy-cleanup.md), [`docs/tls-rotation.md`](./docs/tls-rotation.md), [`docs/troubleshooting.md`](./docs/troubleshooting.md)
- **Migration** — [`CHANGELOG.md`](./CHANGELOG.md), [`#migrating-from-v1x`](#migrating-from-v1x)
- **Audit** — [`AGENTS.md`](./AGENTS.md) (Registry-readiness audit table)

## Goals

### Phase 1 — Internal baseline

A minimal, lean Terraform module that deploys the multi-main n8n Enterprise topology on Azure (AKS + PostgreSQL Flexible Server + Azure Cache for Redis + Application Gateway), validated through n8n-internal testing on a green-field subscription.

### Phase 2 — Production hardening

Tighten the security posture for customer-facing rollouts: customer-managed keys (CMK) on PostgreSQL and the storage account, BYO Key Vault for the App Gateway TLS cert, automated public/private Azure DNS A-record creation, and full propagation of `friendly_name_prefix` + `common_tags` across every taggable resource.

### Phase 3 — Registry publication

Polish to Terraform Registry standards: CI on every PR (fmt, validate, `terraform test`, tflint with the azurerm ruleset, checkov, terraform-docs `--output-check`), operator-facing documentation (`docs/troubleshooting.md`, `docs/post-deployment.md`, `docs/destroy-cleanup.md`, `docs/tls-rotation.md`), a smoke-test script for post-apply verification, and a final Registry-readiness audit before tagging `v1.0.0`.

## Support

This module is open source software, maintained by the n8n Solutions team independently of n8n's enterprise products. While the n8n Support team provides dedicated support for the enterprise offerings, this module isn't included.

## Prerequisites

- **Terraform** `>= 1.9` (every submodule pins this floor in `versions.tf`; 1.9 is the minimum that supports cross-variable validation, used by `modules/infra/`'s `var.app_gateway_keyvault_id` cross-check against `var.app_gateway_keyvault_role_assignment_enabled`)
- **Azure CLI** `>= 2.50` (used for `az login` and the few imperative steps the module shells out to)
- **kubectl** `>= 1.30` (used by `tests/scripts/smoke-test.sh` for post-apply verification; the apply-host bash drain, AKS API readiness probe, post-deploy restart, uuid-ossp bootstrap Job, and KEDA TriggerAuthentication `local-exec kubectl apply` were all retired in registry-hardening Phase 1, 2, and 3 — the `gavinbunney/kubectl` provider now talks to the AKS API directly)
- **Helm** `>= 3.14` (the `helm` provider invokes the local Helm binary)

The caller is responsible for providing:

- A pre-existing **VNet** with five subnets:
  - `aks_subnet_id` — the AKS node subnet (Azure CNI).
  - `appgw_subnet_id` — the Application Gateway subnet.
  - `postgres_subnet_id` — delegated to `Microsoft.DBforPostgreSQL/flexibleServers`.
  - `redis_pe_subnet_id` — `private_endpoint_network_policies` disabled (required for the Redis private endpoint).
  - One spare subnet for future workloads / per the example.
- An **n8n Enterprise license key** (`var.n8n_license_key`).
- A configured `azurerm` provider in the calling root module (this module declares `required_providers` but does not configure them).

## Usage

The canonical pattern is to call both submodules from your own root module, threading `module.infra`'s outputs into `module.workload`'s inputs. The example below mirrors the wiring inside [`examples/complete/main.tf`](./examples/complete/main.tf):

```hcl
module "tls" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-self-signed"

  domain_name          = "n8n.example.com"
  key_vault_id         = azurerm_key_vault.shared.id
  friendly_name_prefix = "acme"
}

module "infra" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/infra"

  location             = "eastus"
  resource_group_name  = azurerm_resource_group.n8n.name   # caller-owned RG
  friendly_name_prefix = "acme"

  vnet_id                    = azurerm_virtual_network.n8n.id
  aks_subnet_id              = azurerm_subnet.aks.id
  postgres_subnet_id         = azurerm_subnet.postgres.id
  redis_subnet_id            = azurerm_subnet.redis_pe.id
  appgw_subnet_id            = azurerm_subnet.appgw.id
  private_endpoint_subnet_id = azurerm_subnet.redis_pe.id

  n8n_domain                     = "n8n.example.com"
  app_gateway_tls_cert_secret_id = module.tls.app_gateway_tls_cert_secret_id
  app_gateway_keyvault_id        = azurerm_key_vault.shared.id
}

module "workload" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/workload"

  friendly_name_prefix = "acme"

  aks_cluster_name    = module.infra.aks_cluster_name
  aks_oidc_issuer_url = module.infra.aks_oidc_issuer_url

  postgres_fqdn           = module.infra.postgres_fqdn
  postgres_admin_username = module.infra.postgres_admin_username
  postgres_admin_password = module.infra.postgres_admin_password
  postgres_database_name  = module.infra.postgres_database_name

  redis_hostname           = module.infra.redis_hostname
  redis_ssl_port           = module.infra.redis_ssl_port
  redis_primary_access_key = module.infra.redis_primary_access_key

  storage_account_name               = module.infra.storage_account_name
  storage_account_primary_access_key = module.infra.storage_account_primary_access_key
  storage_share_name                 = module.infra.storage_share_name

  n8n_workload_uami_client_id = module.infra.n8n_workload_uami_client_id

  n8n_domain                     = "n8n.example.com"
  app_gateway_id                 = module.infra.app_gateway_id
  app_gateway_tls_cert_secret_id = module.tls.app_gateway_tls_cert_secret_id
  key_vault_id                   = module.infra.key_vault_id

  n8n_license_key = var.n8n_license_key
}
```

Neither submodule declares `provider {}` blocks. Callers configure `azurerm` (used by `modules/infra/`) and `kubernetes` / `helm` / `kubectl` (used by `modules/workload/`, wired against the AKS cluster `modules/infra/` creates via the `aks_kube_config` output). See [`examples/complete/providers.tf`](./examples/complete/providers.tf) for the canonical certificate-based auth wiring.

For a full end-to-end example including the resource groups, VNet + 5 subnets, public Azure DNS zone with auto-managed A-record, and the shared Key Vault, see [`examples/complete/`](./examples/complete/). If `terraform apply` fails on a `helm_release`, a `time_sleep` gate (`aks_api_warmup`, `n8n_helm_settle`), or the `kubectl_manifest.keda_trigger_authentication` defer-rendered manifest, see [`docs/troubleshooting.md`](./docs/troubleshooting.md). Destroy-time hangs (Azure Files volume detach, App Gateway frontend-IP release, namespace finalizers) are covered in [`docs/destroy-cleanup.md`](./docs/destroy-cleanup.md).

### TLS cert and Key Vault

The module no longer provisions a Key Vault or imports a certificate (registry-hardening US-012, Phase 4 R4.3). Provisioning the cert is the caller's job; pick one of:

- **Use one of the two TLS submodules** — `modules/tls-letsencrypt/` (production) or `modules/tls-self-signed/` (lab / internal-only). Each submodule creates an `azurerm_key_vault_certificate` in a caller-supplied Key Vault and exposes the resulting versioned secret URI as its `app_gateway_tls_cert_secret_id` output. See `examples/complete-*/` for the full wiring.
- **Bring your own cert** — import a PFX / PEM cert into a Key Vault out-of-band (or via your own `azurerm_key_vault_certificate`) and feed the resulting secret URI into this module as `var.app_gateway_tls_cert_secret_id`.

In both cases, pair the secret URI with `var.app_gateway_keyvault_id` (the resource ID of the same vault). When set, the module grants the App Gateway's user-assigned identity (`<friendly_name_prefix>-appgw-tls`) the **Key Vault Secrets User** role on the supplied vault via `azurerm_role_assignment.appgw_kv_secrets_user`. When unset, the caller is responsible for granting the UAMI access (e.g. via an access policy on a vault in legacy access-policy mode).

The supplied vault must be reachable by the App Gateway with the following requirements:

- The vault should be **RBAC-mode** (`enable_rbac_authorization = true`). Legacy access-policy mode also works, but the caller must pre-grant the App Gateway UAMI `Get` on certificates and secrets via an access policy they manage themselves; the role assignment the module creates is harmless but inert in access-policy mode.
- The vault must allow the App Gateway's network path (firewall rules / private endpoint / public access) — the module does not configure the vault's networking.

The App Gateway fetches the cert as a secret reference at runtime, so **Key Vault Secrets User** is the minimum role needed for the runtime read.

## Migrating from v1.x

Phase 4 R4.3 (registry-hardening US-012) collapses the legacy three-mode TLS surface (`var.tls_mode = self_signed | letsencrypt | custom_pfx`) into a single BYO-secret contract: `var.app_gateway_tls_cert_secret_id`. The module no longer provisions a Key Vault or imports certificates — provisioning the cert is now the caller's job, and the Let's Encrypt and self-signed flows live in `modules/tls-letsencrypt/` and `modules/tls-self-signed/`.

See [`CHANGELOG.md`](./CHANGELOG.md) for the full v2.0.0 breaking-change list. The exact `.tf` snippet diff each old `tls_mode` value needs is below.

### From `tls_mode = "self_signed"` (v1.x default)

```diff
+ module "tls" {
+   source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-self-signed"
+
+   domain_name          = "n8n.example.com"
+   key_vault_id         = azurerm_key_vault.shared.id
+   friendly_name_prefix = "acme"
+   common_tags          = local.common_tags
+ }
+
  module "n8n" {
    source = "github.com/n8n-io/terraform-azurerm-n8n"

-   tls_mode = "self_signed"
+   app_gateway_tls_cert_secret_id = module.tls.app_gateway_tls_cert_secret_id
+   app_gateway_keyvault_id        = azurerm_key_vault.shared.id
    # …
  }
```

You bring your own Key Vault (`azurerm_key_vault.shared` above) — the module no longer creates one. See [`examples/complete-self-signed/`](./examples/complete-self-signed/) for a full end-to-end wiring including the vault, vault access policies, and submodule call.

### From `tls_mode = "letsencrypt"`

```diff
+ module "tls" {
+   source = "github.com/n8n-io/terraform-azurerm-n8n//modules/tls-letsencrypt"
+
+   acme_email                   = "platform@example.com"
+   domain_name                  = "n8n.example.com"
+   dns_zone_name                = "example.com"
+   dns_zone_resource_group_name = "dns-rg"
+   key_vault_id                 = azurerm_key_vault.shared.id
+   friendly_name_prefix         = "acme"
+   common_tags                  = local.common_tags
+ }
+
  module "n8n" {
    source = "github.com/n8n-io/terraform-azurerm-n8n"

-   tls_mode          = "letsencrypt"
-   letsencrypt_email = "platform@example.com"
+   app_gateway_tls_cert_secret_id = module.tls.app_gateway_tls_cert_secret_id
+   app_gateway_keyvault_id        = azurerm_key_vault.shared.id
    # …
  }
```

The submodule needs `vancluever/acme` and `hashicorp/tls` configured in your root `providers.tf` — these were declared by the root in v1.x but moved into the submodule in v2.0.0. See [`examples/complete-letsencrypt/providers.tf`](./examples/complete-letsencrypt/providers.tf) for the canonical wiring (including the LE staging-server URL nudge for first-apply rehearsals).

### From `tls_mode = "custom_pfx"`

There's no submodule for this path — the BYO cert flow goes through your own Key Vault directly:

```diff
+ resource "azurerm_key_vault_certificate" "n8n_tls" {
+   name         = "n8n-tls"
+   key_vault_id = azurerm_key_vault.shared.id
+
+   certificate {
+     contents = var.custom_pfx_data       # base64-encoded PFX, as before
+     password = var.custom_pfx_password
+   }
+ }
+
  module "n8n" {
    source = "github.com/n8n-io/terraform-azurerm-n8n"

-   tls_mode             = "custom_pfx"
-   custom_pfx_data      = var.custom_pfx_data
-   custom_pfx_password  = var.custom_pfx_password
+   app_gateway_tls_cert_secret_id = azurerm_key_vault_certificate.n8n_tls.secret_id
+   app_gateway_keyvault_id        = azurerm_key_vault.shared.id
    # …
  }
```

The `var.custom_pfx_data` / `var.custom_pfx_password` variables on the consumer side can stay if the PFX bytes are still injected via env var (`TF_VAR_custom_pfx_data`); only the *consumer* of those vars moved from inside the module to a caller-side `azurerm_key_vault_certificate`. See [`docs/tls-rotation.md`](./docs/tls-rotation.md) for rotation under the new contract.

### Provider-block changes in your `providers.tf`

After upgrading, the root module no longer pulls `vancluever/acme` or `hashicorp/tls`. After the Phase-5 split (v3.0.0) the root module no longer pulls **any** providers — every provider lives inside the submodule that consumes it. Callers configuring providers for this module:

- **`modules/infra/`**: configure `azurerm` (3 providers declared: `azurerm`, `random`, `time`).
- **`modules/workload/`**: configure `kubernetes`, `helm`, and `kubectl` from the AKS kubeconfig (5 providers declared: `kubernetes`, `helm`, `random`, `time`, `kubectl`). The canonical wiring (cert-based auth via `module.infra.aks_kube_config`) lives in [`examples/complete/providers.tf`](./examples/complete/providers.tf).
- **Self-signed TLS path** (`modules/tls-self-signed/`): add `provider "tls" {}` to your root `providers.tf`. Drop `provider "acme" {}` if it's only there for this module.
- **Let's Encrypt TLS path** (`modules/tls-letsencrypt/`): keep both `provider "acme"` and `provider "tls"`.
- **BYO cert path**: drop both `provider "acme"` and `provider "tls"` if they're only there for this module.

## Reference

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |

## Providers

No providers.

## Modules

No modules.

## Resources

No resources.

## Inputs

No inputs.

## Outputs

No outputs.
<!-- END_TF_DOCS -->

## Examples

- [`examples/complete/`](./examples/complete/) — full end-to-end deployment, including the network RG + VNet + 5 subnets, public DNS zone, shared Key Vault, and `modules/tls-self-signed/` for the listener cert. Lab-ready default.
- [`examples/complete-letsencrypt/`](./examples/complete-letsencrypt/) — same shape but wired to `modules/tls-letsencrypt/` for production-grade Let's Encrypt TLS via DNS-01 against an Azure DNS zone.
- [`examples/complete-self-signed/`](./examples/complete-self-signed/) — explicit self-signed-only deployment (same submodule wiring as `examples/complete/` but with `var.tls_validity_period_hours` exposed).

## Troubleshooting

For failure modes seen in real `terraform apply` runs — Helm 4 cache layout, KEDA TriggerAuthentication ordering, AKS API readiness probe, the `uuid-ossp` allowlist on Flex Server, the multi-main migration race ("n8n is starting up" hang), Azure Files CIFS permission-check, and `terraform destroy` hangs — see [`docs/troubleshooting.md`](./docs/troubleshooting.md). Each section follows the same shape: symptom, root cause, resolution.

## Operator docs

Day-2 reference docs for running the module in production:

- [`docs/post-deployment.md`](./docs/post-deployment.md) — post-apply checks: license activation, DNS verification, capturing the n8n encryption key.
- [`docs/destroy-cleanup.md`](./docs/destroy-cleanup.md) — standard destroy path (gated by `time_sleep.wait_for_aks_drain` / `var.aks_destroy_drain_seconds`), manual cleanup of Azure Files volume-detach hangs, App Gateway frontend-IP release, and namespace finalizers.
- [`docs/tls-rotation.md`](./docs/tls-rotation.md) — how to rotate the App Gateway TLS cert (rotate the cert in your Key Vault, then re-apply with the new versioned URI passed as `var.app_gateway_tls_cert_secret_id`).
- [`docs/troubleshooting.md`](./docs/troubleshooting.md) — apply-time failure modes and their fixes.

## See also

This module is the Azure sibling of [`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n). The two modules share the same shape (file layout, variable naming, output naming, quality bar) so callers can switch clouds with minimal cognitive overhead. Cloud-specific deltas — the Flex Server `azure.extensions = UUID-OSSP` allowlist, the Azure Files destroy-time CIFS-detach window tuning, and the `kubectl_manifest`-driven KEDA `TriggerAuthentication` install — are documented in [`AGENTS.md`](./AGENTS.md) and [`docs/troubleshooting.md`](./docs/troubleshooting.md). The five historical `null_resource` workarounds and the legacy three-mode TLS surface (`var.tls_mode = self_signed | letsencrypt | custom_pfx`) were retired in registry-hardening Phases 1, 2, 3, and 4; Phase 5 (US-014..US-026) split the umbrella module into [`modules/infra/`](./modules/infra/) (3 providers — `azurerm`, `random`, `time`) and [`modules/workload/`](./modules/workload/) (5 providers — `kubernetes`, `helm`, `random`, `time`, `kubectl`). The root pins **0** providers and carries no resources, no inputs, and no outputs. See the Registry-readiness audit table in [`AGENTS.md`](./AGENTS.md) for the replacement of each retired workaround.
