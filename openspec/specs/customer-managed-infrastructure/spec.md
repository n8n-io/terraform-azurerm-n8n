# customer-managed-infrastructure Specification

## Purpose
Define a consistent and secure contract for deploying n8n onto Azure and Kubernetes layers that a platform team owns outside this module.
## Requirements
### Requirement: Explicit ownership switches
Every independently customer-manageable layer SHALL use a plan-known boolean that defaults to module ownership and SHALL require explicit caller references when module ownership is disabled.

#### Scenario: Keep greenfield defaults
- **WHEN** a caller does not set any ownership switches
- **THEN** the module SHALL create the same AKS, Blob, namespace, Secret, KEDA, and webhook HPA layers that it created before modularity was added

#### Scenario: Select a customer-managed layer
- **WHEN** a caller disables an ownership switch and supplies its required references
- **THEN** the module SHALL create no resources owned by that layer and SHALL configure downstream consumers from the supplied references

### Requirement: Plan-time contract diagnostics
The module SHALL reject incomplete customer-managed contracts at plan time and SHALL emit a non-failing diagnostic when caller references or tuning inputs are ignored because the corresponding layer remains module-managed.

#### Scenario: Omit a required reference
- **WHEN** a caller disables a layer but omits one of its required references or attestations
- **THEN** Terraform planning SHALL fail with an error that names the missing contract

#### Scenario: Supply an ignored reference
- **WHEN** a caller supplies an existing-resource reference while the corresponding create switch remains true
- **THEN** Terraform SHALL warn that the reference is ignored and identify the switch that selects it

### Requirement: Existing AKS contract
The root module SHALL support an existing AKS cluster through an explicit cluster name and resource group, and SHALL require an attestation that the cluster has OIDC issuer and workload identity enabled, schedulable capacity, compatible Kubernetes and provider access, and no conflicting module-owned names.

#### Scenario: Deploy onto existing AKS
- **WHEN** AKS creation is disabled and the caller supplies the cluster references and confirms the prerequisites
- **THEN** the module SHALL create no AKS cluster, node pool, or API warm-up resource and SHALL use the existing cluster's identity and OIDC coordinates for downstream workload wiring

#### Scenario: Reject unconfirmed prerequisites
- **WHEN** AKS creation is disabled without confirming the existing-cluster prerequisites
- **THEN** Terraform planning SHALL fail before creating Kubernetes or Azure workload resources

### Requirement: Customer-managed Blob contract
The root module SHALL support an existing Azure Blob storage account and private container through explicit account, container, and endpoint references, SHALL require an attestation that private networking, encryption, and retention are configured outside the module, and SHALL grant its n8n workload identity container-scoped data-plane access when automatic authentication is selected.

#### Scenario: Use existing Blob storage
- **WHEN** Blob creation is disabled and the caller supplies the required references and confirms the prerequisites
- **THEN** the module SHALL create no storage account, container, private endpoint, private DNS, or lifecycle policy, SHALL configure every n8n pod to use the supplied Blob endpoint, and SHALL create only the container-scoped workload role assignment when automatic authentication is selected

### Requirement: Customer-managed Kubernetes objects
The root module SHALL independently support a pre-existing n8n namespace, existing Kubernetes Secret key references for the n8n license key, n8n encryption key, PostgreSQL password, and Redis password, an existing KEDA installation, and a caller-managed webhook HPA.

#### Scenario: Reference existing Secrets
- **WHEN** a caller supplies an existing Secret reference for a supported credential
- **THEN** the module SHALL not create the corresponding Kubernetes Secret and the n8n chart or KEDA authentication SHALL reference the supplied Secret name and key without reading the Secret value into Terraform

#### Scenario: Keep the task-runner token module-managed
- **WHEN** caller-managed credential references are used
- **THEN** the task-runner authentication token SHALL remain module-generated and module-managed because it does not encrypt persisted data or authenticate to an external system

### Requirement: Direct controller composition
The repository SHALL expose a directly callable controllers submodule that can install KEDA into a target cluster, while the root module SHALL call that submodule by default.

#### Scenario: Install KEDA through the root
- **WHEN** the default root-module path is planned
- **THEN** the root SHALL call the controllers submodule and order the n8n workload after KEDA and its CRDs

#### Scenario: Install KEDA separately
- **WHEN** an advanced caller invokes the controllers submodule directly and disables the root KEDA installation
- **THEN** the caller SHALL be able to order the n8n module after the direct controller call without installing a duplicate KEDA release

### Requirement: Existing-cluster ingress boundary
The root module SHALL require caller-owned ingress when AKS creation is disabled.

#### Scenario: Reject managed ingress on existing AKS
- **WHEN** AKS creation is disabled while module-managed ingress remains enabled
- **THEN** Terraform planning SHALL fail and direct the caller to disable managed ingress and route the exported n8n service coordinates through an existing ingress controller

### Requirement: Explicit parity exclusions
The module SHALL NOT expose Azure inputs that only imitate AWS features without a secure Azure-native implementation in this architecture.

#### Scenario: Review the parity surface
- **WHEN** an operator reads the customer-managed infrastructure documentation
- **THEN** the documentation SHALL identify excluded AWS-only capabilities and SHALL not claim support for keyless n8n Azure Key Vault external secrets, IAM permission boundaries, AWS KMS controls on Storage or PostgreSQL, RDS snapshot restoration, or EBS CSI ownership

### Requirement: AKS Key Vault-backed add-ons
The root module SHALL support optionally enabling the AKS Key Vault Secrets Provider add-on and AKS KMS etcd encryption against a caller-owned Key Vault, both gated on module-managed AKS, and SHALL only optionally manage the minimum role assignment each add-on's identity needs.

#### Scenario: Enable the Key Vault Secrets Provider add-on
- **WHEN** a caller enables the Key Vault Secrets Provider add-on with module-managed AKS
- **THEN** the module SHALL configure the AKS-managed Secrets Store CSI driver add-on with autorotation and SHALL grant its auto-created identity Key Vault Secrets User on a caller-named vault only when the caller also enables that role assignment

#### Scenario: Enable KMS etcd encryption
- **WHEN** a caller supplies a Key Vault key identifier for KMS etcd encryption with module-managed AKS
- **THEN** the module SHALL configure AKS KMS etcd encryption using that key and SHALL grant the cluster's own identity Key Vault Crypto Service Encryption User on a caller-named vault only when the caller also enables that role assignment

#### Scenario: Reject Key Vault add-ons without module-managed AKS
- **WHEN** either Key Vault-backed add-on is enabled while AKS creation is disabled
- **THEN** Terraform planning SHALL fail because there is no module-managed cluster resource to attach the add-on to

### Requirement: Pre-release state boundary
The modularity change SHALL NOT promise Terraform state compatibility for resources whose addresses change because of ownership gates or controller extraction.

#### Scenario: Upgrade a pre-release deployment
- **WHEN** an operator upgrades an existing pre-release test deployment
- **THEN** the documentation SHALL warn that Terraform may propose replacement and SHALL require plan review, backup of durable n8n data and encryption keys, and recreation where necessary
