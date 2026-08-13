## ADDED Requirements

### Requirement: Customer-managed infrastructure examples
The repository SHALL include `customer-managed-cluster`, `customer-managed-redis`, `customer-managed-storage`, and `customer-managed-everything` examples that demonstrate each supported ownership boundary individually and in combination.

#### Scenario: Plan customer-managed cluster
- **WHEN** the customer-managed-cluster mocked test runs
- **THEN** it SHALL assert that the example owns an AKS stand-in outside the n8n module, disables module AKS and ingress creation, and routes provider and module references to the existing cluster contract

#### Scenario: Plan customer-managed Redis
- **WHEN** the customer-managed-redis mocked test runs
- **THEN** it SHALL assert that the example owns a Redis stand-in outside the n8n module and supplies the external endpoint and credential contract while the module creates no Redis resources

#### Scenario: Plan customer-managed storage
- **WHEN** the customer-managed-storage mocked test runs
- **THEN** it SHALL assert that the example owns private Blob infrastructure outside the n8n module, the n8n module creates no storage, private endpoint, DNS, or lifecycle resources, and the module grants its workload identity access only to the supplied container

#### Scenario: Plan customer-managed everything
- **WHEN** the customer-managed-everything mocked test runs
- **THEN** it SHALL assert that the example combines existing AKS, external PostgreSQL and Redis, existing Blob, existing namespace and Secrets, direct controller composition, caller-managed ingress, and caller-managed webhook autoscaling without duplicate ownership of the selected layers

## MODIFIED Requirements

### Requirement: Runnable example contract
Every example SHALL include provider constraints, provider wiring, variables, outputs, an example variable file, generated reference documentation, a platform lock file, and a mocked Terraform test.

#### Scenario: Validate all examples in CI
- **WHEN** the example matrix runs without Azure credentials
- **THEN** every sizing, split-ingress, and customer-managed example SHALL initialize, validate, pass mocked tests, lint, and pass terraform-docs drift checks
