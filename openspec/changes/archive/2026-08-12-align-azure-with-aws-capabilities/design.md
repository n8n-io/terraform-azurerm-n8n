## Context

See `proposal.md` for motivation and the capability specs for observable behavior. The current root has no resources. Azure infrastructure lives in `modules/infra`, Kubernetes resources live in `modules/workload`, and callers connect both through an example. The AWS sibling instead provides one root module with 116 inputs, six focused examples, extensive plan diagnostics, and cloud-neutral n8n runtime controls.

The design also draws on HashiCorp's `terraform-azurerm-terraform-enterprise-aks-hvd` repository. Applicable patterns include zonal AKS pools, API authorized ranges, upgrade surge settings, subnet-scoped Network Contributor roles, private endpoints and DNS, PostgreSQL backup and maintenance controls, Azure Managed Redis with encrypted `NoCluster` access, and explicit public or private DNS contracts. Its manual Helm post-steps and optional bring-your-own AKS path do not fit this module's one-apply AWS-aligned contract.

Terraform 1.9 remains the minimum. Guard expressions must use conditional expressions rather than relying on `&&` or `||` short-circuiting. CRDs installed during the same apply continue to use `gavinbunney/kubectl` rather than `kubernetes_manifest`.

## Goals / Non-Goals

**Goals:**

- Make the root the only public n8n deployment module.
- Match all practical AWS workload behavior with Azure-native infrastructure.
- Keep managed services private by default and preserve the Azure-specific PostgreSQL, KEDA, and Azure Files safeguards.
- Use Azure Blob Storage as the preferred Azure-native external store for binary and execution data.
- Keep optional features non-disruptive at their defaults where the clean major-version baseline permits it.
- Make every example and optional topology testable without cloud credentials.

**Non-Goals:**

- Preserve Terraform state or resource addresses from v3.
- Support a caller-supplied AKS cluster in this change.
- Create the caller's resource group or VNet inside the root module.
- Provide multi-region active-active n8n, automatic restore drills, or a bundled observability backend.
- Certify Azure Government, Azure China, or disconnected-cloud deployment in this change.
- Provision Microsoft Entra applications, Graph permissions, or admin consent for workflow-node credentials.
- Remove credentials from Terraform state entirely. Terraform-managed PostgreSQL, Redis, Key Vault certificate references, and Azure Files mounts necessarily place sensitive material or references in state.

## Decisions

### 1. Flatten the two deployment tiers into the root

Move the canonical resources and provider declarations from `modules/infra` and `modules/workload` into concern-based root files, then delete those two submodules. Keep the TLS helper modules because certificate issuance is a separate lifecycle and Azure has no ACM-equivalent service that gives App Gateway a publicly trusted certificate from a DNS zone in one native resource.

The root follows the AWS file shape where practical: `aks.tf`, `database.tf`, `redis.tf`, `storage.tf`, `iam.tf`, `controllers.tf`, `keda.tf`, `n8n.tf`, `ingress.tf`, `dns.tf`, `scaling.tf`, `cleanup.tf`, `locals.tf`, `variables.tf`, `outputs.tf`, and `versions.tf`.

Alternative considered: add a thin root wrapper around the two submodules. Rejected because the user selected a single module, a wrapper would retain duplicated interfaces and nested provider complexity, and there is no state-compatibility requirement.

### 2. Retain caller-owned Azure foundations

Require an existing resource group, VNet, AKS subnet, PostgreSQL delegated subnet, private-endpoint subnet, and Application Gateway subnet. Examples create these foundations. The root creates AKS because this matches the AWS sibling's ownership and preserves one apply.

Adopt HVD's AKS availability zones, API authorized ranges, explicit upgrade surge, role-based access control, OIDC, workload identity, and subnet role assignments. Keep the AKS API warm-up gate because it addresses a proven Azure provider timing gap. Ignore changes to the autoscaler-owned node count after creation.

Alternative considered: HVD's optional existing-AKS path. Rejected for this change because it doubles every AKS-dependent contract and undermines the requested AWS-shaped module.

### 3. Use Azure Managed Redis for the managed queue

Replace legacy `azurerm_redis_cache` with `azurerm_managed_redis`. Configure one default database with encrypted client protocol, access-key authentication, `NoCluster` policy, disabled public access, a private endpoint, and private DNS. `NoCluster` preserves the standard Redis endpoint semantics expected by n8n and KEDA. Expose a validated SKU and a high-availability input. Document regional SKU availability and replacement behavior for high-availability or clustering-policy changes.

External Redis receives a complete host, port, TLS, username, and password contract. Locals select one canonical connection object consumed by both Helm and KEDA, preventing drift between execution and scaling clients.

Alternative considered: retain Azure Cache for Redis for address continuity. Rejected because this is a clean major release and Azure Managed Redis is the current Azure-native path used by the HVD reference.

### 4. Extend PostgreSQL without changing the private-server baseline

Gate PostgreSQL Flexible Server, its database, private DNS, password generation, and extension allowlist behind `create_database`. Add backup retention, geo-redundant backup, maintenance window, zone selection, and zone-redundant HA controls. The external path accepts a complete connection contract and creates no database resources.

