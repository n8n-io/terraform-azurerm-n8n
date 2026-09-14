## ADDED Requirements

### Requirement: License-aware main topology and maintenance

The module SHALL select single-main queue mode when `n8n_main_hpa_min_replicas = 1` and multi-main when it is greater than 1. The default minimum SHALL remain 2. Single-main SHALL not activate the multi-main feature and SHALL not require `feat:multipleMainInstances`; selected storage and other licensed features SHALL retain their independent entitlement requirements.

Single-main SHALL render one main replica, a main HPA with minimum and maximum 1, a main `Recreate` strategy that clears previous rolling-update settings, and an enabled main PodDisruptionBudget with `minAvailable = 0`. Multi-main SHALL retain chart rollout defaults, the configured replica floor/ceiling, and a main PodDisruptionBudget protecting one available replica. Worker and webhook rollout strategies SHALL remain unchanged. The floating-license-detach default SHALL remain false on both paths.

Documentation SHALL state that single-main upgrades and voluntary eviction cause editor, API, and scheduled-trigger downtime. It SHALL NOT describe `Recreate` as a general at-most-one guarantee for manual deletion, node failure, or forced operations.

#### Scenario: Select a single main with a higher configured ceiling
- **WHEN** the main minimum is 1 and the configured maximum is 20
- **THEN** multi-main SHALL be disabled and the main Deployment SHALL request one replica
- **AND** the main HPA SHALL have minimum and maximum 1
- **AND** the rendered main strategy SHALL be `Recreate` without a `rollingUpdate` configuration
- **AND** the main PDB SHALL allow voluntary eviction with `minAvailable = 0`

#### Scenario: Preserve the default multi-main deployment
- **WHEN** the caller leaves main topology inputs unchanged
- **THEN** multi-main SHALL remain enabled with a floor of 2 and the existing configured ceiling
- **AND** the module SHALL leave the main rollout strategy at the chart default and protect one main through its PDB

#### Scenario: Return to multiple mains
- **GIVEN** the operator has a license with `feat:multipleMainInstances`
- **WHEN** the desired main minimum changes from 1 to a valid value greater than 1
- **THEN** the desired configuration SHALL restore multi-main, its configured ceiling, chart rollout behavior, and a PDB minimum of 1
- **AND** the documentation SHALL require checking the live transition rather than treating rendered manifests as upgrade proof

#### Scenario: Separate Business compatibility from storage licensing
- **WHEN** an operator follows the new-deployment recipe for a Business license without Azure storage entitlements
- **THEN** the documented configuration SHALL select single-main, database binary storage, database execution storage, and only the database available binary mode
- **AND** the documentation SHALL warn that topology selection alone does not grant Azure storage entitlements or migrate retained objects

### Requirement: Configurable AKS OS-disk size

The module SHALL expose nullable `aks_node_os_disk_size_gb`, accepting positive whole numbers, and SHALL apply a supplied size to both module-managed AKS node pools. Null SHALL preserve provider/Azure disk-sizing defaults. The module SHALL provide the rotation names required by the selected AzureRM node-pool resources without changing disk type, node-count ownership, or existing sizing defaults. Documentation SHALL warn that changing disk size cycles nodes and that AzureRM's cycling path does not perform cordon/drain or guarantee uninterrupted workloads.

#### Scenario: Configure both managed pools
- **WHEN** AKS is module-managed and `aks_node_os_disk_size_gb = 256`
- **THEN** both the system and user pools SHALL be configured with OS-disk size 256
- **AND** both SHALL have valid, distinct temporary rotation names while retaining autoscaler-owned live node counts

#### Scenario: Preserve default disk sizing
- **WHEN** the disk input is null
- **THEN** the module SHALL not prescribe an OS-disk size or change the existing disk type
- **AND** no AWS 20 GiB or 100 GiB sizing assumption SHALL be introduced into Azure defaults

