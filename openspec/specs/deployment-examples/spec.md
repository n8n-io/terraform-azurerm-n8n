## Purpose

Give operators tested Azure reference deployments for common sizes, DNS providers, and ingress topologies using the same organization as the AWS sibling.
## Requirements
### Requirement: Three sizing tiers
The repository SHALL include `small`, `medium`, and `large` examples with documented target scale, AKS capacity, n8n autoscaler ranges, PostgreSQL sizing, Redis sizing, storage durability, and expected cost factors.

#### Scenario: Select a production tier
- **WHEN** an operator compares the sizing table
- **THEN** the operator SHALL be able to choose an example whose AKS and pod autoscaling limits are internally consistent for the stated workload band

### Requirement: Large Azure topology
The `large` example SHALL use Azure-native high-throughput and high-availability choices, including zone-redundant PostgreSQL, highly available Azure Managed Redis, private Azure Blob storage, larger AKS subnets, and PgBouncer where connection pressure requires it.

#### Scenario: Plan the large example
- **WHEN** the mocked large example test runs
- **THEN** it SHALL assert the high-availability, sizing, PgBouncer, storage, and autoscaling decisions that distinguish it from medium

### Requirement: Split ingress example
The repository SHALL include a `split-ingress` example with a public webhook-only endpoint and an internal admin endpoint, optional WAF attachment, distinct DNS names, and complete webhook routing.

#### Scenario: Keep the editor private
- **WHEN** the split-ingress example is deployed
- **THEN** the public endpoint SHALL expose all webhook path prefixes without a `/` catch-all and the internal endpoint SHALL expose the editor plus all webhook prefixes

### Requirement: Runnable example contract
Every example SHALL include provider constraints, provider wiring, variables, outputs, an example variable file, generated reference documentation, a platform lock file, and a mocked Terraform test.

#### Scenario: Validate all examples in CI
- **WHEN** the example matrix runs without Azure credentials
- **THEN** every sizing, split-ingress, and customer-managed example SHALL initialize, validate, pass mocked tests, lint, and pass terraform-docs drift checks

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
