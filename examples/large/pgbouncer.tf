# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# PgBouncer multiplexes the client pools from high n8n replica ceilings onto
# fewer PostgreSQL server connections. Required anti-affinity and a disruption
# budget prevent one node drain from removing both poolers.
resource "kubernetes_namespace" "pgbouncer" {
  metadata {
    name = "pgbouncer"
  }
}

resource "kubernetes_secret" "pgbouncer" {
  metadata {
    name      = "pgbouncer-secret"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  data = {
    DB_PASSWORD = random_password.postgres.result
  }
}

resource "kubernetes_deployment" "pgbouncer" {
  # checkov:skip=CKV_K8S_22:The image entrypoint writes generated configuration into its filesystem. Verify writable paths before enforcing a read-only root filesystem.
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
    labels    = { app = "pgbouncer" }
  }

  spec {
    replicas = local.tier.pgbouncer_replicas

    selector {
      match_labels = { app = "pgbouncer" }
    }

    template {
      metadata {
        labels = { app = "pgbouncer" }
      }

      spec {
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_labels = { app = "pgbouncer" }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "pgbouncer"
          image = "edoburu/pgbouncer:v1.23.1-p3@sha256:377dec3c0e4a66a1077ec043e16a26ed5702a6d954011a7983a1457c2e070b1d"

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "512Mi"
            }
          }

          port {
            container_port = 5432
            protocol       = "TCP"
          }

          env {
            name  = "DB_HOST"
            value = azurerm_postgresql_flexible_server.n8n.fqdn
          }
          env {
            name  = "DB_USER"
            value = azurerm_postgresql_flexible_server.n8n.administrator_login
          }
          env {
            name  = "DB_NAME"
            value = azurerm_postgresql_flexible_server_database.n8n.name
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.pgbouncer.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }
          env {
            name  = "AUTH_TYPE"
            value = "plain"
          }
          env {
            name  = "POOL_MODE"
            value = "transaction"
          }
          env {
            name  = "DEFAULT_POOL_SIZE"
            value = "150"
          }
          env {
            name  = "MAX_CLIENT_CONN"
            value = "3000"
          }
          env {
            name  = "SERVER_IDLE_TIMEOUT"
            value = "300"
          }
          env {
            name  = "SERVER_TLS_SSLMODE"
            value = "require"
          }
          env {
            name  = "IGNORE_STARTUP_PARAMETERS"
            value = "statement_timeout,extra_float_digits"
          }

          readiness_probe {
            tcp_socket {
              port = "5432"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = "5432"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  spec {
    min_available = 1

    selector {
      match_labels = { app = "pgbouncer" }
    }
  }
}

resource "kubernetes_service" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace.pgbouncer.metadata[0].name
  }

  spec {
    selector = { app = "pgbouncer" }

    port {
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
