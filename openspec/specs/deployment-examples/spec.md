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

The repository SHALL include a `split-ingress` example with a public webhook-only endpoint and an internal admin endpoint, optional WAF attachment, distinct DNS names, and complete webhook routing. The example SHALL pass its public webhook base URL separately from the canonical admin domain so n8n advertises webhooks on the public host while editor and OAuth2 callback URLs use the admin host.

#### Scenario: Keep the editor private
- **WHEN** the split-ingress example is deployed
- **THEN** the public endpoint SHALL expose all webhook path prefixes without a `/` catch-all and the internal endpoint SHALL expose the editor plus all webhook prefixes

#### Scenario: Render independent advertised URLs
- **WHEN** the split-ingress mocked test runs
- **THEN** it SHALL assert that the module receives the admin domain as `n8n_domain` and the public webhook HTTPS address as `n8n_webhook_url`
- **AND** existing assertions for the five production webhook prefixes and absence of a public catch-all SHALL remain intact

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

### Requirement: Main topology selection in existing examples

The `small`, `medium`, `large`, `split-ingress`, `customer-managed-cluster`, `customer-managed-redis`, `customer-managed-storage`, and `customer-managed-everything` examples SHALL expose `n8n_main_hpa_min_replicas` as a validated variable passed to the root module. Defaults SHALL remain 3 for medium, 6 for large, and 2 for the other examples. Selecting 1 SHALL request single-main without requiring source edits to the example's module block. Documentation SHALL explain that other selected features, including Azure storage, still require their own entitlements.

#### Scenario: Select a single main through example variables
- **WHEN** an operator sets main minimum to 1 in any existing example's input configuration
- **THEN** that example SHALL pass 1 to the root module and the effective main ceiling SHALL be 1
- **AND** the example's unrelated service, storage, and workload settings SHALL remain unchanged

#### Scenario: Preserve each example's default topology
- **WHEN** all example variables remain at their defaults
- **THEN** medium SHALL retain 3 mains, large SHALL retain 6, and the other examples SHALL retain 2
- **AND** their existing distinguishing topology tests SHALL continue passing

### Requirement: Evidence-bound Azure sizing guidance

This port SHALL preserve existing Azure example VM sizes, node bounds, pod resources and ceilings, database and Redis SKUs, PostgreSQL pool size, PgBouncer replicas and limits, pruning settings, and storage modes/replication defaults. Documentation SHALL explain that AWS measurements motivate diagnostics but do not establish Azure capacity or performance. Pool-sizing guidance SHALL describe a lazy per-process maximum and aggregate connection budgets rather than one connection per workflow.

#### Scenario: Review the large-tier port
- **WHEN** the large example is compared with its pre-change configuration
- **THEN** its infrastructure and workload sizing values SHALL remain unchanged, including two PgBouncer replicas and `postgres_pool_size = 5`
- **AND** documentation SHALL identify connection wait time, total connection budgets, Redis load, disk pressure, DNS errors, and pruning backlog as signals to measure before retuning

#### Scenario: Discuss execution-data offload
- **WHEN** an operator reads the updated storage/sizing guidance
- **THEN** the documentation SHALL distinguish storage durability, feature entitlements, and measured bottlenecks
- **AND** it SHALL NOT claim AWS S3 throughput percentages or AWS database TPS bands as Azure Blob or Flexible Server results
