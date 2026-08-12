# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — First release

Initial public release of `terraform-azurerm-n8n`: a single resource-bearing
root module that deploys a production-grade, multi-main [n8n](https://n8n.io)
Enterprise installation on Microsoft Azure. The module's shape mirrors its
[`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) sibling —
one root, `versions.tf`/`variables.tf`/`locals.tf`/`outputs.tf` plus one file
per concern, no nested `module` calls.

### Added

- **Azure Kubernetes Service (AKS)** with the OIDC issuer and workload
  identity enabled, availability-zone-spread node pools, optional API-server
  authorized IP ranges, a configurable node-image upgrade `max_surge`, and an
  autoscaler-owned node count.
- **Multiple n8n main pods** plus dedicated **worker** and
  **webhook-processor** pods (queue mode) — the Enterprise multi-main
  topology — each independently autoscaled (main/webhook HPA, worker KEDA
  `ScaledObject`).
- **PostgreSQL — Flexible Server**, on a delegated subnet with the
  `uuid-ossp` extension allow-listed via `azure.extensions`, or an external
  PostgreSQL endpoint (`create_database = false`).
- **Azure Managed Redis** behind a private endpoint (`NoCluster`, encrypted
  protocol, access-key auth) for the Bull queue backing workers, or an
  external Redis endpoint (`create_redis = false`).
- **Private Azure Blob Storage** for binary and execution data, authenticated
  via AKS workload identity by default, with `database`/`azure` binary-data
  modes and `database`/`azure` execution-data modes.
- **Application Gateway (WAF_v2 by default)** with **AGIC** and **KEDA** for
  ingress, queue-driven worker scaling, and HPA-driven main/webhook-processor
  scaling — or `create_ingress = false` for a caller-owned ingress topology.
- **Azure Key Vault**-backed TLS for the App Gateway listener via a single
  BYO-secret contract (`var.app_gateway_tls_cert_secret_id`), paired with
  `var.app_gateway_keyvault_id` for the optional role assignment.
- **Optional public or private Azure DNS** A-records for the canonical domain
  and every additional domain.
- The full n8n runtime, execution, lifecycle, task-runner, logging,
  template, personalization, community-package, and floating-license
  control surface, plus custom image/pull-secret/extra-volume/extra-env
  support and OpenTelemetry/log-streaming observability.
- A main HPA, a webhook HPA, and worker KEDA floors/ceilings tied to Helm
  replica counts, plus an advisory AKS capacity diagnostic.
- `examples/small`, `examples/medium`, `examples/large`, and
  `examples/split-ingress`.
- `modules/tls-letsencrypt/` and `modules/tls-self-signed/` TLS helper
  submodules.
- `docs/redis.md`, `docs/data-storage.md`, `docs/observability.md`,
  `docs/azure-key-vault-external-secrets.md`, `docs/post-deployment.md`,
  `docs/troubleshooting.md`, `docs/destroy-cleanup.md`,
  `docs/tls-rotation.md`.

[0.1.0]: https://github.com/n8n-io/terraform-azurerm-n8n/releases/tag/v0.1.0