#### Scenario: Ignore disk tuning on an existing cluster
- **WHEN** `create_aks = false` and a disk size is supplied
- **THEN** no module-managed cluster or node pool SHALL be created or modified
- **AND** Terraform SHALL emit a non-failing ignored-AKS-tuning diagnostic naming the disk input

#### Scenario: Reject invalid disk sizes
- **WHEN** the disk size is zero, negative, or fractional
- **THEN** Terraform planning SHALL fail at the disk-size input

## MODIFIED Requirements

### Requirement: Independent workload autoscalers

The module SHALL manage a CPU-based HPA for main pods, Redis queue-depth KEDA scaling for worker pods, and, by default, a CPU-based HPA for webhook pods. The webhook HPA SHALL be independently disableable for caller ownership. Single-main mode SHALL retain the main HPA but constrain it to one replica; only multi-main mode SHALL scale main replicas above one.

#### Scenario: Scale each pod family
- **WHEN** main CPU in multi-main mode, webhook CPU, or Redis queue depth exceeds its configured target and the corresponding autoscaler is module-owned
- **THEN** that autoscaler SHALL increase only its owned deployment up to its effective ceiling

#### Scenario: Defer webhook scaling
- **WHEN** webhook HPA ownership is disabled
- **THEN** the module SHALL create no webhook HPA while preserving the configured webhook replica floor in Helm

#### Scenario: Preserve worker and webhook scaling with a single main
- **WHEN** single-main is selected
- **THEN** worker KEDA and the selected webhook autoscaler ownership SHALL remain unchanged
- **AND** high main CPU SHALL NOT authorize the main HPA to create a second main

### Requirement: Scaling contract validation

Every main, webhook, and worker minimum SHALL be less than or equal to its configured maximum, and default effective ceilings SHALL fit the default AKS node-pool capacity model. Main minimums and maximums SHALL be positive whole numbers, with minimum 1 accepted for single-main. A higher configured main maximum SHALL remain valid in single-main but SHALL have an effective value of 1.

#### Scenario: Reject an inverted range
- **WHEN** a caller sets an autoscaler minimum above its maximum
- **THEN** Terraform planning SHALL fail before Kubernetes receives the object

#### Scenario: Reject an invalid main count
- **WHEN** a main minimum or maximum is zero, negative, or fractional
- **THEN** Terraform planning SHALL fail at the corresponding input

### Requirement: Capacity diagnostic

The module SHALL emit a non-failing plan diagnostic when configured pod CPU demand at all effective autoscaler maxima exceeds the modeled schedulable CPU of module-managed maximum AKS node pools. It SHALL use the clamped main ceiling in single-main mode and include the optional Redis exporter's CPU request only when enabled. It SHALL suppress that model for customer-managed AKS because the module does not know the cluster's complete capacity, and for valid VM SKUs outside its reviewed map.

#### Scenario: Warn about unschedulable maxima
- **WHEN** total main, worker, webhook, sidecar, optional exporter, daemon, and control workload requests exceed modeled module-managed node capacity
- **THEN** Terraform SHALL warn with calculated demand, supply, VM size, node maximum, and effective main maximum without failing the plan

#### Scenario: Use customer-managed capacity
- **WHEN** AKS creation is disabled
- **THEN** Terraform SHALL not report capacity based on ignored module-managed node sizing inputs and the caller attestation SHALL carry capacity responsibility

#### Scenario: Avoid a false single-main capacity warning
- **WHEN** main minimum is 1 and the configured main maximum is raised without changing any other input
- **THEN** modeled CPU demand and warning details SHALL continue using one main plus its enabled sidecar, not the unused configured maximum

#### Scenario: Count only an enabled exporter
- **WHEN** exporter enablement changes from false to true without other changes
- **THEN** modeled CPU demand SHALL increase by exactly the exporter's configured CPU request

#### Scenario: Keep unknown valid SKUs advisory
- **WHEN** a valid AKS VM SKU is absent from the reviewed capacity map
- **THEN** Terraform SHALL suppress the capacity warning rather than guess its CPU supply
