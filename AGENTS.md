# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this
repository. Human contributors should also find this useful — it explains *what*
this module is and *what bar* it is held to.

This file is the Azure sibling of
[`terraform-aws-n8n/AGENTS.md`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/AGENTS.md).
The shape, quality bar, and "what not to do" list are intentionally aligned;
the deltas below cover Azure-specific runtime hardening that the AWS module
doesn't need.

## `align-azure-with-aws-capabilities` internal iteration

This module used a two-tier composition (`modules/infra/` +
`modules/workload/`, no resources at the root) during internal development. The
`align-azure-with-aws-capabilities`
change (`openspec/changes/align-azure-with-aws-capabilities/`) flattened that
back into **one resource-bearing root module**, matching `terraform-aws-n8n`'s
shape, and ported the AWS sibling's PostgreSQL/Redis external-endpoint modes,
Azure Blob storage, full n8n runtime controls, autoscaling, ingress patterns,
and DNS/TLS integration onto the Azure-specific foundation. `modules/infra/`
and `modules/workload/` were deleted once every resource, control, and
safeguard they owned was represented at the root (section 15.5). The
subsequent `slim-first-release-surface` change removed Azure Files support,
the `filesystem` binary/execution-data storage modes, the two DNS-provider
examples, and the version-history framing ahead of the module's first public
release (`0.1.0`) — see [`CHANGELOG.md`](./CHANGELOG.md). The "What this repo
is" / "File layout" sections below describe the current shape.

**Storage and workload integration.** Root `storage.tf` owns the private
Azure Blob container, its private endpoint, and private DNS zone — Blob is
the module's only durable binary/execution-data backend. `shared_access_key_enabled`
on the storage account derives solely from the retained connection-string/
account-key compatibility inputs; workload identity is otherwise the only
authentication path. Root `helm_release.n8n` merges `local.n8n_extra_volumes` /
`local.n8n_extra_volume_mounts` at the chart's top level so every pod family
receives caller-supplied typed volumes.

**Combined provider graph.** The root declares all six providers the former
two-tier composition used across both submodules (`azurerm`, `kubernetes`,
`helm`, `random`, `time`, `kubectl`) in one `required_providers` block. AKS
and the Kubernetes/Helm controllers form one same-apply graph: namespace
creation depends on `time_sleep.aks_api_warmup`; KEDA installs before the
CRD-aware TriggerAuthentication; the n8n release installs after both. Mocked
plans and `terraform graph` verify those static edges, but they do not prove
live Azure lifecycle behavior — track cold create, no-op apply, Helm-only
update, AKS credential rotation, partial-apply recovery, AKS replacement,
normal destroy, and unavailable-API recovery per `openspec/changes/
align-azure-with-aws-capabilities/tasks.md` section 17.4 before treating the
one-apply contract as a release guarantee for a given release.

**Runtime controls.** Root `n8n.tf` owns the chart-native resource, execution,
lifecycle, task-runner, logging, template, personalization, community-package,
and floating-license settings. The chart's `config.extraEnv` is shared by
main, worker, and webhook containers. Keep feature variables omitted when
their defaults match n8n, but always render
`N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false` because n8n's upstream `true`
default can invalidate the shared floating certificate during a multi-main
rollout.

**Custom workload configuration.** The chart does not render image pull
Secrets, so root Terraform takes over the n8n ServiceAccount only when
`n8n_image_pull_secrets` is non-empty. It uses the distinct
`n8n-enterprise-pull` name to avoid colliding with the chart-owned account and
moves the workload-identity federated subject with it. Inputs contain existing
Secret names only, never registry credentials. Keep `local.n8n_managed_env_names` and
`local.n8n_managed_env_prefixes` synchronized with every environment variable
the module or chart owns before adding to `config.extraEnv`.

**Data and observability configuration.** Root `n8n.tf` renders binary mode,
historical binary modes, execution-data mode, Azure connection, metrics,
OpenTelemetry, and log-streaming settings through the shared `config.extraEnv`
list so main, worker, and webhook processes stay aligned. Binary-data modes are
restricted to `database`/`azure` for both binary and execution data — 0.1.0 has
neither n8n's inline-memory `default` binary mode nor a shared-filesystem path.
Azure binary and execution storage have
separate Enterprise entitlements. Mode changes never backfill data, so keep
historical modes and their backends configured until retained objects have
expired or moved. The Azure Key Vault
external-secrets integration is caller-configured in n8n and uses a client
secret, not the Blob workload identity or App Gateway identity. The pinned
n8n path currently constructs the public Azure vault endpoint and does not
expose sovereign vault or authority settings.

