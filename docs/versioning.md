# Version and pin inventory

Every version this module pins, where it lives, and what checking it costs.
Added in `port-aws-050-enhancements`, mirroring the AWS sibling's
`docs/versioning.md`.

## Pins and where they live

| Pin | Current | File | Bump tier |
|---|---|---|---|
| `terraform` floor | `>= 1.13` (root and examples); `>= 1.9` (`modules/controllers`, `modules/tls-letsencrypt`, `modules/tls-self-signed`) | `versions.tf` | Minor-required: raising the floor can drop support for older caller pipelines. 1.12 is the first release that short-circuits `\|\|`/`&&`, which the root's `var.x == null \|\| var.x.attr` validations need; 1.13 stops `terraform test` leaking a provider process per run block (issue #63). The floor is also the second Terraform version in the CI `test` matrix; change both together. |
| `azurerm` provider | `>= 4.39.0, < 5.0.0` (root); `>= 4.75.0, < 5.0.0` (examples, for the `persist_id_on_create_before_polling_for_completion` provider feature); `~> 4.0` (`modules/tls-letsencrypt`, `modules/tls-self-signed`) | `versions.tf` | Verification-required: re-run the full offline matrix; a major bump needs a live-apply check per `docs/manual-azure-qualification.md`. |
| `kubernetes` provider | `~> 3.0` | `versions.tf` (root, `modules/controllers`, all example roots) | Verification-required for a major bump (2.x to 3.x deprecated unversioned resource types with no working `moved` block; see `AGENTS.md`'s "Historical retirements"). Patch-safe within `~> 3.0`. |
| `helm` provider | `~> 3.0` | `versions.tf` (root, `modules/controllers`, all example roots) | Patch-safe within `~> 3.0`. The 2.x to 3.x major bump is done: it was breaking for callers (provider `kubernetes`/`exec` blocks became attributes, `registry` blocks became the `registries = [{ ... }]` list attribute, `helm_release` `set` blocks became lists, `metadata[0]` became `metadata`) and needed no state step; see [README.md, Moving the helm provider from 2.x to 3.x](../README.md#moving-the-helm-provider-from-2x-to-3x). A future 4.x major (Helm 4 support is open upstream) is verification-required: plan from existing 3.x state and run a live in-place upgrade of `examples/small` before releasing. |
| `random` provider | `~> 3.0` | `versions.tf` | Patch-safe. |
| `time` provider | `~> 0.14` | `versions.tf` | Patch-safe. |
| `kubectl` provider (gavinbunney) | `>= 1.14` | `versions.tf` | Patch-safe; this provider has no active maintainer, watch for a fork if it goes stale. |
| `acme` provider (vancluever) | `~> 3.0` | `modules/tls-letsencrypt/versions.tf` | Verification-required, even for a patch release: plan from state written by the previous pin and confirm `acme_certificate.n8n` is not replaced. `3.1.1` dropped the state migration from 2.x, so a certificate issued with 2.x needs one apply with a release that still carries it (`3.0.0`, `3.0.1`, or `3.1.0`; any one is enough) before a later 3.x release, or the next plan replaces it (`key_type` `2048` to `RSA2048`; see `modules/tls-letsencrypt/README.md`). |
| `tls` provider | `~> 4.0` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| n8n Helm chart (`n8n_chart_version`) | `1.16.0` | `variables.tf` default | Minor-required: diff `values.yaml`/`values.schema.json` with `tests/scripts/chart-values-diff.sh <candidate>` before bumping, and diff `templates/` too (`1.13.0` to `1.14.0` renamed the chart's `WEBHOOK_URL` to `N8N_WEBHOOK_URL`, n8n-hosting #184, with no release-note entry; `1.14.0` to `1.15.0` renamed the chart's `DB_POSTGRESDB_SSL` to `DB_POSTGRESDB_SSL_ENABLED`, n8n-hosting #175, which the module also sets, so it needed `local.n8n_chart_renders_postgres_ssl_enabled` to avoid a duplicate env name; `1.15.0` to `1.16.0` stopped rendering the single-main PDB, n8n-hosting #228, which `tests/scripts/smoke-test.sh` checked for); re-run `tests/scripts/check-n8n-chart.sh` against the new default (a chart bump is also an n8n upgrade for callers with `n8n_image_tag = null`, so treat the new `appVersion` as an n8n upgrade too), and add the version to `local.n8n_chart_has_worker_only_runners` (`scaling.tf`) only after checking `deployment-main.yaml`'s runner placement. This pin matches `terraform-aws-n8n` #201; the siblings may have moved on since, so check `tests/scripts/check-version-drift.sh` and their defaults before the next bump. `n8n_worker_keda_pause` warns on any chart older than `1.13.0` (numeric major.minor compare in `scaling.tf`, so the floor needs no edit on future bumps). Alternate/conditional pin: `n8n_worker_pools` (Early Alpha) needs a chart that renders `queueMode.workerGroups`, not released to any numbered chart version as of `1.16.0` (merged to the chart's `preview/worker-pools` branch only). `examples/worker-pools` overrides this pin to the preview build's own tag (e.g. `1.11.0-preview.workerpools.1`, published by n8n-io/n8n-hosting#191's `Preview chart` GitHub Action); a numbered release is accepted instead only with `n8n_worker_pools_chart_verified = true`, for a private mirror already verified to carry the feature. |
| KEDA Helm chart (`keda_chart_version`) | `2.21.0` | `variables.tf` and `modules/controllers/variables.tf` defaults (keep both and their tests in step) | Minor-required: KEDA publishes a Kubernetes support matrix per release, so check the pin supports the Kubernetes version of the cluster KEDA runs on before moving either: `aks_kubernetes_version` when `create_aks = true`, or the caller-managed cluster's own version when `create_aks = false` (with `install_keda = false` the caller owns KEDA and this pin does not apply). Ideally it also covers the next AKS minor. As of 2026-10-14, KEDA `2.21` is tested on 1.34 to 1.36, `2.20` on 1.33 to 1.35, and `2.15` on 1.28 to 1.30 ([compatibility matrix](https://keda.sh/docs/2.21/operate/cluster/#kubernetes-compatibility)). The matrix lists tested versions, not a compatibility guarantee, and the chart's `kubeVersion: >=v1.23.0-0` does not enforce it, so pick a specific KEDA release whose tested window covers the target cluster version. A bump can change the `TriggerAuthentication` and `ScaledObject` CRDs the module relies on: read the release's breaking changes and the [migration guide](https://keda.sh/docs/2.21/migration/) against the `TriggerAuthentication` in `locals.tf` (`secretTargetRef` only) and the worker `ScaledObject` the n8n chart renders (`redis` triggers with `address`, `listName`, `listLength`, `enableTLS`, plus the `autoscaling.keda.sh/paused` annotations), and diff `templates/crds/` between the two tags (the chart renders its CRDs from `templates/`, so a bump upgrades them in place). Verify with a live in-place upgrade of `examples/small` from the previous default and the smoke test with `LOAD_TEST=true` (worker scaling), not only the offline suite. `tests/scripts/check-version-drift.sh` reports both defaults against the kedacore chart repository. |
| n8n application image tag (`n8n_image_tag`) | `null` (the chart's `appVersion`, `2.43.5` at chart `1.16.0`) | `variables.tf` default | Verification-required: crosses n8n's own migration/behavior boundaries; needs a qualification run per `docs/manual-azure-qualification.md`. With the null default the running version moves with `n8n_chart_version`, so every chart bump needs that qualification too. `tests/scripts/check-n8n-chart.sh` asserts the pinned chart's `appVersion` is a concrete version at or above `2.39.0`, the premise of `local.n8n_chart_default_image_current`. |
| AKS `aks_kubernetes_version` | `1.36` | `variables.tf` default; the `1.36` literal in `scaling.tf`'s `aks_tuning_requires_module_managed_aks` check (keep it in lockstep, or callers with `create_aks = false` get a false warning) | Verification-required for module-managed clusters (`create_aks = true`): check Azure's [supported-versions page](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions) (or `endoflife.date/azure-kubernetes-service`) for the target version's GA and end-of-life dates, confirm the pinned KEDA chart supports it (see the KEDA row), then run `tests/scripts/preflight-region-check.sh` and a live apply on the new version. With `create_aks = false` this input does not manage or upgrade the caller-managed cluster; leave it at its default to avoid the non-failing tuning warning, and check that cluster's own version against the KEDA row. As of 2026-10-14 `1.36` is GA until 2027-06-30 (long-term support to 2028-06-30), `1.35` is GA until 2027-03-31 (long-term support to 2028-03-31), and Microsoft's calendar lists `1.37` as GA in October 2026, outside KEDA 2.21's tested window. A new default upgrades only the control plane of existing module-managed clusters, leaving node pools on their version (one live run, 2026-10-14; see `docs/troubleshooting.md` and `docs/qualification-runs/2026-10-14-aks-1.36-swedencentral.md`). This module has no checkov allow-list that holds the default back; an earlier version of this row cited one by copying the AWS sibling's `CKV_AWS_339`. |
| PostgreSQL major (`pg_version`) | `16` | `variables.tf` default | Verification-required: raising it on an existing server runs Azure's in-place major version upgrade, with downtime and no rollback; lowering it replaces the server. See [`docs/build-time-decisions.md`](./build-time-decisions.md). |
| Redis SKU family (`redis_sku_name`) | `Balanced_B0` (root default; sizing examples override) | `variables.tf` | Verification-required: Azure Managed Redis SKU/region availability shifts; run `tests/scripts/preflight-region-check.sh --probe-redis` before changing a live deployment's SKU. |
| Terraform CI toolchain (`TF_VERSION`) | `1.16.6` | `.github/workflows/terraform-tests.yml` | Patch-safe; keep in step with the local dev-loop version noted in `AGENTS.md`. The `test` job's `matrix.terraform` repeats this value (matrix values cannot read `env`), so bump both. |
| tflint (`TFLINT_VERSION`) | `v0.64.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; re-run `tflint` locally and triage any new rule findings. |
| checkov (`CHECKOV_VERSION`) | `3.3.29` | `.github/workflows/terraform-tests.yml` | Verification-required: a checkov version bump can change which checks a resource draws (see the `AGENTS.md` correction on `redis_exporter`'s count-0 visibility); triage findings in the same commit as the bump. |
| Helm CLI (`azure/setup-helm`) | `v4.3.0` action, `v3.16.4` binary | `.github/workflows/terraform-tests.yml`, `.github/workflows/version-drift.yml` | Patch-safe; bump both workflows together. |
| `terraform-docs` | `v0.24.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; a version drift between local and CI produces spurious README diff noise (whitespace only), not a functional break. |
| markdownlint | (see CI workflow) | `.github/workflows/terraform-tests.yml`, `.markdownlint.yml` | Patch-safe. |

## Checking currency

`tests/scripts/check-version-drift.sh` checks, with no credentials:

- **Terraform providers** in `versions.tf`, `modules/controllers/versions.tf`,
  and `modules/tls-*/versions.tf`, against the registry.terraform.io versions
  list (what `terraform init` resolves; prereleases are ignored). Each
  constraint is evaluated, not compared as text: a constraint that already
  admits the latest release (`~> 3.0` against 3.3.0) is `OK`, and a latest
  release outside it (`~> 2.12` against 3.3.0) is `DRIFT ... (outside
  constraint)`. An identical constraint in several files is one line.
- **CI toolchain** (`TF_VERSION`, `TFLINT_VERSION`, `CHECKOV_VERSION`) against
  GitHub releases.
- **n8n chart** (`n8n_chart_version`) against the highest plain `X.Y.Z` tag in
  the chart's OCI registry (`ghcr.io/n8n-io/n8n-helm-chart/n8n`).
- **KEDA chart** (`keda_chart_version`, root and `modules/controllers`)
  against the kedacore chart repository index.
- **AKS** (`aks_kubernetes_version`) against
  [endoflife.date's AKS calendar](https://endoflife.date/azure-kubernetes-service):
  the newest GA minor and the pin's end-of-life date. `INFO` while the pin is
  supported, `DRIFT` once it is past end of life or within 90 days of it.
  This is not regional availability: run `tests/scripts/preflight-region-check.sh`
  before a bump.

It does not check `n8n_image_tag`, the example-only constraints, the Terraform
floor, the Helm CLI, `terraform-docs`, or markdownlint, and it cannot check
pins that need a credentialed, account-scoped Azure API call (PostgreSQL major
version support and Redis SKU/region availability; use
`tests/scripts/preflight-region-check.sh` against a real subscription).

Each finding is one line starting with `DRIFT:`, `OK:`, `ERROR:` (a lookup
failed or returned something unparseable; never treated as current), or
`INFO:`, and the report ends with `N pin(s) behind upstream, M lookup(s)
failed`. The script exits 0 when every lookup succeeded, drift or not, and 2
when any lookup failed. The constraint evaluator and tag selection live in
`tests/scripts/lib/constraints.sh`, unit-tested offline by
`tests/scripts/test-version-drift-constraints.sh` on every pull request.

`.github/workflows/version-drift.yml` runs it every Monday (and on manual
dispatch) and syncs the report to a single "Version drift report (automated)"
tracking issue: the open or most recently closed issue titled exactly that
and labelled `version-drift` (an unlabelled one with that exact title is
adopted and labelled; other `version-drift` issues are never touched). A
complete report replaces the issue body. A comment is posted only when the set
of `DRIFT:`/`ERROR:` lines changes (a body edit notifies nobody). The issue is
closed when a report has neither, and reopened when the findings change while
it is closed. If you close it by hand while the findings stay the same, it
stays closed and later reports only refresh the body, until the findings
change. An incomplete report (its last line is not the summary, or the counts
disagree with its lines, as after exit 1 for a missing `curl` or `jq`, or a
crash) writes nothing to the issue, not even the label, and fails the run. A
report with `ERROR:` lines is synced too, and the run then fails, so a failed
lookup is visible both in the issue and as a red run. The decision logic is
`tests/scripts/drift-issue-sync.sh`, whose offline self-test runs on every pull
request; `tests/scripts/test-version-drift-workflow.sh` runs the workflow's own
steps offline. Run the report locally any time:

```bash
tests/scripts/check-version-drift.sh
```

It never modifies a pin. Bumping is always a deliberate, reviewed commit.

## Cadence

Review the weekly drift report every time it lands. A patch-safe pin behind
latest: bump it in the next PR that touches that file anyway, no separate
ticket needed. A minor- or verification-required pin behind latest: file an
issue using this doc's tiers to scope the work. A security fix in any pin does
not wait for the next PR: bump it on its own.

A provider pin whose constraint already admits the latest release (for example
`~> 3.0` against 3.3.0) needs no constraint change; the report prints it as
`OK`, not `DRIFT`. The committed `.terraform.lock.hcl` files still hold CI and
the examples at the version they recorded, so refresh them separately, under
the same cadence as a patch-safe pin. Upgrade every root that commits a lock file,
then record all three platforms' checksums:

```bash
for lock in $(git ls-files '*.terraform.lock.hcl'); do
  dir="$(dirname "$lock")"
  terraform -chdir="$dir" init -backend=false -upgrade
  terraform -chdir="$dir" providers lock \
    -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
done
```

Review the version changes before committing: `-upgrade` moves every provider
the constraints admit, not only the one in the report. `terraform providers
lock` on its own keeps an existing selection and does not upgrade it.
