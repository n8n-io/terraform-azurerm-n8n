# Tasks: slim-first-release-surface

## 1. Remove the DNS-provider examples

- [x] 1.1 Delete `examples/cloudflare/` and `examples/godaddy/` entirely (including lock files, tests, and generated READMEs).
- [x] 1.2 Remove both examples from every matrix in `.github/workflows/terraform-tests.yml` (docs, validate, test, tflint jobs) and from the `DIRS` array and comment in `init.sh`.
- [x] 1.3 Add a "DNS-01 providers" section to `modules/tls-letsencrypt/README.md` with copyable Cloudflare and GoDaddy `provider "acme"` / DNS-challenge snippets distilled from the deleted examples, and note that no runnable example exercises DNS-01 end to end.
- [x] 1.4 Update `examples/README.md`, the root `README.md` (examples table, "Ingress, DNS, and TLS" section, operator-doc links), and `AGENTS.md` (file layout, sizing-examples section, local development loop, lock-file loop) to list only `small`, `medium`, `large`, and `split-ingress`.
- [x] 1.5 Verify: `grep -ri "cloudflare\|godaddy"` across the repo (excluding `openspec/changes/archive/` and git history) returns only the `modules/tls-letsencrypt/README.md` guidance; `./init.sh` passes.

## 2. Remove Azure Files infrastructure from the root

- [x] 2.1 In `storage.tf`, delete `azurerm_storage_share.n8n`, `azurerm_private_dns_zone.file`, `azurerm_private_dns_zone_virtual_network_link.file`, `azurerm_private_endpoint.file`, `kubernetes_secret.n8n_files_credentials`, `kubernetes_persistent_volume_v1.n8n_files`, and `kubernetes_persistent_volume_claim_v1.n8n_files`; rewrite the file header for Blob-only duty.
- [x] 2.2 Set `shared_access_key_enabled = var.azure_blob_connection_string != null || var.azure_blob_account_key != null` on `azurerm_storage_account.n8n` (design decision 2).
- [x] 2.3 Delete `cleanup.tf` (the `time_sleep.wait_for_aks_drain` gate) and remove it from `helm_release.n8n`'s `depends_on`; remove `var.aks_destroy_drain_seconds` (design decision 1).
- [x] 2.4 Remove `var.create_azure_files`, `var.storage_share_quota_gb`, and `var.azure_files_mount_path` from `variables.tf`, and the `storage_account_primary_access_key`, `storage_share_name`, and `storage_persistent_volume_claim_name` outputs from `outputs.tf`.
- [x] 2.5 Remove `local.azure_files_helm_values` from `locals.tf` and simplify `helm_release.n8n`'s `extraVolumes` / `extraVolumeMounts` to `local.n8n_extra_volumes` / `local.n8n_extra_volume_mounts`; update the `versions.tf` provider-rationale comment (the `time` provider no longer has a destroy-time gate).
- [x] 2.6 Update `tests/defaults.tftest.hcl`: delete the Azure Files run and every share/PV/PVC/drain-gate assertion (including `rejects_destroy_drain_duration_above_ceiling`, `rejects_noncanonical_azure_files_mount_path`, `rejects_azure_files_mount_collision_with_chart_data`, `rejects_storage_share_quota_outside_range`), and add an assertion that the storage account plans with shared key access disabled by default.

## 3. Remove the filesystem storage modes

- [x] 3.1 Restrict `var.n8n_binary_data_storage_mode` and `var.n8n_available_binary_data_modes` to `database` and `azure`, and `var.n8n_execution_data_storage_mode` to `database` and `azure`, with validation messages stating 0.1.0 supports neither n8n's inline-memory `default` binary mode nor `filesystem` (design decision 3).
- [x] 3.2 Remove `var.n8n_storage_path`, `local.n8n_filesystem_storage_enabled`, and the conditional `N8N_STORAGE_PATH` env block in `n8n.tf`; render `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` as a constant `"true"`; drop `N8N_STORAGE_PATH` from `local.n8n_managed_env_names` only if the chart no longer owns it (verify before removing).
- [x] 3.3 Update `tests/defaults.tftest.hcl`: replace filesystem-mode runs with `expect_failures` cases for `filesystem` in each of the three mode inputs, and assert `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` renders `true`.

## 4. Update examples and live scripts

- [x] 4.1 Remove the Azure Files toggle and the ZRS/GZRS replication switch from `examples/large/` (variables, main, tfvars example, outputs if any) and its `tests/defaults.tftest.hcl` run `large_optional_azure_files_plan`; pin the large tier's replication type explicitly.
- [x] 4.2 Update `examples/small/`, `examples/medium/`, and `examples/split-ingress/` for removed inputs/outputs (drop `storage_persistent_volume_claim_name`-style passthroughs and any `create_azure_files` mention in tfvars examples or comments).
- [x] 4.3 Update `examples/README.md`'s comparison table (storage durability column no longer offers GZRS-via-Files) and regenerate every example's terraform-docs block.
- [x] 4.4 Update `tests/scripts/smoke-test.sh`, `tests/scripts/.env.example`, and `tests/scripts/README.md`: remove the Azure Files share and PVC checks and the historical-filesystem read path; Blob assertions remain.

