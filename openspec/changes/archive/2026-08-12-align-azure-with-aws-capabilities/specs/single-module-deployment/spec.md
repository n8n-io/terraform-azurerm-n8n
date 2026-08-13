## Purpose

Define one cohesive Azure module contract that provisions infrastructure and the n8n workload without requiring callers to compose internal tiers.

## ADDED Requirements

### Requirement: Resource-bearing root module
The repository root SHALL expose the production n8n deployment as one Terraform module and SHALL directly own its Azure, Kubernetes, Helm, and lifecycle resources without calling `modules/infra` or `modules/workload`.

#### Scenario: Deploy from the root
- **WHEN** a caller supplies the required resource group, VNet, subnet, domain, certificate, and license inputs to one root module block
- **THEN** one Terraform apply SHALL provision the AKS, data-service, storage, ingress, controller, and n8n workload resources

### Requirement: Caller-owned provider configuration
The root module SHALL declare all directly used providers and version constraints but SHALL NOT configure providers internally.

#### Scenario: Configure providers in a calling root
- **WHEN** a caller configures AzureRM and the Kubernetes-facing providers against the target AKS cluster
- **THEN** the module SHALL accept those configurations without containing a `provider` block

### Requirement: Azure deployment prerequisites
The module SHALL require a pre-existing resource group, VNet, and purpose-specific subnets and SHALL validate their identifiers before resource creation.

#### Scenario: Reject an invalid subnet identifier
- **WHEN** a caller supplies a value that is not a fully qualified Azure subnet resource ID
- **THEN** Terraform planning SHALL fail at the variable boundary with an actionable error

### Requirement: Stable public contract
The root SHALL expose discrete, documented outputs for AKS access, n8n access, managed-service endpoints, credentials, ingress integration, and workload service discovery, marking every secret-bearing output sensitive.

#### Scenario: Consume a workload ordering output
- **WHEN** a caller references the namespace or service outputs from another Kubernetes resource
- **THEN** the output SHALL derive from the managed resource attribute so Terraform preserves the dependency edge

### Requirement: Clean major-version transition
The single-module release SHALL be documented as a destructive major-version transition and SHALL NOT claim state compatibility with the previous two-tier layout.

#### Scenario: Upgrade from the two-tier release
- **WHEN** an existing v3 user reads the upgrade instructions
- **THEN** the instructions SHALL require destroying the old deployment before applying the new root and SHALL describe data backup prerequisites and rollback boundaries
