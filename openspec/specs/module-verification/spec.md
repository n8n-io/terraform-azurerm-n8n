## Purpose

Define repeatable plan-time, static, documentation, and live checks that verify the expanded Azure module without applying cloud resources in continuous integration.

## Requirements

### Requirement: Root mocked test coverage
The root module SHALL have plan-time Terraform tests with mocked providers covering default resources, every customer-managed ownership path, combined ownership paths, output contracts, input failures, and non-failing diagnostics.

#### Scenario: Test without Azure credentials
- **WHEN** `terraform test` runs at the module root in CI
- **THEN** all managed and customer-managed root tests SHALL execute without contacting Azure or Kubernetes

#### Scenario: Prevent duplicate ownership
- **WHEN** a customer-managed path is planned with valid references
- **THEN** tests SHALL assert zero resources for the disabled layer and the expected effective references in downstream workload configuration

### Requirement: Feature-specific assertions
Every added resource, submodule boundary, ownership input, credential source, or structural output SHALL have an objective assertion in the root, controllers, or relevant example test, and invalid combinations SHALL use expected failures where Terraform can represent them.

#### Scenario: Disable managed Redis
- **WHEN** the external Redis test plans with managed Redis disabled
- **THEN** it SHALL assert zero Azure Managed Redis resources and the expected external endpoint and Secret-reference contract

#### Scenario: Call controllers directly
- **WHEN** the controllers submodule test enables or disables KEDA
- **THEN** it SHALL assert the expected namespace and Helm release count, chart repository, version, and exported ordering metadata

### Requirement: Static and generated checks
CI SHALL run formatting, validation, Terraform tests, TFLint with the AzureRM ruleset, Checkov, and terraform-docs output checks against the root, both TLS helpers, the controllers submodule, and every runnable example.

#### Scenario: Detect stale generated documentation
- **WHEN** an input or output changes without refreshing a generated README block
- **THEN** the terraform-docs CI job SHALL fail for the affected root, submodule, or example

### Requirement: Provider lock coverage
The root, every directly callable submodule, and every example SHALL commit provider lock files containing checksums for Linux AMD64, Linux ARM64, and Darwin ARM64.

#### Scenario: Initialize on a supported platform
- **WHEN** CI initializes any tested root on Linux AMD64
- **THEN** Terraform SHALL resolve providers from the committed lock data without checksum errors

### Requirement: First-release versioning baseline
The repository SHALL present itself as an unreleased module whose first published version is `0.1.0`: `CHANGELOG.md` SHALL contain a single `0.1.0` entry describing the released surface, no migration runbook or v2/v3/v4 upgrade language SHALL remain in the documentation, and internal pre-release history SHALL not be presented as published versions.

#### Scenario: Read the release history
- **WHEN** an operator reads `CHANGELOG.md` and the README
- **THEN** they SHALL find exactly one released version (`0.1.0`) and no reference to migrating from earlier module versions

### Requirement: Live deployment smoke test

The smoke test SHALL verify AKS access, namespace and controller readiness, minimum ready replicas, PostgreSQL and Redis connectivity, Azure Blob access when configured, Application Gateway reachability on the managed-ingress path, HTTPS health, complete webhook route ownership, and n8n license validity. It SHALL determine main topology from the deployed configuration rather than the observed pod count. Single-main SHALL be checked against one ready main, HPA 1/1, `Recreate`, and PDB `minAvailable = 0` without requiring multi-main leader election. Multi-main SHALL retain configured replica-floor and leader-election checks. The script SHALL remain an explicitly invoked post-apply check outside CI.

#### Scenario: Verify an applied small deployment
- **WHEN** the smoke test runs after applying `examples/small`
- **THEN** it SHALL exit zero only if every applicable infrastructure, workload, route, storage, and license assertion passes

#### Scenario: Verify an intentional single-main deployment
- **GIVEN** the deployed configuration disables multi-main and the selected license covers the enabled features
- **WHEN** the smoke test runs against a healthy single-main deployment
- **THEN** it SHALL accept one ready main and validate the single-main HPA, strategy, and PDB
- **AND** it SHALL NOT fail or warn merely because there is no second main or multi-main leader-election configuration

#### Scenario: Reject an accidentally degraded multi-main deployment
- **GIVEN** the deployed configuration enables multi-main with a floor greater than 1
- **WHEN** only one main is ready
- **THEN** the smoke test SHALL fail the replica-floor check rather than reclassify the deployment as intentional single-main

### Requirement: Azure storage acceptance
Live verification SHALL test Azure Blob startup access and binary and execution-data operations through n8n, not only direct Azure API access.

#### Scenario: Verify Azure Blob across pod families
- **WHEN** the smoke test restarts main, worker, and webhook pods with Azure storage enabled
- **THEN** n8n SHALL write, read, download, and delete binary data and SHALL write, read, and prune execution data through the private container

#### Scenario: Preserve historical reads
- **WHEN** the default binary mode changes from `database` to `azure`
- **THEN** the smoke test SHALL read one historical database-backed object and one new Azure Blob object before the old mode can be dropped from the available-modes list

