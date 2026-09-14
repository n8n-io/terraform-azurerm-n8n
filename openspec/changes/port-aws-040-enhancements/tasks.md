Implementation starts only after explicit approval, on a non-main branch. Each numbered section is one focused iteration. Read `AGENTS.md`, this change's design, and the relevant delta spec before editing. Keep changes within this port; do not retune Azure examples, bump versions, or reimplement credential overwrites.

Use plan-time mocked tests by default. Fully mocked apply is allowed only when needed to materialize actual Helm values for rendering. No task below requires live Azure resources. Refresh the root generated reference when adding inputs; never hand-edit generated blocks.

## 1. Establish chart-rendering regression coverage

- [x] 1.1 Add `tests/scripts/check-n8n-chart.sh` and a non-secret mocked value fixture/export path that renders the actual module values with chart `1.10.0`; verify the script succeeds without Azure/Kubernetes credentials and with Helm schema validation enabled, and fails if supplied fixture values violate the chart schema.
- [x] 1.2 Add baseline manifest assertions for deployment families, main HPA/PDB, worker KEDA, runtime save-policy values, and current URL naming; verify the existing default configuration passes and deliberate duplicate managed environment entries are detected. Do not duplicate module mapping logic in hand-written fixture values.
- [x] 1.3 Document the script's local command and prerequisites alongside the test fixture; verify `bash -n` and one local rendering run, with temporary rendered files cleaned and no real credentials or state tracked.

## 2. Add single-main topology and maintenance safeguards

- [x] 2.1 Allow main minimum 1 and add consumed topology/effective-ceiling selectors in `locals.tf`; wire `multiMain.enabled`, the active replica-count path, HPA maximum, main-only `Recreate` with rolling-update clearing, and PDB minimum in `n8n.tf`. Verify focused mocked tests cover default multi-main, minimum 1 with maximum 20, restored multi-main values, and invalid counts/ranges.
- [x] 2.2 Use the effective main ceiling in the capacity calculation and warning text in `scaling.tf`; verify tests show that increasing the unused maximum in single-main does not increase demand and that existing managed/external-AKS diagnostics remain intact.
- [x] 2.3 Extend the chart check for both topology branches; verify single-main passes chart schema with one main, HPA 1/1, `Recreate` without `rollingUpdate`, main PDB minimum 0, and unchanged worker/webhook strategies, while multi-main retains chart rollout behavior and PDB minimum 1.
- [x] 2.4 Update root replica/license input descriptions and generated reference without changing credential sources or floating-license defaults; verify `terraform-docs --output-check .` and assertions that both topology branches retain `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false` by default.

## 3. Expose PostgreSQL connection and ping timing

- [x] 3.1 Add the four nullable `postgres_*` runtime inputs and validations from design decision 3; render their matching `DB_*` values through shared application environment configuration. Verify mocked tests cover managed/external PostgreSQL, all-null omission, explicit zero acquisition timeout, and all four overrides together.
- [x] 3.2 Add expected-failure coverage for timing boundaries, fractional acquisition/recovery values, and reserved `DB_*` escape-hatch entries; verify the focused Terraform tests and chart assertions for all three application pod families pass without introducing an ignored-managed-database-tuning warning on the external path.
- [x] 3.3 Replace the `postgres_pool_size` rule of thumb with shared-pool, acquisition-deadline, and aggregate-budget guidance; verify generated docs pass and the diff preserves every existing pool-size value and contains no `apply_immediately` input or service-maintenance substitute.

## 4. Expose Bull worker timing safely

- [x] 4.1 Add the three nullable `n8n_queue_worker_*` inputs, whole-number/minimum validation, and the effective renewal-before-duration check on one variable; assemble one inner worker map and merge it into `redis`. Verify mocked tests retain all three simultaneous overrides and omit unset keys.
- [x] 4.2 Add boundary tests for short locks with implicit renewal, equal/longer renewal, fractional values, sub-1000 values, and stalled interval zero; verify expected failures identify the dedicated variables rather than failing at Helm apply.
- [x] 4.3 Extend rendered ConfigMap/environment checks and generated input docs; verify numeric chart values, one effective entry per worker-timing name, unchanged queue/auth/TLS settings, and no unsupported maximum-stalled-count input.

## 5. Expose execution-save policy controls

