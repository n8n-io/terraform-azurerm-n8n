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
