# Observability

The module exposes n8n Prometheus metrics, OpenTelemetry tracing, and Enterprise log streaming. It does not install Prometheus, Grafana, an OpenTelemetry collector, a tracing backend, or a log receiver.

## Prometheus metrics

Set `n8n_metrics_enabled = true` to render `N8N_METRICS=true` on main, worker, and webhook processes. n8n serves `/metrics` on its existing port 5678.

The Helm chart does not create a ServiceMonitor. Configure scraping in the caller's monitoring stack. The main service is normally the useful scrape target for instance metrics, while process-specific collection may target individual pods.

When metrics are disabled, the module omits `N8N_METRICS` and leaves n8n's default behavior unchanged.

## OpenTelemetry tracing

Set `n8n_otel_enabled = true` and point `n8n_otel_exporter_otlp_endpoint` at an OTLP HTTP base URL. n8n appends `/v1/traces`, so do not include that path in the input.

```hcl
n8n_otel_enabled                = true
n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
n8n_otel_exporter_service_name = "n8n-production"
n8n_otel_traces_sample_rate    = 0.1
```

Optional controls set the OTLP headers, service name, sample rate, node spans, outbound W3C trace-context injection, and production-only filtering. Null values leave n8n's defaults in effect.

The module applies the same `N8N_OTEL_*` variables to main, worker, and webhook processes. This is required in queue mode so worker spans retain their parent context.

`n8n_otel_exporter_otlp_headers` is sensitive in Terraform. The value is still rendered as a literal environment variable, stored in Terraform state, and visible to principals that can inspect pod environments. Restrict access to state and the n8n namespace. Prefer a collector that accepts workload identity or network-level authentication when possible.

Supplying tuning inputs while `n8n_otel_enabled = false` emits a plan diagnostic and renders no OpenTelemetry environment variables.

## Enterprise log streaming

Set `n8n_log_streaming_managed_by_env = true` to manage destinations declaratively. n8n 2.19.0 or later is required. n8n reapplies the destination list at startup and makes the Log Streaming UI read-only.

The typed `n8n_log_streaming_destinations` input supports webhook, syslog, and Sentry destinations. Field names match n8n's environment-managed JSON schema.

```hcl
n8n_log_streaming_managed_by_env = true
n8n_log_streaming_destinations = [
  {
    type             = "webhook"
    label            = "Audit"
    enabled          = true
    subscribedEvents = ["n8n.audit", "n8n.workflow"]
    url              = "https://logs.example.com/n8n"
    method           = "POST"
    sendHeaders      = true
    specifyHeaders   = "keypair"
    headerParameters = {
      parameters = [
        { name = "Authorization", value = "Bearer replace-me" }
      ]
    }
    circuitBreaker = {
      maxFailures   = 5
      failureWindow = 60000
    }
  }
]
```

The module removes absent optional fields, JSON-encodes the destinations, and renders `N8N_LOG_STREAMING_MANAGED_BY_ENV=true` and `N8N_LOG_STREAMING_DESTINATIONS` on every n8n process.

The destination list is sensitive because webhook headers, syslog TLS material, and Sentry DSNs can contain credentials. The JSON still remains in Terraform state and pod environments. Store state securely and limit Kubernetes read access.

When environment management is false, no log-streaming environment variables are rendered and the UI remains authoritative. Supplying destinations while the switch is false emits a plan diagnostic.

## Redis queue metrics exporter

Set `redis_exporter_enabled = true` to create a single-replica [`oliver006/redis_exporter`](https://github.com/oliver006/redis_exporter) Deployment and an internal `ClusterIP` Service on port 9121 in the effective n8n namespace. This is independent of `n8n_metrics_enabled` and of n8n's own `/metrics` endpoint — n8n's built-in queue-depth gauge is not reliable in the multi-main topology every example ships, because only the leader main reports it.

The module installs no Prometheus, ServiceMonitor, or other monitoring backend. It publishes `prometheus.io/scrape`, `prometheus.io/port`, and `prometheus.io/path` pod annotations for a Prometheus that discovers scrape targets by annotation. A Prometheus Operator setup needs a caller-owned `ServiceMonitor` pointed at the `redis-exporter` Service instead.

```hcl
redis_exporter_enabled = true
# redis_exporter_image  = "oliver006/redis_exporter:v1.90.0"  # default; override for a mirror or digest
```

### Connection, authentication, and TLS

The exporter reads the same effective Redis connection n8n and KEDA use:

- **Address:** `rediss://<host>:<port>` when the effective connection uses TLS (always true for the module-managed Azure Managed Redis path; caller-controlled via `redis_external_tls_enabled` on the external path), otherwise `redis://<host>:<port>`. TLS certificate verification stays enabled — there is no server-name override or custom CA input in this port. For an external Redis endpoint, the hostname the exporter dials must be certificate-valid and its issuing CA must be trusted by the exporter's image (which ships the standard system CA bundle).
- **Username:** rendered only when the effective connection carries an ACL username, which only the external Redis path can supply (Azure Managed Redis access-key authentication has no username concept).
- **Password:** rendered as a Kubernetes Secret reference using the same Secret name and key n8n's `redis.passwordSecret` chart value already reads — the module-managed Redis Secret by default, or the caller's own Secret when `redis_password_secret_ref` is set. The module never reads a caller-managed Secret's payload, and creates no separate password Secret for the exporter.
- **Unauthenticated Redis:** when the effective connection has neither a username nor a password (an external endpoint relying on network isolation instead of `AUTH`), the exporter omits both authentication environment entries and uses `redis://`.

### Queue keys

The exporter uses `REDIS_EXPORTER_CHECK_SINGLE_KEYS` — an exact-key lookup, not a glob-pattern scan — against the same two Bull list keys (`bull:jobs:wait`, `bull:jobs:active`) the worker `ScaledObject` already triggers on, so the exporter's observed queue keys always equal KEDA's queue keys.

### Ownership and access

- The exporter targets the effective n8n namespace and AKS cluster (module-managed or caller-managed) without creating either layer.
- Any private-registry pull access for a custom `redis_exporter_image` is the caller's responsibility. The exporter does not receive the n8n Azure workload identity or any other Azure credential.
- The container runs as non-root UID 59000 with a read-only root filesystem, dropped Linux capabilities, no privilege escalation, a memory request/limit, a CPU request, and liveness/readiness probes against `/health`. A replacement image must work under UID 59000 and provide this Redis-independent health endpoint.

Both probes check the exporter HTTP process, not Redis availability. Scraping
still uses `/metrics`. Redis connect/read/write operations time out after 3
seconds so a stalled connection can report `redis_up 0` within Prometheus's
default 10-second scrape timeout. This is a per-operation timeout, not a
deadline for the whole scrape. Avoid concurrent scrapes and check scrape
duration before choosing a shorter Prometheus timeout.

### What this does not prove

A rendered `rediss://` address is not proof that the exporter can successfully authenticate, verify the certificate, or read the two queue keys against Azure Managed Redis or an external Redis endpoint's actual ACL/command permissions. Verify a live scrape (`redis_up` and the two `redis_key_size` series) manually after enabling this in a real deployment.