- [x] 5.1 Replace the four `executions.data` literals with non-nullable inputs and the specified existing defaults; verify mocked tests cover defaults, explicit null fallback, independent success/error policies, and both boolean changes without altering storage or pruning.
- [x] 5.2 Add expected failures for invalid string policies and all four raw `EXECUTIONS_DATA_SAVE_*` names; verify Azure's existing broad `EXECUTIONS_` guard remains unchanged and the chart renders each policy once on main and worker.
- [x] 5.3 Update save-policy documentation and generated reference; verify it names `executions.data`, explains workflow-level overrides, and does not promise a new webhook-only save-policy path or a breaking collision-guard change already present in Azure.

## 6. Add the optional application heap ceiling

- [x] 6.1 Add `n8n_node_max_old_space_size_mb`, its integer/minimum validation, shared application environment entry, and conditional `NODE_OPTIONS` reservation; verify tests cover default omission, a valid ceiling, invalid values, active-input collision, and unrelated caller Node flags when null.
- [x] 6.2 Extend chart assertions and generated docs; verify all three application containers receive exactly one requested heap flag, task-runner configuration and memory limits stay unchanged, and documentation calls for non-heap headroom against the smallest application limit without importing AWS V8 measurements.

## 7. Add caller-managed runner launcher configuration

- [x] 7.1 Add the typed ConfigMap reference, name/key validation, enabled-runner requirement, and `taskRunners.customConfig` mapping; verify tests cover null, default/custom keys, invalid references, disabled runners, and the existing reserved `task-runner-config` volume name.
- [x] 7.2 Extend chart assertions for main/worker sidecar mounts and absence on webhooks; verify exact file path and `subPath`, no new ConfigMap read/create resource, and unchanged existing extra-volume and credential-overwrite tests.
- [x] 7.3 Document deriving the complete file from the matching runner image and manually rolling main/worker after changes; verify the instructions explain allow-lists, caller ordering, and `subPath` non-refresh behavior, and generated docs pass.

## 8. Add optional pod DNS configuration

- [x] 8.1 Add the typed DNS input and null-stripping conversion for chart `dnsConfig`; verify mocked tests cover null, empty/all-null objects, nameserver/search lists, options-only configuration, and an option without a value.
- [x] 8.2 Implement IP, count, joined search-length, Kubernetes search-name, option-name, and `ndots` validations against the documented supported contract; verify valid IPv4/IPv6 cases and expected failures for every invalid class in the workload spec, including malformed numeric `ndots` values without expression-evaluation errors.
- [x] 8.3 Extend chart checks and generated docs; verify identical effective DNS settings on all three pod families, no null YAML fields, no DNS-policy/CoreDNS changes, and guidance for AKS private DNS and older caller-managed clusters without changing example defaults.

## 9. Add the optional Redis exporter

- [x] 9.1 Add exporter switch/image inputs, a shared waiting/active queue-key local consumed by KEDA, and opt-in Deployment/Service resources in `observability.tf`; verify mocked tests cover disabled and explicit-null switches, invalid image references, independent n8n metrics enablement, one replica, `Recreate`, internal port 9121, annotations, probes, resource requests/limit, and all specified security settings.
- [x] 9.2 Wire the effective Redis connection and password reference without reading caller Secrets; verify managed TLS, external TLS with ACL and custom Secret key, external literal-password, and unauthenticated plaintext cases, including exact equality between exporter queue keys and KEDA list names and absence of credentials in `REDIS_ADDR`.
- [x] 9.3 Add namespace, warm-up, managed Secret, and private endpoint/DNS dependency edges as applicable; verify mocked caller-managed cluster/namespace paths create no duplicate infrastructure, and inspect `terraform graph` for required first-apply edges and the absence of an n8n-to-exporter dependency.
- [x] 9.4 Include optional exporter CPU demand in `scaling.tf` and document TLS/CA/ACL, private-image access, and caller-owned scraping in `docs/observability.md`; verify the capacity delta equals the request, external-AKS suppression remains intact, generated docs pass, and Checkov review plus direct security assertions show no new unreviewed hardening gap.

## 10. Adapt node disk sizing to AKS

