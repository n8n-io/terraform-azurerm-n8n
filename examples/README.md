# Deployment examples

The sizing examples use the same single root module and differ only where workload scale changes an Azure or n8n decision.

| Decision | Small | Medium | Large |
|---|---|---|---|
| Intended use | Evaluation and low traffic | Sustained production traffic | High-volume, connection-heavy production |
| AKS VM | `Standard_D2s_v5` | `Standard_D8s_v5` | `Standard_D16s_v5` |
| Nodes per pool | 2 to 6 | 3 to 10 | 5 to 20 |
| AKS SKU tier | Free (no API server SLA) | Standard (financially backed API server SLA) | Standard (financially backed API server SLA) |
| Main replicas | 2 to 6 | 3 to 16 | 6 to 60 |
| Webhook replicas | 2 to 8 | 4 to 24 | 20 to 80 |
| Worker replicas | 1 to 10 | 4 to 30 | 20 to 160 |
| PostgreSQL | GP D2s, 32 GB | GP D4s, 128 GB | GP D8s, 512 GB, zone redundant |
| Redis | Balanced B0 | Balanced B5 | Memory Optimized M20, HA |
| Blob durability | LRS | ZRS | ZRS |
| Database pooler | None | None | PgBouncer, 2 replicas |
| Main cost factors | Baseline AKS, WAF, PostgreSQL, and Redis charges | Higher warm node floor, AKS Standard tier, larger data services, ZRS, gateway autoscaling | Large warm floor, AKS Standard tier, PostgreSQL HA and geo-backups, Redis HA, replicated storage, gateway autoscaling |

These tiers are reference configurations, not throughput or cost guarantees. Workflow shape, payload size, Code nodes, external API latency, retention, and execution-data mode can change demand by orders of magnitude. Run load tests with representative workflows and review the root module's advisory capacity diagnostic.

`small`, `medium`, and `large` issue self-signed certificates only, to keep the Azure Key Vault certificate path runnable without another DNS provider. Replace them with publicly trusted certificates before exposing production traffic. Azure SKU and zone availability varies by region. Check current availability and pricing before apply.

## Main topology selection is separate from feature entitlements

All eight examples in this directory — the three sizing tiers, `split-ingress`, and the four customer-managed examples — expose `n8n_main_hpa_min_replicas`, a passthrough to the root module's own variable of the same name. It defaults to each example's documented floor (2, except medium's 3 and large's 6) and is the only topology selector: setting it to 1 requests single-main queue mode, which works with a license that lacks `feat:multipleMainInstances` (including Business licenses). Selecting a floor of 1 does not change any other example decision — sizing, storage mode, ingress, or Redis/PostgreSQL topology stay exactly as documented above and in the customer-managed table below.

Main-floor selection and Azure storage entitlements are independent. A license without `feat:multipleMainInstances` does not automatically gain `feat:binaryDataAz` or `feat:executionDataAz`. A new Business-tier deployment without those entitlements should set the root module's `n8n_binary_data_storage_mode`/`n8n_execution_data_storage_mode` to `database`, independent of whatever main floor it selects. An existing deployment moving off Azure must set `azure_blob_retain_read_access = true` until its retained objects are addressed.

## Topology examples

These examples are small-sized and each focuses on a single decision instead of workload scale:

| Example | What it demonstrates |
|---|---|
| [`split-ingress`](./split-ingress/) | Two Application Gateways instead of one: a public gateway that serves only webhook traffic, and a private gateway that serves the editor UI and everything else, each with its own standalone AGIC install. |
| [`worker-pools`](./worker-pools/) | Three labelled `n8n_worker_pools` beside the default worker deployment, each with its own KEDA scaler on its own `jobs-<name>` queue. Requires a chart that renders `queueMode.workerGroups` and n8n `2.39.0`+; see the module root README's ["Worker pools (early alpha)"](../README.md#worker-pools-early-alpha) section. Early alpha, subject to change without notice. |

## Customer-managed infrastructure examples

Four further examples each demonstrate one or more ownership boundaries the `customer-managed-infrastructure` capability supports — deploying onto Azure and Kubernetes infrastructure the module does not create or manage. See `docs/customer-managed-infrastructure.md` in the module root for the full ownership convention these examples exercise.

| Example | Ownership boundary |
|---|---|
| [`customer-managed-cluster`](./customer-managed-cluster/) | Existing AKS cluster (`create_aks = false`), with caller-owned ingress since the module cannot manage AGIC on a cluster it does not own. PostgreSQL, Redis, and Blob storage remain module-managed. |
| [`customer-managed-redis`](./customer-managed-redis/) | External Redis endpoint (`create_redis = false`) and a caller-managed Kubernetes Secret for its password. AKS, PostgreSQL, Blob storage, and ingress remain module-managed. |
| [`customer-managed-storage`](./customer-managed-storage/) | Existing private Blob storage account and container (`create_blob_storage = false`), with the module still granting its own workload identity access to the supplied container. AKS, PostgreSQL, Redis, and ingress remain module-managed. |
| [`customer-managed-everything`](./customer-managed-everything/) | Every boundary at once: existing AKS, external PostgreSQL and Redis, existing Blob storage, an existing namespace and Secrets, a direct `modules/controllers` composition, caller-owned ingress, and a caller-owned webhook HPA. |

For a publicly trusted certificate validated against a non-Azure DNS provider
(Cloudflare, GoDaddy, etc.) instead of the self-signed certificates these
examples issue, see the ["DNS-01 providers"
section](../modules/tls-letsencrypt/README.md#dns-01-providers) of
`modules/tls-letsencrypt/README.md`.