### Requirement: Single-apply lifecycle acceptance
Live verification SHALL cover the combined Azure and Kubernetes provider lifecycle before the one-apply contract is released.

#### Scenario: Exercise the provider boundary
- **WHEN** release qualification runs
- **THEN** cold create, no-op apply, Helm-only update, credential rotation, partial-apply recovery, AKS replacement, normal destroy, and unavailable-API recovery SHALL have documented outcomes and recovery steps

### Requirement: Custom-image verification
A separate post-apply script SHALL verify that custom extensions are loaded on both main and worker pods when custom-image inputs are used.

#### Scenario: Detect an unloaded baked node
- **WHEN** a custom image is running but its baked node is absent from a main or worker type list
- **THEN** the custom-image verification script SHALL fail and identify the missing pod family

### Requirement: Offline modularity acceptance
The modularity implementation SHALL be considered complete for this change only when all mocked tests and static checks pass without Azure credentials. Live Azure apply, lifecycle, and smoke-test qualification SHALL remain outside this change.

#### Scenario: Complete the Ralph loop
- **WHEN** every task in this change is checked complete
- **THEN** the repository SHALL pass its full offline verification matrix and SHALL contain no unchecked live-deployment task in this change

### Requirement: Pinned chart rendering acceptance

Offline verification SHALL render the module's selected pinned n8n chart with module-derived non-secret test values, using Helm schema validation. Both CI and the local verification entry point SHALL run the rendering checks without Azure or Kubernetes credentials. Checks SHALL cover default multi-main, single-main with a higher supplied maximum, restored multi-main values, combined runtime tuning, and omitted optional settings. Fixtures SHALL exercise the actual module-to-chart mapping rather than an independently maintained approximation.

#### Scenario: Verify topology manifests
- **WHEN** the rendering checks inspect both topology branches
- **THEN** they SHALL assert the main replica floor, HPA bounds, strategy and PDB selector/minimum
- **AND** they SHALL assert unchanged worker/webhook strategies and scaling ownership
- **AND** single-main SHALL pass the pinned chart schema without a rolling-update field on its `Recreate` Deployment

#### Scenario: Verify runtime manifests
- **WHEN** combined PostgreSQL, Bull, execution-save, heap, runner, DNS, and URL settings are rendered
- **THEN** the checks SHALL resolve the affected literal and ConfigMap-backed environment values and assert the intended pod-family coverage
- **AND** they SHALL reject duplicate managed environment names, entries with both `value` and `valueFrom`, incorrect Bull numeric types, null DNS fields, and incorrect launcher mounts

#### Scenario: Preserve omitted settings
- **WHEN** all nullable runtime additions are unset
- **THEN** the checks SHALL confirm no optional heap, database-timing, runner custom-config, or DNS override is introduced and existing execution-save defaults remain unchanged

### Requirement: Offline AWS 0.4.0 port acceptance

Implementation of this change SHALL be considered complete only after its mocked tests, chart-rendering checks, formatting, validation, TFLint, Checkov review, and generated-documentation checks pass without live cloud credentials. Existing root, submodule, and example verification coverage SHALL remain intact, and combined Terraform test suites SHALL stay within the repository's five-minute budget. Security settings on the new exporter SHALL have direct test assertions even if the scanner does not inspect its resource type.

Documentation SHALL provide a separate manual Azure qualification checklist with expected outcomes. Running that checklist SHALL NOT be an implementation-completion task. Offline success SHALL NOT be presented as evidence of live Azure lifecycle, performance, licensing, or Redis TLS/ACL compatibility.

#### Scenario: Complete implementation without deploying Azure resources
- **WHEN** all implementation tasks are marked complete
- **THEN** the full offline verification matrix and chart-rendering checks SHALL pass
- **AND** the repository SHALL contain a manual Azure checklist rather than an unchecked task requiring a live deployment

#### Scenario: Preserve previously ported behavior
- **WHEN** the regression suite runs
- **THEN** existing credential-overwrite tests, broad managed-environment guards, customer-managed Secret/namespace/cluster paths, and example sizing assertions SHALL remain covered
- **AND** the new tests SHALL assert that PostgreSQL runtime controls and the exporter use effective connections on both ownership branches

#### Scenario: Separate validation evidence
- **WHEN** the change's validation results are recorded
- **THEN** the record SHALL distinguish mocked plans, mocked value materialization if needed, chart rendering, static checks, and unexecuted live checks
- **AND** it SHALL NOT reuse AWS measured outcomes as Azure test results

#### Scenario: Document manual Azure qualification
- **WHEN** an operator reads the checklist
- **THEN** it SHALL cover fresh install, no-op apply, Helm update/rollback, both main-topology transitions, node maintenance, disk rotation, Secret/ConfigMap rotation, split-host OAuth and webhook behavior, private DNS resolution, Redis metrics/TLS/ACL access, and unavailable-API recovery
- **AND** each check SHALL name an expected outcome and a place to record environment, versions, and results
