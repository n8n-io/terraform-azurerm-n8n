## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Offline modularity acceptance
The modularity implementation SHALL be considered complete for this change only when all mocked tests and static checks pass without Azure credentials. Live Azure apply, lifecycle, and smoke-test qualification SHALL remain outside this change.

#### Scenario: Complete the Ralph loop
- **WHEN** every task in this change is checked complete
- **THEN** the repository SHALL pass its full offline verification matrix and SHALL contain no unchecked live-deployment task in this change
