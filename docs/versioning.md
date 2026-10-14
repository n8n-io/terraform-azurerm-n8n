# Version and pin inventory

Every version this module pins, where it lives, and what checking it costs.
Added in `port-aws-050-enhancements`, mirroring the AWS sibling's
`docs/versioning.md`.

## Pins and where they live

| Pin | Current | File | Bump tier |
|---|---|---|---|
| `terraform` floor | `>= 1.12` (root and examples); `>= 1.9` (`modules/controllers`, `modules/tls-letsencrypt`, `modules/tls-self-signed`) | `versions.tf` | Minor-required: raising the floor can drop support for older caller pipelines. 1.12 is the first release that short-circuits `\|\|`/`&&`, which the root's `var.x == null \|\| var.x.attr` validations need. The floor is also the second Terraform version in the CI `test` matrix; change both together. |
| `azurerm` provider | `>= 4.39.0, < 5.0.0` (root and examples); `~> 4.0` (`modules/tls-letsencrypt`, `modules/tls-self-signed`) | `versions.tf` | Verification-required: re-run the full offline matrix; a major bump needs a live-apply check per `docs/manual-azure-qualification.md`. |
| `kubernetes` provider | `~> 3.0` | `versions.tf` (root, `modules/controllers`, all 8 examples) | Verification-required for a major bump (2.x to 3.x deprecated unversioned resource types with no working `moved` block; see `AGENTS.md`'s "Historical retirements"). Patch-safe within `~> 3.0`. |
| `helm` provider | `~> 2.12` | `versions.tf` (root, `modules/controllers`, all example roots) | Patch-safe within `~> 2.12`. A major bump (3.x) is verification-required and breaking for callers: the `kubernetes` block in provider configuration becomes an attribute, `helm_release.n8n.metadata[0]` becomes `metadata`, and `examples/split-ingress` uses `set` blocks. Plan from existing 2.x state before releasing. |
| `random` provider | `~> 3.0` | `versions.tf` | Patch-safe. |
| `time` provider | `~> 0.14` | `versions.tf` | Patch-safe. |
| `kubectl` provider (gavinbunney) | `>= 1.14` | `versions.tf` | Patch-safe; this provider has no active maintainer, watch for a fork if it goes stale. |
| `acme` provider (vancluever) | `~> 2.16` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| `tls` provider | `~> 4.0` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| n8n Helm chart (`n8n_chart_version`) | `1.14.0` | `variables.tf` default | Minor-required: diff `values.yaml`/`values.schema.json` with `tests/scripts/chart-values-diff.sh <candidate>` before bumping, and diff `templates/` too (`1.13.0` to `1.14.0` renamed the chart's `WEBHOOK_URL` to `N8N_WEBHOOK_URL`, n8n-hosting #184, with no release-note entry); re-run `tests/scripts/check-n8n-chart.sh` against the new default. This pin matches the AWS sibling's. `n8n_worker_keda_pause` warns on any chart older than `1.13.0` (numeric major.minor compare in `scaling.tf`, so the floor needs no edit on future bumps). Alternate/conditional pin: `n8n_worker_pools` (Early Alpha) needs a chart that renders `queueMode.workerGroups`, not released to any numbered chart version as of `1.14.0` (merged to the chart's `preview/worker-pools` branch only). `examples/worker-pools` overrides this pin to the preview build's own tag (e.g. `1.11.0-preview.workerpools.1`, published by n8n-io/n8n-hosting#191's `Preview chart` GitHub Action); a numbered release is accepted instead only with `n8n_worker_pools_chart_verified = true`, for a private mirror already verified to carry the feature. |
| KEDA Helm chart (`keda_chart_version`) | `2.21.0` | `variables.tf` and `modules/controllers/variables.tf` defaults (keep both and their tests in step) | Minor-required: KEDA publishes a Kubernetes support matrix per release ([compatibility matrix](https://keda.sh/docs/2.21/operate/cluster/#kubernetes-compatibility): 2.21 is tested on 1.34 to 1.36, 2.20 on 1.33 to 1.35, 2.15 on 1.28 to 1.30), so check the pin supports the default `aks_kubernetes_version`, and ideally the next AKS minor, before moving either. The chart's `kubeVersion: >=v1.23.0-0` does not enforce that window. A bump can change the `TriggerAuthentication` and `ScaledObject` CRDs the module relies on: read the release's breaking changes and the [migration guide](https://keda.sh/docs/2.21/migration/) against the `TriggerAuthentication` in `locals.tf` (`secretTargetRef` only) and the worker `ScaledObject` the n8n chart renders (`redis` triggers with `address`, `listName`, `listLength`, `enableTLS`, plus the `autoscaling.keda.sh/paused` annotations), and diff `templates/crds/` between the two tags (the chart renders its CRDs from `templates/`, so a bump upgrades them in place). Verify with a live in-place upgrade of `examples/small` from the previous default and the smoke test with `LOAD_TEST=true` (worker scaling), not only the offline suite. `tests/scripts/check-version-drift.sh` reports both defaults against the kedacore chart repository. |
| n8n application image tag (`n8n_image_tag`) | `2.35.0` | `variables.tf` default | Verification-required: crosses n8n's own migration/behavior boundaries; needs a qualification run per `docs/manual-azure-qualification.md`. |
| AKS `aks_kubernetes_version` | `1.35` | `variables.tf` default | Verification-required: check Azure's [supported-versions page](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions) (or `endoflife.date/azure-kubernetes-service`) for the target version's GA and end-of-life dates, confirm the pinned KEDA chart supports it (see the KEDA row), then run `tests/scripts/preflight-region-check.sh` and a live apply on the new version. As of 2026-10-14 `1.35` is GA until 2027-03-31 (long-term support to 2028-03-31) and `1.36` is GA. This module has no checkov allow-list that holds the default back; an earlier version of this row cited one by copying the AWS sibling's `CKV_AWS_339`. |
| PostgreSQL major (`pg_version`) | `16` | `variables.tf` default | Verification-required: raising it on an existing server runs Azure's in-place major version upgrade, with downtime and no rollback; lowering it replaces the server. See [`docs/build-time-decisions.md`](./build-time-decisions.md). |
| Redis SKU family (`redis_sku_name`) | `Balanced_B0` (root default; sizing examples override) | `variables.tf` | Verification-required: Azure Managed Redis SKU/region availability shifts; run `tests/scripts/preflight-region-check.sh --probe-redis` before changing a live deployment's SKU. |
| Terraform CI toolchain (`TF_VERSION`) | `1.16.4` | `.github/workflows/terraform-tests.yml` | Patch-safe; keep in step with the local dev-loop version noted in `AGENTS.md`. The `test` job's `matrix.terraform` repeats this value (matrix values cannot read `env`), so bump both. |
| tflint (`TFLINT_VERSION`) | `v0.64.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; re-run `tflint` locally and triage any new rule findings. |
| checkov (`CHECKOV_VERSION`) | `3.3.20` | `.github/workflows/terraform-tests.yml` | Verification-required: a checkov version bump can change which checks a resource draws (see the `AGENTS.md` correction on `redis_exporter`'s count-0 visibility); triage findings in the same commit as the bump. |
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
tracking issue. A report with `ERROR:` lines is synced too, and the run then
fails, so a failed lookup is visible both in the issue and as a red run
(`tests/scripts/test-version-drift-workflow.sh` runs the workflow's own steps
offline to check this). Run it locally any time:

```bash
tests/scripts/check-version-drift.sh
```

It never modifies a pin. Bumping is always a deliberate, reviewed commit.

## Cadence

Review the weekly drift report every time it lands. A patch-safe pin behind
latest: bump it in the next PR that touches that file anyway, no separate
ticket needed. A minor- or verification-required pin behind latest: file an
issue using this doc's tiers to scope the work. A pin whose constraint already
admits the latest release (for example `~> 3.0` against 3.3.0) is not drift;
the report prints it as `OK`, not `DRIFT`.
