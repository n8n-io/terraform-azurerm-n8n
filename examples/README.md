# Deployment examples

The sizing examples use the same single root module and differ only where workload scale changes an Azure or n8n decision.

| Decision | Small | Medium | Large |
|---|---|---|---|
| Intended use | Evaluation and low traffic | Sustained production traffic | High-volume, connection-heavy production |
| AKS VM | `Standard_D2s_v5` | `Standard_D8s_v5` | `Standard_D16s_v5` |
| Nodes per pool | 2 to 6 | 3 to 10 | 5 to 20 |
| Main replicas | 2 to 6 | 3 to 16 | 6 to 60 |
| Webhook replicas | 2 to 8 | 4 to 24 | 20 to 80 |
| Worker replicas | 1 to 10 | 4 to 30 | 20 to 160 |
| PostgreSQL | GP D2s, 32 GB | GP D4s, 128 GB | GP D8s, 512 GB, zone redundant |
| Redis | Balanced B0 | Balanced B5 | Memory Optimized M20, HA |
| Blob durability | LRS | ZRS | ZRS |
| Database pooler | None | None | PgBouncer, 2 replicas |
| Main cost factors | Baseline AKS, WAF, PostgreSQL, and Redis charges | Higher warm node floor, larger data services, ZRS, gateway autoscaling | Large warm floor, PostgreSQL HA and geo-backups, Redis HA, replicated storage, gateway autoscaling |

These tiers are reference configurations, not throughput or cost guarantees. Workflow shape, payload size, Code nodes, external API latency, retention, and execution-data mode can change demand by orders of magnitude. Run load tests with representative workflows and review the root module's advisory capacity diagnostic.

`small`, `medium`, and `large` issue self-signed certificates only, to keep the Azure Key Vault certificate path runnable without another DNS provider. Replace them with publicly trusted certificates before exposing production traffic. Azure SKU and zone availability varies by region. Check current availability and pricing before apply.

## Topology examples

These examples are small-sized and each focuses on a single decision instead of workload scale:

| Example | What it demonstrates |
|---|---|
| [`split-ingress`](./split-ingress/) | Two Application Gateways instead of one: a public gateway that serves only webhook traffic, and a private gateway that serves the editor UI and everything else, each with its own standalone AGIC install. |

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
