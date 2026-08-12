## Purpose

Give operators tested Azure reference deployments for common sizes, DNS providers, and ingress topologies using the same organization as the AWS sibling.

## ADDED Requirements

### Requirement: Three sizing tiers
The repository SHALL include `small`, `medium`, and `large` examples with documented target scale, AKS capacity, n8n autoscaler ranges, PostgreSQL sizing, Redis sizing, storage durability, and expected cost factors.

#### Scenario: Select a production tier
- **WHEN** an operator compares the sizing table
- **THEN** the operator SHALL be able to choose an example whose AKS and pod autoscaling limits are internally consistent for the stated workload band

### Requirement: Large Azure topology
The `large` example SHALL use Azure-native high-throughput and high-availability choices, including zone-redundant PostgreSQL, highly available Azure Managed Redis, private Azure Blob storage, optional durable Azure Files replication, larger AKS subnets, and PgBouncer where connection pressure requires it.

#### Scenario: Plan the large example
- **WHEN** the mocked large example test runs
- **THEN** it SHALL assert the high-availability, sizing, PgBouncer, storage, and autoscaling decisions that distinguish it from medium

### Requirement: DNS-provider variants
The repository SHALL include `cloudflare` and `godaddy` examples at small sizing that obtain and validate a certificate through the named DNS provider, import it into Key Vault, and pass its secret URI to the root module.

#### Scenario: Use Cloudflare-hosted DNS
- **WHEN** the Cloudflare example is applied with valid provider credentials
- **THEN** certificate validation and the application DNS record SHALL use Cloudflare while the n8n infrastructure remains Azure-native

### Requirement: Split ingress example
The repository SHALL include a `split-ingress` example with a public webhook-only endpoint and an internal admin endpoint, optional WAF attachment, distinct DNS names, and complete webhook routing.

#### Scenario: Keep the editor private
- **WHEN** the split-ingress example is deployed
- **THEN** the public endpoint SHALL expose all webhook path prefixes without a `/` catch-all and the internal endpoint SHALL expose the editor plus all webhook prefixes

### Requirement: Runnable example contract
Every example SHALL include provider constraints, provider wiring, variables, outputs, an example variable file, generated reference documentation, a platform lock file, and a mocked Terraform test.

#### Scenario: Validate all examples in CI
- **WHEN** the example matrix runs without Azure credentials
- **THEN** every example SHALL initialize, validate, pass mocked tests, lint, and pass terraform-docs drift checks
