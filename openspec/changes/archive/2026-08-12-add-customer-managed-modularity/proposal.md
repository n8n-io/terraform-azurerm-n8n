## Why

The Azure module still assumes that it owns AKS, Blob storage, the n8n namespace, Kubernetes Secrets, KEDA, and the webhook HPA. This prevents platform teams from deploying n8n onto shared or separately managed Azure and Kubernetes foundations. The latest AWS sibling, commit `3081ecf`, establishes a consistent customer-managed infrastructure convention and a directly callable controllers submodule that the Azure module should match where Azure offers a secure equivalent.

## What Changes

- Add plan-known `create_*` and `install_*` switches with caller-supplied references for an existing AKS cluster, Azure Blob account and container, namespace, Kubernetes Secrets, KEDA installation, and webhook HPA.
- Keep the existing external PostgreSQL and Redis paths, but allow their workload credentials to come from caller-managed Kubernetes Secrets.
- Extract the KEDA operator and namespace into a directly callable `modules/controllers` submodule. The root calls it by default so greenfield behavior remains the default.
- Add chart repository overrides for private KEDA mirrors and define ordering requirements for direct submodule callers.
- Add customer-managed cluster, Redis, storage, and everything examples, with mocked tests and the same CI and documentation coverage as existing examples. The module continues to own the n8n workload identity and its least-privilege access grant when it targets a caller-owned Blob container.
- Document the shared customer-managed-layer convention, caller attestations, ownership boundaries, unsupported combinations, and destroy ordering.
- Exclude AWS features without a secure Azure equivalent, including IAM permission boundaries, AWS KMS controls, RDS snapshot restoration, EBS CSI ownership, and keyless n8n Azure Key Vault external-secrets integration.
- **BREAKING**: Resource address changes introduced by conditional gates and the controllers extraction will not include `moved` blocks. This repository is still preparing its first release, so the implementation may require replacement of existing pre-release test deployments.
- Keep the implementation and verification workflow offline. Live Azure qualification remains outside this change.

## Capabilities

### New Capabilities

- `customer-managed-infrastructure`: Consistent ownership switches, references, attestations, diagnostics, controller composition, and unsupported-combination rules for caller-managed Azure and Kubernetes layers.

### Modified Capabilities

- `single-module-deployment`: Allow the root to target either module-created or existing AKS and to compose the controllers submodule while preserving the default greenfield call path.
- `managed-service-topologies`: Add caller-managed Azure Blob storage and Kubernetes Secret references for external PostgreSQL and Redis credentials.
- `n8n-workload-configuration`: Add caller-owned namespace, Secret, KEDA, and webhook-HPA paths without changing default workload behavior.
- `autoscaling-and-capacity`: Make autoscaler ownership and the advisory capacity model accurate for module-managed and customer-managed clusters.
- `ingress-dns-and-tls`: Define the supported caller-owned ingress requirement for existing AKS.
- `deployment-examples`: Add four runnable customer-managed infrastructure examples.
- `module-verification`: Extend offline validation, mocked tests, static analysis, lock coverage, and generated documentation to the root, controllers submodule, and new examples.

## Impact

- Root Terraform: `aks.tf`, `iam.tf`, `controllers.tf`, `keda.tf`, `storage.tf`, `n8n.tf`, `scaling.tf`, `ingress.tf`, `locals.tf`, `variables.tf`, `outputs.tf`, and `versions.tf`.
- New public submodule: `modules/controllers/` with its own provider constraints, inputs, outputs, tests, lock file, and generated README.
- New examples: `examples/customer-managed-cluster`, `examples/customer-managed-redis`, `examples/customer-managed-storage`, and `examples/customer-managed-everything`.
- Tests and tooling: root and example Terraform tests, `init.sh`, CI matrices, TFLint, Checkov, terraform-docs, and multi-platform provider locks.
- Documentation: root README, examples comparison, contributor guidance, troubleshooting, destroy ordering, and a customer-managed infrastructure guide.
- Existing pre-release Terraform state is intentionally not preserved across newly gated or extracted resources.
