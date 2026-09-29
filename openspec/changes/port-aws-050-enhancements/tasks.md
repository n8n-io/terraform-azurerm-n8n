Implementation starts only after explicit approval, on a non-main branch.
Each numbered section is one focused iteration. Read `AGENTS.md`, this
change's `design.md`, and the relevant delta spec before editing. Keep
changes within this port; do not retune Azure examples, add
`n8n_worker_pools`, install metrics-server, or bump the PostgreSQL version
(excluded by design).

Use plan-time mocked tests by default. No task below requires live Azure
resources. Refresh generated references when adding inputs; never
hand-edit generated blocks. Every new input gets a `validation` block or a
`# no validation: <reason>` comment.

## 1. Bump provider floors, chart default, and CI toolchain

- [x] 1.1 Bump `kubernetes` to `~> 3.0` and `time` to `~> 0.14` in root
  `versions.tf`, `modules/controllers`, `modules/tls-self-signed`,
  `modules/tls-letsencrypt`, and all eight examples (12 files). Review the
  Kubernetes provider v3 upgrade guide against every example's
  `providers.tf` `kubernetes {}`/`helm {}` blocks; fix any removed or
  renamed argument. Verify `terraform init -upgrade` and `validate`
  succeed in all 12 directories.
- [x] 1.2 Refresh all 12 `.terraform.lock.hcl` files with
  `terraform providers lock -platform=linux_amd64 -platform=linux_arm64
  -platform=darwin_arm64`. Verify each lock lists kubernetes 3.x and time
  0.14.x with hashes for all three platforms.
- [x] 1.3 Add `tests/scripts/chart-values-diff.sh` (and
  `tests/scripts/lib/tf-defaults.sh` with the shared `read_default`
  helper); run it for `1.10.0 -> 1.11.0` and record the diff in the PR.
  Re-verify against the 1.11.0 templates: KEDA `listName` ownership,
  `/mcp/` route ownership, and whether `executions.data` now renders on the
  webhook processor (adjust `n8n.tf:264` webhook-only duplicate if so).
- [x] 1.4 Bump `n8n_chart_version` default to `"1.11.0"`; update its
  description. Verify `tests/scripts/check-n8n-chart.sh` passes against the
  new default with Helm schema validation on, and no duplicated managed env
  entry appears on any pod family.
- [x] 1.5 Confirm a plan assertion exists for top-level `replicaCount ==
  n8n_main_hpa_min_replicas` on both topologies; add one if missing. No
  code change to `n8n.tf:237`.
- [x] 1.6 Compare mocked `terraform plan` for `examples/small` before and
  after 1.1-1.4; verify only `helm_release.n8n` changes in-place with zero
  replacements.
- [x] 1.7 Bump `TF_VERSION` to `1.16.2`, `TFLINT_VERSION` to `v0.64.0`,
  `azure/setup-helm` to `v4.3.0` with a current Helm 3 pin, and add a
  pinned `CHECKOV_VERSION` (`3.3.17`) to the checkov step. Verify each pin
  individually against the current workflow; re-run tflint locally at the
  new version and triage any new rule findings without adding blanket
  ignores.

## 2. Add `n8n_worker_extra_env`

- [x] 2.1 Add non-nullable `n8n_worker_extra_env` (default `[]`) mapped to
  `queueMode.workerExtraEnv`, omitted from Helm values when empty. Reuse the
  `n8n_extra_env` reserved-prefix guard and add a C_IDENTIFIER name check.
  Verify mocked tests: empty default omits the key, valid entries render,
  reserved-prefix and malformed names fail at plan.
- [x] 2.2 Extend `n8n_credentials_overwrite_secret_ref`'s conflict
  validation to scan `n8n_worker_extra_env` for
  `CREDENTIALS_OVERWRITE_DATA` / `CREDENTIALS_OVERWRITE_DATA_FILE`. Verify a
  new expected-failure test alongside the existing `n8n_extra_env` case.
- [x] 2.3 Extend `check-n8n-chart.sh` to assert the entry renders only on
  the worker Deployment. Refresh generated docs.

## 3. Port confirmed fixes and Azure-specific collateral

- [x] 3.1 Add a 63-character per-label validation to
  `n8n_image_pull_secrets`. Verify expected failure for a 64-char label and
  a pass for a 253-char name whose labels are all `<= 63`.
- [x] 3.2 Fold a 63-character bound into `examples/split-ingress`
  `webhook_subdomain`'s validation; add an expected-failure run.
- [x] 3.3 Set `nullable = false` on `pg_backup_retention_days`; add a run
  asserting explicit `null` resolves to 7.
