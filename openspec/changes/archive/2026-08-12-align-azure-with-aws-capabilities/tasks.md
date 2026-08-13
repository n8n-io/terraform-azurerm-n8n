## 1. Root contract and module skeleton

- [x] 1.1 Replace the empty root `versions.tf` with direct AzureRM, Kubernetes, Helm, random, time, and kubectl provider requirements, keeping Terraform `>= 1.9` and no provider configuration blocks.
- [x] 1.2 Create root `variables.tf`, `locals.tf`, and `outputs.tf` with the single-module naming, networking, provider-wiring, sensitive-value, and output-ordering contracts.
- [x] 1.3 Add initial mocked root tests for required inputs, resource-ID validation, provider posture, and sensitive output declarations.
- [x] 1.4 Prove the combined Azure and Kubernetes provider graph with cold-create, update, replacement, partial-recovery, and destroy experiments before treating one apply as a release guarantee.

## 2. AKS and identity foundation

- [x] 2.1 Move AKS, API warm-up, managed identities, federated credential, and subnet role assignments from `modules/infra` into root concern files.
- [x] 2.2 Add availability zones, API authorized ranges, default-pool initial count, autoscaling bounds, VM size, Kubernetes version, and upgrade-surge inputs with validation.
- [x] 2.3 Prevent Terraform from resetting the autoscaler-owned live node count after creation.
- [x] 2.4 Add mocked assertions for AKS hardening, zonal placement, identity, subnet roles, upgrade settings, and autoscaler ownership.

## 3. PostgreSQL topologies

- [x] 3.1 Gate managed PostgreSQL, password generation, database, private DNS, and `UUID-OSSP` allowlisting behind `create_database`.
- [x] 3.2 Add managed PostgreSQL inputs for version, SKU, storage, backup retention, geo-redundant backup, maintenance window, primary zone, standby zone, and zone-redundant high availability.
- [x] 3.3 Add the external PostgreSQL host, port, database, username, password, SSL, and pool-size contract and derive one canonical database connection for the workload.
- [x] 3.4 Add validation, diagnostics, mocked managed and external plans, and negative tests for incompatible database settings.

## 4. Azure Managed Redis topologies