**Workload scaling and capacity.** The chart owns the main HPA and worker KEDA
ScaledObject, while root `scaling.tf` owns the webhook HPA because the chart
suppresses that object whenever KEDA is enabled. Helm replica counts must
remain tied to the three autoscaler floors. The CPU capacity check models
both untainted AKS pools, subtracts documented AKS and fixed system workload
allowances, warns only for reviewed Dsv4, Dsv5, and Dsv7 SKUs, and stays silent for
unknown valid SKUs. Keep the SKU map and reservation comments current when
AKS or example sizing changes. The warning is advisory and does not replace
live capacity testing.

**Managed ingress.** Root `ingress.tf` owns the conditional public or
private-only Application Gateway, subnet NSG, WAF policy, AGIC permissions,
and Kubernetes Ingress. `create_ingress = false` must also remove the AKS
AGIC addon while preserving the resource-derived service-discovery outputs.
Keep all five entries in `local.n8n_webhook_path_prefixes` before `/` for
every host. The subnet NSG must retain `GatewayManager` access on
65200-65535 and `AzureLoadBalancer` probe access before its deny rule. Source
restrictions apply to the editor and webhook paths together.

**DNS and certificate integration.** Root `dns.tf` accepts at most one
caller-owned public or private Azure DNS zone ID with a matching explicit,
plan-known record toggle. It parses the zone name and resource group from
that ID, creates an A record for every value in `local.n8n_ingress_domains`,
and targets the matching public or internal Application Gateway frontend.
Every host must live in the selected zone, and `create_ingress = false` must
omit all records. Root `keyvault.tf` grants only `Key Vault Secrets User` to
the gateway TLS identity when explicitly enabled, waits for RBAC propagation,
and stays behind the same ingress gate. The Let's Encrypt helper normalizes
its canonical name and subject alternative names to lowercase and requires
every name to use its one Azure DNS challenge zone.

**Sizing examples.** `examples/small`, `examples/medium`, and `examples/large`
call the resource-bearing root directly and own their Azure foundations. Keep
each example self-contained. The large tier intentionally owns PostgreSQL so
n8n can use the external database contract through the example-owned
two-replica PgBouncer service, and pins an explicit storage replication type.
Keep each tier's mocked test and
`examples/README.md` comparison table synchronized with sizing changes.
`examples/split-ingress` demonstrates `create_ingress = false` plus two
caller-owned Application Gateways. Non-Azure DNS-01 validation (Cloudflare,
GoDaddy) is documented, not demonstrated by a runnable example — see the
"DNS-01 providers" section of `modules/tls-letsencrypt/README.md`.

## What this repo is

