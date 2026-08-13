## Purpose

Define repeatable plan-time, static, documentation, and live checks that verify the expanded Azure module without applying cloud resources in continuous integration.

## ADDED Requirements

### Requirement: Root mocked test coverage
The root module SHALL have plan-time Terraform tests with mocked providers covering default resources, optional topologies, output contracts, input failures, and non-failing diagnostics.

#### Scenario: Test without Azure credentials
- **WHEN** `terraform test` runs at the module root in CI
- **THEN** all root tests SHALL execute without contacting Azure or Kubernetes

### Requirement: Feature-specific assertions
Every added resource or structural input SHALL have an objective assertion in the root or relevant example test, and invalid combinations SHALL use expected failures where Terraform can represent them.

#### Scenario: Disable managed Redis
- **WHEN** the external Redis test plans with managed Redis disabled
- **THEN** it SHALL assert zero Azure Managed Redis resources and the expected external endpoint contract

### Requirement: Static and generated checks
CI SHALL run formatting, validation, Terraform tests, TFLint with the AzureRM ruleset, Checkov, and terraform-docs output checks against the root and every runnable example.

#### Scenario: Detect stale generated documentation
- **WHEN** an input or output changes without refreshing a generated README block
- **THEN** the terraform-docs CI job SHALL fail

### Requirement: Provider lock coverage
The root and every example SHALL commit provider lock files containing checksums for Linux AMD64, Linux ARM64, and Darwin ARM64.

#### Scenario: Initialize on a supported platform
- **WHEN** CI initializes any tested root on Linux AMD64
- **THEN** Terraform SHALL resolve providers from the committed lock data without checksum errors

### Requirement: Live deployment smoke test
The smoke test SHALL verify AKS access, namespace and controller readiness, minimum ready replicas, PostgreSQL and Redis connectivity, Azure Blob and optional Azure Files access, Application Gateway reachability, HTTPS health, complete webhook route ownership, and n8n license validity.

#### Scenario: Verify an applied small deployment
- **WHEN** the smoke test runs after applying `examples/small`
- **THEN** it SHALL exit zero only if every infrastructure, workload, route, storage, and license assertion passes

### Requirement: Azure storage acceptance
Live verification SHALL test Azure Blob startup access and binary and execution-data operations through n8n, not only direct Azure API access.

#### Scenario: Verify Azure Blob across pod families
- **WHEN** the smoke test restarts main, worker, and webhook pods with Azure storage enabled
- **THEN** n8n SHALL write, read, download, and delete binary data and SHALL write, read, and prune execution data through the private container

#### Scenario: Preserve historical reads
- **WHEN** the default binary mode changes from filesystem to Azure
- **THEN** the smoke test SHALL read one historical filesystem object and one new Azure object before the old backend can be retired

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
