# Shared responsibility

This module creates and configures an opinionated slice of Azure
infrastructure for n8n: AKS, App Gateway/AGIC with a WAF policy, a
PostgreSQL Flexible Server, Azure Managed Redis, Blob storage, and the n8n
Helm release. It does not, and is not intended to, run the whole platform
for you. This page collects the ownership boundaries that are otherwise
scattered across the README's "Out of scope" and "Support" sections,
individual variable descriptions, and several other docs, into one table so
a platform partner pricing a build on top of the module can find every gap
in one place.

Read this alongside
[`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md),
which documents the caller-managed *layers* (AKS, Blob, namespace, Secrets,
KEDA, webhook HPA) this module can hand off entirely. The rows below cover
responsibilities that exist regardless of which layer ownership mode is
selected.

| Area | What the module does | What the caller owns | Related input / doc |
|---|---|---|---|
| Cluster security add-ons and policy | Creates the AKS cluster (or attaches to an existing one), its node pool(s), and an optional API-server IP allowlist. | Microsoft Defender for Containers, Azure Policy for Kubernetes, KMS etcd encryption, and any admission-control policy are not enabled by the module and must be turned on separately (e.g. via `az aks` / the `azurerm_kubernetes_cluster` resource outside this module, or a policy assignment against the resulting cluster). | `aks_api_authorized_ip_ranges`; [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#aks-cluster-create_aks) |
| Network egress and DNS | Creates the cluster's VNet-attached subnets, the App Gateway public frontend, and (for `create_database = true`) the PostgreSQL private DNS zone and VNet link. | No egress firewall, NAT gateway, or user-defined route is created — outbound traffic from the cluster is unrestricted unless the caller adds one. Public DNS records for the n8n hostname, and DNS resolution for an externally supplied PostgreSQL endpoint (`create_database = false`), are also the caller's responsibility. | `n8n_dns_config`; [Prerequisites](../README.md#prerequisites) |
| Secrets and Terraform state | Generates the PostgreSQL admin password, the n8n encryption key, and the task-runner token as Terraform-managed values, and can read Blob/OTLP/log-streaming/extra-env values from variables. | Every generated or caller-supplied value the module does not receive through a `*_secret_ref` lands in Terraform state on the default path: `random_password.postgres_admin`, `n8n_encryption_key`, `n8n_task_runners_token`, plus whichever of `azure_blob_account_key`, `azure_blob_connection_string`, `n8n_otel_exporter_otlp_headers`, `n8n_log_streaming_destinations`, and `n8n_extra_env` the caller sets. `n8n_image_pull_secrets` is never persisted to state. Securing the Terraform state backend (encryption at rest, restricted access) is the caller's responsibility in every mode. Route the license key, encryption key, credentials-overwrite payload, and Redis password through `n8n_license_key_secret_ref`, `n8n_encryption_key_secret_ref`, `n8n_credentials_overwrite_secret_ref`, and `redis_password_secret_ref` to keep those specific values out of state; the task-runner token has no such alternative and is always module-generated. | [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#kubernetes-secret-references); [Capture the n8n encryption key](./post-deployment.md#capture-the-n8n-encryption-key) |
| Backup and restore | Configures native PostgreSQL Flexible Server backup retention and optional geo-redundancy (`pg_backup_retention_days`, `pg_geo_redundant_backup_enabled`). | Restore testing, cross-service disaster-recovery runbooks, and any backup for Redis or Blob data beyond Blob's own optional soft-delete are not provided — Azure Managed Redis has no module-level backup at all. Build a DR runbook around the managed services' native capabilities. | `pg_backup_retention_days`, `pg_geo_redundant_backup_enabled`; [`docs/deletion-safety.md`](./deletion-safety.md) |
| Upgrades and migration rollback | Supports bumping `n8n_image_tag` / `n8n_chart_version` on an existing deployment, with per-version upgrade notes. | Database migration rollback on a failed upgrade is not automatic — n8n's own migrations run forward-only, so a caller who needs to roll back a bad upgrade restores from a PostgreSQL backup taken before the upgrade. | [`docs/upgrading-n8n.md`](./upgrading-n8n.md) |
| Monitoring and alerting | Wires Prometheus metrics, OpenTelemetry, and log-streaming destinations when the caller configures them. | Container Insights / Azure Monitor managed Prometheus, alert rules, and dashboards are not created by the module. | [`docs/observability.md`](./observability.md) |
| Support boundary | Open source, maintained by the n8n Solutions team. | n8n's enterprise Support offering does not cover this module. | [Support](../README.md#support) |

This page does not repeat the full ownership contract for caller-managed
AKS, Blob storage, the namespace, Secrets, KEDA, or the webhook HPA — see
[`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md)
for those.
