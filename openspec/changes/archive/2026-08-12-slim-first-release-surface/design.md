# Design: slim-first-release-surface

Technical decisions for slimming the module to its 0.1.0 surface. The change is
almost entirely subtractive; these notes pin the judgment calls so each task
section can be implemented without re-deriving them.

## Decision 1: The destroy-time drain gate goes with Azure Files

`time_sleep.wait_for_aks_drain` (`cleanup.tf`) exists for exactly one documented
failure mode: asynchronous SMB/CIFS detach after Helm uninstalls pods that mount
the Azure Files share. With no Azure Files support there are no SMB mounts, so
the gate and `var.aks_destroy_drain_seconds` are removed rather than kept "just
in case" (simplest-solution rule). `helm_release.n8n` drops the gate from its
`depends_on`; destroy order becomes Helm release → Secrets/PVC-free namespace →
Azure resources, all inferred from existing references. If the live destroy
qualification (task section 7) surfaces a different teardown race, reintroduce a
gate with that failure mode documented — do not resurrect the CIFS rationale.
This also retires Azure-specific delta #2 in `AGENTS.md`, leaving two deltas
(the `azure.extensions` allowlist and the CRD-aware KEDA install).

## Decision 2: Storage account authentication follows the remaining consumers

`shared_access_key_enabled` currently enables key auth for the Azure Files CSI
credential or Blob compatibility credentials. With Files gone it derives only
from the retained compatibility inputs:
`var.azure_blob_connection_string != null || var.azure_blob_account_key != null`.
The workload-identity default therefore runs with shared key access disabled,
which is the stricter posture Checkov already prefers.

## Decision 3: Keep `n8n_available_binary_data_modes`, restrict its domain

Historical-mode machinery stays: transitions between `database` and `azure`
still need the previous mode readable while retained objects age out. The value
domain shrinks to `database` and `azure` for both binary and execution data.
n8n's explicit `default` binary mode is not a database alias: it stores inline
base64 data in process memory and bypasses queue mode's automatic `database`
fallback, so the module rejects it alongside `filesystem`. `n8n_storage_path`
is deleted, and `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` renders a constant
`"true"` (previously relaxed only for the Azure Files mount).

## Decision 4: `modules/tls-letsencrypt/` stays, its DNS-01 docs move home

The Let's Encrypt helper keeps its own mocked test suite and remains published.
The Cloudflare/GoDaddy provider wiring its two deleted examples demonstrated
(ACME provider blocks, API-token variables, DNS-challenge configuration)
condenses into a "DNS-01 providers" section of `modules/tls-letsencrypt/README.md`
with copyable provider-block snippets. No runnable example exercises DNS-01 end
to end after this change; that is an accepted 0.1.0 trade-off, recorded in that
README.

## Decision 5: Version reset mechanics

`CHANGELOG.md` becomes a single `0.1.0` entry describing the shipped surface
(one resource-bearing root, managed/external PostgreSQL and Redis, Azure Blob
storage, App Gateway ingress, DNS/TLS integration, four examples, two TLS
helpers). The v2/v3/v4 entries and `docs/v4-migration-runbook.md` are deleted —
they describe unpublished internal iterations. `AGENTS.md` keeps its historical
retirements section (it documents why patterns look the way they do) but drops
any instruction that treats v3.x deployments as existing, and the README loses
its "Migrating to v4.x" section. Git history remains the archaeological record.
