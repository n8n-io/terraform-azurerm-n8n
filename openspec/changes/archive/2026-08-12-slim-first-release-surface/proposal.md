# Slim the module surface for the 0.1.0 first release

## Why

The module is about to ship its first public release. The current surface carries
capabilities that inflate the input contract, the test matrix, and the operator
documentation without earning their keep for an initial release:

- The `cloudflare` and `godaddy` examples exist only to demonstrate non-Azure
  ACME DNS-01 validation for the `modules/tls-letsencrypt/` helper. They add two
  full example roots (providers, lock files, tests, generated docs) and two cells
  to every CI matrix, yet the DNS-01 provider wiring they demonstrate is a
  property of the TLS submodule, not of the n8n module.
- Optional Azure Files support (`create_azure_files`) exists to serve the
  shared-`filesystem` binary/execution-data modes. It drags in a share, a second
  private DNS zone and endpoint, a CSI credential Secret, a static PV/PVC pair, a
  destroy-time SMB drain gate, an account-key authentication path on the storage
  account, three inputs, three outputs, and a replication toggle in the large
  example. Azure Blob with workload identity is the recommended data plane; the
  filesystem compatibility path is legacy weight for a first release.
- The repository still presents itself as v4.0.0 of a module with v2/v3 history
  and a destructive v3-to-v4 migration runbook. No published release exists, so
  there are no v3.x users and nothing to migrate from.

A leaner 0.1.0 is easier to test exhaustively, easier to review, and leaves the
removed capabilities available as deliberate, spec-driven additions later.

## What Changes

- Delete `examples/cloudflare/` and `examples/godaddy/` entirely, including their
  CI matrix cells (docs, validate, test, tflint), `init.sh` entries, and every
  README/AGENTS cross-reference. Essential ACME DNS-01 provider guidance moves
  into `modules/tls-letsencrypt/README.md`. `examples/small`, `examples/medium`,
  `examples/large`, and `examples/split-ingress` remain.
- Remove Azure Files support: the `create_azure_files`, `storage_share_quota_gb`,
  and `azure_files_mount_path` inputs; the share, file private DNS zone, file
  private endpoint, CSI credential Secret, static PV, and PVC resources; the
  all-pod Helm volume fragment; the `storage_account_primary_access_key`,
  `storage_share_name`, and `storage_persistent_volume_claim_name` outputs; and
  the destroy-time drain gate (`time_sleep.wait_for_aks_drain` plus
  `var.aks_destroy_drain_seconds`), whose only documented failure mode is the
  Azure Files SMB detach.
- Remove the `filesystem` binary-data and execution-data storage modes.
  Binary-data modes reduce to `database` and `azure`; execution-data modes reduce
  to `database` and `azure`. `n8n_storage_path` is removed and
  `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` is always rendered `true`.
- The storage account keeps Blob-only duty: `shared_access_key_enabled` derives
  solely from the retained connection-string/account-key compatibility inputs.
- Reset release framing to a true first release: collapse `CHANGELOG.md` to a
  single `0.1.0` entry, delete `docs/v4-migration-runbook.md`, and remove the
  "Migrating to v4.x" README section and all v3/v4 migration language.
- Fold the two outstanding live-verification tasks from the archived
  `align-azure-with-aws-capabilities` change (live smoke run and single-apply
  lifecycle qualification) into this change as its final section, updated to the
  slimmed surface.

Kept deliberately (out of scope): external PostgreSQL/Redis endpoints,
caller-owned ingress (`create_ingress = false`) and the `split-ingress` example,
Blob compatibility credentials and the custom Blob endpoint, the custom
image/pull-secret/extra-volume surface, OpenTelemetry and log-streaming inputs,
the advisory capacity model, additional domains, and both DNS record paths.

## Capabilities

### Modified Capabilities

- `deployment-examples`: the DNS-provider variants requirement is removed; the
  large tier loses its optional Azure Files durability toggle.
- `managed-service-topologies`: the optional shared Azure Files storage
  requirement is removed; private networking covers PostgreSQL, Redis, and Blob
  only.
- `n8n-workload-configuration`: binary-data modes reduce to `database`/`azure`
  and execution-data modes reduce to `database`/`azure`; no shared-filesystem
  path exists.
- `module-verification`: the smoke test and storage acceptance drop their Azure
  Files and historical-filesystem assertions; a first-release versioning
  baseline (0.1.0, no migration runbook) is added; live verification transfers
  from the archived change.

## Impact

- Root files: `storage.tf`, `cleanup.tf`, `n8n.tf`, `locals.tf`, `variables.tf`,
  `outputs.tf`, `versions.tf` (comment only).
- Examples: `examples/cloudflare/` and `examples/godaddy/` deleted;
  `examples/large/` loses the Azure Files/GZRS toggle; `examples/README.md`
  comparison table updated.
- CI and tooling: `.github/workflows/terraform-tests.yml` matrices, `init.sh`.
- Tests: `tests/defaults.tftest.hcl`, `examples/large/tests/defaults.tftest.hcl`,
  `tests/scripts/smoke-test.sh`, `tests/scripts/.env.example`,
  `tests/scripts/README.md`.
- Docs: `README.md`, `AGENTS.md` (Azure-specific delta #2 retired, file layout,
  examples), `CHANGELOG.md` (reset to 0.1.0), `docs/data-storage.md`,
  `docs/destroy-cleanup.md`, `docs/troubleshooting.md`,
  `docs/post-deployment.md`, `docs/v4-migration-runbook.md` (deleted),
  `modules/tls-letsencrypt/README.md` (gains DNS-01 provider guidance).
