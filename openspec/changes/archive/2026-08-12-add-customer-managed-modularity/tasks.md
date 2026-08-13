## 1. Ownership contracts and effective references

- [x] 1.1 Add non-nullable ownership switches and validated existing-resource, prerequisite-attestation, namespace, chart-repository, and Secret-reference inputs to `variables.tf`, with hard failures for incomplete selected contracts and no inferred ownership from nullable references.
- [x] 1.2 Add effective AKS, namespace, Blob, and Secret-reference locals plus ignored-input `check` diagnostics, keeping all ownership decisions plan-known and all default paths equivalent to the current greenfield behavior.
- [x] 1.3 Extend root mocked tests for every new input default, required-reference failure, mutually exclusive credential source, prerequisite attestation, and ignored-input warning.

## 2. Existing AKS support

- [x] 2.1 Gate the AKS cluster, user pool, API warm-up gate, and cluster-only identity and AGIC integration resources on `create_aks`; add the existing AKS lookup and select one effective cluster ID, name, OIDC issuer, and kubeconfig contract.
- [x] 2.2 Update workload federation, outputs, Kubernetes dependencies, and managed-ingress validation to use the effective AKS contract, require caller-owned ingress on existing AKS, and avoid indexing absent managed resources.
- [x] 2.3 Gate the managed-cluster CPU capacity model and diagnose ignored AKS tuning on the existing-cluster path.
- [x] 2.4 Add mocked root tests proving zero managed AKS resources, effective existing-cluster outputs and federation, rejected missing attestations, rejected managed ingress, suppressed capacity warnings, and unchanged managed defaults.

## 3. Controllers submodule

- [x] 3.1 Create `modules/controllers/` with copyright headers, provider requirements, validated KEDA namespace, install switch, chart repository and version inputs, Helm lifecycle settings, and outputs suitable for direct callers and root tests.
- [x] 3.2 Replace root KEDA namespace and release resources with a default `module "controllers"` call; keep n8n TriggerAuthentication at the root and order it and the n8n Helm release after the submodule for install and destroy safety.
- [x] 3.3 Add `install_keda` and prerequisite-attestation behavior for externally installed KEDA, including diagnostics for ignored KEDA settings and documentation of the direct-call `depends_on` contract and ownership-change finalizer hazard.
- [x] 3.4 Add controllers-submodule mocked tests, generated README configuration, and a multi-platform lock file; update root tests to assert module outputs and both installed and external KEDA paths.

## 4. Namespace and autoscaler ownership

- [x] 4.1 Gate the n8n namespace on `create_namespace`, route every namespaced resource and output through the effective namespace, and ensure the module never deletes a caller-owned namespace.
- [x] 4.2 Gate only the webhook HPA on `n8n_webhook_hpa_enabled` while preserving Helm's webhook replica floor and all webhook service outputs.
- [x] 4.3 Add mocked tests for caller-managed namespace and webhook HPA paths, including zero resource counts, correct downstream namespaces, unchanged defaults, and invalid namespace contracts.

## 5. Caller-managed Kubernetes Secrets

- [x] 5.1 Implement effective Secret name and key selection for n8n license and encryption credentials, gate corresponding generated and Kubernetes Secret resources, and render the chart from the selected source without reading caller-managed Secret values.
- [x] 5.2 Implement external PostgreSQL and external Redis password Secret references, enforce their mode and mutual-exclusion rules, and update both n8n and KEDA authentication to use the same effective Redis Secret reference.
- [x] 5.3 Keep the task-runner token module-managed and make the `n8n_encryption_key` and password outputs explicitly null when Terraform does not know caller-managed Secret values.
- [x] 5.4 Add mocked tests for generated, literal, and caller-managed Secret branches; assert absent managed Secrets, exact Helm/KEDA references, null outputs, sensitivity, and all invalid source combinations.

## 6. Customer-managed Blob storage

- [x] 6.1 Gate the storage account, container, private DNS, VNet link, private endpoint, and lifecycle policy on `create_blob_storage`; select one effective account, container, ID, and endpoint without inspecting customer-managed storage through data sources.
- [x] 6.2 Scope workload-identity Blob access to the effective container when automatic authentication is active, omit the role grant for compatibility credentials, and preserve the existing managed-container least-privilege path.
- [x] 6.3 Update storage environment rendering, outputs, lifecycle diagnostics, and documentation for caller-owned retention, networking, encryption, and cross-subscription role-assignment permissions.
- [x] 6.4 Add mocked tests proving zero managed Blob infrastructure, correct effective workload settings and outputs, conditional container role assignment, rejected incomplete contracts, and unchanged managed defaults.

## 7. Customer-managed examples

- [x] 7.1 Add `examples/customer-managed-cluster` with a caller-owned AKS stand-in, direct provider wiring, disabled module AKS and ingress, complete inputs and outputs, generated docs, lock file, and mocked ownership assertions.
- [x] 7.2 Add `examples/customer-managed-redis` with an external Redis stand-in and caller-managed credential Secret, plus complete documentation, lock file, and mocked endpoint, Secret, and zero-resource assertions.
- [x] 7.3 Add `examples/customer-managed-storage` with private Blob infrastructure outside the n8n module and a module-owned workload role grant to the supplied container, plus complete documentation, lock file, and mocked ownership assertions.
- [x] 7.4 Add `examples/customer-managed-everything` combining existing AKS, external PostgreSQL and Redis, existing Blob, namespace and Secrets, direct controllers composition, caller-owned ingress, and caller-owned webhook HPA; assert no duplicate ownership and explicit ordering in mocked tests.
- [x] 7.5 Update `examples/README.md` and all shared example inventories to compare and link the four customer-managed roots without changing existing sizing decisions.

## 8. Documentation and contributor contracts

- [x] 8.1 Add `docs/customer-managed-infrastructure.md` describing the ownership convention, each layer's references and attestations, direct controllers use, provider wiring, unsupported parity features, and the rule against data-source security audits.
- [x] 8.2 Update `README.md`, `AGENTS.md`, troubleshooting, destroy cleanup, post-deployment, and storage documentation for existing AKS behavior, Secret references, KEDA finalizer ordering, customer-managed Blob responsibilities, and excluded AWS-only capabilities.
- [x] 8.3 Document the intentionally state-breaking pre-release transition, including plan review, n8n encryption-key and durable-data backup, recreation, and rollback boundaries; do not add `moved` blocks or claim no-op upgrades.
- [x] 8.4 Regenerate terraform-docs for the root, controllers submodule, TLS helpers, and every example, and verify every generated block is current.

## 9. CI and offline verification

- [x] 9.1 Add the controllers submodule and four customer-managed examples to `init.sh`, CI format, docs, validate, test, TFLint, and Checkov target matrices, keeping every command credential-free.
- [x] 9.2 Refresh root, submodule, and example provider locks for Linux AMD64, Linux ARM64, and Darwin ARM64 and commit every required lock file.
- [x] 9.3 Run `terraform fmt -recursive`, initialization, validation, and all mocked Terraform test suites across the root, three submodules, and eight examples; keep the combined Terraform test wall clock under five minutes.
- [x] 9.4 Run TFLint on every Terraform root, terraform-docs output checks, the repository's variable/input contract checks, and Checkov with no regression in curated findings.
- [x] 9.5 Sweep for stale unconditional managed-resource references, duplicate KEDA resources, undocumented ownership inputs, state-migration claims, and unchecked tasks; confirm `openspec validate add-customer-managed-modularity --strict` passes and that this change contains no live Azure verification task.
