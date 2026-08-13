## ADDED Requirements

### Requirement: Caller-managed workload credentials
The module SHALL accept mutually exclusive literal-value and existing Kubernetes Secret references for the n8n license key and n8n encryption key, and SHALL preserve the selected Secret name and key across main, worker, and webhook pod families.

#### Scenario: Use an existing license Secret
- **WHEN** a caller supplies the name and key of a Kubernetes Secret containing the n8n license
- **THEN** the module SHALL create no license Secret and the chart SHALL reference the caller-managed Secret

#### Scenario: Use an existing encryption-key Secret
- **WHEN** a caller supplies the name and key of a Kubernetes Secret containing the n8n encryption key
- **THEN** the module SHALL create no encryption-key Secret, SHALL not generate or output an effective encryption key, and SHALL configure every pod family from that Secret

#### Scenario: Reject two credential sources
- **WHEN** a caller supplies both a literal value and an existing Secret reference for one credential
- **THEN** Terraform planning SHALL fail and require exactly one selected source

### Requirement: Caller-managed namespace
The module SHALL allow n8n to deploy into a pre-existing namespace without creating or deleting that namespace.

#### Scenario: Use a platform-owned namespace
- **WHEN** namespace creation is disabled and a valid namespace name is supplied
- **THEN** every n8n Secret, ServiceAccount, manifest, Helm release, HPA, and output SHALL use that namespace while no namespace resource is created

### Requirement: Independent webhook HPA ownership
The module SHALL allow callers to disable only the module-managed webhook HPA while retaining the webhook deployment and service.

#### Scenario: Use a platform autoscaler
- **WHEN** the module-managed webhook HPA is disabled
- **THEN** the module SHALL create no webhook HPA and SHALL leave the webhook deployment available for a caller-managed autoscaler

### Requirement: External KEDA ownership
The module SHALL allow callers to use a pre-existing KEDA installation while preserving worker ScaledObject and TriggerAuthentication behavior.

#### Scenario: Use existing KEDA
- **WHEN** KEDA installation is disabled and the caller confirms a compatible KEDA installation already exists
- **THEN** the module SHALL install no KEDA operator or KEDA namespace and SHALL still create the n8n-specific authentication resource and chart-rendered worker ScaledObject after the caller-provided ordering edge

#### Scenario: Reject an unconfirmed external KEDA path
- **WHEN** KEDA installation is disabled without confirming that compatible CRDs and controllers exist
- **THEN** Terraform planning SHALL fail before applying the n8n release
