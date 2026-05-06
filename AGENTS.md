# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this
repository. Human contributors should also find this useful — it explains *what*
this module is and *what bar* it is held to.

This file is the Azure sibling of
[`terraform-aws-n8n/AGENTS.md`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/AGENTS.md).
The shape, quality bar, and "what not to do" list are intentionally aligned;
the deltas below cover Azure-specific runtime hardening that the AWS module
doesn't need.

## What this repo is

`terraform-azurerm-n8n` is a Terraform module that deploys a **production-grade,
multi-main [n8n Enterprise](https://n8n.io) installation on Microsoft Azure**. A
single `terraform apply` brings up the full stack:

- **Azure Kubernetes Service (AKS)** cluster with OIDC issuer and workload
  identity enabled, sized for the multi-main workload (default
  `Standard_D4s_v4`, autoscaled).
- **Multiple n8n main pods** + dedicated **worker pods** (queue mode) — the
  Enterprise multi-main topology.
- **Azure Database for PostgreSQL — Flexible Server**, on a delegated subnet
  with the `uuid-ossp` extension allow-listed via `azure.extensions`.
- **Azure Cache for Redis** behind a private endpoint for the Bull queue
  backing workers.
- **Azure Files** (Storage Account + file share) for shared binary / file
  storage, mounted RWX into worker pods.
- **Application Gateway (WAF_v2 by default)** with **AGIC** (Application
  Gateway Ingress Controller) and **KEDA** for ingress, queue-driven worker
  scaling, and HPA-driven webhook-processor scaling.
- **Azure Key Vault**-backed TLS for the App Gateway listener via a single
  BYO-secret contract: the caller supplies a Key Vault Secret URI as
  `var.app_gateway_tls_cert_secret_id`. The two `modules/tls-letsencrypt/`
  and `modules/tls-self-signed/` submodules expose this exact value as
  their `app_gateway_tls_cert_secret_id` output for callers who don't
  already have a cert. Pair the URI with `app_gateway_keyvault_id` so
  this module grants the App Gateway UAMI `Key Vault Secrets User` on
  the vault holding the cert.
- **Optional Azure DNS** A-record (public or private zone) when the caller
  passes a zone — single-apply path, mirroring the AWS module's
  `route53_zone_id` pattern (Phase 2).

An **n8n Enterprise license key** is required (`var.n8n_license_key`) — the
module does not provision a community-edition deployment.

The module **expects a pre-existing VNet** and five pre-tagged subnets. A
complete reference deployment that includes the VNet (built from the
`Azure/avm-res-network-virtualnetwork/azurerm` AVM module) lives in
[`examples/complete/`](./examples/complete/).

### Architecture at a glance

```
              ┌──────── Azure DNS (optional, public or private) ────┐
              │                                                     │
   user ──► App Gateway (AGIC, WAF_v2) ──► AKS ──► n8n mains ──► Postgres Flex
                                              │             │     (delegated subnet,
                                              │             │      private DNS zone)
                                              │             │
                                              │             └──► Redis Cache (private
                                              │                   endpoint, TLS-only) ◄── workers (KEDA-scaled)
                                              │
                                              └──► Azure Files (Storage Account +
                                                   share) for binary data
```

### File layout

The module follows the [standard module
structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
expected by the Terraform Registry. After registry-hardening Phase 5
(US-014..US-025), the module is split into a **two-tier composition** —
the root no longer owns any resources of its own; both submodules under
`modules/` are the canonical source. Consumers wire both tiers in their
own root module (see `examples/complete/` for the canonical pattern).

**Root strategy: DELETE.** Per the US-025 R5.3 AC, the listed resource
files (`aks.tf`, `database.tf`, `redis.tf`, `storage.tf`, `ingress.tf`,
`n8n.tf`, `keda.tf`, `scaling.tf`, `iam.tf`, `cleanup.tf`) plus the
related `controllers.tf` / `tls.tf` / `dns.tf` / `locals.tf` /
`outputs.tf` / `variables.tf` were **deleted** rather than retained as
thin wrappers. The DELETE rationale: with both submodules complete and
self-contained, an umbrella wrapper at root would only add a passthrough
layer (re-declaring every variable, re-exporting every output) without
giving consumers any expressive power they don't already have by calling
`module "infra" {...}` and `module "workload" {...}` directly. The split
matches the project description's stretch goal of two registry-publishable
tiers (`terraform-azurerm-n8n-infra` + `terraform-azurerm-n8n-workload`)
with no umbrella.

| File / dir                        | Purpose                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| `versions.tf`                     | `required_version` only — root has no resources, so no `required_providers` block is needed. **No `provider {}` blocks.** |
| `modules/infra/`                  | **Tier 1 — Azure IaaS.** AKS, PostgreSQL Flexible Server, Redis Cache, Storage Account / Azure Files share, Application Gateway, IAM (UAMIs + role assignments), and the BYO Key Vault role assignment for the App Gateway TLS cert. Provider count: 3 (azurerm, random, time). |
| `modules/workload/`               | **Tier 2 — Kubernetes workload.** KEDA Helm release, n8n Helm release + namespace + chart-side Secrets, n8n Ingress, post-install settle gate (`time_sleep.n8n_helm_settle`), webhook-processor HPA, KEDA `TriggerAuthentication` CR (`kubectl_manifest`, CRD-aware), destroy-time `time_sleep.wait_for_aks_drain` gate. Provider count: 5 (kubernetes, helm, random, time, kubectl). |
| `modules/tls-self-signed/`        | Lab-grade self-signed cert issued via `tls_self_signed_cert` and imported into a caller-owned Key Vault. |
| `modules/tls-letsencrypt/`        | Production-grade Let's Encrypt cert issued via `vancluever/acme` (DNS-01) and imported into a caller-owned Key Vault. |
| `examples/complete/`              | End-to-end runnable example demonstrating the canonical two-tier wiring (`module "infra"` + `module "workload"` + the `tls-self-signed` submodule + caller-owned VNet/DNS/KV). |
| `tests/scripts/smoke-test.sh`     | Post-`apply` smoke test for live deployments.               |
| `docs/`                           | Long-form supplementary docs (troubleshooting, post-deploy, cleanup, TLS rotation). |
| `README.md`                       | Human entry point; points at the two submodules' READMEs and the umbrella example. |
| `LICENSE`                         | MIT. Required for registry publication.                     |
| `.copywrite.hcl`                  | Enforces the `# Copyright n8n GmbH 2025` / `# SPDX-License-Identifier: MIT` header on every `.tf`. |
| `.github/workflows/`              | CI: fmt, validate, test, tflint, checkov, terraform-docs.   |

### Azure-specific deltas vs `terraform-aws-n8n`

These are the things the AWS module does **not** need but this module
**does** — they exist because Azure managed services have specific failure
modes the prototype encountered. **Preserve them when restructuring.**

After Phases 1, 2, 3, 4, and 5 of the registry-hardening campaign, only
**two** genuine deltas remain. Everything else either matches the AWS
sibling's pattern with a different parameter (e.g. the destroy-time
`time_sleep` mirrors AWS's `time_sleep.wait_for_alb_cleanup`) or has been
retired — see "Phase 1 + Phase 2 + Phase 3 + Phase 4 retirements" below.

1. **`azure.extensions = UUID-OSSP` allowlist on Flex Server**
   (`azurerm_postgresql_flexible_server_configuration.uuid_ossp` in
   `modules/infra/database.tf`) — Flex Server requires server-level
   allowlisting before any client (n8n's migrations or an operator's
   `psql`) can run `CREATE EXTENSION "uuid-ossp"`. The configuration
   resource is the only Terraform-side requirement; no in-cluster
   bootstrap Job is needed because n8n's current migrations don't depend
   on `uuid_generate_v4()` (verified against `packages/@n8n/db/AGENTS.md`).
   HVD takes the same shape with
   `azure.extensions = "CITEXT,HSTORE,UUID-OSSP"`. AWS RDS has no
   equivalent allowlist requirement, so this delta has no sibling.
2. **Azure Files destroy-time CIFS-detach window tuning**
   (`time_sleep.wait_for_aks_drain` in `modules/workload/cleanup.tf`,
   parameterised by `var.aks_destroy_drain_seconds`, default 120 s).
   Mirrors `terraform-aws-n8n`'s `time_sleep.wait_for_alb_cleanup` (60 s)
   in shape, but the parameter value is Azure-specific: SMB / CIFS detach
   on Azure Files takes longer than AWS ALB ENI release, and the gate
   sits between `helm_release.n8n` uninstall and `kubernetes_namespace.n8n`
   delete to absorb the asynchronous detach. The structural pattern is
   identical to the AWS sibling's; only the duration tuning is a delta.
3. **KEDA `TriggerAuthentication` CRD-aware install**
   (`kubectl_manifest.keda_trigger_authentication` in
   `modules/workload/keda.tf`) — KEDA's `TriggerAuthentication` CRD is
   installed by `helm_release.keda` on first apply, but
   `hashicorp/kubernetes_manifest` validates CRDs at plan time, which
   would force a two-pass apply. The module installs the CR via
   `gavinbunney/kubectl_manifest`, which defers schema resolution to
   apply time and lets a single-pass apply succeed against a fresh
   cluster. AWS Redis (ElastiCache) doesn't require auth, so the AWS
   sibling's KEDA wiring uses the chart's built-in ScaledObject without
   a TriggerAuthentication — no equivalent delta in `terraform-aws-n8n`.

(The destroy-time `time_sleep` is a structural-vs-tuning judgement call:
the same idiom exists in the AWS sibling, but the parameter value is
Azure-specific, so the row is preserved here as a tuning-level delta.)

#### Phase 1 + Phase 2 + Phase 3 + Phase 4 retirements

All five `null_resource` workarounds the prototype shipped with have been
replaced with declarative idioms that are **not** Azure-specific in shape
(only in parameter values), and the three-mode TLS surface
(`var.tls_mode = self_signed | letsencrypt | custom_pfx`) was collapsed
into a single BYO-secret contract — so none of these are listed as deltas
any more:

- **AKS API warm-up** — `time_sleep.aks_api_warmup` in
  `modules/infra/aks.tf` (`var.aks_api_warmup_seconds`, default 90 s,
  range 30..600). Replaced the `null_resource.wait_for_aks_api`
  `/healthz` poll-loop in registry-hardening US-003. The kubernetes /
  helm providers' built-in retry handles any post-gate 503s.
- **uuid-ossp bootstrap Job** — deleted entirely in registry-hardening
  US-001; the server-level `azure.extensions` allowlist (delta #1 above)
  is now the only Terraform-side artefact.
- **Post-deploy migration rollout-restart** — chart-native Redis
  multi-main leader election (`multiMain.setup`) plus `helm_release.n8n`
  running with `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true`
  together absorb the `CREATE INDEX CONCURRENTLY` race natively. A small
  `time_sleep.n8n_helm_settle` (default 60 s, configurable via
  `var.n8n_helm_post_install_settle_seconds`) gates the Ingress so AGIC
  reconciles against a fully-converged deployment. Replaced
  `null_resource.post_deploy_restart` in registry-hardening US-002.
- **Destroy-time Azure Files drain** — `time_sleep.wait_for_aks_drain`
  in `modules/workload/cleanup.tf` (`var.aks_destroy_drain_seconds`,
  default 120 s, range 30..600). Mirrors `terraform-aws-n8n`
  `time_sleep.wait_for_alb_cleanup` (60 s; Azure's window is longer
  because SMB detach is slower than ALB ENI release). Replaced
  `null_resource.drain_n8n_pods` (60-line shell-out drain via `az` +
  `kubectl`) in registry-hardening US-005. Listed as delta #2 above for
  the parameter-tuning aspect.
- **KEDA TriggerAuthentication apply-time `kubectl`** —
  `kubectl_manifest.keda_trigger_authentication` in
  `modules/workload/keda.tf` (under the `gavinbunney/kubectl` provider).
  Replaced `null_resource.keda_trigger_authentication` (50-line shell-out
  `kubectl apply` provisioner) in registry-hardening US-007 (Phase 3 R3.2).
  The R3.1 chart-native path is unavailable because the n8n-io chart at
  the pinned version does not expose `keda.triggerAuthentication.*`
  values nor `extraManifests` / `extraObjects` hooks (verified upstream
  values.yaml).
- **Three-mode TLS surface (`var.tls_mode`) + module-owned Key Vault** —
  collapsed into a single BYO-secret contract:
  `var.app_gateway_tls_cert_secret_id` + the optional
  `var.app_gateway_keyvault_id` (role-assignment scope). The
  `azurerm_key_vault.n8n` resource and the three per-mode cert resources
  (`azurerm_key_vault_certificate.{self_signed,letsencrypt,custom_pfx}`)
  were deleted; the `acme_*` and `tls_*` helper trees moved into the new
  `modules/tls-letsencrypt/` (US-009) and `modules/tls-self-signed/`
  (US-010) submodules. Retired in registry-hardening US-012 (Phase 4
  R4.3).

#### Phase 5 — two-tier split

Phase 5 (US-014..US-026) split the (then) single-tier root module into
two registry-publishable submodules: `modules/infra/` (Tier 1, Azure
IaaS) and `modules/workload/` (Tier 2, Kubernetes workload). The root
module no longer carries any resources, providers, inputs, or outputs —
only `versions.tf` with `required_version = ">= 1.9"`. The umbrella
example (`examples/complete/`) is the canonical wiring template that
calls both submodules from a single Terraform configuration.

Provider posture after the split:

- **Root**: 0 providers (no resources).
- **`modules/infra/`**: 3 providers — `azurerm`, `random`, `time`. The
  `time` provider backs the two declarative gates that replaced
  `null_resource.wait_for_aks_api` (US-003) and feeds into the
  workload-tier destroy ordering.
- **`modules/workload/`**: 5 providers — `kubernetes`, `helm`, `random`,
  `time`, `kubectl`. The `kubectl` provider backs the single CRD-aware
  manifest (`kubectl_manifest.keda_trigger_authentication`) that the
  n8n chart at the pinned version doesn't render; a follow-up PR can
  revisit moving the TriggerAuthentication into a chart-rendered
  manifest if upstream adds first-class `keda.triggerAuthentication.*`
  values, at which point the workload tier drops to 4 providers.

The remaining gap to `terraform-aws-n8n`'s 5-provider posture is the
+1 `kubectl` in the workload tier; everything else is structurally
mirrored. See the Registry-readiness audit table below for the
complete end-state KPIs.

## Quality bar: HashiCorp Terraform Registry & Partner Premier Tier

This module targets the same quality criteria HashiCorp publishes for
partner modules in the Terraform Registry as the AWS sibling — specifically
the [Partner Premier
Tier](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
and the broader [Terraform partnerships
guidelines](https://developer.hashicorp.com/terraform/docs/partnerships).

> Module quality is ensured through a varied set of standards focused on
> HashiCorp-defined, best-in-class infrastructure as code principles. This
> includes:
>
> - Successfully passing TFLint, Checkov, or another static code analysis tool
>   and reporting the result to HashiCorp
> - Traditional unit and integration testing via Terraform test
> - Adherence to Terraform's official naming conventions
> - Clear module documentation
> - Inclusion of all standard module files

Concretely, in this repo:

### 1. Static analysis (TFLint + Checkov)

`.github/workflows/terraform-tests.yml` runs both on every PR and push to `main`:

- **`terraform fmt -check -recursive`** — canonical formatting.
- **`terraform validate`** against `modules/infra/`, `modules/workload/`,
  and `examples/complete/` (the root has no resources after the Phase-5
  split, so `terraform validate` at the root is trivially clean).
- **`tflint`** against `modules/infra/`, `modules/workload/`, and the
  example, with the **azurerm** ruleset initialized via `tflint --init`.
  The ruleset comes from `.tflint.hcl` at the module root, which pins
  `terraform-linters/tflint-ruleset-azurerm`.
- **`checkov`** (`bridgecrewio/checkov-action@v12`) against the Terraform
  framework. `soft_fail` is currently `true` — see the inline comment in the
  workflow. **When you add new resources, do not regress curated findings;
  prefer fixing them over adding suppressions.**

### 2. Unit + integration tests via `terraform test`

After the Phase-5 split, three plan-time test suites cover the module:

- `modules/infra/tests/defaults.tftest.hcl` exercises every Azure IaaS
  resource the infra tier creates. Uses `mock_provider` for `azurerm`,
  `random`, and `time`.
- `modules/workload/tests/defaults.tftest.hcl` exercises every
  Kubernetes-side resource the workload tier creates. Uses
  `mock_provider` for `kubernetes`, `helm`, `random`, `time`, and
  `kubectl`.
- `examples/complete/tests/defaults.tftest.hcl` exercises the umbrella
  example end-to-end (caller-owned RGs / VNet / DNS / shared KV plus
  both module calls plus the tls-self-signed submodule), catching wiring
  mistakes between the example and a realistic caller. All seven
  providers mocked.

The root has no resources after the Phase-5 split, so it carries no
`tests/*.tftest.hcl` suite. `tests/scripts/smoke-test.sh` is the
**integration / post-apply** check used against a real cluster — kept
out of CI on purpose (it needs live Azure credentials and an applied
stack).

All three suites run **without Azure credentials** and are safe to run
in CI.

When you add a feature, add an `assert` for it in the relevant
`.tftest.hcl` file. Use `command = plan` unless you specifically need
apply semantics.

**Combined wall-clock budget:** `modules/infra/` + `modules/workload/`
+ `examples/complete/` test suites must complete in **under 5 minutes**
on a clean GitHub Actions runner. If you add a run that pushes the budget, profile it. Measured on
`terraform 1.15.1` (US-028, 2026-05-05) on a local laptop: module-root
6 runs ≈ 2 s, example 1 run ≈ 1 s — combined wall-clock is well below the
budget; CI runners with cold provider caches add ~30 s per `init`.

### 3. Naming conventions

This module follows the [Terraform module
conventions](https://developer.hashicorp.com/terraform/language/modules/develop/structure):

- Repository name is **`terraform-<PROVIDER>-<NAME>`** → `terraform-azurerm-n8n`.
- Resource names use **`snake_case`**. The "main" resource of a kind in this
  module is named `n8n` (e.g. `azurerm_kubernetes_cluster.n8n`,
  `azurerm_postgresql_flexible_server.n8n`, `azurerm_redis_cache.n8n`) —
  this matches the registry convention of using a short, descriptive label
  rather than repeating the resource type.
- Variables and outputs use **`snake_case`** with a leading noun
  (`location`, `friendly_name_prefix`, `n8n_domain`, `aks_subnet_id`,
  `appgw_fqdn`).
- Every variable has a `description` and a `type`. Most have a `validation`
  block that fails fast with a useful error message — preserve this when
  adding new inputs. If a variable genuinely doesn't need validation, leave a
  `# no validation: <reason>` comment immediately above it so the
  `invalid_inputs_fail_fast` test sweep stays honest.
- Every output has a `description`. Outputs containing secrets are marked
  `sensitive = true`.
- All taggable `azurerm_*` resources receive `local.common_tags`, which
  always includes `ManagedBy = "terraform"` and `Project = "n8n"` and merges
  `var.common_tags` on top. Resources also set a `Name` tag derived from
  `var.friendly_name_prefix`.

### 4. Clear documentation

- `README.md` is the entry point. The `## Reference` section between
  `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is **auto-generated**
  — do not hand-edit it. All rendering options (formatter, output template,
  `lockfile: false` to keep providers shown as constraints) live in
  `.terraform-docs.yml`, so refreshing the README is one command:

  ```bash
  brew install terraform-docs   # or: see the install step in .github/workflows/terraform-tests.yml
  terraform-docs .
  ```

  CI installs the same version (`v0.22.0`, tracking the brew default) and
  runs `terraform-docs --output-check .`. If your local version differs
  from CI's, the markdown table whitespace will drift and the check will
  fail; bump both together when upgrading.

- `examples/complete/README.md` documents the runnable example.
- `docs/troubleshooting.md`, `docs/post-deployment.md`,
  `docs/destroy-cleanup.md`, and `docs/tls-rotation.md` cover operator-facing
  concerns that don't belong inline in `README.md`.
- Inline comments in `.tf` files use the `# ── Section ──` banner style.
  Match it when adding new sections.
- The destroy-time `time_sleep.wait_for_aks_drain` gate (that replaced
  the legacy bash drain in registry-hardening US-005) and the
  `kubectl_manifest.keda_trigger_authentication` defer-rendered manifest
  (that replaced the legacy `local-exec kubectl apply` workaround in
  US-007) each carry a comment block above the resource documenting the
  failure mode prevented and a link to the relevant troubleshooting doc.

### 5. Standard module files

All of the following are present and should stay present:

- `README.md`, `LICENSE`, `versions.tf`, `variables.tf`, `outputs.tf`
- `examples/` with at least one runnable example
- `tests/` with at least one `.tftest.hcl` suite
- `.github/workflows/` with the CI pipeline above
- `.copywrite.hcl` enforcing the MIT header on every `.tf`

## How to work in this repo (agent quick reference)

### Local development loop

```bash
terraform fmt -recursive                       # before committing (covers both submodules + the example)

# Tier 1 — modules/infra/
cd modules/infra
terraform init -backend=false
terraform validate
terraform test -verbose                        # plan-time, no Azure creds needed
tflint --init && tflint --format compact

# Tier 2 — modules/workload/
cd ../workload
terraform init -backend=false
terraform validate
terraform test -verbose
tflint --init && tflint --format compact

# Umbrella example
cd ../../examples/complete
terraform init -backend=false
terraform validate
terraform test -verbose
tflint --init && tflint --format compact

# Static analysis (matches CI):
cd ../..
checkov -d . --framework terraform --soft-fail

# Refresh the README reference blocks (matches CI's --output-check):
terraform-docs modules/infra
terraform-docs modules/workload
terraform-docs examples/complete
```

After running any `terraform init`, clean up `.terraform/` and
`.terraform.lock.hcl` before committing — both are gitignored but `init`
will create them.

A real deployment uses `terraform apply` from `examples/complete/` with a
populated `terraform.tfvars` — but **never apply from CI** in this repo.

### Running `tests/scripts/smoke-test.sh` against a live deployment

The smoke test is intentionally **not** wired into CI. Run it manually from
a machine that has `az login`'d to the target subscription:

```bash
az login
cd examples/complete
terraform init && terraform apply               # populated terraform.tfvars
../../tests/scripts/smoke-test.sh               # uses `terraform output` to discover the cluster
```

The script asserts: AKS API responds, n8n namespace exists, ≥2 main pods
Ready, ≥1 worker pod Ready, ≥2 webhook-processor pods Ready, App Gateway
public IP reachable, HTTPS GET on `n8n_url` returns 200, license is valid.
Non-zero exit on any failed assertion.

### When adding a new input

1. Add it to `variables.tf` with `description`, `type`, sensible `default`
   (if any), and a `validation` block (or a `# no validation: <reason>`
   comment).
2. Surface it on the resource(s) that consume it.
3. If it's a structural change, add an `assert` in `tests/defaults.tftest.hcl`.
4. If it can be misused, add an `expect_failures` case to the
   `invalid_inputs_fail_fast` run.
5. Re-run `terraform-docs .` to refresh the `README.md` reference table.

### When adding a new resource

1. Put it in the existing `.tf` file matching its concern (e.g. anything
   PostgreSQL → `database.tf`). Create a new file only for a genuinely new
   concern.
2. Open the file with the copywrite header (`# Copyright n8n GmbH 2025` /
   `# SPDX-License-Identifier: MIT`) — `.copywrite.hcl` enforces this.
3. Tag it with `tags = merge(local.common_tags, { Name = "..." })` if the
   resource supports tags.
4. Reference it from the relevant output, if it's user-facing.
5. Add a plan-time assertion if the resource encodes a non-obvious default.
6. Run `tflint` and `checkov` locally before pushing — CI will run them
   anyway, but failing fast saves a round trip.

### What *not* to do

- Don't configure providers inside the module. `versions.tf` declares
  `required_providers`; provider configuration is the caller's job (see
  `examples/complete/providers.tf`).
- Don't introduce nested `module` calls inside the module root — this
  module is intentionally flat so registry consumers can read it top to
  bottom. (`examples/complete/` may call AVM modules; the module root may
  not.)
- Don't drop networking into the module root. The caller passes `vnet_id`
  and the five subnet IDs; only the two private DNS zones
  (`privatelink.postgres.database.azure.com`,
  `privatelink.redis.cache.windows.net`) are module-owned.
- Don't reintroduce a `null_resource` workaround. All five the prototype
  shipped with were replaced in Phases 1, 2, and 3 of the registry-hardening
  campaign — see the Registry-readiness audit table for what shipped where.
  If you need to apply CRD-aware Kubernetes manifests, use the
  `gavinbunney/kubectl` provider's `kubectl_manifest` resource (already in
  `versions.tf`); if you need a destroy-time wait, use `time_sleep` with
  `destroy_duration`.
- Don't commit `terraform.tfstate*`, `*.tfplan`, `apply*.log`, or
  `terraform.tfvars`. The `.gitignore` already covers these; check before
  committing if you ran `apply` locally inside `examples/complete/`.
- Don't hand-edit the `<!-- BEGIN_TF_DOCS -->` block in `README.md`.
- Don't widen `soft_fail` or silence lint rules without a comment explaining
  why and a follow-up TODO.
- Don't use `hashicorp/kubernetes_manifest` for resources whose CRD is
  installed by the module itself (e.g. KEDA `TriggerAuthentication`) —
  `kubernetes_manifest` validates against the CRD's OpenAPI schema **at
  plan time**, which forces a two-pass apply against a fresh cluster (the
  CRD doesn't exist yet on the first plan). Use
  `gavinbunney/kubectl_manifest` instead — it defers schema resolution to
  apply time, so a single-pass apply works. The KEDA TriggerAuthentication
  in `keda.tf` is the canonical example.

## Registry-readiness audit (Phase 5 exit criterion)

Before tagging `v3.0.0` (the Phase-5 split major), every box below must
be checked. Audited on 2026-05-06 against `ralph/registry-hardening`
HEAD as the Phase-5 close-out pass (US-025 wired the split; US-026
verified the end-state KPIs and signed off the audit below).

- [x] Repo named `terraform-azurerm-n8n`.
- [x] `LICENSE` is MIT, copyright n8n GmbH 2025.
- [x] No `provider {}` blocks at the module root or in either submodule
      (only in `examples/complete/providers.tf`).
- [x] Two-tier composition layout — `modules/infra/` + `modules/workload/`
      are the canonical resource-bearing modules; the root carries
      `versions.tf` only (no resources, no providers, no inputs / outputs).
      `examples/complete/main.tf` calls both submodules directly.
- [x] Copywrite header on every `.tf` file (`modules/infra/` +
      `modules/workload/` + `examples/complete/`).
- [x] Every n8n-owned resource named `.n8n` (or a topic-scoped `.<topic>`
      where one cluster hosts multiple of the same resource type, e.g.
      `azurerm_user_assigned_identity.aks_kubelet` / `.appgw_tls_cert` /
      `.n8n_workload`).
- [x] `terraform fmt -check -recursive` passes (the recursive walk covers
      both submodules and the example).
- [x] `terraform validate` passes at the root and at every resource-bearing
      directory: `modules/infra/`, `modules/workload/`, the two TLS
      submodules, and the three `examples/complete*/` examples.
- [x] `terraform test` passes everywhere — 60 mock-backed tests across
      eight locations: 0 root, 29 `modules/infra/`, 19 `modules/workload/`,
      4 `modules/tls-letsencrypt/`, 5 `modules/tls-self-signed/`, 1 each
      for `examples/complete/`, `examples/complete-letsencrypt/`, and
      `examples/complete-self-signed/`.
- [x] `tflint` passes (azurerm ruleset) at every location — gated by the
      `.github/workflows/terraform-tests.yml` `tflint` job (matrix
      expanded in US-026 to cover every submodule and example).
- [x] `checkov` passes (`soft_fail` allowed) — gated by the
      `.github/workflows/terraform-tests.yml` `checkov` job.
- [x] `terraform-docs --output-check` passes at every directory whose
      `README.md` carries a `<!-- BEGIN_TF_DOCS -->` block (root,
      `modules/infra/`, `modules/workload/`, and the three
      `examples/complete*/` examples; the two TLS submodules ship
      hand-written READMEs without the marker by design).
      terraform-docs v0.22.0.
- [x] `null_resource` workaround Phase-tracking — every workaround the
      prototype shipped with has been replaced with a declarative idiom.
      **`null_resource` count: 0** (`grep -rc '^resource "null_resource"' modules/ *.tf` returns 0).
      **Provider counts after the Phase-5 split:**
      - Root: **0** providers (no resources, no inputs / outputs).
      - `modules/infra/`: **3** (`azurerm`, `random`, `time`).
      - `modules/workload/`: **5** (`kubernetes`, `helm`, `random`,
        `time`, `kubectl`).
      The remaining gap to `terraform-aws-n8n`'s 5-provider posture is
      `kubectl` only, which backs the single CRD-aware
      `kubectl_manifest.keda_trigger_authentication` install in
      `modules/workload/keda.tf` (the n8n chart at the pinned version
      doesn't render the TriggerAuthentication; a follow-up PR can
      revisit if upstream adds first-class
      `keda.triggerAuthentication.*` values). `tls` and `acme` were
      removed in US-012 and now live inside the
      `modules/tls-letsencrypt/` and `modules/tls-self-signed/`
      submodules. The breaking-change migration guide
      (`var.tls_mode → var.app_gateway_tls_cert_secret_id`,
      single-tier root → two-tier `module.infra` + `module.workload`)
      lives in [`CHANGELOG.md`](./CHANGELOG.md).

      | Workaround                                  | Phase   | Story  | Status   | Replacement                                                                                                                                                                                     |
      | ------------------------------------------- | ------- | ------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
      | `null_resource.create_uuid_extension`       | 1 R1.1  | US-001 | DELETED  | `azurerm_postgresql_flexible_server_configuration.uuid_ossp` in `modules/infra/database.tf` (server-level `azure.extensions` allowlist).                                                       |
      | `null_resource.post_deploy_restart`         | 1 R1.2  | US-002 | DELETED  | Chart-native Redis multi-main leader election + `helm_release.n8n {wait, atomic, timeout, cleanup_on_fail}` + `time_sleep.n8n_helm_settle` in `modules/workload/n8n.tf` (`var.n8n_helm_post_install_settle_seconds`, 60 s). |
      | `null_resource.wait_for_aks_api`            | 1 R1.3  | US-003 | DELETED  | `time_sleep.aks_api_warmup` in `modules/infra/aks.tf` (`var.aks_api_warmup_seconds`, default 90 s, range 30..600) + kubernetes/helm provider built-in retry on transient API errors.            |
      | `null_resource.drain_n8n_pods`              | 2 R2.1  | US-005 | DELETED  | `time_sleep.wait_for_aks_drain` in `modules/workload/cleanup.tf` (`var.aks_destroy_drain_seconds`, default 120 s, range 30..600). Mirrors `terraform-aws-n8n` `time_sleep.wait_for_alb_cleanup`. |
      | `null_resource.keda_trigger_authentication` | 3 R3.2  | US-007 | DELETED  | `kubectl_manifest.keda_trigger_authentication` in `modules/workload/keda.tf` (gavinbunney/kubectl provider). Defers schema resolution to apply time, so a single-pass apply works.              |
- [x] Combined `terraform test` wall-clock < 5 minutes on a clean GitHub
      Actions runner.

## References

- [`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) — sibling
  module; this repo's quality bar mirrors its AGENTS.md, layout, and CI
  shape.
- [Terraform module structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Publishing modules to the Terraform Registry](https://developer.hashicorp.com/terraform/registry/modules/publish)
- [Terraform partnerships guidelines](https://developer.hashicorp.com/terraform/docs/partnerships)
- [Announcing the new Partner Premier Tier for the Terraform Registry](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
- [`terraform test` framework](https://developer.hashicorp.com/terraform/language/tests)
- [`terraform-docs`](https://terraform-docs.io/)
- [TFLint](https://github.com/terraform-linters/tflint) ·
  [tflint-ruleset-azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm) ·
  [Checkov](https://www.checkov.io/)
- [`Azure/avm-res-network-virtualnetwork/azurerm`](https://registry.terraform.io/modules/Azure/avm-res-network-virtualnetwork/azurerm/latest)
  — AVM module used by `examples/complete/` to build the five subnets with
  the required delegations / network-policy settings.
