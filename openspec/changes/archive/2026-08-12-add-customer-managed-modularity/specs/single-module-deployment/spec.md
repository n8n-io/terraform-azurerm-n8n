## MODIFIED Requirements

### Requirement: Resource-bearing root module
The repository root SHALL expose the production n8n deployment as one Terraform module, SHALL directly own or conditionally reference its Azure and Kubernetes layers, and SHALL compose only the documented controllers submodule and TLS helper modules.

#### Scenario: Deploy from the root
- **WHEN** a caller supplies the required resource group, VNet, subnet, domain, certificate, and license inputs to one root module block with ownership defaults unchanged
- **THEN** one Terraform apply SHALL provision AKS, data services, storage, ingress, KEDA, and the n8n workload

#### Scenario: Deploy onto existing foundations
- **WHEN** a caller disables supported ownership layers and supplies their required references and attestations
- **THEN** one root module block SHALL deploy the remaining n8n resources without recreating the referenced infrastructure

### Requirement: Caller-owned provider configuration
The root module and directly callable controllers submodule SHALL declare their directly used providers and version constraints but SHALL NOT configure providers internally.

#### Scenario: Configure providers in a calling root
- **WHEN** a caller configures AzureRM and the Kubernetes-facing providers against either a module-created or existing AKS cluster
- **THEN** the selected module path SHALL accept those configurations without containing a `provider` block

### Requirement: Stable public contract
The root SHALL expose discrete, documented outputs for the effective AKS target, n8n access, effective service endpoints, credentials, ingress integration, workload identity, and service discovery, marking every secret-bearing output sensitive.

#### Scenario: Read effective cluster coordinates
- **WHEN** a caller selects either module-created or existing AKS
- **THEN** the AKS outputs SHALL describe the effective target cluster without indexing an absent managed resource

#### Scenario: Consume a workload ordering output
- **WHEN** a caller references the namespace or service outputs from another Kubernetes resource
- **THEN** the output SHALL derive from the active managed resource or workload release so Terraform preserves the applicable dependency edge

### Requirement: Clean major-version transition
The modularity refactor SHALL be documented as an intentionally state-breaking pre-release transition and SHALL NOT include `moved` blocks for newly gated or extracted resources.

#### Scenario: Upgrade from the two-tier release
- **WHEN** an existing pre-release user reads the upgrade guidance
- **THEN** the guidance SHALL require reviewing replacement actions, preserving the n8n encryption key and durable data, and recreating affected test infrastructure where necessary