- [x] 10.1 Add nullable `aks_node_os_disk_size_gb` with positive-whole-number validation and wire both managed pools, preserving the system rotation name and adding a distinct valid user-pool rotation name; verify mocked tests for null, 256, invalid values, unchanged disk type, and existing node-count lifecycle ignores.
- [x] 10.2 Extend ignored-AKS-tuning diagnostics for a supplied size with `create_aks = false`; verify the external-cluster test expects the warning and zero managed cluster/pool resources while the default external path stays warning-free.
- [x] 10.3 Document provider-driven cycling, lack of automatic cordon/drain, maintenance/headroom requirements, and provider/Azure default sizing; verify generated docs pass and the diff adds no AWS disk default, disk-type control, drain provisioner, or example sizing change.

## 11. Correct editor and split-webhook URLs

- [x] 11.1 Add validated nullable `n8n_webhook_url` and render the effective current webhook URL plus canonical editor URL through the existing shared path; verify mocked tests for null, split hosts, a valid port/base path, every invalid URL class, and reserved-name collisions.
- [x] 11.2 Extend the chart check to assert one current webhook and editor URL on each application container, no deprecated alias, and no chart URL duplicate; verify internal `N8N_HOST`/protocol/port and ingress resource counts remain unchanged on both ownership paths.
- [x] 11.3 Pass the public webhook URL in `examples/split-ingress/main.tf`, update callback documentation and generated references, and add the example assertion; verify its full mocked suite retains all five production webhook routes and no public catch-all, and documents test-webhook/form behavior as a manual compatibility check rather than silently changing routing.

## 12. Expose example topology selection without retuning

- [x] 12.1 Add the main-minimum passthrough, validation, and sample-variable documentation to all eight existing example roots; verify each example's default floor remains 2 except medium 3 and large 6, with no other sizing changes.
- [x] 12.2 Extend each example's mocked suite for minimum 1 and effective maximum 1 while retaining existing default/ownership assertions; verify all eight suites pass and large keeps two PgBouncer replicas, pool size 5, and its current storage/HA configuration.
- [x] 12.3 Regenerate only the examples' generated reference blocks and update `examples/README.md` to distinguish topology selection from feature entitlements; verify all eight `terraform-docs --output-check` runs pass and the comparison table retains the original sizing values.

## 13. Update operational guidance and offline smoke coverage

- [x] 13.1 Make `tests/scripts/smoke-test.sh` detect configured topology and branch its main replica, HPA, strategy, PDB, and leader checks; preserve applicable service/storage/route/license checks. Verify shell syntax and offline command fixtures for intentional single-main, healthy multi-main, and degraded multi-main with one ready pod, without invoking Azure.
- [x] 13.2 Update root README and relevant `docs/post-deployment.md`, `docs/troubleshooting.md`, `docs/data-storage.md`, and customer-managed guidance for Business single-main, the database-only new-deployment recipe, separate Blob entitlements, downtime, Helm recovery, and retained-data cautions; verify a documentation review finds no claim that changing only the main floor grants all example features.
- [x] 13.3 Add a manual Azure qualification checklist with expected outcomes and result fields for every case in the verification spec, linking existing lifecycle guidance rather than replacing it; verify the checklist explicitly marks live execution as outside implementation completion and leaves no live-deployment checkbox in this task list.
- [x] 13.4 Update `CHANGELOG.md` Unreleased and relevant `AGENTS.md` contracts to describe actual Azure ports, existing parity, and excluded AWS changes; verify no fictitious Azure release or live measurement is introduced, no legacy Redis TLS input name is copied, and guidance emphasizes measurement without changing tuning defaults.

## 14. Integrate and run the complete offline acceptance matrix

- [x] 14.1 Wire chart rendering and offline smoke-fixture checks into `.github/workflows/terraform-tests.yml` and `openspec/init.sh` with documented, reproducible tool prerequisites; verify both entry points include the new commands without removing any existing root/submodule/example target or adding live smoke invocation.
- [x] 14.2 Run formatting, initialization/validation, all mocked Terraform tests, chart rendering, and shell checks across the root, three submodules, and eight examples; verify every applicable check passes without cloud credentials and record combined Terraform test duration against the five-minute budget.
- [x] 14.3 Run TFLint across the existing matrix, review Checkov findings without widening suppressions/soft-fail policy, and run every existing generated-docs check; verify exporter hardening through direct tests and that unchanged provider versions/lock files require no refresh. Clean recreated `.terraform/` directories before a commit.
- [x] 14.4 Review the final diff against the applicability matrix and run `openspec validate port-aws-040-enhancements --strict`; verify all scenario groups have coverage, existing credential-overwrite tests remain intact, no unrelated defaults or files changed, and the completion record separates offline evidence from unexecuted Azure qualification.
