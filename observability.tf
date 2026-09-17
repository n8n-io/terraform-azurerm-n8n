# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Redis exporter (opt-in) ────────────────────────────────────────────────
# Bull queue depth is the signal KEDA scales workers on, and it is the first
# thing anyone asks for during an incident. n8n's own /metrics does expose a
# queue gauge, but it is not reliable in multi-main topologies — every
# example this module ships — because only the leader main reports, so the
# figure is wrong rather than missing. Redis itself is the source of truth,
# and this exporter is the supported way to read it from inside the cluster
# (queue depth, plus standard Redis engine/connection metrics).
#
# Off by default: redis_exporter_enabled = false creates neither resource.
# This is a plain Deployment/Service pair rather than anything the n8n chart
# renders — the chart has no exporter of its own to enable.
#
# The exporter reads the same effective Redis connection and the same
# password reference n8n and KEDA use (local.redis_connection,
# local.redis_password_secret_name/_key, redis.tf), so it cannot end up
# pointed at a different queue than the one n8n is actually running on. It
# does not scrape anything; a Prometheus that already discovers pods by
# annotation picks it up from the pod annotations below, and a Prometheus
# Operator setup points a caller-owned ServiceMonitor at the Service. Neither
# is installed by this module.
locals {
  # rediss:// when the effective endpoint speaks TLS — the same
  # local.redis_connection.tls_enabled value n8n and KEDA read, so the
  # exporter cannot end up with a different view of the endpoint's TLS
  # requirement than the workloads have. TLS certificate verification is
  # left enabled; no custom server-name or CA override is exposed here.
  redis_exporter_addr = "${local.redis_connection.tls_enabled ? "rediss" : "redis"}://${local.redis_connection.host}:${local.redis_connection.port}"

  # Exact-key lookup (not a glob pattern scan) of the same two Bull lists
  # KEDA's worker ScaledObject already triggers on (local.n8n_bull_queue_keys,
  # locals.tf), so the exporter's observed queue keys equal KEDA's queue keys
  # by construction. Database 0 is the only queue namespace this module uses.
  redis_exporter_check_single_keys = join(",", [for key in local.n8n_bull_queue_keys : "db0=${key}"])
}

resource "kubernetes_deployment_v1" "redis_exporter" {
  count = var.redis_exporter_enabled ? 1 : 0

  metadata {
    name      = "redis-exporter"
    namespace = local.n8n_namespace
    labels = {
      "app"                          = "redis-exporter"
      "app.kubernetes.io/name"       = "redis-exporter"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/part-of"    = "n8n"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    # One replica deliberately: two would double every counter a naive
    # Prometheus query sums, and there is nothing to fail over to — the
    # exporter holds no state and a restart re-reads Redis from scratch.
    replicas = 1

    # Recreate rather than the RollingUpdate default, for the same reason: a
    # rolling update would briefly run the old and new pod side by side
    # behind the same annotations and Service, double-counting for one
    # scrape interval during an image bump.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { "app" = "redis-exporter" }
    }

    template {
      metadata {
        labels = { "app" = "redis-exporter" }

        # Annotation-based scrape convention. Harmless when the cluster's
        # Prometheus uses ServiceMonitors instead — nothing reads them.
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9121"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        container {
          name  = "redis-exporter"
          image = var.redis_exporter_image

          env {
            name  = "REDIS_ADDR"
            value = local.redis_exporter_addr
          }

          env {
            name  = "REDIS_EXPORTER_CHECK_SINGLE_KEYS"
            value = local.redis_exporter_check_single_keys
          }

          # Bound Redis I/O below Prometheus's default 10s scrape timeout.
          # Probes use /health so a stalled scrape cannot restart the exporter.
          env {
            name  = "REDIS_EXPORTER_CONNECTION_TIMEOUT"
            value = "3s"
          }

          # ACL username. Only present on the external Redis path — Azure
          # Managed Redis access-key authentication has no username concept
          # (redis.tf). Not a credential, so it is a literal env value
          # rather than a Secret reference, matching redis.username in the
          # chart's own Helm values (n8n.tf).
          dynamic "env" {
            for_each = local.redis_username_present ? [1] : []
            content {
              name  = "REDIS_USER"
              value = local.redis_connection.username
            }
          }

          # References the same Secret name/key n8n's redis.passwordSecret
          # block reads (local.redis_password_secret_name/_key, locals.tf):
          # the module-managed kubernetes_secret.n8n_redis by default, or the
          # caller's own Secret when redis_password_secret_ref selects one.
          # Never reads a caller-managed Secret's payload.
          dynamic "env" {
            for_each = local.redis_password_present ? [1] : []
            content {
              name = "REDIS_PASSWORD"
              value_from {
                secret_key_ref {
                  name = local.redis_password_secret_name
                  key  = local.redis_password_secret_key
                }
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 9121
          }

          # The exporter holds no state and does no work between scrapes, so
          # these are deliberately small. Memory is capped but CPU is not: a
          # throttled exporter reports late during exactly the incident it
          # exists for, and one pod without a CPU limit cannot starve a node.
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          # /health checks the HTTP process without contacting Redis or
          # waiting on the scrape mutex. A Redis outage must not remove the
          # exporter from Service endpoints or trigger container restarts.
          liveness_probe {
            http_get {
              path = "/health"
              port = 9121
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 9121
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            # 59000 is the UID the upstream image already declares (USER
            # 59000:59000 in its Dockerfile) — this pins it rather than
            # overriding it, so a caller-supplied redis_exporter_image must
            # work as that UID.
            run_as_user = 59000
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  # Namespace and AKS API warm-up edges even when create_namespace = false —
  # kubernetes_namespace.n8n resolves to no instance in that mode and carries
  # no ordering edge on its own (design.md decision 1). Also depends on the
  # module-managed Redis Secret (when it exists) and the private endpoint on
  # the module-managed Redis path, preserving the same first-apply ordering
  # n8n's own kubernetes_secret.n8n_redis and helm_release.n8n rely on.
  depends_on = [
    kubernetes_namespace.n8n,
    time_sleep.aks_api_warmup,
    kubernetes_secret.n8n_redis,
    azurerm_private_endpoint.redis,
  ]
}

resource "kubernetes_service_v1" "redis_exporter" {
  count = var.redis_exporter_enabled ? 1 : 0

  metadata {
    name      = "redis-exporter"
    namespace = local.n8n_namespace
    labels = {
      "app"                          = "redis-exporter"
      "app.kubernetes.io/name"       = "redis-exporter"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/part-of"    = "n8n"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = { "app" = "redis-exporter" }

    port {
      name        = "metrics"
      port        = 9121
      target_port = 9121
      protocol    = "TCP"
    }
  }

  # Same reasoning as the Deployment above.
  depends_on = [
    kubernetes_namespace.n8n,
    time_sleep.aks_api_warmup,
    kubernetes_secret.n8n_redis,
    azurerm_private_endpoint.redis,
  ]
}
