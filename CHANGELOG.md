# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v3.0.0] — Phase 5 of registry-hardening (BREAKING)

Phase 5 (registry-hardening US-014..US-026) splits the (then) single-tier
root module into a **two-tier composition**: `modules/infra/` (Tier 1,
Azure IaaS) and `modules/workload/` (Tier 2, Kubernetes workload). The
root module no longer owns any resources — it carries `versions.tf` only
(`required_version = ">= 1.9"`, no `required_providers`, no resources,
no inputs, no outputs). Consumers wire both submodules in their own root
module; the umbrella example (`examples/complete/`) is the canonical
wiring template. Combined with the Phase 4 TLS-submodule extraction
(v2.0.0), this repository now ships **four** registry-publishable
submodules and zero `null_resource` workarounds.

### Breaking changes

- **Root module no longer accepts inputs.** Every `var.*` declared on
  the v2.x root has moved into one of the two submodules. Callers
  pinning `source = "github.com/n8n-io/terraform-azurerm-n8n"` (or the
  registry equivalent) at the root must rewrite to call
  `modules/infra/` and `modules/workload/` separately. The umbrella
  example (`examples/complete/main.tf`) is the canonical wiring
  template — every cross-tier input on `module "workload"` sources
  from a `module.infra` output of the same name.
- **Root module no longer publishes outputs.** Outputs that v2.x
  callers consumed (`aks_cluster_name`, `n8n_url`, `n8n_namespace`,
  `kube_config`, …) now live on the relevant submodule. Update
  consumers from `module.n8n.<output>` to `module.infra.<output>` or
  `module.workload.<output>` per the table in
  [`examples/complete/outputs.tf`](./examples/complete/outputs.tf).
- **Root module no longer pulls any providers.** v2.x pinned six
  providers (`azurerm`, `kubernetes`, `helm`, `random`, `kubectl`,
  `time`); v3.0.0 pins **zero** at the root. Provider configuration
  is the caller's job, scoped to whichever submodule consumes it:
  `azurerm` for `modules/infra/`; `kubernetes` + `helm` + `kubectl`
  for `modules/workload/`. See
  [`examples/complete/providers.tf`](./examples/complete/providers.tf)
  for the canonical certificate-based-via-`aks_kube_config` wiring.
- **Workload-module variable names mirror infra-module output names.**
  Cross-tier inputs on `module "workload"` are named to match the
  upstream `module.infra` output one-to-one, so the wiring is
  mechanical. Variables that v2.x exposed on the umbrella with a
  different name (e.g. legacy `aks_node_sku` ↔ submodule
  `aks_node_vm_size`, legacy `redis_sku` ↔ submodule `redis_sku_name`)
  use the submodule-side spelling at v3.0.0.
- **Root resource group provisioning moved to the caller.** v2.x
  created the resource group inside the module via
  `azurerm_resource_group.n8n`; v3.0.0 expects the caller to provide
  it via `var.resource_group_name` on `modules/infra/` (BYO-RG
  contract introduced in US-014). The umbrella example creates two
  RGs — a network RG (VNet/DNS/shared KV) and a workload RG passed to
  `module.infra` — mirroring the typical platform-team / workload-team
  split.
- **Root tests deleted.** With no resources at the root, the suite
  under `tests/defaults.tftest.hcl` is empty by construction; the
  per-submodule + per-example test suites cover the full surface.

### Added

- **`modules/infra/` submodule** (US-014..US-020, Phase 5 R5.1) —
  Tier 1, Azure IaaS only. Owns AKS cluster + node pool + UAMIs,
  PostgreSQL Flexible Server + private DNS zone, Redis Cache + private
  endpoint + private DNS zone, Storage Account + Azure Files share,
  Application Gateway + Public IP + Key Vault role assignment, IAM
  (UAMIs + role assignments), and the federated identity credential
  binding the n8n workload UAMI to the AKS OIDC issuer. Provider
  count: **3** (`azurerm`, `random`, `time`). Output contract locked
  by `command = apply` plan-time test
  ([`tests/defaults.tftest.hcl#output_contract_complete`](./modules/infra/tests/defaults.tftest.hcl)).
