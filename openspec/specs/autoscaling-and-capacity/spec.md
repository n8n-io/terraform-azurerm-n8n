## Purpose

Coordinate cluster and pod autoscaling so Helm upgrades, Azure node scaling, and workload autoscalers do not fight or advertise unschedulable defaults.

## Requirements

### Requirement: Production AKS controls
The module SHALL create AKS with workload identity, OIDC, role-based access control, availability-zone placement, configurable API authorized ranges, configurable node-pool upgrade surge, and cluster autoscaling bounds.

#### Scenario: Restrict the control plane
- **WHEN** authorized API CIDR ranges are supplied
- **THEN** the AKS API server SHALL accept public access only from those ranges

### Requirement: Autoscaler-owned node count
Terraform SHALL set the initial AKS node count at creation and SHALL not reset the live node count after the cluster autoscaler changes it.

#### Scenario: Plan after cluster scale-out
- **WHEN** AKS has scaled the default node pool above its initial node count
- **THEN** a subsequent Terraform plan SHALL not propose restoring the initial count

### Requirement: Independent workload autoscalers
The module SHALL manage a CPU-based HPA for main pods, a CPU-based HPA for webhook pods, and Redis queue-depth KEDA scaling for worker pods.

#### Scenario: Scale each pod family
- **WHEN** main CPU, webhook CPU, or Redis queue depth exceeds its configured target
- **THEN** the corresponding autoscaler SHALL increase only its owned deployment up to the configured ceiling

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
The module SHALL emit a non-failing plan diagnostic when configured pod CPU demand at all autoscaler maxima exceeds the modeled schedulable CPU of the maximum AKS node pool.

#### Scenario: Warn about unschedulable maxima
- **WHEN** total main, worker, webhook, sidecar, daemon, and control workload requests exceed modeled node capacity
- **THEN** Terraform SHALL warn with calculated demand, supply, VM size, and node maximum without failing the plan
