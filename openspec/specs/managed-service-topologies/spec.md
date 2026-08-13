## Purpose

Define secure Azure-native database, queue, and shared-storage choices that support both module-managed and caller-managed production topologies.
## Requirements
### Requirement: Managed or external PostgreSQL
The module SHALL support a module-managed PostgreSQL Flexible Server by default and an external PostgreSQL endpoint when managed database creation is disabled. The PostgreSQL password SHALL come from either a Terraform value or a caller-managed Kubernetes Secret reference, but not both.

#### Scenario: Create managed PostgreSQL
- **WHEN** `create_database` is true
- **THEN** the module SHALL create a private PostgreSQL Flexible Server, database, private DNS integration, generated administrator credential, and the `UUID-OSSP` extension allowlist

#### Scenario: Use external PostgreSQL
- **WHEN** `create_database` is false and the caller supplies the required host, database, username, port, TLS settings, and exactly one password source
- **THEN** the module SHALL create no PostgreSQL server resources and SHALL configure every n8n pod to use the supplied endpoint and password source

#### Scenario: Reference an existing database Secret
- **WHEN** a caller supplies an existing Kubernetes Secret name and key for the PostgreSQL password
- **THEN** Terraform SHALL not read or output that password and SHALL not create the module-managed database password Secret

### Requirement: PostgreSQL reliability controls
The managed database path SHALL expose version, SKU, storage, backup retention, geo-redundant backup, maintenance window, primary zone, and zone-redundant high-availability controls with cross-input validation.

#### Scenario: Reject unsupported high availability
- **WHEN** zone-redundant high availability is enabled with a Burstable PostgreSQL SKU or identical primary and standby zones
- **THEN** Terraform planning SHALL fail before calling Azure

### Requirement: Azure Managed Redis
The managed queue path SHALL use Azure Managed Redis with encrypted client connections, access-key authentication, private endpoint DNS, `NoCluster` database policy, a validated compatible SKU, and configurable high availability.

#### Scenario: Create a highly available managed queue
- **WHEN** managed Redis and Redis high availability are enabled
- **THEN** the module SHALL create a private Azure Managed Redis database with high availability, TLS-only client protocol, authentication, and a primary endpoint consumable by n8n and KEDA

#### Scenario: Reject an incompatible managed Redis SKU
- **WHEN** a caller selects a SKU that does not support `NoCluster` or the selected capacity
- **THEN** Terraform planning SHALL fail and explain the supported limit, regional-availability caveat, and replacement risk

### Requirement: External Redis
The module SHALL support an external Redis endpoint with explicit host, port, TLS, optional username, and either a password value or caller-managed Kubernetes Secret reference when managed Redis creation is disabled.

#### Scenario: Scale workers against external Redis
- **WHEN** `create_redis` is false and a valid external Redis contract is supplied
- **THEN** n8n and both KEDA queue triggers SHALL use the same external host, port, TLS, username, and selected password source

#### Scenario: Reference an existing Redis Secret
- **WHEN** a caller supplies an existing Kubernetes Secret name and key for the Redis password
- **THEN** the module SHALL not create a Redis credential Secret and both n8n and KEDA SHALL reference the caller-managed Secret without reading its value into Terraform

#### Scenario: Reject ignored Redis tuning
- **WHEN** a caller disables managed Redis but sets a managed-only SKU or high-availability option
- **THEN** Terraform SHALL emit a plan-time diagnostic identifying the ignored setting

### Requirement: Azure Blob external storage
The module SHALL support either a module-managed private Azure Blob account and container or a caller-managed account and container as the preferred store for n8n binary and execution data, with independent mode controls and one effective Azure connection configuration.

#### Scenario: Store binary and execution data in Azure
- **WHEN** the caller enables both Azure storage modes and keeps Blob creation enabled
- **THEN** every n8n pod SHALL use the module-created private container through `DefaultAzureCredential` while binary and execution objects remain in their distinct n8n prefixes

#### Scenario: Store data in customer-managed Azure Blob
- **WHEN** the caller enables an Azure storage mode, disables Blob creation, and supplies the existing storage contract
- **THEN** every n8n pod SHALL use the supplied account, container, endpoint, and authentication mode while the module creates no Blob infrastructure

### Requirement: Azure Blob identity and networking
The managed Blob path SHALL use a Blob private endpoint, VNet-linked private DNS, disabled public data-plane access, and container-scoped `Storage Blob Data Contributor` access for the n8n workload identity. The customer-managed Blob path SHALL require caller attestation of equivalent network and storage controls, SHALL not inspect or modify the supplied storage configuration, and SHALL grant the module-owned n8n workload identity container-scoped data-plane access when automatic authentication is selected.

#### Scenario: Validate Blob access at startup
- **WHEN** an n8n pod starts with module-managed Azure storage enabled
- **THEN** its identity SHALL resolve the storage account privately and list, read, write, inspect, copy, and delete objects in the configured container

#### Scenario: Trust an attested existing container
- **WHEN** an existing Blob contract is selected and its prerequisites are confirmed
- **THEN** the module SHALL configure n8n from caller inputs without making plan-time Azure data-source calls against the existing account or container and SHALL limit any module-created integration resource to the required container-scoped workload role assignment

### Requirement: Azure storage authentication choices
The module SHALL use workload identity and `DefaultAzureCredential` by default and SHALL support caller-supplied connection-string, account-key, and custom-endpoint settings as sensitive compatibility inputs.

#### Scenario: Use a custom Azure endpoint
- **WHEN** a caller supplies a valid custom or sovereign Blob endpoint
- **THEN** every n8n pod SHALL receive the endpoint without the module claiming that the target cloud is certified

### Requirement: Safe storage retention
The module SHALL keep binary-data lifecycle deletion separate from n8n-managed execution-data pruning and SHALL preserve access to historical storage modes during transitions. It SHALL create lifecycle expiry only for a container dedicated to binary data.

#### Scenario: Share a container with execution data
- **WHEN** Azure binary and execution-data modes use the same container
- **THEN** the module SHALL omit lifecycle expiry, warn that binary objects remain indefinitely, and SHALL not expire the container, `workflows/`, or execution-data objects broadly

#### Scenario: Use a binary-only container
- **WHEN** the managed container stores binary data but not execution data and the caller supplies a retention period
- **THEN** the module SHALL apply container lifecycle expiry and document that enabling execution-data storage later requires removing that rule first

#### Scenario: Change the binary write mode
- **WHEN** a caller changes the default binary-data mode
- **THEN** the module SHALL retain configured historical modes and SHALL document that it does not backfill existing objects

### Requirement: Private service networking
Module-managed PostgreSQL, Redis, and Blob storage SHALL deny public data-plane access and use private DNS linked to the supplied VNet. Customer-managed services SHALL remain the caller's networking responsibility.

#### Scenario: Resolve managed services privately
- **WHEN** a pod resolves a module-managed PostgreSQL, Redis, or storage hostname
- **THEN** DNS SHALL return the corresponding private endpoint or delegated-subnet address rather than a public endpoint

#### Scenario: Use an external endpoint
- **WHEN** a customer-managed database, Redis, or Blob layer is selected
- **THEN** the module SHALL neither create private DNS or endpoint resources for that layer nor claim to validate its network posture