- **`modules/workload/` submodule** (US-021..US-024, Phase 5 R5.2) —
  Tier 2, Kubernetes workload only. Owns KEDA Helm release + namespace,
  KEDA `TriggerAuthentication` (via `gavinbunney/kubectl_manifest` to
  defer CRD schema resolution to apply time), n8n Helm release +
  namespace + chart-side Secrets, n8n Ingress (AGIC), webhook-processor
  HPA, post-install settle gate (`time_sleep.n8n_helm_settle`), and
  destroy-time CIFS-detach window gate (`time_sleep.wait_for_aks_drain`).
  Provider count: **5** (`kubernetes`, `helm`, `random`, `time`,
  `kubectl`). Output contract locked by the same apply-mode pattern
  as `modules/infra/`.
- **`examples/complete/`** rewritten end-to-end (US-025) as the
  canonical two-tier wiring template. Two RGs (network + workload),
  hand-rolled VNet + 5 subnets, public Azure DNS zone with
  auto-managed A-record, shared Key Vault, `module.tls_self_signed`,
  `module.infra`, `module.workload`. Every cross-tier input sources
  from a `module.infra` output verbatim.

### Changed

- **Root `versions.tf`** trimmed to `required_version = ">= 1.9"` only
  (no `required_providers`, no resources). The credit comment block
  points at the two submodules' provider lists.
- **`AGENTS.md` Registry-readiness audit** updated to capture the
  end-state KPIs: `null_resource` count = 0 across all three locations
  (root + both submodules); provider counts 0 / 3 / 5; combined
  `terraform test` wall-clock < 5 minutes on a clean GitHub Actions
  runner. The "Azure-specific deltas vs `terraform-aws-n8n`" section
  is reduced to **two** structural deltas (Flex Server `UUID-OSSP`
  allowlist; KEDA `TriggerAuthentication` CRD-aware install) plus
  one tuning-level delta (Azure Files destroy_duration) — the four
  null_resource workarounds and the three-mode TLS surface are gone.