- [x] 3.4 Add a `<= 64` character validation on `domain_name` in
  `modules/tls-letsencrypt` and `modules/tls-self-signed` (RFC 5280 CN
  limit), with an expected-failure test in each submodule suite and a
  description update. Leave `subject_alternative_names` at 253.
- [x] 3.5 Verify `tests/defaults.tftest.hcl` covers `n8n..example.com` and
  `n8n.-prod.example.com` rejection for `n8n_domain` and
  `n8n_additional_domains`; add the runs if absent. No validation change.
- [x] 3.6 Pin `redis_exporter_image`'s default by digest; update the
  description; update `tests/scripts/check-redis-exporter.py` to strip the
  `@sha256:...` suffix before extracting the tag. Verify the exporter
  mocked tests and a `python3 -m py_compile` on the script.
- [x] 3.7 Add `tests/checkov/opt-in.tfvars` (`redis_exporter_enabled =
  true` plus any other count-0 opt-in resource an audit of `count =` in
  the root finds) and a second checkov pass in the workflow that fails if
  `kubernetes_deployment_v1.redis_exporter` and its Service are not
  reached. Triage the resulting `CKV_K8S_*` findings: fix on merit, annotate
  `CKV_K8S_11` as a deliberate trade at the resource. Do not widen
  `soft_fail`.
- [x] 3.8 Correct the AGENTS.md checkov paragraph (section 9 of
  `port-aws-040-enhancements` notes) to the count-0 UNKNOWN diagnosis; add a
  one-line note in `tests/scripts/README.md` that the AWS smoke-test
  misdetection does not apply (Azure reads the flag via `printenv` and the
  topology via the HPA).

## 4. Add deletion-safety analogs (best effort)

- [x] 4.1 Confirm against the azurerm 4.x schema that
  `azurerm_postgresql_flexible_server` exposes no deletion-protection or
  final-snapshot attribute. If one exists, wire it as a validated input
  defaulting to current behavior; otherwise add no input.
- [x] 4.2 Add nullable `blob_delete_retention_days` (default `null`,
  validated 1..365 when set) wiring `blob_properties.delete_retention_policy`
  and `container_delete_retention_policy` on the module-managed storage
  account; include it in `blob_tuning_requires_module_managed_blob_storage`.
  Verify mocked tests: null leaves no policy block, a value renders both
  policies, `create_blob_storage = false` with a value emits the check
  warning.
- [x] 4.3 Write `docs/deletion-safety.md` mapping all five AWS controls to
  their Azure outcome (wired / covered by `pg_backup_retention_days` /
  absent with reason); link from `docs/destroy-cleanup.md` and the README.
  Verify no claim of parity for an absent control.
- [x] 4.4 Pass `blob_delete_retention_days` and `pg_backup_retention_days`
  through every example that keeps module-owned Blob/PostgreSQL as nullable
  variables defaulting to the module value; add a "Production
  considerations" table to each such example README; assert wiring at
  defaults and flipped in each example test. `customer-managed-storage`
  takes only the PostgreSQL input; `customer-managed-everything` takes
  neither. Refresh generated docs.

## 5. Add parity, version-drift, lint, and versioning docs

- [x] 5.1 Add `scripts/check-example-parity.sh` with a per-example
  allowlist. Verify it fails on an injected one-sided variable and on a
  stale allowlist entry, and passes on the tree after section 4.
- [x] 5.2 Add `tests/scripts/check-version-drift.sh` covering the six
  providers, CI toolchain, `n8n_chart_version`, and
  `aks_kubernetes_version` against an AKS-specific public source; wire it
  as a report-only `version-drift` job in `terraform-tests.yml`. (Scoped
  down from a separate weekly `version-drift.yml` with a tracking issue;
  a `schedule:` trigger is a follow-up, and no doc calls it "weekly".)
  Verify `bash -n`, `shellcheck`, `--help`, and one local run that reports
  without failing.
- [x] 5.3 Add a markdownlint CI job with a permissive `.markdownlint.yml`.
  (Implemented by disabling the rules the generated `BEGIN_TF_DOCS` blocks
  trip repo-wide in `.markdownlint.yml`, each with a comment, instead of
  wrapping nine blocks in disable/restore comments; same outcome, one
  place to maintain.) Run locally and fix findings in-change.
- [x] 5.4 Write `docs/versioning.md` (pin inventory, file locations, three
  bump tiers) and add a README `## Compatibility` section linking it and
  stating the Kubernetes 3.x / time 0.14 floors and the caller pin-widening
  note.
- [x] 5.5 Wire `check-example-parity.sh`, `chart-values-diff.sh --help`,
  and the checkov opt-in pass into `.github/workflows/terraform-tests.yml`
  and `openspec/init.sh` without removing existing targets. All new
  scripts stay bash 3.2 compatible (no `declare -A`), matching the repo
  convention in `tests/scripts/verify-custom-image.sh`, so `init.sh` runs
  on a stock macOS; `markdownlint` and the network-dependent drift report
  are optional there.