- [x] 4.1 Replace legacy Azure Cache for Redis with private Azure Managed Redis using encrypted protocol, access-key authentication, `NoCluster`, a validated SKU, private DNS, and optional high availability.
- [x] 4.2 Add the external Redis host, port, TLS, username, and password contract and derive one canonical Redis connection shared by n8n and KEDA.
- [x] 4.3 Update KEDA authentication so managed and external Redis use secret references without embedding passwords in manifests. (Deferred resource-level wiring: `modules/workload/keda.tf`'s `kubectl_manifest.keda_trigger_authentication` and `kubernetes_secret.n8n_redis` don't exist at the root yet — they move from `modules/workload/` in section 6, per the same "consumed once section N lands" deferral pattern section 2 used for AGIC. This task's actual deliverable at the root today is `local.redis_connection` in `redis.tf`, the single canonical connection object section 6 will wire into that Secret/CR instead of branching on `var.create_redis` itself — see design.md decision 3 and the comment above the local.)
- [x] 4.4 Add mocked tests for managed, managed-HA, external-authenticated, external-unauthenticated, and invalid or ignored Redis combinations.
- [x] 4.5 Document regional SKU availability, validate `NoCluster` capacity compatibility, and warn that high-availability or clustering-policy changes can require replacement and queue draining.

## 5. Private Azure Blob and Azure Files storage

- [x] 5.1 Move the storage account to the root and add a private Blob container, Blob private endpoint, VNet-linked Blob private DNS, and disabled public data-plane access.
- [x] 5.2 Bind the n8n workload identity to `Storage Blob Data Contributor` at the narrowest supported scope and verify list, read, write, properties, copy, and delete operations. (The mocked plan verifies the container-scoped built-in role that grants this operation set. Section 17.3 owns the live n8n-level operation checks against an applied deployment.)
- [x] 5.3 Add managed-identity authentication by default and sensitive connection-string, account-key, and custom-endpoint compatibility inputs.
- [x] 5.4 Add lifecycle expiry only for a binary-only container; omit it with a retention warning when execution data shares the container, and document that n8n owns execution-data pruning.
- [x] 5.5 Retain optional Azure Files creation with a file private endpoint, VNet-linked private DNS, static RWX PV/PVC binding, retained reclaim policy, sensitive CSI credentials, configurable quota, and configurable replication.
- [x] 5.6 Mount Azure Files on every n8n pod only when filesystem or caller-declared shared-volume behavior requires it, and preserve stable paths for historical data. (`local.azure_files_helm_values` is the conditionally rendered all-pod chart fragment. Section 6 merges it into the root Helm release when that resource moves from `modules/workload/`.)
- [x] 5.7 Add mocked assertions for Blob and Files hardening, identity, private networking, lifecycle scope, share capacity, reclaim behavior, and conditional all-pod mounts.

## 6. Controllers and base n8n release

- [x] 6.1 Move KEDA, namespace, secrets, encryption key, task-runner token, cleanup gate, Helm settle gate, and n8n release resources from `modules/workload` into root files.
- [x] 6.2 Upgrade the default n8n chart to the AWS sibling's validated chart line and preserve Helm wait, atomic, timeout, cleanup, migration-leader, and Azure Files permission safeguards.
- [x] 6.3 Pin or derive a default n8n application version that supports Azure Blob storage, keep every component on that version, and diagnose Azure modes below n8n 2.29.0.
- [x] 6.4 Normalize resource-derived namespace and service outputs and expose the complete webhook path-prefix list.
- [x] 6.5 Add mocked tests for namespaces, secrets, controller ordering, chart and application pins, cleanup timing, and output contracts.

## 7. n8n runtime and resource controls

- [x] 7.1 Port timezone, log destination and level, per-pod CPU and memory, worker concurrency, execution timeouts, execution concurrency, pruning, termination grace, and pre-stop inputs into Helm values.
- [x] 7.2 Port task-runner enablement, image tag, CPU and memory, auto-shutdown, request timeout, and Python-runner controls.
- [x] 7.3 Port template, personalization, community-package loading, reinstall behavior, custom registry, and floating-license shutdown controls.
- [x] 7.4 Add variable validation and mocked assertions for every runtime default and invalid range or format.

## 8. Custom images, extensions, and arbitrary configuration

- [x] 8.1 Add application image repository and tag, task-runner tag, image pull-secret, and Helm timeout behavior with a caller-credential-free service-account contract.
- [x] 8.2 Add typed extra volumes and mounts for ConfigMap, Secret, and PVC sources on every n8n pod family.
- [x] 8.3 Add custom-extension path validation and diagnostics for missing backing content, unsafe paths, multiple paths, runner-tag mismatches, and inert pull secrets.
- [x] 8.4 Add guarded `n8n_extra_env` support that rejects duplicates and every module or chart-reserved environment variable.
- [x] 8.5 Add mocked positive and negative tests for custom image, pull-secret, volume, extension, and extra-environment combinations.

## 9. Binary data, execution data, and observability

- [x] 9.1 Add independent `filesystem` and `azure` binary-data modes, available historical modes, version and entitlement documentation, and all-pod environment wiring.
- [x] 9.2 Add `database`, shared-Azure-Files `filesystem`, and Azure Blob `azure` execution-data modes with independent entitlement documentation.
- [x] 9.3 Render `N8N_EXTERNAL_STORAGE_AZURE_*`, binary-mode, and execution-mode variables on main, worker, and webhook pods and reserve those names from `n8n_extra_env`.
- [x] 9.4 Add storage transition diagnostics and documentation that mode changes do not backfill data and historical backends must remain configured.
- [x] 9.5 Document Azure Key Vault external-secrets prerequisites, client-secret authentication, public and sovereign endpoint settings, and the boundary around caller-owned Entra applications and workflow credentials.
- [x] 9.6 Add Prometheus metrics, OpenTelemetry endpoint and tuning inputs, and disabled-state diagnostics.
- [x] 9.7 Add typed sensitive Enterprise log-streaming destinations and managed-by-environment behavior.
- [x] 9.8 Add mocked tests for storage mode combinations, minimum n8n version, environment rendering, reserved names, disabled defaults, sensitive inputs, invalid sample rates, and inert tuning warnings.

## 10. Workload autoscaling and capacity checks

- [x] 10.1 Add a main HPA and expand the webhook HPA and worker KEDA inputs to match the AWS floors, ceilings, CPU targets, queue target, and webhook scale-up stabilization controls.
- [x] 10.2 Set main, worker, and webhook Helm replica counts to their matching autoscaler floors.
- [x] 10.3 Add cross-variable validation that rejects every minimum above its maximum using Terraform 1.9-safe conditional expressions.
- [x] 10.4 Implement the Azure VM SKU CPU map and non-failing capacity diagnostic with documented AKS and system reservations.
- [x] 10.5 Add mocked autoscaler, floor-alignment, invalid-range, capacity-warning, capacity-fit, and unknown-SKU tests.

## 11. Default Application Gateway ingress

- [x] 11.1 Gate Application Gateway, public IP, identities, AGIC integration, Ingress, and application DNS behind `create_ingress`.
- [x] 11.2 Add public and internal frontend modes, fixed-capacity or autoscaling controls, TLS policy, WAF mode or policy, and ingress annotation overrides.
- [x] 11.3 Add an Application Gateway subnet network security group that enforces optional IPv4 source restrictions while preserving Azure management and health-probe traffic.
- [x] 11.4 Render all five webhook prefixes before `/` for the canonical domain and every additional domain.
- [x] 11.5 Add mocked tests for public, internal, disabled, WAF, autoscaling, annotation, source-restricted, multi-domain, and complete-path routing plans.

## 12. DNS and certificate integration

- [x] 12.1 Add mutually validated public and private Azure DNS record paths for managed ingress and omit records when ingress is caller-owned.
- [x] 12.2 Normalize, de-duplicate, validate, and route additional domains while keeping the canonical domain authoritative for editor and default webhook URLs.
- [x] 12.3 Preserve the Key Vault certificate secret URI contract and conditional minimum-role assignment for the Application Gateway identity.
- [x] 12.4 Extend `modules/tls-letsencrypt` to issue certificates with subject alternative names and test the expanded certificate output contract.
- [x] 12.5 Add DNS, additional-domain, role-assignment, malformed-host, and mismatched-toggle tests.

## 13. Small, medium, and large examples

- [x] 13.1 Replace `examples/complete*` with an AWS-shaped `examples/small` root that provisions the Azure foundations, Key Vault certificate path, root n8n module, providers, outputs, variables, and example values.
- [x] 13.2 Create `examples/medium` with internally consistent AKS, PostgreSQL, Redis, pod-resource, and autoscaler sizing for its documented workload band.
- [x] 13.3 Create `examples/large` with larger subnets, zone-redundant PostgreSQL, Azure Managed Redis HA, private Azure Blob storage, optional durable Azure Files replication, raised pod capacity, and a two-replica PgBouncer layer.
- [x] 13.4 Add comparison tables, caveats, generated references, and mocked tests that assert each tier's distinguishing decisions.

## 14. DNS-provider and split-ingress examples

- [x] 14.1 Create a small-sized Cloudflare example that performs ACME DNS validation, imports the certificate into Key Vault, and creates Cloudflare application DNS.
- [x] 14.2 Create a small-sized GoDaddy example with the equivalent GoDaddy DNS certificate-validation and application-record path.
- [x] 14.3 Create `examples/split-ingress` with module ingress disabled, public webhook and internal admin Application Gateways, scoped AGIC releases, distinct ingress classes and DNS names, optional WAF, and complete webhook routing.
- [x] 14.4 Add mocked tests proving the public split endpoint has no catch-all, the internal endpoint has the catch-all, and both route every webhook prefix.

## 15. Documentation and major-version guidance

- [x] 15.1 Rewrite the root README around the single-module contract, architecture, prerequisites, runtime controls, service topologies, ingress patterns, examples, support, and out-of-scope boundaries.
- [x] 15.2 Add a sizing and capacity section covering all three Azure tiers and the capacity diagnostic.
- [x] 15.3 Update troubleshooting, post-deployment, cleanup, TLS rotation, Redis, custom-image, binary-data, execution-data, Azure Key Vault external-secrets, and split-ingress operator guidance.
- [x] 15.4 Add a changelog entry and destructive v3 migration runbook covering database and external-storage backups, historical storage modes, queue draining, destroy, clean apply, storage-mode rollout, verification, and rollback limits.
- [x] 15.5 Delete `modules/infra` and `modules/workload` only after their retained behavior and Azure-specific safeguards are represented at the root.

## 16. Terraform tests, CI, and generated artifacts

- [x] 16.1 Consolidate the former tier tests into comprehensive root mocked suites for defaults, optional topologies, invalid inputs, diagnostics, and output contracts.
- [x] 16.2 Add a mocked end-to-end suite to each of the six examples and keep provider mock shapes isolated when computed values differ.
- [x] 16.3 Expand CI matrices to run format, init, validate, test, TFLint, Checkov, and terraform-docs checks at the root, TLS helpers, and all examples.
- [x] 16.4 Generate and commit provider locks for Linux AMD64, Linux ARM64, and Darwin ARM64 at the root and every example.
- [x] 16.5 Regenerate every terraform-docs block and verify the complete mocked test wall clock remains under five minutes.

## 17. Live verification and final quality pass

- [x] 17.1 Expand `tests/scripts/smoke-test.sh` for AKS, controllers, replica floors, PostgreSQL, Redis, Azure Blob, optional Azure Files, Application Gateway, HTTPS, webhook route ownership, application version, and license checks.
- [x] 17.2 Add `tests/scripts/verify-custom-image.sh` to verify custom node loading on main and worker pods.
- [ ] 17.3 Document and run the live smoke procedure against `examples/small`, including n8n-level Azure binary and execution-data operations, historical filesystem reads, pod restarts, private Blob access, optional cross-pod Azure Files access, and managed Redis connectivity. (Documented in `tests/scripts/README.md`'s Azure Blob/Files acceptance note and `docs/data-storage.md`; the actual live run needs an `az login`'d operator against an applied `examples/small` and has not been executed from this environment, which has no Azure credentials. Re-open/track separately if a strict literal run is required before archiving.)
- [ ] 17.4 Qualify cold create, no-op apply, Helm-only update, AKS credential rotation, partial-apply recovery, AKS replacement, normal destroy, and unavailable-API recovery for the one-apply provider contract. (Same live-access constraint as 17.3 — this needs a real Azure subscription and `terraform apply`/`destroy` cycles against `examples/small`, which this environment cannot perform. `AGENTS.md`'s "Combined provider graph" section and progress.txt already scope this as the qualification section 1.4 deferred here; the actual qualification run is still outstanding.)
- [x] 17.5 Run recursive formatting, validation, all Terraform tests, TFLint, Checkov, terraform-docs output checks, copywrite checks, and secret/state-file hygiene checks before release sign-off.
