## Context

See [proposal.md](proposal.md) for motivation and scope. Source is the
tagged AWS `0.4.0..0.5.0` diff (`CHANGELOG.md` `[0.5.0] - 2026-09-21`), not
AWS HEAD or earlier-release features.

Azure baseline, confirmed by direct read (not assumed):

- `versions.tf`: `kubernetes ~> 2.0`, `time ~> 0.12`, `helm ~> 2.12`.
- `variables.tf`: `n8n_chart_version = "1.10.0"`; `redis_exporter_image`
  tag-only (`oliver006/redis_exporter:v1.90.0`); `n8n_image_pull_secrets`
  has a DNS-1123 regex and a 253-char total check but no 63-char per-label
  bound; `pg_backup_retention_days` has a default but no `nullable = false`;
  `n8n_domain` and `n8n_additional_domains` **already** enforce 63-char
  labels, 253 total, and no leading/trailing hyphens.
- `n8n.tf:237`: `replicaCount = var.n8n_main_hpa_min_replicas` is **already**
  set explicitly alongside `multiMain.replicas`. `local.n8n_bull_queue_keys`
  sets KEDA `listName` explicitly.
- `storage.tf`: no `delete_retention_policy` / soft delete configured.
- `database.tf`: no deletion-protection attribute; retention via
  `pg_backup_retention_days` (7..35, Azure forbids disabling backups).
- `tests/scripts/smoke-test.sh`: topology detected from the rendered
  `n8n-main` HPA; `N8N_MULTI_MAIN_SETUP_ENABLED` read via `printenv` inside
  the pod, **not** from the Deployment spec `.value`. AWS's misdetection bug
  does not exist here.
- `tests/scripts/check-redis-exporter.py:36` derives the exporter version
  with `image.rsplit(":", 1)[1]`; a digest-pinned image breaks it.
- `.github/workflows/terraform-tests.yml`: `TF_VERSION 1.15.1`,
  `TFLINT_VERSION v0.53.0`, `azure/setup-helm@v4` with Helm `v3.16.4`,
  checkov via `bridgecrewio/checkov-action@v12` with **no** pinned checkov
  version and `soft_fail: true`. No markdownlint job. No `check-checkov.sh`,
  no `tests/checkov/`, no `scripts/`, no Taskfile.
- `AGENTS.md` (port-aws-040 section 9 paragraph) states "Checkov's Terraform
  framework registers its `CKV_K8S_*` checks against the unsuffixed
  `kubernetes_deployment`/`kubernetes_service` resource types only". AWS
  0.5.0 proved this diagnosis wrong: checkov does register `_v1` types; it
  returns UNKNOWN for count-0 resources and drops them.
- No `docs/versioning.md`, no README "Compatibility"/"Stability" section,
  no `docs/helm-chart-coverage.md`, no `docs/upgrading-n8n.md` equivalent.
- `examples/split-ingress/variables.tf` declares `webhook_subdomain`
  (single label). No example passes `n8n_image_pull_secrets` through.
- Both TLS submodules take `domain_name`, which becomes the certificate CN.

User decisions (this port):

1. Deletion-safety analogs: best-effort mapping, not a literal AWS-input
   port. Document explicitly wherever no Azure primitive matches.
2. Version-currency tooling: in scope for this change, adapted to AKS.
3. `n8n_worker_pools`: excluded from the initial scope (alpha, unreleased
   chart branch), then requested as a follow-up inside this same change
   once the official preview chart build became pullable. See Decision 6.

## Goals and non-goals

**Goals:** Close the provider-floor gap, bump the chart default with the
1.11.0 delta re-verified against Azure's own routing/KEDA/executions
wiring, port the confirmed bug fixes (image-pull-secret label length,
`pg_backup_retention_days` nullability, checkov count-0 blind spot, wrong
AGENTS.md diagnosis), pin the exporter image by digest without breaking
the existing exporter probe script, add the CN-length analog on the TLS
submodules, add `n8n_worker_extra_env`, add best-effort deletion-safety
controls with honest documentation, and add AKS-adapted version-currency
and example-parity tooling.

**Non-goals:** No resource-module split, provider configuration, cloud
service topology change, metrics-server installation,
`db_engine_version`-style PostgreSQL bump (ordinary currency, tracked
separately), Istio documentation, helm-chart-coverage doc/check (Azure has
no coverage doc to gate; see table), or live Azure qualification as a
completion gate.

## Release applicability assessment