Keep a generated administrator password for the managed path, matching the AWS module's caller experience. HVD's required pre-existing Key Vault password is useful for Terraform Enterprise bootstrap policy but would add a new external prerequisite without removing the value from Terraform state.

### 5. Use Azure Blob as the preferred external data plane

Support Azure Blob Storage independently for binary data and execution data. n8n 2.29.0 added `azure` to both `N8N_DEFAULT_BINARY_DATA_MODE` and `N8N_EXECUTION_DATA_STORAGE_MODE`. The two features share `N8N_EXTERNAL_STORAGE_AZURE_*` configuration but require separate Enterprise entitlements: `feat:binaryDataAz` and `feat:executionDataAz`.

The managed path creates a private Blob container, a Blob private endpoint, and VNet-linked `privatelink.blob.core.windows.net` DNS. Every n8n pod uses the chart-rendered workload service account and `DefaultAzureCredential`. Grant that identity `Storage Blob Data Contributor` at container scope where Azure permits it. The role must cover startup list access and runtime read, write, properties, copy, and delete operations.

Expose independent binary-data and execution-data mode inputs. Wire `N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME`, `N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME`, and `N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT=true` to main, worker, and webhook pods. Support a caller-owned Azure endpoint for sovereign or custom Blob endpoints without claiming sovereign-cloud certification. Keep connection-string and account-key authentication as explicit opt-in compatibility paths; mark their values sensitive.

Mode changes affect new writes only. Keep every historical binary mode in `N8N_AVAILABLE_BINARY_DATA_MODES` and preserve its storage and credentials until retained data expires or an operator migrates it. n8n prunes Azure execution bundles, but Azure lifecycle rules prune binary objects. Current object paths do not provide one static prefix that selects binary objects across all workflow and execution IDs while excluding execution bundles. Permit container expiry only when the container is dedicated to binary data. When execution data shares the container, omit module-managed expiry, warn that binary objects remain indefinitely, and never apply a container-wide or `workflows/`-wide rule.

Use a validated n8n application version of at least 2.29.0. Prefer a patched version that contains the Azure Blob startup-probe fix when supporting container-scoped SAS. Keep all n8n components on the same version during storage rollouts.

### 6. Retain Azure Files as an optional filesystem path

Retain the Terraform-owned Azure Files share and static RWX binding for callers that select filesystem binary or execution-data modes, need legacy filesystem data during migration, or attach a shared custom volume. Add a file private endpoint and private DNS, disable public network access, and expose quota and replication controls.

When enabled, all pod families mount the same claim. The Azure Files CSI credential remains a Kubernetes Secret backed by the storage account key. Workload identity cannot replace the SMB credential in this static share contract without a different storage protocol and SKU.

Alternative considered: remove Azure Files after adding Blob Storage. Rejected because historical filesystem data, custom shared volumes, and explicit filesystem mode still require shared filesystem semantics. Alternative considered: an in-cluster S3-compatible service. Rejected because it is not Azure-native and adds an operational data service.

### 7. Port cloud-neutral n8n controls from AWS

Port the AWS variables, validations, checks, Helm values, service-account behavior, and custom-image verification that are independent of AWS. Keep Azure-specific differences in derived values: Redis uses the managed or external TLS contract, persistent data uses Azure Files, and CIFS permission enforcement stays disabled.

Use typed objects for additional volumes and log-streaming destinations where practical. Reserve every module-owned environment variable so `n8n_extra_env` cannot silently replace connection or identity settings. Set chart deployment replicas to autoscaler floors and default `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN` to false.

### 8. Coordinate AKS and workload autoscaling

Add a main HPA beside the existing webhook HPA and worker KEDA object. Expose all floors, ceilings, CPU targets, worker queue target, and webhook scale-up stabilization. Set Helm's three replica values to those floors.

Model AKS schedulable CPU from a documented map of supported Azure VM SKUs and fixed AKS/system workload reservations. Emit a warning only when a SKU is known and demand exceeds supply. Unknown SKUs do not fail planning. Variable validation rejects inverted ranges independently of the advisory model.

### 9. Treat Application Gateway as conditional ingress infrastructure

`create_ingress=true` creates Application Gateway, its managed identity and certificate access, AGIC integration, the Kubernetes Ingress, and optional DNS records. `false` omits all of them and returns resource-derived namespace and service outputs for caller-owned routing.

Public mode creates a public frontend. Internal mode creates only a private frontend. IPv4 source controls are enforced with an Application Gateway subnet network security group that retains Azure-required management and health-probe rules. App Gateway TLS policy, WAF mode or policy, autoscaling or fixed capacity, and Ingress annotations remain explicit inputs.

Render all five webhook prefixes before `/` for every canonical and additional host. Additional domains are normalized and de-duplicated. The module trusts the supplied Key Vault certificate to contain the required names and documents that Azure cannot inspect its SAN set reliably at plan time.

Alternative considered: one dual-frontend gateway for split ingress. Rejected because it couples public webhook and private editor exposure to one gateway and does not match the operational isolation of the AWS two-ALB example. The split example disables module ingress and owns two Application Gateways plus two scoped AGIC releases with distinct ingress classes.

