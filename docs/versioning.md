# Version and pin inventory

Every version this module pins, where it lives, and what checking it costs.
Added in `port-aws-050-enhancements`, mirroring the AWS sibling's
`docs/versioning.md`.

## Pins and where they live

| Pin | Current | File | Bump tier |
|---|---|---|---|
| `terraform` floor | `>= 1.9` | `versions.tf` (root + every submodule/example) | Minor-required: raising the floor can drop support for older caller pipelines. |
| `azurerm` provider | `~> 4.0` | `versions.tf` | Verification-required: re-run the full offline matrix; a major bump needs a live-apply check per `docs/manual-azure-qualification.md`. |
| `kubernetes` provider | `~> 3.0` | `versions.tf` (root, `modules/controllers`, all 8 examples) | Verification-required for a major bump (2.x to 3.x deprecated unversioned resource types with no working `moved` block; see `AGENTS.md`'s "Historical retirements"). Patch-safe within `~> 3.0`. |
| `helm` provider | `~> 2.12` | `versions.tf` | Patch-safe. |
| `random` provider | `~> 3.0` | `versions.tf` | Patch-safe. |
| `time` provider | `~> 0.14` | `versions.tf` | Patch-safe. |
| `kubectl` provider (gavinbunney) | `>= 1.14` | `versions.tf` | Patch-safe; this provider has no active maintainer, watch for a fork if it goes stale. |
| `acme` provider (vancluever) | `~> 2.16` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| `tls` provider | `~> 4.0` | `modules/tls-letsencrypt/versions.tf` | Patch-safe. |
| n8n Helm chart (`n8n_chart_version`) | `1.13.0` | `variables.tf` default | Minor-required: diff `values.yaml`/`values.schema.json` with `tests/scripts/chart-values-diff.sh <candidate>` before bumping; re-run `tests/scripts/check-n8n-chart.sh` against the new default. This pin matches the AWS sibling's. `n8n_worker_keda_pause` warns on any chart older than `1.13.0` (numeric major.minor compare in `scaling.tf`, so the floor needs no edit on future bumps). Alternate/conditional pin: `n8n_worker_pools` (Early Alpha) needs a chart that renders `queueMode.workerGroups`, not released to any numbered chart version as of `1.13.0` (merged to the chart's `preview/worker-pools` branch only). `examples/worker-pools` overrides this pin to the preview build's own tag (e.g. `1.11.0-preview.workerpools.1`, published by n8n-io/n8n-hosting#191's `Preview chart` GitHub Action); a numbered release is accepted instead only with `n8n_worker_pools_chart_verified = true`, for a private mirror already verified to carry the feature. |
| n8n application image tag (`n8n_image_tag`) | `2.35.0` | `variables.tf` default | Verification-required: crosses n8n's own migration/behavior boundaries; needs a qualification run per `docs/manual-azure-qualification.md`. |
| AKS `aks_kubernetes_version` | `1.35` | `variables.tf` default | Verification-required: check Azure's [supported-versions page](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions) and this module's own checkov `CKV_AZURE_339` allow-list before bumping (see `AGENTS.md`'s "Compatibility" note on why `1.36` is deliberately not yet the default). |
| PostgreSQL major (`pg_version`) | `16` | `variables.tf` default | Verification-required: a major-version bump on Flexible Server is not in-place. |
| Redis SKU family (`redis_sku_name`) | `Balanced_B0` (root default; sizing examples override) | `variables.tf` | Verification-required: Azure Managed Redis SKU/region availability shifts; run `tests/scripts/preflight-region-check.sh --probe-redis` before changing a live deployment's SKU. |
| Terraform CI toolchain (`TF_VERSION`) | `1.16.4` | `.github/workflows/terraform-tests.yml` | Patch-safe; keep in step with the local dev-loop version noted in `AGENTS.md`. |
| tflint (`TFLINT_VERSION`) | `v0.64.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; re-run `tflint` locally and triage any new rule findings. |
| checkov (`CHECKOV_VERSION`) | `3.3.20` | `.github/workflows/terraform-tests.yml` | Verification-required: a checkov version bump can change which checks a resource draws (see the `AGENTS.md` correction on `redis_exporter`'s count-0 visibility); triage findings in the same commit as the bump. |
| Helm CLI (`azure/setup-helm`) | `v4.3.0` action, `v3.16.4` binary | `.github/workflows/terraform-tests.yml` | Patch-safe. |
| `terraform-docs` | `v0.24.0` | `.github/workflows/terraform-tests.yml` | Patch-safe; a version drift between local and CI produces spurious README diff noise (whitespace only), not a functional break. |
| markdownlint | (see CI workflow) | `.github/workflows/terraform-tests.yml`, `.markdownlint.yml` | Patch-safe. |

## Checking currency

`tests/scripts/check-version-drift.sh` reports drift for every pin above
except the ones that need a credentialed, account-scoped Azure API call
(PostgreSQL major version support and Redis SKU/region availability -
those need `tests/scripts/preflight-region-check.sh` against a real
subscription instead). It runs as the report-only `version-drift` job in
`.github/workflows/terraform-tests.yml` on every push, pull request, and
manual dispatch (there is no scheduled run yet); run it locally any time
with no credentials required:

```bash
tests/scripts/check-version-drift.sh
```

It never modifies a pin. Bumping is always a deliberate, reviewed commit.