| AWS 0.5.0 change | Decision | Azure action and reason |
|---|---|---|
| Kubernetes provider `~>3.0` | Port | Same deprecated unversioned resources (`kubernetes_namespace`, 3x `kubernetes_secret`) in the Azure root plus `examples/large/pgbouncer.tf`-style usage to audit; same in-place-only upgrade shape. Requires 12-directory 3-platform lock refresh (AGENTS.md rule) and a v3 upgrade-guide review of every example `providers.tf` `kubernetes {}` block. |
| `time` provider `~>0.14` | Port | Additive. The 2026-09-16 qualification run already resolved `time 0.14.0` under `~> 0.12`, so no behavior change. |
| `n8n_chart_version` default `1.11.0` | Port, re-verify | Chart 1.11.0's two changes: KEDA `listName` default moved (inert: Azure sets `listName` from `local.n8n_bull_queue_keys`), chart Ingress gained `/mcp/` (inert: Azure disables the chart Ingress and already routes `/mcp`). Must also re-verify the `n8n.tf:264` comment "Chart 1.10.0 renders executions.data only on main and worker pods" still holds on 1.11.0 before keeping the webhook-only duplicate. |
| `replicaCount` explicit set | Already present | `n8n.tf:237`. Add a plan assertion if none exists; no code change. |
| `metrics_server_chart_version` bump | Skip | Azure installs no metrics-server; AKS ships it as a managed addon. |
| `db_engine_version` bump | Skip | RDS-specific; Flexible Server currency is separate. |
| CI toolchain bumps | Port, adapted | `TF_VERSION 1.15.1 -> 1.16.2`, `TFLINT_VERSION v0.53.0 -> v0.64.0`, Helm `v3.16.4` -> current under `azure/setup-helm@v4.3.0`. `CHECKOV_VERSION` does not exist in Azure: adding a pin is new work, do it (an unpinned scanner is itself a currency gap). |
| markdownlint CI job | Port (bounded) | Azure has `README.md`, `AGENTS.md`, `docs/*.md` and no lint. Add with the same `<!-- markdownlint-disable -->` wrap around the generated block. Expect a first-run cleanup pass; keep the config permissive (line-length off) to avoid the noise the AWS repo hit. |
| `docs/versioning.md` | Port | Azure has no pin inventory. Write one enumerating providers, Terraform floor, n8n chart, `aks_kubernetes_version`, PostgreSQL version, Redis SKU/version knobs, CI toolchain, and the three bump tiers. Link from a new README `## Compatibility` section (Azure has none today) and from `AGENTS.md`. |
| `check-version-drift.sh` + weekly workflow | Port, adapted | Replace EKS/`endoflife.date` with the AKS supported-versions source (see Decision 5). Wired as a report-only job in the existing workflow; a `schedule:` trigger is a follow-up, so no doc may call it "weekly" until one exists. |
| `check-helm-chart-coverage.sh` + `docs/helm-chart-coverage.md` | Skip | The check gates a coverage doc Azure never had. Creating the doc is a separate, larger documentation change; do not half-port the gate. Flag for a follow-up. |
| `chart-values-diff.sh` | Port | Tiny, credential-free, directly useful for the 1.11.0 bump in this change. No Taskfile: expose as a plain script documented in `tests/scripts/README.md`. |
| `n8n_worker_pools` (alpha), its example, `verify-worker-pools.sh`, pool env-name guards | Port (follow-up, adapted) | Initially skipped as alpha on an unreleased chart branch; re-scoped in once `oci://ghcr.io/n8n-io/n8n-helm-chart/n8n:1.11.0-preview.workerpools.1` was pullable. Two Azure adaptations differ from the AWS shape, both because the AWS premises do not hold here: pool scalers reference the module's existing `TriggerAuthentication` (this module's default worker does too; AWS uses flat metadata), and the n8n 2.39 image floor is a hard validation on `n8n_image_tag` (its default here is a pinned version, not `null`). See Decision 6. |
| `n8n_worker_extra_env` | Port | Generic chart passthrough, independent of pools. Extend the credentials-overwrite conflict validation to cover it. |
| Deletion controls (5 AWS inputs) | Port, adapted (best effort) | See Decision 3. |
| `scripts/check-example-parity.sh` | Port | Same drift class across Azure's eight examples. |
| Deletion-control passthrough into every example | Port | Follows from Decision 3 outcome. |
| `db_backup_retention_period` `nullable = false` | Port | Confirmed: `pg_backup_retention_days` lacks `nullable = false`; explicit `null` fails its `>= 7` validation instead of falling back to 7. |
| Fix: `n8n_image_pull_secrets` 63-char label bound | Port (root only) | Confirmed gap at `variables.tf:1068-1079`. No Azure example passes this input through, so no example work. |
| Fix: `webhook_subdomain` 63-char bound | Port | `examples/split-ingress/variables.tf:36` exists with a single-label validation; fold the bound in. |
| Fix: `smoke-test.sh` multi-main misdetection | Not applicable | Azure reads the flag via `printenv` in the pod and detects topology from the HPA. Add a one-line note in `tests/scripts/README.md`; no code change. |
| Fix: checkov count-0 exporter blind spot | Port (new) | Azure has no second pass. Add `tests/checkov/opt-in.tfvars` and a second checkov run reaching `kubernetes_deployment_v1.redis_exporter[0]`/its Service. Correct the wrong AGENTS.md diagnosis and re-triage the exporter's real `CKV_K8S_*` findings (AWS found 3 untriaged; expect `CKV_K8S_11` no-CPU-limit as the deliberate annotated trade, plus the two the digest pin fixes). |
| Fix: domain validation tightening | Already present | `variables.tf:2386,2414`. Verify tests cover `n8n..example.com` and `n8n.-prod.example.com`; add if missing. |
| Fix: ACM 64-char Common Name precondition | Port, adapted | Azure never issues a cert at the root, but both TLS submodules do: `domain_name` becomes the CN. Add a `<= 64` character validation on `domain_name` in `modules/tls-letsencrypt` and `modules/tls-self-signed`. `subject_alternative_names` keep the 253 SAN limit. |
| Fix: examples missing "Production considerations" | Conditional | Depends on Decision 3 outcome: only if a new deletion-safety input lands does every example that keeps module-owned PostgreSQL/Blob need the table. |
| Fix: cloudflare/godaddy README notes | Not applicable | Those examples were removed by `slim-first-release-surface`. |
| Security: `redis_exporter_image` digest pin | Port | Confirmed tag-only. Must also update `check-redis-exporter.py:36` version parsing to strip `@sha256:...` before `rsplit`. |
| Compatibility/Known-limitations notes | Port, adapted | Write Azure's own "What moves on apply" section in `CHANGELOG.md` (chart bump rolls all pods; provider bump is warning-only). |
| `docs/istio-ingress.md` | Skip | Out of scope; `split-ingress` documents the `create_ingress = false` contract. |