- **`README.md`** ToC and intro point at the two submodules' READMEs
  (`modules/infra/README.md`, `modules/workload/README.md`) explicitly
  rather than the directory paths. The migration section's "Provider
  block changes" subsection now reflects the post-split posture
  (root pins 0 providers; provider configuration moves to the
  caller's `examples/complete/providers.tf`).

### Removed

- **All `.tf` resource files at the root.** `aks.tf`, `cleanup.tf`,
  `controllers.tf`, `database.tf`, `dns.tf`, `iam.tf`, `ingress.tf`,
  `keda.tf`, `locals.tf`, `n8n.tf`, `outputs.tf`, `redis.tf`,
  `scaling.tf`, `storage.tf`, `tls.tf`, `variables.tf`, and
  `tests/defaults.tftest.hcl` were deleted (US-025 chose the DELETE
  strategy over a thin-wrapper umbrella).
- **All root `required_providers` entries.** The v2.x list of six
  (`azurerm`, `kubernetes`, `helm`, `random`, `kubectl`, `time`) was
  deleted along with the resources. Each provider is re-declared
  inside the submodule that consumes it.
- **`null_resource` count = 0** across the entire repository
  (`grep -rE '^resource "null_resource"' --include="*.tf" .` returns
  no matches). Final retirement count: 5 (US-001 / US-002 / US-003 /
  US-005 / US-007 across Phases 1–3); the Phase-5 split surfaced no
  new `null_resource` candidates.

### Migration

Update your root module to call both submodules separately:

```diff
- module "n8n" {
-   source = "github.com/n8n-io/terraform-azurerm-n8n"
-
-   location             = "eastus"
-   friendly_name_prefix = "acme"
-
-   # … 40+ inputs spanning AKS sizing, Postgres, Redis, App Gateway,
-   # n8n chart, KEDA, autoscaling, tags …
- }
+ module "infra" {
+   source = "github.com/n8n-io/terraform-azurerm-n8n//modules/infra"
+
+   location             = "eastus"
+   resource_group_name  = azurerm_resource_group.n8n.name   # caller-owned RG
+   friendly_name_prefix = "acme"
+
+   # AKS sizing, Postgres, Redis, Storage, App Gateway, IAM, Key Vault role
+   # assignment — see modules/infra/variables.tf for the full surface.
+ }
+
+ module "workload" {
+   source = "github.com/n8n-io/terraform-azurerm-n8n//modules/workload"
+
+   friendly_name_prefix = "acme"
+
+   aks_cluster_name           = module.infra.aks_cluster_name
+   aks_oidc_issuer_url        = module.infra.aks_oidc_issuer_url
+   postgres_fqdn              = module.infra.postgres_fqdn
+   postgres_admin_username    = module.infra.postgres_admin_username
+   postgres_admin_password    = module.infra.postgres_admin_password
+   postgres_database_name     = module.infra.postgres_database_name
+   redis_hostname             = module.infra.redis_hostname
+   redis_ssl_port             = module.infra.redis_ssl_port
+   redis_primary_access_key   = module.infra.redis_primary_access_key
+   storage_account_name       = module.infra.storage_account_name
+   storage_account_primary_access_key = module.infra.storage_account_primary_access_key
+   storage_share_name         = module.infra.storage_share_name
+   n8n_workload_uami_client_id = module.infra.n8n_workload_uami_client_id
+
+   n8n_domain                     = "n8n.example.com"
+   app_gateway_id                 = module.infra.app_gateway_id
+   app_gateway_tls_cert_secret_id = module.tls.app_gateway_tls_cert_secret_id
+   key_vault_id                   = module.infra.key_vault_id
+
+   n8n_license_key = var.n8n_license_key
+ }
```

The full canonical wiring (including the resource group + VNet + DNS
zone + shared Key Vault + `module.tls_self_signed`) lives in
[`examples/complete/main.tf`](./examples/complete/main.tf). State
migration: `terraform state mv` is *not* sufficient because the
resources moved into deeply nested submodule addresses. The clean path
is `terraform destroy` against the v2.x state, then `terraform apply`
against the v3.0.0 layout. Only the workload-tier resources (AKS, KEDA,
n8n release) actually destroy/recreate — the IaaS resources move with
addresses preserved if you import them under the new submodule
addresses, but for most callers the destroy/apply pair is simpler than
the import script.

### Notes

- Final root provider count is **0**; `modules/infra/` pins 3
  (`azurerm`, `random`, `time`); `modules/workload/` pins 5
  (`kubernetes`, `helm`, `random`, `time`, `kubectl`). The remaining
  gap to `terraform-aws-n8n`'s 5-provider posture is the +1 `kubectl`
  in the workload tier; everything else mirrors the AWS sibling
  one-to-one.
- `null_resource` count is **0**. Final retirement count: 5 (US-001 /
  US-002 / US-003 / US-005 / US-007 across Phases 1–3). No new
  `null_resource` workarounds were introduced during the split.
- Combined `terraform test` wall-clock is well under the 5-minute
  ceiling on a clean GitHub Actions runner — the per-submodule suites
  run in single-digit seconds each on a developer laptop and the
  example suites in the same range.

[v3.0.0]: https://github.com/n8n-io/terraform-azurerm-n8n/releases/tag/v3.0.0

## [v2.0.0] — Phase 4 of registry-hardening (BREAKING)

Phase 4 collapses the historical three-mode TLS surface
(`var.tls_mode = self_signed | letsencrypt | custom_pfx`) into a single
BYO-secret contract and lifts the Let's Encrypt and self-signed flows out
of the root module into dedicated submodules. The root module no longer
provisions a Key Vault or imports certificates — provisioning the cert is
now the caller's job.

### Breaking changes

- **`var.tls_mode` removed.** The legacy three-mode toggle is gone. The
  module no longer dispatches between `self_signed`, `letsencrypt`, and
  `custom_pfx` branches.
- **`var.letsencrypt_email`, `var.custom_pfx_data`, `var.custom_pfx_password` removed.**
  These per-mode inputs are no longer read by the root module. Callers
  who need a Let's Encrypt cert call `modules/tls-letsencrypt/`; callers
  who need a self-signed cert call `modules/tls-self-signed/`; callers
  with a BYO PFX import the cert into Key Vault out-of-band and pass the
  resulting versioned secret URI directly.
- **`var.app_gateway_tls_cert_secret_id` added (REQUIRED).** Type `string`,
  no default. Must be a versioned Azure Key Vault Secret URI matching
  `^https://<vault>.vault.azure.net/secrets/<cert>(/<version>)?$`. The
  App Gateway listener reads the cert from this URI at runtime via the
  `<friendly_name_prefix>-appgw-tls` user-assigned identity.
- **Root module's `required_providers` list shrinks from 8 → 6.**
  `vancluever/acme ~> 2.0` and `hashicorp/tls ~> 4.0` are no longer pulled
  by the root. Both providers now live exclusively inside the new
  `modules/tls-letsencrypt/` (acme + tls + azurerm) and
  `modules/tls-self-signed/` (tls + azurerm) submodules. The root pins:
  `azurerm`, `kubernetes`, `helm`, `random`, `kubectl`, `time`.
- **`hashicorp/null` already removed (US-007, Phase 3).** The remaining
  null_resource workarounds the prototype shipped with were retired
  across registry-hardening Phases 1–3; the `null` provider exited the
  root in Phase 3 R3.2 (US-007). After Phase 4 the root provider count
  is 6 and the null_resource count is 0.
- **Module-owned `azurerm_key_vault.n8n` deleted.** The module no longer
  creates its own Key Vault. Callers who relied on the module-owned vault
  must provision their own Key Vault (or reuse an existing one) and pass
  its resource ID via `var.app_gateway_keyvault_id` so the role assignment
  can land on the correct scope.
- **Module-owned cert resources deleted.**
  `azurerm_key_vault_certificate.{self_signed,letsencrypt,custom_pfx}`,
  `tls_private_key.{acme_account,self_signed}`,
  `tls_self_signed_cert.self_signed`, `acme_registration.n8n`, and
  `acme_certificate.n8n` are gone from the root module. Each lives in
  its corresponding submodule with a single contract output:
  `app_gateway_tls_cert_secret_id`.

### Added

- **`modules/tls-letsencrypt/` submodule** (US-009, Phase 4 R4.1a) — issues
  a Let's Encrypt cert via DNS-01 against an Azure DNS zone and imports
  it into a caller-supplied Key Vault. Inputs: `acme_email`, `domain_name`,
  `dns_zone_name`, `dns_zone_resource_group_name`, `key_vault_id`,
  `friendly_name_prefix`, `common_tags`. Output:
  `app_gateway_tls_cert_secret_id`.
- **`modules/tls-self-signed/` submodule** (US-010, Phase 4 R4.2a) — issues
  a self-signed cert via `hashicorp/tls` and imports it into a
  caller-supplied Key Vault. Inputs: `domain_name`, `key_vault_id`,
  `friendly_name_prefix`, `common_tags`, `validity_period_hours` (default
  8760, range 24..87600 — newly tunable per the submodule extraction).
  Output: `app_gateway_tls_cert_secret_id`. Lab / internal-only.
- **`examples/complete-letsencrypt/`** (US-011, Phase 4 R4.1b) — full
  end-to-end example wiring `modules/tls-letsencrypt/` + `module.n8n`
  with a shared example-owned Key Vault and a public DNS zone for the
  DNS-01 challenge.
- **`examples/complete-self-signed/`** (US-011, Phase 4 R4.2b) — full
  end-to-end example wiring `modules/tls-self-signed/` + `module.n8n`
  with a shared example-owned Key Vault. Same shape as
  `examples/complete/`, with `var.tls_validity_period_hours` exposed.

### Changed

- **`examples/complete/`** rewritten to call `modules/tls-self-signed/`
  via a shared example-owned Key Vault, then feed the submodule's
  `app_gateway_tls_cert_secret_id` output into `module.n8n`. The example
  preserves the zero-config UX (no extra var needed; `tls_mode` defaulted
  to `self_signed` in v1.x).
- **`var.app_gateway_keyvault_id`** description rewritten — the variable
  now describes the scope of `azurerm_role_assignment.appgw_kv_secrets_user`
  (the role assignment that grants the App Gateway UAMI `Key Vault Secrets User`
  on the vault holding `var.app_gateway_tls_cert_secret_id`). Behaviour
  unchanged: when null, the caller is responsible for granting the UAMI
  access out-of-band.
- **`docs/tls-rotation.md`** rewritten end-to-end around the new contract:
  rotation in `letsencrypt` mode is "taint inside the submodule and
  re-apply"; rotation in `self_signed` mode is the same; rotation with a
  BYO cert is "import a new version into Key Vault and re-apply" with no
  module-side cert state.

### Removed

- `var.tls_mode`, `var.letsencrypt_email`, `var.custom_pfx_data`,
  `var.custom_pfx_password` (root module inputs).
- `azurerm_key_vault.n8n`, `azurerm_key_vault_certificate.{self_signed,letsencrypt,custom_pfx}`,
  `tls_private_key.{acme_account,self_signed}`,
  `tls_self_signed_cert.self_signed`, `acme_registration.n8n`,
  `acme_certificate.n8n` (root module resources).
- `data.azurerm_client_config.current` (root module data source — no
  consumers after the module-owned Key Vault was deleted).
- `vancluever/acme ~> 2.0` and `hashicorp/tls ~> 4.0` from root
  `required_providers`.

### Migration

See the [**Migrating from v1.x**](./README.md#migrating-from-v1x) section
in `README.md` for the exact `.tf` snippet diff each `tls_mode` value
needs. The high-level shape:

- `tls_mode = "self_signed"` → call `modules/tls-self-signed/` and pass
  its output to `var.app_gateway_tls_cert_secret_id`.
- `tls_mode = "letsencrypt"` → call `modules/tls-letsencrypt/` and pass
  its output to `var.app_gateway_tls_cert_secret_id`.
- `tls_mode = "custom_pfx"` → import the PFX into Key Vault out-of-band
  (or via your own `azurerm_key_vault_certificate`) and pass the resulting
  `secret_id` to `var.app_gateway_tls_cert_secret_id`.

In all three cases, pair `var.app_gateway_tls_cert_secret_id` with
`var.app_gateway_keyvault_id` so the module grants the App Gateway UAMI
`Key Vault Secrets User` on the vault holding the cert.

### Notes

- Final root provider count is **6** (azurerm, kubernetes, helm, random,
  kubectl, time). The remaining gap to `terraform-aws-n8n`'s 5-provider
  posture is `kubectl` only — it backs the single CRD-aware manifest
  (`kubectl_manifest.keda_trigger_authentication` in `keda.tf`) that the
  n8n chart at the pinned version doesn't render. A follow-up PR can
  revisit moving the TriggerAuthentication into a chart-rendered manifest
  if upstream adds first-class `keda.triggerAuthentication.*` values.
- `null_resource` count is **0**. All five workarounds the prototype
  shipped with were retired across Phases 1, 2, and 3.

[v2.0.0]: https://github.com/n8n-io/terraform-azurerm-n8n/releases/tag/v2.0.0
