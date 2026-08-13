## Purpose

Coordinate cluster and pod autoscaling so Helm upgrades, Azure node scaling, and workload autoscalers do not fight or advertise unschedulable defaults.
## Requirements
### Requirement: Production AKS controls
When AKS creation is enabled, the module SHALL create AKS with workload identity, OIDC, role-based access control, availability-zone placement, configurable API authorized ranges, configurable node-pool upgrade surge, and cluster autoscaling bounds. When AKS creation is disabled, the module SHALL require an attestation that the existing cluster provides the required identity, access, compatibility, and capacity controls.

#### Scenario: Restrict the control plane
- **WHEN** authorized API CIDR ranges are supplied for a module-managed cluster
- **THEN** the AKS API server SHALL accept public access only from those ranges

#### Scenario: Use existing cluster controls
- **WHEN** AKS creation is disabled
- **THEN** the AKS sizing, version, availability-zone, upgrade, API-range, and node-count inputs SHALL not create or modify cluster resources and Terraform SHALL diagnose non-default ignored tuning

### Requirement: Autoscaler-owned node count
Terraform SHALL set the initial AKS node count at creation and SHALL not reset the live node count after the cluster autoscaler changes it.

#### Scenario: Plan after cluster scale-out
- **WHEN** AKS has scaled the default node pool above its initial node count
- **THEN** a subsequent Terraform plan SHALL not propose restoring the initial count

### Requirement: Independent workload autoscalers
The module SHALL manage a CPU-based HPA for main pods, Redis queue-depth KEDA scaling for worker pods, and, by default, a CPU-based HPA for webhook pods. The webhook HPA SHALL be independently disableable for caller ownership.

#### Scenario: Scale each pod family
- **WHEN** main CPU, webhook CPU, or Redis queue depth exceeds its configured target and the corresponding autoscaler is module-owned
- **THEN** that autoscaler SHALL increase only its owned deployment up to the configured ceiling

#### Scenario: Defer webhook scaling
- **WHEN** webhook HPA ownership is disabled
- **THEN** the module SHALL create no webhook HPA while preserving the configured webhook replica floor in Helm

### Requirement: Helm replica floors
The n8n Helm values SHALL set each deployment's replica count to the matching autoscaler minimum rather than a fixed unrelated value.

#### Scenario: Upgrade at configured floors
- **WHEN** Helm upgrades a deployment resting at its autoscaler minimum
- **THEN** Helm SHALL not reduce the deployment below that minimum before the autoscaler reconciles

### Requirement: Scaling contract validation
Every main, webhook, and worker minimum SHALL be less than or equal to its maximum, and default ceilings SHALL fit the default AKS node-pool capacity model.

#### Scenario: Reject an inverted range
- **WHEN** a caller sets an autoscaler minimum above its maximum
- **THEN** Terraform planning SHALL fail before Kubernetes receives the object

### Requirement: Capacity diagnostic
The module SHALL emit a non-failing plan diagnostic when configured pod CPU demand at all autoscaler maxima exceeds the modeled schedulable CPU of a module-managed maximum AKS node pool. It SHALL suppress that model for customer-managed AKS because the module does not know the cluster's complete capacity.

#### Scenario: Warn about unschedulable maxima
- **WHEN** total main, worker, webhook, sidecar, daemon, and control workload requests exceed modeled module-managed node capacity
- **THEN** Terraform SHALL warn with calculated demand, supply, VM size, and node maximum without failing the plan

#### Scenario: Use customer-managed capacity
- **WHEN** AKS creation is disabled
- **THEN** Terraform SHALL not report capacity based on ignored module-managed node sizing inputs and the caller attestation SHALL carry capacity responsibility
