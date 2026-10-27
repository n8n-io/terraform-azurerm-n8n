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
| `helm` provider | `~> 2.12` | `versions.tf` (root, `modules/controllers`, all example roots) | Patch-safe within `~> 2.12`. A major bump (3.x) is verification-required and breaking for callers: the `kubernetes` block in provider configuration becomes an attribute, `helm_release.n8n.metadata[0]` becomes `metadata`, and `examples/split-ingress` uses `set` blocks. Plan from existing 2.x state before releasing. |
| `random` provider | `~> 3.0` | `versions.tf` | Patch-safe. |
| `time` provider | `~> 0.14` | `versions.tf` | Patch-safe. |
| `kubectl` provider (gavinbunney) | `>= 1.14` | `versions.tf` | Patch-safe; this provider has no active maintainer, watch for a fork if it goes stale. |
| `acme` provider (vancluever) | `~> 2.16` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| `tls` provider | `~> 4.0` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| n8n Helm chart (`n8n_chart_version`) | `1.14.0` | `variables.tf` default | Minor-required: diff `values.yaml`/`values.schema.json` with `tests/scripts/chart-values-diff.sh <candidate>` before bumping, and diff `templates/` too (`1.13.0` to `1.14.0` renamed the chart's `WEBHOOK_URL` to `N8N_WEBHOOK_URL`, n8n-hosting #184, with no release-note entry); re-run `tests/scripts/check-n8n-chart.sh` against the new default. This pin matches the AWS sibling's. `n8n_worker_keda_pause` warns on any chart older than `1.13.0` (numeric major.minor compare in `scaling.tf`, so the floor needs no edit on future bumps). Alternate/conditional pin: `n8n_worker_pools` (Early Alpha) needs a chart that renders `queueMode.workerGroups`, not released to any numbered chart version as of `1.14.0` (merged to the chart's `preview/worker-pools` branch only). `examples/worker-pools` overrides this pin to the preview build's own tag (e.g. `1.11.0-preview.workerpools.1`, published by n8n-io/n8n-hosting#191's `Preview chart` GitHub Action); a numbered release is accepted instead only with `n8n_worker_pools_chart_verified = true`, for a private mirror already verified to carry the feature. |
| KEDA Helm chart (`keda_chart_version`) | `2.15.0` | `variables.tf` and `modules/controllers/variables.tf` defaults | Minor-required: KEDA publishes a Kubernetes support matrix per release, so check the pin supports the Kubernetes version of the cluster KEDA runs on before moving either: `aks_kubernetes_version` when `create_aks = true`, or the caller-managed cluster's own version when `create_aks = false` (with `install_keda = false` the caller owns KEDA and this pin does not apply). The default pair is already outside that window: KEDA `2.15` is tested on Kubernetes 1.28 to 1.30, while the AKS default is `1.35`. As of 2026-10-14, KEDA `2.20` is tested on 1.33 to 1.35 and `2.21` on 1.34 to 1.36 ([KEDA cluster docs](https://keda.sh/docs/latest/operate/cluster/)). The matrix lists tested versions, not a compatibility guarantee, and later releases can drop older Kubernetes versions, so pick a specific KEDA release whose tested window covers the target cluster version. A bump can change the `TriggerAuthentication` and `ScaledObject` CRDs the module relies on, so verify with a live apply and the smoke test (worker scaling), not only the offline suite. Not yet covered by `tests/scripts/check-version-drift.sh`. |
| n8n application image tag (`n8n_image_tag`) | `2.35.0` | `variables.tf` default | Verification-required: crosses n8n's own migration/behavior boundaries; needs a qualification run per `docs/manual-azure-qualification.md`. |
| AKS `aks_kubernetes_version` | `1.35` | `variables.tf` default; the `1.35` literal in `scaling.tf`'s `aks_tuning_requires_module_managed_aks` check (keep it in lockstep, or callers with `create_aks = false` get a false warning) | Verification-required for module-managed clusters (`create_aks = true`): check Azure's [supported-versions page](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions) (or `endoflife.date/azure-kubernetes-service`) for the target version's GA and end-of-life dates, confirm the pinned KEDA chart supports it (see the KEDA row), then run `tests/scripts/preflight-region-check.sh` and a live apply on the new version. With `create_aks = false` this input does not manage or upgrade the caller-managed cluster; leave it at its default to avoid the non-failing tuning warning, and check that cluster's own version against the KEDA row. As of 2026-10-14 `1.35` is GA until 2027-03-31 (long-term support to 2028-03-31) and `1.36` is GA. This module has no checkov allow-list that holds the default back; an earlier version of this row cited one by copying the AWS sibling's `CKV_AWS_339`. |
| PostgreSQL major (`pg_version`) | `16` | `variables.tf` default | Verification-required: raising it on an existing server runs Azure's in-place major version upgrade, with downtime and no rollback; lowering it replaces the server. See [`docs/build-time-decisions.md`](./build-time-decisions.md). |
| Redis SKU family (`redis_sku_name`) | `Balanced_B0` (root default; sizing examples override) | `variables.tf` | Verification-required: Azure Managed Redis SKU/region availability shifts; run `tests/scripts/preflight-region-check.sh --probe-redis` before changing a live deployment's SKU. |
| Terraform CI toolchain (`TF_VERSION`) | `1.16.4` | `.github/workflows/terraform-tests.yml` | Patch-safe; keep in step with the local dev-loop version noted in `AGENTS.md`. The `test` job's `matrix.terraform` repeats this value (matrix values cannot read `env`), so bump both. |
| tflint (`TFLINT_VERSION`) | `v0.64.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; re-run `tflint` locally and triage any new rule findings. |
| checkov (`CHECKOV_VERSION`) | `3.3.20` | `.github/workflows/terraform-tests.yml` | Verification-required: a checkov version bump can change which checks a resource draws (see the `AGENTS.md` correction on `redis_exporter`'s count-0 visibility); triage findings in the same commit as the bump. |
| Helm CLI (`azure/setup-helm`) | `v4.3.0` action, `v3.16.4` binary | `.github/workflows/terraform-tests.yml`, `.github/workflows/version-drift.yml` | Patch-safe; bump both workflows together. |
| `terraform-docs` | `v0.24.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; a version drift between local and CI produces spurious README diff noise (whitespace only), not a functional break. |
| markdownlint | (see CI workflow) | `.github/workflows/terraform-tests.yml`, `.markdownlint.yml` | Patch-safe. |

## Checking currency

`tests/scripts/check-version-drift.sh` reports the Terraform providers, the
CI toolchain versions (Terraform, tflint, checkov), the n8n chart and a
best-effort AKS version list. It does not yet report the KEDA chart, the
submodule provider constraints, `n8n_image_tag`, the Helm CLI, `terraform-docs`
or markdownlint, and it cannot report the ones that need a credentialed,
account-scoped Azure API call (PostgreSQL major version support and Redis
SKU/region availability; use `tests/scripts/preflight-region-check.sh` against
a real subscription for those). `.github/workflows/version-drift.yml` runs it every
Monday (and on manual dispatch) and syncs the report to a single
"Version drift report (automated)" tracking issue; run it locally any time
with no credentials required:

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
`~> 3.0` against 3.3.0) needs no constraint change, even though the report may
print it. The committed `.terraform.lock.hcl` files still hold CI and the
examples at the version they recorded, so refresh them separately, under the
same cadence as a patch-safe pin. Upgrade every root that commits a lock file,
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
