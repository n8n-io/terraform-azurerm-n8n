## Why

The Azure module currently exposes a much smaller production and operator surface than its AWS sibling, and its two-tier composition makes the common deployment harder to consume. Azure users need one root module with comparable workload controls, managed-service choices, ingress patterns, sizing examples, and verification while retaining Azure-specific security and reliability requirements.

## What Changes

- **BREAKING** Replace the resource-free root and the `modules/infra` plus `modules/workload` composition contract with one resource-bearing root module similar to `terraform-aws-n8n`. This is a clean major-version deployment with no state migration compatibility.
- Port every practical AWS capability to an equivalent Azure input, output, resource, warning, test, and operator workflow.
- Adopt Azure-native production practices from HashiCorp's `terraform-azurerm-terraform-enterprise-aks-hvd`, including availability-zone placement, AKS upgrade and API controls, private service access, PostgreSQL high availability and backup controls, Azure Managed Redis, workload identity where supported, and explicit public or private DNS paths.
- Add managed or external PostgreSQL and Redis modes, encrypted authenticated Redis connectivity, Redis high availability, and private Azure storage networking.
- Add first-class Azure Blob Storage modes for binary data and execution data with workload-identity authentication, while retaining Azure Files as an optional shared-filesystem compatibility path.
- Document the infrastructure boundary for recent Azure Enterprise integrations, including Azure Key Vault external secrets and Microsoft Entra workflow credentials.
- Add the AWS sibling's n8n image, extension, volume, environment, observability, execution, lifecycle, resource, and autoscaling controls.
- Add module-managed or caller-managed ingress, public or internal Application Gateway modes, source restrictions, additional domains, complete webhook path routing, and a split public-webhook/internal-admin reference topology.
- Replace the current examples with AWS-shaped `small`, `medium`, `large`, `cloudflare`, `godaddy`, and `split-ingress` examples using Azure equivalents.
- Expand mocked plan-time tests, CI matrices, documentation, smoke tests, and custom-image verification for the new root and all examples.

## Capabilities

### New Capabilities

- `single-module-deployment`: One root module owns the Azure infrastructure and Kubernetes workload through a cohesive public contract.
- `managed-service-topologies`: Managed and external PostgreSQL, Redis, Azure Blob, and Azure Files topologies with Azure-native security, availability, retention, and recovery controls.
- `n8n-workload-configuration`: Advanced n8n image, runtime, extension, storage, observability, and lifecycle controls equivalent to the AWS module.
- `autoscaling-and-capacity`: Coordinated AKS, main, webhook, and worker autoscaling with safe floors, ceilings, and capacity diagnostics.
- `ingress-dns-and-tls`: Default, private, caller-owned, multi-domain, and split ingress patterns with Azure DNS and Key Vault TLS integration.
- `deployment-examples`: Azure sizing, DNS-provider, and topology examples organized like the AWS sibling.
- `module-verification`: Mocked tests, static analysis, generated documentation checks, and live smoke verification for the expanded module.

### Modified Capabilities

None. OpenSpec was initialized for this change and has no existing capability specifications.

## Impact

- Affects the root Terraform files, `modules/infra`, `modules/workload`, TLS helpers, all examples, tests, CI, README, changelog, and operator documentation.
- Adds or changes AzureRM, Kubernetes, Helm, kubectl, random, and time provider usage at the root. DNS-provider examples retain their provider-specific dependencies.
- Replaces Azure Cache for Redis with Azure Managed Redis on the managed path and changes the example and resource address model.
- Requires n8n 2.29.0 or later for Azure Blob binary-data and execution-data modes and requires the matching Enterprise license entitlements.
- Requires a new major version and clean deployment. Existing v3 users must destroy the old two-tier deployment before applying the new root module.