## Decisions

### 1. Provider floor and chart default bumps

Bump `kubernetes` to `~> 3.0` and `time` to `~> 0.14` in every
`required_providers` block: root, `modules/controllers`,
`modules/tls-self-signed`, `modules/tls-letsencrypt`, all eight examples.
Then refresh all twelve `.terraform.lock.hcl` files for
`linux_amd64`, `linux_arm64`, `darwin_arm64` (AGENTS.md requirement).
Review the Kubernetes provider v3 upgrade guide against each example's
`providers.tf` `provider "kubernetes" {}` / `provider "helm" {}` block for
removed or renamed configuration arguments before assuming `init` alone is
enough.

Bump `n8n_chart_version` default to `"1.11.0"`. Re-verify the three
chart-side assumptions Azure encodes: KEDA `listName` ownership (inert),
`/mcp/` route ownership (inert), and the `n8n.tf:264` claim that the chart
renders `executions.data` only on main and worker (must be re-checked
against 1.11.0 templates; if the chart now renders it on the webhook
processor too, drop Azure's webhook-only duplicate instead of shipping a
duplicated env entry).

`replicaCount` is already explicit; only add a plan assertion if the test
suite lacks one.

Verify the upgrade shape via mocked `terraform plan` on `examples/small`
before and after: only `helm_release.n8n`'s `version` changes in-place, no
resource replacement. This proves plan shape only; live verification stays
outside this port (matching `port-aws-040-enhancements`).

**Alternative rejected:** Renaming unversioned resources to `_v1` in the
same change. No working `moved` block upstream (same open provider issue
AWS cites); the deprecation warning is accepted as cosmetic.

### 2. `n8n_worker_extra_env`, independent of worker pools

Add non-nullable `n8n_worker_extra_env` (default `[]`), `list(object({
name = string, value = string }))`, mapped to `queueMode.workerExtraEnv`.
Reuse `n8n_extra_env`'s reserved-prefix collision guard and add a
C_IDENTIFIER name check. Extend `n8n_credentials_overwrite_secret_ref`'s
conflict validation to scan this input for `CREDENTIALS_OVERWRITE_DATA[_FILE]`.
Omit the chart key entirely when empty (no `helm_release` diff for callers
who do not set it). No pool env-name guard: nothing to guard.