`terraform-azurerm-n8n` is a Terraform module that deploys a **production-grade,
multi-main [n8n Enterprise](https://n8n.io) installation on Microsoft Azure**. A
single `terraform apply` brings up the full stack:

- **Azure Kubernetes Service (AKS)** cluster with OIDC issuer and workload
  identity enabled, availability-zone-spread node pools, optional API-server
  authorized IP ranges, and an autoscaler-owned node count (default
  `Standard_D4s_v4`).
- **Multiple n8n main pods** plus dedicated **worker** and **webhook-processor**
  pods (queue mode) — the Enterprise multi-main topology, each independently
  autoscaled (main/webhook HPA, worker KEDA `ScaledObject`).
- **PostgreSQL — Flexible Server**, on a delegated subnet with the `uuid-ossp`
  extension allow-listed via `azure.extensions`, or an external PostgreSQL
  endpoint (`create_database = false`).
- **Azure Managed Redis** behind a private endpoint (`NoCluster`, encrypted
  protocol, access-key auth) for the Bull queue backing workers, or an
  external Redis endpoint (`create_redis = false`).
- **Private Azure Blob Storage** for binary and execution data, authenticated
  via AKS workload identity by default, with PostgreSQL as the durable
  non-Azure binary and execution-data backend.
- **Application Gateway (WAF_v2 by default)** with **AGIC** (Application
  Gateway Ingress Controller) and **KEDA** for ingress, queue-driven worker
  scaling, and HPA-driven main/webhook-processor scaling — or
  `create_ingress = false` for a caller-owned ingress topology.
- **Azure Key Vault**-backed TLS for the App Gateway listener via a single
  BYO-secret contract: the caller supplies a Key Vault Secret URI as
  `var.app_gateway_tls_cert_secret_id`. The two `modules/tls-letsencrypt/`
  and `modules/tls-self-signed/` submodules expose this exact value as
  their `app_gateway_tls_cert_secret_id` output for callers who don't
  already have a cert. Pair the URI with `app_gateway_keyvault_id` so
  this module grants the App Gateway UAMI `Key Vault Secrets User` on
  the vault holding the cert.
- **Optional public or private Azure DNS** A-records for the canonical domain
  and every additional domain, when the caller passes a zone ID and the
  matching record toggle.

An **n8n Enterprise license key** is required (`var.n8n_license_key`) — the
module does not provision a community-edition deployment.

The module **expects a pre-existing VNet** and five pre-sized subnets. The
`examples/small`, `examples/medium`, and `examples/large` roots create those
Azure foundations and call the resource-bearing root directly.

### Architecture at a glance

```
              ┌──────── Azure DNS (optional, public or private) ────┐
              │                                                     │
   user ──► App Gateway (AGIC, WAF_v2) ──► AKS ──► n8n mains ──► PostgreSQL Flex
                                              │             │     (delegated subnet,
                                              │             │      private DNS zone)
                                              │             │
                                              │             └──► Azure Managed Redis
                                              │                   (private endpoint,
                                              │                   TLS-only) ◄── workers (KEDA-scaled)
                                              │
                                              └──► Azure Blob Storage (private endpoint,
                                                   workload identity) for binary /
                                                   execution data
```

### File layout

The module follows the [standard module
structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
expected by the Terraform Registry: one resource-bearing root, one file per
concern, no nested `module` calls at the root.

| File / dir                        | Purpose                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| `versions.tf`                     | `required_providers` (`azurerm`, `kubernetes`, `helm`, `random`, `time`, `kubectl`), `required_version = ">= 1.9"`. **No `provider {}` blocks.** |
| `variables.tf` / `locals.tf` / `outputs.tf` | Root input, naming/tag, and output contract. |
| `aks.tf`, `iam.tf`                | AKS cluster + node pool, workload/AGIC UAMIs, AKS API warm-up gate, workload-identity federated credential. No dormant identities: a kubelet UAMI (private-ACR pulls, CMK disks) is added only when a story binds it. |
| `database.tf`                     | Managed PostgreSQL Flexible Server or external-endpoint contract; `local.postgres_connection`. |
| `redis.tf`                        | Managed Azure Managed Redis or external-endpoint contract; `local.redis_connection`. |
| `storage.tf`                      | Private Azure Blob container, private endpoint, private DNS. |
| `controllers.tf`, `keda.tf`, `n8n.tf` | KEDA + namespace + Secrets + n8n Helm release + post-install settle gate. |
| `scaling.tf`                      | Webhook-processor HPA and the advisory AKS capacity diagnostic. |
| `ingress.tf`, `keyvault.tf`, `dns.tf` | Conditional Application Gateway + AGIC + NSG + Kubernetes Ingress, Key Vault role assignment, public/private Azure DNS A-records. |
| `modules/tls-self-signed/`        | Lab-grade self-signed cert issued via `tls_self_signed_cert` and imported into a caller-owned Key Vault. |
| `modules/tls-letsencrypt/`        | Production-grade Let's Encrypt cert issued via `vancluever/acme` (DNS-01, with subject alternative names) and imported into a caller-owned Key Vault. |
| `examples/small/`, `examples/medium/`, `examples/large/` | End-to-end sizing examples with caller-owned Azure foundations, a Key Vault certificate helper, and one root `module "n8n"` call. |
| `examples/split-ingress/` | Single-decision topology example — module ingress fully disabled in favor of two caller-owned Application Gateways. |
| `tests/scripts/smoke-test.sh`     | Post-`apply` smoke test for live deployments.               |
| `docs/`                           | Long-form supplementary docs (troubleshooting, post-deploy, cleanup, TLS rotation, Redis, data storage, observability, Azure Key Vault external secrets). |
| `README.md`                       | Human entry point — architecture, prerequisites, usage, and the auto-generated Reference block. |
| `LICENSE`                         | MIT. Required for registry publication.                     |
| `.copywrite.hcl`                  | Enforces the `# Copyright n8n GmbH 2025` / `# SPDX-License-Identifier: MIT` header on every `.tf`. |
| `.github/workflows/`              | CI: fmt, validate, test, tflint, checkov, terraform-docs.   |
| `openspec/`                       | OpenSpec change artifacts (proposal, design, delta specs, tasks) for in-flight and recently shipped changes. Intentionally tracked — this file references them — and ships in release tags as contributor documentation. |
| `.agents/skills/`                 | Vendored agent skills used by AI contributors working in this repo. Intentionally tracked; inert for module consumers. Loop-runner state (`progress.txt`, `skills-lock.json`, `logs/`) is gitignored and must never be committed. |

### Azure-specific deltas vs `terraform-aws-n8n`

These are the things the AWS module does **not** need but this module
**does** — they exist because Azure managed services have specific failure
modes the prototype encountered. **Preserve them when restructuring.**

Only **two** genuine deltas remain. Everything else either matches the AWS
sibling's pattern with a different parameter or has been retired — see
"Historical retirements" below.

1. **`azure.extensions = UUID-OSSP` allowlist on Flex Server**
   (`azurerm_postgresql_flexible_server_configuration.uuid_ossp` in
   `database.tf`) — Flex Server requires server-level allowlisting before
   any client (n8n's migrations or an operator's `psql`) can run
   `CREATE EXTENSION "uuid-ossp"`. The configuration resource is the only
   Terraform-side requirement; no in-cluster bootstrap Job is needed because
   n8n's current migrations don't depend on `uuid_generate_v4()` (verified
   against `packages/@n8n/db/AGENTS.md`). HVD takes the same shape with
   `azure.extensions = "CITEXT,HSTORE,UUID-OSSP"`. AWS RDS has no equivalent
   allowlist requirement, so this delta has no sibling.
2. **KEDA `TriggerAuthentication` CRD-aware install**
   (`kubectl_manifest.keda_trigger_authentication` in `keda.tf`) — KEDA's
   `TriggerAuthentication` CRD is installed by `helm_release.keda` on first
   apply, but `hashicorp/kubernetes_manifest` validates CRDs at plan time,
   which would force a two-pass apply. The module installs the CR via
   `gavinbunney/kubectl_manifest`, which defers schema resolution to apply
   time and lets a single-pass apply succeed against a fresh cluster.

Azure Managed Redis (this module's Redis backend) replacing legacy Azure
Cache for Redis is a resource-type change, not a structural delta vs AWS —
AWS ElastiCache doesn't require the equivalent authentication contract, so
there's no shared pattern to compare against either way.

#### Historical retirements

All five `null_resource` workarounds the prototype shipped with were
replaced with declarative idioms that are **not** Azure-specific in shape
(only in parameter values), and the legacy three-mode TLS surface
(`var.tls_mode = self_signed | letsencrypt | custom_pfx`) was collapsed into
a single BYO-secret contract. The internal two-tier split (`modules/infra/` +
`modules/workload/`, 0 providers at the root) was itself later reverted by
`align-azure-with-aws-capabilities` back into one resource-bearing root:

- **AKS API warm-up** — `time_sleep.aks_api_warmup` in `aks.tf`
  (`var.aks_api_warmup_seconds`, default 90 s, range 30..600). Replaced the
  `null_resource.wait_for_aks_api` `/healthz` poll-loop. The kubernetes /
  helm providers' built-in retry handles any post-gate 503s.
- **uuid-ossp bootstrap Job** — deleted entirely; the server-level
  `azure.extensions` allowlist (delta #1 above) is now the only
  Terraform-side artefact.
- **Post-deploy migration rollout-restart** — chart-native Redis multi-main
  leader election (`multiMain.setup`) plus `helm_release.n8n` running with
  `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true`
  together absorb the `CREATE INDEX CONCURRENTLY` race natively. A small
  `time_sleep.n8n_helm_settle` (default 60 s, configurable via
  `var.n8n_helm_post_install_settle_seconds`) gates the Ingress so AGIC
  reconciles against a fully-converged deployment.
- **KEDA TriggerAuthentication apply-time `kubectl`** —
  `kubectl_manifest.keda_trigger_authentication` in `keda.tf` (delta #2
  above). The chart-native path is unavailable because the n8n-io chart at
  the pinned version does not expose `keda.triggerAuthentication.*` values
  nor `extraManifests` / `extraObjects` hooks (verified upstream
  `values.yaml`).
- **Destroy-time Azure Files CIFS-detach drain** — `time_sleep.wait_for_aks_drain`
  in `cleanup.tf` existed only to absorb the asynchronous SMB detach after Helm
  uninstalled pods mounting the Azure Files share. Removed by
  `slim-first-release-surface` alongside Azure Files support itself — no
  shared-filesystem mount means no CIFS detach to wait on. If a live destroy
  qualification surfaces a different teardown race, reintroduce a gate with
  that failure mode documented; do not resurrect the CIFS rationale.
- **Three-mode TLS surface (`var.tls_mode`) + module-owned Key Vault** —
  collapsed into a single BYO-secret contract: `var.app_gateway_tls_cert_secret_id`
  + the optional `var.app_gateway_keyvault_id` (role-assignment scope). The
  `acme_*` and `tls_*` helper trees live in `modules/tls-letsencrypt/` and
  `modules/tls-self-signed/`.
- **Two-tier composition (`modules/infra/` + `modules/workload/`)** — every
  resource, control, and safeguard both submodules owned now lives at the
  root in the concern files listed under [File layout](#file-layout) above.

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
- **`terraform validate`** against the root, both TLS submodules, and every
  example.
- **`tflint`** against the same set, with the **azurerm** ruleset initialized
  via `tflint --init`. The ruleset comes from `.tflint.hcl` at the module
  root, which pins `terraform-linters/tflint-ruleset-azurerm`.
- **`checkov`** (`bridgecrewio/checkov-action@v12`) against the Terraform
  framework. `soft_fail` is currently `true` — see the inline comment in the
  workflow. **When you add new resources, do not regress curated findings;
  prefer fixing them over adding suppressions.**

### 2. Unit + integration tests via `terraform test`

- `tests/defaults.tftest.hcl` exercises every resource, output, and
  diagnostic the root module owns. Uses `mock_provider` for all six
  declared providers.
- `modules/tls-letsencrypt/tests/*.tftest.hcl` and
  `modules/tls-self-signed/tests/*.tftest.hcl` cover the two TLS helpers.
- Each of `examples/small`, `examples/medium`, `examples/large`, and
  `examples/split-ingress` carries its own `tests/*.tftest.hcl` suite
  asserting the example's distinguishing decisions (sizing, split-ingress
  routing).

`tests/scripts/smoke-test.sh` is the **integration / post-apply** check used
against a real cluster — kept out of CI on purpose (it needs live Azure
credentials and an applied stack).

All Terraform test suites run **without Azure credentials** and are safe to
run in CI.

When you add a feature, add an `assert` for it in the relevant
`.tftest.hcl` file. Use `command = plan` unless you specifically need
apply semantics.

**Combined wall-clock budget:** every `terraform test` suite in this repo
(root + both TLS submodules + all six examples) must complete in **under 5
minutes** on a clean GitHub Actions runner. If you add a run that pushes the
budget, profile it.

### 3. Naming conventions

This module follows the [Terraform module
conventions](https://developer.hashicorp.com/terraform/language/modules/develop/structure):

- Repository name is **`terraform-<PROVIDER>-<NAME>`** → `terraform-azurerm-n8n`.
- Resource names use **`snake_case`**. The "main" resource of a kind in this
  module is named `n8n` (e.g. `azurerm_kubernetes_cluster.n8n`,
  `azurerm_postgresql_flexible_server.n8n`, `azurerm_managed_redis.n8n`) —
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

  CI installs the same version (`v0.24.0`, tracking the brew default) and
  runs `terraform-docs --output-check .`. If your local version differs
  from CI's, the markdown table whitespace will drift and the check will
  fail; bump both together when upgrading.

- `examples/README.md` compares the sizing tiers; each tier has its own generated README reference.
- `docs/troubleshooting.md`, `docs/post-deployment.md`, `docs/destroy-cleanup.md`,
  `docs/tls-rotation.md`, `docs/redis.md`, `docs/data-storage.md`,
  `docs/observability.md`, and `docs/azure-key-vault-external-secrets.md`
  cover operator-facing concerns that don't belong inline in `README.md`.
- Inline comments in `.tf` files use the `# ── Section ──` banner style.
  Match it when adding new sections.
- The `kubectl_manifest.keda_trigger_authentication` defer-rendered manifest
  carries a comment block above the resource documenting the failure mode
  prevented and a link to the relevant troubleshooting doc.

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
terraform fmt -recursive        # before committing (covers the root + both TLS submodules + every example)

# Root module
terraform init -backend=false
terraform validate
terraform test -verbose         # plan-time, no Azure creds needed
tflint --init && tflint --format compact

# TLS helper submodules
for dir in modules/tls-self-signed modules/tls-letsencrypt; do
  terraform -chdir="$dir" init -backend=false
  terraform -chdir="$dir" validate
  terraform -chdir="$dir" test -verbose
done

# Examples
for dir in examples/small examples/medium examples/large examples/split-ingress; do
  terraform -chdir="$dir" init -backend=false
  terraform -chdir="$dir" validate
  terraform -chdir="$dir" test -verbose
done

# Static analysis (matches CI):
checkov -d . --framework terraform --soft-fail

# Refresh the README reference blocks (matches CI's --output-check):
terraform-docs .
terraform-docs examples/small
terraform-docs examples/medium
terraform-docs examples/large
```

`./init.sh` runs the offline subset of this loop (fmt, init, validate, test)
across the root, both TLS submodules, and all four examples in one command —
safe to run repeatedly, no Azure credentials required.

After running any `terraform init`, clean up `.terraform/` before committing
— it is gitignored and `init` will recreate it. `.terraform.lock.hcl` is the
opposite: it is intentionally tracked (not gitignored) at the root and every
example/submodule, per module-verification's "Provider lock coverage"
requirement. After adding or bumping a provider, refresh every lock file for
all three supported platforms and commit the result:

```bash
for dir in . modules/tls-self-signed modules/tls-letsencrypt \
  examples/small examples/medium examples/large \
  examples/split-ingress; do
  terraform -chdir="$dir" providers lock \
    -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
done
```

A real deployment uses `terraform apply` from the selected sizing example with
a populated `terraform.tfvars`, but **never apply from CI** in this repo.

### Running `tests/scripts/smoke-test.sh` against a live deployment

The smoke test is intentionally **not** wired into CI. Run it manually from
a machine that has `az login`'d to the target subscription:

```bash
az login
cd examples/small
terraform init && terraform apply               # populated terraform.tfvars
../../tests/scripts/smoke-test.sh               # uses `terraform output` to discover the cluster
```

The script asserts: AKS API responds, n8n namespace exists, main/worker/
webhook-processor pods meet their autoscaler floors, PostgreSQL and Redis
connectivity, Azure Blob access, App Gateway reachable, HTTPS GET on
`n8n_url` returns 200, license is valid. Non-zero exit on any failed
assertion.

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
  `examples/small/providers.tf`).
- Don't introduce nested `module` calls inside the module root. This module is
  intentionally flat so registry consumers can read it top to bottom. Examples
  may call helper modules; the module root may not.
- Don't drop networking into the module root. The caller passes `vnet_id`
  and the five subnet IDs; only the private DNS zones (Postgres, Redis, Blob)
  are module-owned.
- Don't reintroduce a `null_resource` workaround. All five the prototype
  shipped with have been replaced — see "Historical retirements" above for
  what shipped where. If you need to apply CRD-aware Kubernetes manifests,
  use the `gavinbunney/kubectl` provider's `kubectl_manifest` resource
  (already in `versions.tf`); if you need a destroy-time wait, use
  `time_sleep` with `destroy_duration`.
- Don't commit `terraform.tfstate*`, `*.tfplan`, `apply*.log`, or
  `terraform.tfvars`. The `.gitignore` already covers these; check before
  committing if you ran `apply` locally inside an example directory.
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
- Don't reintroduce a two-tier `modules/infra` + `modules/workload` split.
  The root is intentionally the single resource-bearing module again after
  `align-azure-with-aws-capabilities` — see the "Historical retirements"
  section above for why the split was reverted.

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
  — AVM module used by the sizing examples to build the five subnets with
  the required delegations / network-policy settings.
