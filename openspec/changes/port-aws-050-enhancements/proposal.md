## Why

[terraform-aws-n8n 0.5.0](https://github.com/n8n-io/terraform-aws-n8n/blob/main/CHANGELOG.md#050---2026-09-21)
bumped the Kubernetes/time provider floors and the n8n chart, added
deletion-time safety controls, tightened several validations, fixed a
checkov blind spot for count-0 resources, pinned a mutable image, and added
version-currency, chart-diff, example-parity, and markdown-lint tooling.
Azure was last caught up through AWS 0.4.0 (`port-aws-040-enhancements`).
Port the applicable parts. Several 0.5.0 items are already present in
Azure (explicit `replicaCount`, DNS-1123 domain validation) or do not apply
(smoke-test misdetection, metrics-server, RDS version); the design records
each with file-level evidence so nothing is re-implemented or skipped by
assumption.

## What changes

- Bump `kubernetes` to `~> 3.0` and `time` to `~> 0.14` in all 12
  `required_providers` blocks; refresh all 12 lock files for three
  platforms; review the provider v3 upgrade guide against every example
  `providers.tf`.
- Bump `n8n_chart_version` default to `1.11.0` after re-verifying the
  1.11.0 delta against Azure's own KEDA `listName`, `/mcp/` routing, and
  webhook-side `executions.data` wiring via a new `chart-values-diff.sh`.
- Bump CI toolchain (`TF_VERSION`, `TFLINT_VERSION`, Helm setup) and add a
  pinned `CHECKOV_VERSION` (Azure currently runs checkov unpinned).
- Add `n8n_worker_extra_env` (chart `queueMode.workerExtraEnv`) with the
  same guards as `n8n_extra_env` and coverage under the credentials-overwrite
  conflict validation.
- Follow-up scope added after the initial proposal: `n8n_worker_pools`
  (EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE), chart-values-only via
  `queueMode.workerGroups`, with a `helm_release.n8n` precondition for the
  chart pairing, a hard `n8n_image_tag` 2.39.0 floor while pools are
  declared, reuse of the module's `TriggerAuthentication` for every pool
  scaler, `examples/worker-pools/`, and `tests/scripts/verify-worker-pools.sh`.
  See design Decision 6 and the `n8n-workload-configuration` delta spec.
- Best-effort deletion-safety analogs: new nullable
  `blob_delete_retention_days` (blob/container soft delete, absent today),
  `nullable = false` on `pg_backup_retention_days`, and a
  `docs/deletion-safety.md` stating plainly which AWS controls
  (`db_deletion_protection`, final snapshot, automated-backup deletion)
  have no Flexible Server analog. No placeholder inputs. Pass the two
  inputs through every example that keeps the module-owned layer, with a
  "Production considerations" table.
- Fixes: 63-char label bound on `n8n_image_pull_secrets` (root; no example
  passes it through) and on `examples/split-ingress` `webhook_subdomain`;
  RFC 5280 64-char Common Name bound on `domain_name` in both TLS
  submodules (the Azure analog of AWS's ACM precondition).
- checkov: add an opt-in second pass so the count-0 `redis_exporter`
  Deployment/Service is actually evaluated; triage its findings; correct
  the wrong "checkov ignores `_v1` types" diagnosis in `AGENTS.md`.
- Security: pin `redis_exporter_image`'s default by digest; update
  `tests/scripts/check-redis-exporter.py`, whose tag parsing breaks on a
  digest.
- Tooling and docs: `scripts/check-example-parity.sh`,
  `tests/scripts/check-version-drift.sh` with an AKS-specific
  Kubernetes-support source as a report-only CI job (no schedule yet), a markdownlint CI job
  with generated blocks wrapped, `docs/versioning.md`, and a README
  `## Compatibility` section (none exists today).
- Explicit exclusions: `metrics_server_chart_version` (AKS ships
  metrics-server), the RDS
  `db_engine_version` bump, `check-helm-chart-coverage.sh` (gates a
  coverage doc Azure never had; follow-up), `docs/istio-ingress.md`, and
  cloudflare/godaddy README notes (examples removed earlier).

## Capabilities

### New capabilities

None.

### Modified capabilities

- `managed-service-topologies`: Blob soft-delete retention, non-nullable
  backup retention, deletion-safety documentation.
- `n8n-workload-configuration`: `n8n_worker_extra_env`; digest-pinned
  exporter image.
- `ingress-dns-and-tls`: Common Name length bound in the TLS submodules;
  webhook subdomain label bound.
- `module-verification`: version-drift, chart-diff, example-parity,
  checkov opt-in pass, markdownlint, pin inventory.

## Impact

Touches `versions.tf` x12, all 12 lock files, `variables.tf`, `locals.tf`,
`n8n.tf` (only if 1.11.0 changed `executions.data` rendering),
`storage.tf`, `modules/tls-*/variables.tf` and tests,
`examples/split-ingress/variables.tf`, example variables/READMEs/tests for
the two pass-throughs, `observability.tf` description,
`tests/scripts/check-redis-exporter.py`, new scripts under `scripts/` and
`tests/scripts/`, `tests/checkov/opt-in.tfvars`, two workflow files, a
`.markdownlint.yml`, `docs/deletion-safety.md`, `docs/versioning.md`,
README, `AGENTS.md`, `CHANGELOG.md`. No nested module, no provider
configuration, no live credentials to complete. The chart bump rolls every
n8n pod once; the provider bump is warning-only on unversioned resources;
this port proves the plan shape under mocks, not a live Azure apply.