### 3. Deletion-safety analogs (best effort)

| AWS input | Azure outcome | Basis |
|---|---|---|
| `db_deletion_protection` | No provider attribute on `azurerm_postgresql_flexible_server`; `lifecycle.prevent_destroy` cannot be variable-driven. **Documentation only.** Verify the current azurerm 4.x schema during implementation; wire directly if an attribute has appeared. | `database.tf` read; Terraform language constraint. |
| `db_skip_final_snapshot` / `db_final_snapshot_identifier` | No destroy-time snapshot concept on the server resource. **Documentation only**, pointing at Azure's automated-backup retention window as the recovery path. | `database.tf` read. |
| `db_delete_automated_backups` | Covered by existing `pg_backup_retention_days` (Azure forbids disabling backups). **Document coverage; no new input.** Apply the `nullable = false` fix here. | `variables.tf:281`. |
| `s3_force_destroy` | Blob containers delete contents on destroy with no guard, so Azure's default already equals `force_destroy = true`. The nearest safety net is blob soft delete, absent today. **Add optional `blob_delete_retention_days` (nullable, default null = unchanged)** wiring `blob_properties.delete_retention_policy` (and `container_delete_retention_policy`) on the module-managed account; include in the existing `blob_tuning_requires_module_managed_blob_storage` check. | `storage.tf` read: no `delete_retention_policy`. |

Write `docs/deletion-safety.md` (linked from `docs/destroy-cleanup.md` and
the README) enumerating each AWS control against its Azure outcome. Every
input added here must wire to a real control; a no-op input named after a
safety feature is prohibited.

### 4. Confirmed fixes and their Azure-specific collateral

- `n8n_image_pull_secrets`: add the 63-char per-label validation (root
  only).
- `webhook_subdomain` (`examples/split-ingress`): fold the 63-char bound
  into the existing single-label validation.
- `pg_backup_retention_days`: `nullable = false`; add a test asserting
  explicit `null` yields 7.
- TLS submodules: `domain_name` `<= 64` characters (RFC 5280 CN) in both
  `modules/tls-letsencrypt` and `modules/tls-self-signed`, with a submodule
  test each.
- `redis_exporter_image`: pin default by digest (reuse AWS's multi-arch
  index digest if it verifies for `v1.90.0`); update
  `check-redis-exporter.py` to split on `@` before `:`; update the
  `redis_exporter_image` description.
- checkov: add `tests/checkov/opt-in.tfvars` (`redis_exporter_enabled =
  true`, plus any other count-0 opt-in resources found by audit) and a
  second pass in the workflow that fails if the exporter resources are not
  reached. Pin `CHECKOV_VERSION`. Re-triage the exporter's findings; keep
  `CKV_K8S_11` as an annotated deliberate trade. Correct the AGENTS.md
  paragraph.
- Domain validation: already present; ensure regression tests exist.
- smoke-test: no change; document non-applicability.

### 5. AKS-adapted version-currency, parity, and lint tooling

`tests/scripts/check-version-drift.sh`: report drift for the six providers
(GitHub releases/registry), CI toolchain (`TF_VERSION`, `TFLINT_VERSION`,
`CHECKOV_VERSION`, Helm, terraform-docs), `n8n_chart_version` (OCI tags),
and `aks_kubernetes_version` against Microsoft's AKS supported-versions
data (`az aks get-versions` needs credentials, so use the public
release-notes/JSON source; document the fallback if none is stable). Report
only, exit 0. Wired as a report-only `version-drift` job
(`continue-on-error`) in `.github/workflows/terraform-tests.yml`; the AWS
sibling's separate scheduled workflow and tracking-issue sync are a
follow-up, not part of this change. Share the `read_default` helper in
`tests/scripts/lib/tf-defaults.sh` with `chart-values-diff.sh`.

`scripts/check-example-parity.sh`: names-only diff against `examples/small`
with a per-example allowlist (split-ingress's `webhook_subdomain` and
second-gateway inputs; customer-managed stand-in inputs; large's
PgBouncer/replication inputs). Fail on stale allowlist entries.

markdownlint: add a CI job over `README.md`, `AGENTS.md`, `docs/**/*.md`,
`examples/**/README.md` with a permissive `.markdownlint.yml`; wrap every
generated `BEGIN_TF_DOCS` block with disable/restore comments placed
outside the block. Run once locally and fix findings in the same change.

