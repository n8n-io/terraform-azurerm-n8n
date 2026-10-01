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
which documents the caller-managed *layers* (AKS, Blob, namespace, KEDA,
webhook HPA) this module can hand off entirely, and the per-value Kubernetes
Secret references that let a caller supply specific credentials instead of
letting the module generate them. Secret references cover selected values
only, not a full Secrets layer handoff: `kubernetes_secret.n8n_task_runners`
remains module-created in every mode. The rows below cover responsibilities
that exist regardless of which layer ownership mode is selected.

| Area | What the module does | What the caller owns | Related input / doc |
|---|---|---|---|
| Cluster security add-ons and policy | Creates the AKS cluster (or attaches to an existing one), its node pool(s), and an optional API-server IP allowlist. | Microsoft Defender for Containers, Azure Policy for Kubernetes, KMS etcd encryption, and any admission-control policy are not enabled by the module and must be turned on separately (e.g. via `az aks` / the `azurerm_kubernetes_cluster` resource outside this module, or a policy assignment against the resulting cluster). | `aks_api_authorized_ip_ranges`; [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#aks-cluster-create_aks) |
| Network egress and DNS | Uses caller-provided VNet/subnets; when `create_ingress = true`, creates an App Gateway with a public or internal frontend; when `create_database = true`, creates the PostgreSQL private DNS zone and VNet link; and when `create_ingress = true` and (`create_public_dns_record = true` or `create_private_dns_record = true`), creates an `azurerm_dns_a_record` (public) or `azurerm_private_dns_a_record` (private) for the n8n hostname in a caller-supplied DNS zone. | The DNS zone itself is always caller-owned; the module only creates the A record inside it, and only when `create_ingress = true` and the corresponding toggle is enabled. No record is created at all when `create_ingress = false`, even if a record toggle is left on. A record is caller-owned whenever `create_public_dns_record = false` (or `create_private_dns_record = false`). DNS resolution for an externally supplied PostgreSQL endpoint (`create_database = false`) is also always the caller's responsibility. No egress firewall, NAT gateway, or user-defined route is created — outbound traffic from the cluster is unrestricted unless the caller adds one. | `n8n_dns_config`, `create_public_dns_record`, `create_private_dns_record`; [Prerequisites](../README.md#prerequisites) |
| Secrets and Terraform state | Generates the PostgreSQL admin password when `create_database = true`, the n8n encryption key, and the task-runner token as Terraform-managed values, and can read Blob/OTLP/log-streaming/extra-env values from variables. | Every generated or caller-supplied value the module does not receive through a `*_secret_ref` lands in Terraform state on the default path: `random_password.postgres_admin`, `postgres_external_password` when `create_database = false` and `postgres_password_secret_ref` is unset, `n8n_encryption_key`, `n8n_license_key` when `n8n_license_key_secret_ref` is unset, `n8n_task_runners_token`, `redis_external_password` when `create_redis = false` and `redis_password_secret_ref` is unset, and the managed Redis primary access key when `create_redis = true`, plus whichever of `azure_blob_account_key`, `azure_blob_connection_string`, `n8n_otel_exporter_otlp_headers`, `n8n_log_streaming_destinations`, and `n8n_extra_env` the caller sets. `n8n_image_pull_secrets` entries are stored in state as part of the module-managed ServiceAccount object (their Secret names, never the registry credentials inside those Secrets). Securing the Terraform state backend (encryption at rest, restricted access) is the caller's responsibility in every mode. Route the license key, encryption key, credentials-overwrite payload, external PostgreSQL password, and Redis password through `n8n_license_key_secret_ref`, `n8n_encryption_key_secret_ref`, `n8n_credentials_overwrite_secret_ref`, `postgres_password_secret_ref` (external database path only), and `redis_password_secret_ref` (external Redis path only, `create_redis = false` — the module-managed Azure Managed Redis instance always uses its own generated access key) to keep those specific values out of state; the task-runner token has no such alternative and is always module-generated. | [`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md#kubernetes-secret-references); [Capture the n8n encryption key](./post-deployment.md#capture-the-n8n-encryption-key) |
| Backup and restore | Configures native PostgreSQL Flexible Server backup retention and optional geo-redundancy (`pg_backup_retention_days`, `pg_geo_redundant_backup_enabled`). | Restore testing, cross-service disaster-recovery runbooks, and any backup for Redis or Blob data beyond Blob's own optional soft-delete are not provided — Azure Managed Redis has no module-level backup at all. Build a DR runbook around the managed services' native capabilities. | `pg_backup_retention_days`, `pg_geo_redundant_backup_enabled`; [`docs/deletion-safety.md`](./deletion-safety.md) |
| Upgrades and migration rollback | Supports bumping `n8n_image_tag` / `n8n_chart_version` on an existing deployment, with per-version upgrade notes. | Database migration rollback on a failed upgrade is not automatic — n8n's own migrations run forward-only, so a caller who needs to roll back a bad upgrade restores from a PostgreSQL backup taken before the upgrade. | [`docs/upgrading-n8n.md`](./upgrading-n8n.md) |
| Monitoring and alerting | Wires Prometheus metrics, OpenTelemetry, and log-streaming destinations when the caller configures them. | Container Insights / Azure Monitor managed Prometheus, alert rules, and dashboards are not created by the module. | [`docs/observability.md`](./observability.md) |
| Support boundary | Open source, maintained by the n8n Solutions team. | n8n's enterprise Support offering does not cover this module. | [Support](../README.md#support) |

This page does not repeat the full ownership contract for caller-managed
AKS, Blob storage, the namespace, KEDA, or the webhook HPA, or the per-value
Kubernetes Secret reference contract, see
[`docs/customer-managed-infrastructure.md`](./customer-managed-infrastructure.md)
for those.