## 5. Reset release framing and documentation

- [x] 5.1 Collapse `CHANGELOG.md` to a single `0.1.0` entry describing the shipped surface; delete `docs/v4-migration-runbook.md` (design decision 5).
- [x] 5.2 Update `README.md`: remove the "Migrating to v4.x" section, Azure Files from the architecture diagram, feature bullets, prerequisites, managed-topologies table, and operator-doc list; state the Blob-only storage contract.
- [x] 5.3 Update `AGENTS.md`: retire Azure-specific delta #2 (drain gate) leaving two deltas, update the storage/workload-integration paragraph, file layout (`cleanup.tf` gone, runbook gone), and remove v3.x-migration language while keeping the historical-retirements record.
- [x] 5.4 Update `docs/data-storage.md` (Blob-only modes, no filesystem migration path), `docs/destroy-cleanup.md` (no drain gate; new destroy ordering), `docs/troubleshooting.md`, and `docs/post-deployment.md` for the removed surface.
- [x] 5.5 Regenerate terraform-docs for the root and all four remaining examples; confirm `--output-check` passes everywhere.

## 6. Full offline verification sweep

- [x] 6.1 Run `./init.sh` (fmt, init, validate, mocked tests across root, both TLS submodules, and the four remaining examples) and `tflint` on every target; all green.
- [x] 6.2 Run `checkov -d . --framework terraform --soft-fail` and confirm no new findings versus the pre-change baseline (the shared-key-disabled default may remove findings; none may be added).
- [x] 6.3 Sweep for stragglers: `grep -ri "azure_files\|create_azure_files\|storage_share\|wait_for_aks_drain\|aks_destroy_drain\|n8n_storage_path\|v4-migration\|Migrating to v4"` (excluding `openspec/changes/archive/`) returns nothing; `grep -ri "filesystem"` returns only intentional validation messages and historical notes.
- [x] 6.4 Confirm the combined `terraform test` wall clock stays under the 5-minute budget and lock files exist for all remaining targets.

## 7. Live verification (folded from align-azure-with-aws-capabilities 17.3/17.4 — requires an az-login'd operator)

- [ ] 7.1 Apply `examples/small` against a real subscription and run `tests/scripts/smoke-test.sh`, including n8n-level Azure Blob binary and execution-data operations, pod restarts across all three families, private Blob access, and managed Redis connectivity, per the updated `module-verification` spec.
- [ ] 7.2 Qualify the single-apply lifecycle on the slimmed surface: cold create, no-op apply, Helm-only update, AKS credential rotation, partial-apply recovery, AKS replacement, normal destroy (verifying the drain-gate removal causes no teardown race — design decision 1), and unavailable-API recovery, with documented outcomes and recovery steps.
- [ ] 7.3 Record the results in `docs/troubleshooting.md` / `docs/destroy-cleanup.md` as applicable and check this section off only after both runs pass.

## 8. Registry review remediation

- [x] 8.1 Correct the binary-data contract from `default`/`azure` to `database`/`azure`, add negative coverage for n8n's inline-memory `default` mode, and synchronize the OpenSpec artifacts and storage documentation.
- [x] 8.2 Reset TLS helper source examples to `v0.1.0`, remove links and comments for deleted complete examples, and frame the former v3/v4 architecture solely as internal pre-release history.
- [x] 8.3 Remove stale Azure Files descriptions from the retained examples, regenerate terraform-docs, and rerun the full offline verification sweep.
- [x] 8.4 Configure every complete example for AzureRM Entra storage data-plane authentication, grant the applying identity Blob data-plane RBAC before module creation, and document the equivalent caller prerequisite discovered by live cold-create verification.
- [x] 8.5 Move the small tier to a subscription-available `Standard_D2s_v7` AKS SKU and extend the advisory capacity model to the Dsv7 family after East US rejected D4s_v4 and the live subscription's 10-vCPU regional quota could not fit two minimum-size D4s pools.
- [x] 8.6 Allow the small example to retain resource groups and global DNS zones when regional resources move after a partial apply, avoiding AzureRM's resource-group contains-resources deletion guard.
- [x] 8.7 Advance the default AKS release to the current standard-support 1.35 line after live Azure rejected 1.33 as LTS-only. Keep the small tier on its cost-appropriate Balanced B1 Redis SKU; live probes confirmed insufficient capacity for Balanced B1/B3 and Compute Optimized X3 across East US, East US 2, and West Europe, so changing the canonical tier cannot resolve a transient regional allocation constraint.
- [x] 8.8 Configure a temporary AKS default-pool rotation name so VM-size and other rotation-required updates do not fail in AzureRM after initial creation.