## 6. Integrate, document, and run the offline acceptance matrix

- [x] 6.1 Update `CHANGELOG.md` Unreleased with a "What moves on apply"
  section (chart bump rolls all n8n pods; provider bump is warning-only;
  exporter re-pull only when enabled), plus Added/Changed/Fixed/Security
  and explicit exclusions (metrics-server, PostgreSQL version,
  helm-chart-coverage, Istio docs; `n8n_worker_pools` moved from excluded
  to section 7). Update `AGENTS.md`
  contracts. Verify no fictitious live measurement is introduced.
- [x] 6.2 Run `terraform fmt -recursive`, `./openspec/init.sh` (fmt, init,
  validate, test across root, three submodules, eight examples). Verify
  combined `terraform test` wall-clock stays under 5 minutes.
- [x] 6.3 Run `tflint` (new version) across the matrix, both checkov
  passes, markdownlint, `shellcheck` on every new script, and
  `terraform-docs --output-check` for the root and eight examples.
- [x] 6.4 Review the final diff against the applicability table: every
  "Port" row has a change, every "Skip"/"Already present" row introduced
  none. Clean recreated `.terraform/` directories before committing.

## 7. `n8n_worker_pools` follow-up (early alpha; design Decision 6)

- [x] 7.1 Add `worker-pools.tf`: `local.n8n_worker_groups` mapping
  `var.n8n_worker_pools` onto `queueMode.workerGroups`, with per-pool
  sizing falling back to the module-wide `n8n_worker_*` inputs; merge into
  `helm_release.n8n` only when non-empty; append
  `N8N_WORKER_POOLS_ENABLED=true` to `config.extraEnv` only when non-empty.
- [x] 7.2 Reserve `N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME` in
  `local.n8n_managed_env_names`; reject `N8N_WORKER_POOL_NAME` in pool
  `extra_env`; extend the credentials-overwrite conflict check to pool
  `extra_env`.
- [x] 7.3 Pool scalers reference `local.n8n_redis_keda_auth_name` via
  `keda.authenticationRef` (key omitted when unauthenticated; the chart
  schema's `minLength: 1` rejects an empty name) and carry only
  `enableTLS` in `keda.triggerMetadata`, rendered unconditionally, matching
  the default worker's triggers in `n8n.tf`. Verified the chart exposes
  `workerGroups[].keda.authenticationRef` on both the branch schema and the
  published `1.11.0-preview.workerpools.1` build.
- [x] 7.4 `lifecycle.precondition` on `helm_release.n8n` for the chart
  pairing (`local.n8n_chart_renders_worker_pools`,
  `n8n_worker_pools_chart_verified`); hard `validation` on `n8n_image_tag`
  for the 2.39.0 floor while pools are declared.
- [x] 7.5 Pool-name validations (1-43 lowercase DNS label, unique, not
  `default`), replica/concurrency/quantity validations, and the pool CPU
  contribution to `scaling.tf`'s capacity model.
- [x] 7.6 `examples/worker-pools/` (three pools, required
  `n8n_chart_version`, `n8n_image_tag` default 2.39.0) with its own test
  suite; allowlisted in `scripts/check-example-parity.sh`; added to every
  CI matrix and `openspec/init.sh`. `check-n8n-chart.sh` pulls the preview
  chart and renders the pool Deployment and ScaledObject for both the
  unauthenticated and authenticated Redis fixtures.
- [x] 7.7 `tests/scripts/verify-worker-pools.sh`: post-apply pool
  Deployment/ScaledObject verification comparing each pool trigger's
  `enableTLS` and `authenticationRef.name` against the default worker's
  and asserting no credential in trigger metadata.
- [x] 7.8 Root `tests/defaults.tftest.hcl` coverage for every scenario in
  the `n8n-workload-configuration` delta spec (mapping, sizing inheritance,
  KEDA auth reuse on the managed, unauthenticated-external, and
  authenticated-external Redis paths, name/bounds validations, chart
  precondition, image floor incl. the module default, floor inert without
  pools).
- [x] 7.9 Document in `README.md` (`## Worker pools (early alpha)`),
  `CHANGELOG.md`, `AGENTS.md`, and `examples/worker-pools/README.md`.
- [x] 7.10 Live: run `tests/scripts/verify-worker-pools.sh` against a full
  `examples/worker-pools` apply (the first live run was torn down on a
  subscription vCPU quota before the verifier ran). Passed on the second
  run, see `docs/qualification-runs/2026-09-22-pr6-swedencentral.md`,
  "Worker pools verifier".