`docs/versioning.md` + README `## Compatibility`: pin inventory and bump
tiers as described in the table.

**Alternative rejected:** Reusing `endoflife.date` for AKS. No AKS-specific
product entry; would misreport AKS's own support windows.

## Risks and trade-offs

- Documentation-only deletion-safety outcomes may read as missing parity;
  mitigated by an explicit gap table rather than placeholder inputs.
- Kubernetes 2.x to 3.x is breaking for callers pinned at `~> 2.0`; treat as
  a minor release with the same pin-widening guidance AWS gives.
- markdownlint's first run may surface many findings; bounded by a
  permissive config and fixing in-change.
- Chart 1.11.0 may have changed `executions.data` rendering; the re-check
  in Decision 1 prevents shipping duplicated env entries.

## Migration plan

No state moves or renames. Chart bump rolls every n8n pod once (in-place
`helm_release` update). Provider bump: deprecation warnings only. New
inputs default to current behavior. Live qualification (provider-bump
apply, soft-delete input against a real storage account) is a separate
follow-up recorded per `docs/manual-azure-qualification.md`.

## Source evidence

- [AWS 0.5.0 changelog](https://github.com/n8n-io/terraform-aws-n8n/blob/main/CHANGELOG.md#050---2026-09-21)
  (full section read; no GitHub Release page exists yet).
- Direct reads: `versions.tf`, `variables.tf` (lines 94-103, 281-290,
  985-994, 1063-1085, 1487-1497, 2381-2428), `n8n.tf` (186-267, 588-596),
  `locals.tf:357`, `observability.tf`, `storage.tf`, `database.tf`,
  `tests/scripts/smoke-test.sh` (220-272, 768-798),
  `tests/scripts/check-redis-exporter.py:22-38`,
  `.github/workflows/terraform-tests.yml`, `README.md` headings,
  `docs/` listing, `examples/split-ingress/variables.tf:36`,
  `modules/tls-*/variables.tf` `domain_name`.
- `openspec/changes/archive/2026-09-14-port-aws-040-enhancements/` as the
  structural precedent.

### 6. `n8n_worker_pools` (follow-up scope, early alpha)

Chart-values-only: each `var.n8n_worker_pools` entry becomes one
`queueMode.workerGroups` entry (`worker-pools.tf`), rendered by the chart
into a worker Deployment plus a KEDA `ScaledObject` on `jobs-<name>`. Zero
new Terraform resources; default `[]` omits the key so an untouched
deployment sees no Helm diff. `N8N_WORKER_POOLS_ENABLED=true` is appended to
`config.extraEnv` only while pools are declared, and both pool env names are
reserved in `local.n8n_managed_env_names`.

Two Azure-specific departures from the AWS port, each because a premise the
AWS shape rests on is false here:

1. **KEDA authentication.** The chart's `workerGroups[].keda` exposes
   `authenticationRef` as well as `triggerMetadata` (verified against the
   `preview/worker-pools` branch schema and the published
   `1.11.0-preview.workerpools.1` build). This module's default worker
   authenticates through `kubectl_manifest.keda_trigger_authentication`,
   so every pool does too: `triggerMetadata = { enableTLS = tostring(...) }`
   rendered unconditionally, `authenticationRef = { name = ... }` merged in
   only when `local.redis_authentication_enabled` (omitted, not `""`: the
   chart schema puts `minLength: 1` on that name, and Helm validates it
   before the template's guard runs; `check-n8n-chart.sh` renders the
   unauthenticated path against the preview build). No credential in
   scaler metadata, and `verify-worker-pools.sh` can compare pool triggers
   against the default worker's key-for-key. The AWS flat
   `passwordFromEnv`/`username` shape matches the AWS default worker, not
   this module's.
2. **Image floor severity.** AWS uses an advisory `check` because its
   `n8n_image_tag` defaults to `null`. Here the variable defaults to a
   pinned version and its regex validation rejects `null`, so the 2.39.0
   floor is fully decidable at plan and is a `validation` on
   `n8n_image_tag`, next to the existing 2.19 and 2.29 floors.

The chart pairing stays a `lifecycle.precondition` on `helm_release.n8n`:
numbered chart versions fail while `n8n_worker_pools` is non-empty unless
`n8n_worker_pools_chart_verified` attests them; a SemVer prerelease passes
on the version string alone. Replace with a numeric floor once
n8n-io/n8n-hosting#189 reaches a numbered release.