### 10. Keep certificate issuance outside the root

The root accepts a Key Vault certificate secret URI and optional vault role-assignment scope. Azure DNS examples use the existing Let's Encrypt helper, extended for subject alternative names. Cloudflare and GoDaddy examples perform ACME DNS validation with their provider and import the resulting certificate into an example-owned Key Vault.

This keeps the root provider set focused and lets enterprise users bring certificates from their existing public key infrastructure.

### 11. Define the Azure Key Vault external-secrets boundary

n8n's Azure Key Vault external-secrets provider is separate from Application Gateway certificate access and Azure Blob authentication. It currently uses a tenant ID, client ID, and client-secret value rather than AKS workload identity. It supports public, US Government, China, and custom vault and authority endpoints.

Do not add an AzureAD provider, create a service-principal secret, or pass external-secrets provider credentials through Terraform without a supported n8n environment contract. Document the caller-owned service principal and `Key Vault Secrets User` prerequisites and provide an operator workflow for completing provider configuration in n8n. Endpoint support does not constitute sovereign-cloud certification.

Microsoft Entra service-principal credentials, certificate authentication, Graph application permissions, and admin consent for workflow nodes remain caller-owned workflow-integration concerns. Document this boundary instead of creating broad Entra resources in the deployment module.

### 12. Mirror the AWS example and verification layout

Replace `complete*` with `small`, `medium`, `large`, `cloudflare`, `godaddy`, and `split-ingress`. Small supplies defaults, medium raises warm capacity, and large adds zone-redundant PostgreSQL, Azure Managed Redis HA, durable file replication, larger address space, and a two-replica PgBouncer layer.

Create one comprehensive mocked root suite plus a mocked end-to-end suite per example. CI matrices run init, validate, test, TFLint, and terraform-docs at each root; Checkov scans the repository. Keep live apply and smoke verification manual. Commit multi-platform provider locks like the AWS sibling.

## Risks / Trade-offs

- [One module mixes Azure and Kubernetes provider graphs] -> Keep the proven AKS warm-up gate, explicit dependency edges, Helm wait/atomic settings, and CRD-aware kubectl resource.
- [The v3 migration destroys queues and potentially persistent data] -> Require database, encryption-key, and Azure Files backups before destroy; publish a clean-deploy runbook and rollback limits.
- [Azure Managed Redis differs from legacy Azure Cache for Redis] -> Use a validated `NoCluster`-compatible SKU, TLS, private DNS, and shared connection locals; warn about replacement, require queue draining, and cover managed/external and HA combinations with tests and live smoke probes.
- [Azure Blob storage uses two independent license entitlements] -> Validate the application version, document both entitlements, and test startup failure and successful access for each mode independently.
- [Binary and execution data share one Azure container but have different pruning owners] -> Permit lifecycle expiry only for a binary-only container; otherwise omit expiry, warn about indefinite binary retention, and prohibit broad deletion.
- [Azure Files credentials remain in state and a Kubernetes Secret] -> Mark all inputs and outputs sensitive, restrict storage networking, document state access, and avoid exposing keys in generated docs or scripts.
- [Filesystem execution-data behavior depends on a shared mount and n8n version] -> Pin and document the validated chart/application versions, mount the same claim on every pod family, and add a live cross-pod write/read smoke assertion.
- [Application Gateway source restrictions can block webhooks] -> Document the blast radius, warn when caller annotations or caller-owned network controls supersede module inputs, and direct mixed public/private users to `split-ingress`.
- [Capacity arithmetic is approximate and Azure VM SKUs evolve] -> Keep it advisory, support a reviewed SKU map, remain silent for unknown SKUs, and verify tier examples against actual requested CPU.
- [Six examples increase CI and maintenance cost] -> Share conventions rather than hidden modules, use mocked plan tests, cache providers through committed lock files, and keep total test time under five minutes.

## Migration Plan

1. Release the change as the next major version and publish the destructive upgrade notice before code examples.
2. Existing v3 users export the n8n encryption key, back up PostgreSQL and all external execution bundles, drain Redis queues, and copy Azure Files data.
3. Users run `terraform destroy` with the v3 two-tier configuration. If destroy cannot complete, they follow the existing Azure Files and namespace cleanup guide before continuing.
4. Users replace the two module calls with one root `module "n8n"` block and adopt the closest new example.
5. Users initialize against the new provider lock and review a plan that creates a fresh deployment.
6. Users apply, restore Azure Files data to the same n8n storage path where applicable, and verify credentials decrypt with the backed-up n8n encryption key.
7. Users configure all historical binary modes and storage credentials, verify old reads, then enable Azure Blob for new binary or execution-data writes only after storage networking, RBAC, application version, and license checks pass.
8. Users run the expanded smoke test and retain each old backend until all references have expired or an operator has migrated them.
9. Rollback requires destroying the new deployment, checking out the prior major version, and restoring the prior service and external-storage backups. Terraform state alone is not a rollback mechanism across this boundary.
