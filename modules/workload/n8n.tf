# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── n8n workload (namespace + secrets + Helm release + Ingress) ───────────────
# Phase 5 R5.2c (registry-hardening US-023). Moves the chart-side n8n stack
# from the root module's `n8n.tf` into this submodule. Owns:
#
#   - `kubernetes_namespace.n8n`               name from `local.n8n_namespace`
#                                              (locals.tf, US-008). Every
#                                              cross-file namespace reference
#                                              (the kubectl_manifest
#                                              TriggerAuthentication body in
#                                              keda.tf, the webhook-processor
#                                              HPA's metadata.namespace in
#                                              scaling.tf) reads this local —
#                                              renaming the namespace is a
#                                              single-local edit.
#   - 4 `kubernetes_secret` resources         DB password, Redis access key,
#                                              n8n license key, n8n encryption
#                                              key (chart-rendered via
#                                              `passwordSecret` / `secretRefs`
#                                              mechanisms).
#   - `kubernetes_secret.n8n_files_credentials` storage account name + key for
#                                               the in-tree `azure_file` PV
#                                               driver.
#   - Static `kubernetes_persistent_volume_v1` +
#     `kubernetes_persistent_volume_claim_v1` pair bound to the pre-existing
#     Azure Files share (provided via `var.storage_share_name`). RWX so all
#     n8n pods (main, workers, webhook processors) see the same files.
#   - `helm_release.n8n`                       multi-main + queue mode +
#                                              webhook-processor isolation.
#                                              Chart pinned via
#                                              `var.n8n_chart_version`.
#   - `time_sleep.n8n_helm_settle`             post-install settle window —
#                                              gates `kubernetes_ingress_v1.n8n`
#                                              so AGIC reconciles against a
#                                              fully-converged deployment.
#                                              Replaces the legacy
#                                              `null_resource.post_deploy_restart`
#                                              (registry-hardening US-002).
#   - `kubernetes_ingress_v1.n8n`              AGIC-managed Ingress; webhook
#                                              traffic routes to
#                                              n8n-webhook-processor, all
#                                              other paths to n8n-main.
#                                              Cookie-based session affinity
#                                              pins each browser to a single
#                                              main pod (WebSocket
#                                              stickiness).
#
# Federated identity credential note: the matching `azurerm_federated_identity_credential.n8n_workload`
# resource that binds the chart-rendered `n8n-enterprise` ServiceAccount to
# the `n8n_workload` UAMI lives in `modules/infra/iam.tf` rather than in this
# submodule. This deviates from the literal text of US-023's AC ("moved into
# modules/workload/iam.tf") to preserve the chart-only consumer posture
# documented in `modules/workload/AGENTS.md` ("Don't add an `azurerm`
# provider here") and the five-provider count
# (`kubernetes` / `helm` / `random` / `time` / `kubectl`) declared in
# `versions.tf`. The credential's only Kubernetes-side metadata is two
# literal strings (the namespace and the chart-rendered SA name), neither
# of which is an actual cross-tier resource reference, so `modules/infra/`
# can host it without a graph contortion. The literals must stay in lockstep
# with `local.n8n_namespace = "n8n"` here and the n8n Helm chart's hardcoded
# `n8n-enterprise` SA name. See `modules/infra/iam.tf` for the matching
# resource and the cross-reference comment.
#
# Azure-specific deltas vs the AWS sibling's chart-side n8n.tf:
#   - Database SSL with `rejectUnauthorized = false`: Azure provisions
#     Postgres Flexible Server with a CA the n8n container's trust store
#     does not include; SSL is required (Azure enforces it) but cert
#     verification is disabled inside the VNet.
#   - Redis on TLS port 6380 (NOT 6379): Azure Cache for Redis exposes 6380
#     for TLS only; `non_ssl_port_enabled = false` is hardcoded in
#     `modules/infra/redis.tf`.
#   - `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS = "false"`: Azure Files mounts
#     via CIFS, which does not support chmod — n8n's settings-file
#     permission check would fail on every startup otherwise.
#   - `persistence.existingClaim` instead of dynamic provisioning: the
#     infra submodule pre-creates the storage account + share and the
#     workload submodule binds them statically here so the share's lifecycle
#     stays under Terraform control (rather than being managed by the
#     chart's PVC, which would create a SECOND ad-hoc storage account).

# ── Encryption key ───────────────────────────────────────────────────────────
# n8n uses this key to encrypt credentials in the database. All main pods
# need the same value, so it lives in a Kubernetes Secret rather than per-pod
# state. `random_password` (not `random_id`) mirrors the prototype's choice
# and keeps the value rotatable via taint without re-generating the whole
# module.
resource "random_password" "n8n_encryption_key" {
  length           = 48
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Task-runner shared auth token ────────────────────────────────────────────────
# Shared secret the chart-rendered task-runner sidecar (`taskRunners.
# enabled = true` in the helm values below) uses to authenticate against
# the n8n main process's task broker. Special chars are excluded so the
# value travels through env vars + JSON without escaping concerns;
# 48 bytes of base62 entropy (`random_password length = 48 special =
# false`) matches the n8n docs' guidance of "random secure shared secret".
# The matching `kubernetes_secret.n8n_task_runners` below holds the
# value; the chart's `taskRunners.authToken.existingSecret` /
# `existingSecretKey` values bind to it.
resource "random_password" "n8n_task_runners_token" {
  length  = 48
  special = false
}

# ── Namespace ────────────────────────────────────────────────────────────────
# Name comes from `local.n8n_namespace` (locals.tf) — single source of truth
# for every cross-file namespace reference (the kubectl_manifest
# TriggerAuthentication in keda.tf, the webhook-processor HPA's
# metadata.namespace in scaling.tf, the federated-identity-credential
# subject in modules/infra/iam.tf). The 5 m delete timeout matches the keda
# namespace in controllers.tf and the AWS sibling — namespaces with stuck
# finalizers can hang `terraform destroy` indefinitely otherwise.
resource "kubernetes_namespace" "n8n" {
  metadata {
    name = local.n8n_namespace
  }

  timeouts {
    delete = "5m"
  }
}

# ── Secrets ──────────────────────────────────────────────────────────────────
# Four chart-consumed secrets. DB and Redis passwords are referenced by the
# n8n Helm chart's `database.passwordSecret` / `redis.passwordSecret`
# mechanisms; license + encryption keys are mounted as env vars via
# `secretRefs.existingSecret`.

resource "kubernetes_secret" "n8n_db" {
  metadata {
    name      = "n8n-db-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    password = var.postgres_admin_password
  }
}

# Name MUST be `local.n8n_redis_secret_name` ("n8n-redis-secret") — keda.tf
# (US-022) references this name via the same local in the
# TriggerAuthentication YAML body, so changing the secret name without
# updating the local breaks KEDA's queue-depth scaling silently (KEDA's
# `secretTargetRef` would resolve to nothing).
resource "kubernetes_secret" "n8n_redis" {
  metadata {
    name      = local.n8n_redis_secret_name
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    password = var.redis_primary_access_key
  }
}

resource "kubernetes_secret" "n8n_license" {
  metadata {
    name      = "n8n-license-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    activationKey = var.n8n_license_key
  }
}

# Holds the four core n8n secrets the chart's `n8n.coreSecretsEnv` template
# reads via `secretKeyRef` when `secretRefs.existingSecret` is set:
#   - N8N_ENCRYPTION_KEY — the rotation-sensitive bit; rest are non-secret
#     but the chart routes them through the same Secret to keep its env
#     wiring uniform (see `templates/_environment-helpers.tpl` in the
#     pinned chart). Missing any of the four keys causes pods to crash
#     at startup with `couldn't find key <X> in Secret n8n/<name>`. Only
#     N8N_ENCRYPTION_KEY actually needs to be a secret; the other three
#     are functional config kept here so the chart's existingSecret
#     contract stays satisfied without the operator having to provision
#     a parallel ConfigMap-style override.
resource "kubernetes_secret" "n8n_encryption_key" {
  metadata {
    name      = "n8n-encryption-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    N8N_ENCRYPTION_KEY = random_password.n8n_encryption_key.result
    N8N_HOST           = var.n8n_domain
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = "https"
  }
}

# Holds the task-runner shared auth token. Created unconditionally (rather
# than count-gated on `var.n8n_task_runners_enabled`) so toggling the
# feature on/off doesn't trigger a chart-redeploy as the only resource-
# graph change — the chart values branch on the var; a dormant secret is
# a one-key, gitignored-equivalent footprint. Matches the pattern of the
# n8n_license secret above (created for future external-rotation tooling
# even though the chart references it inline today).
resource "kubernetes_secret" "n8n_task_runners" {
  metadata {
    name      = local.n8n_task_runners_secret_name
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    N8N_RUNNERS_AUTH_TOKEN = random_password.n8n_task_runners_token.result
  }
}

# ── Azure Files static PV/PVC ────────────────────────────────────────────────
# Binds the pre-created Azure Files share (`modules/infra/storage.tf`) into
# the cluster as a ReadWriteMany volume. The in-tree `azure_file` PV driver
# needs a Kubernetes Secret holding the storage account name + key; the
# Secret lives in the same namespace as the PVC.
#
# Why static PV/PVC instead of dynamic provisioning via the `azurefile-csi`
# storage class (which is what the AKS prototype does): the infra submodule
# pre-creates `azurerm_storage_account.n8n` + `azurerm_storage_share.n8n_binary`
# (US-018) so the share's lifecycle (tags, network rules, future CMK
# wiring) stays under Terraform control. With dynamic provisioning the
# chart's PVC would create a SECOND, ad-hoc storage account on the fly —
# the pre-created share would sit unused and Terraform would have no
# visibility into the share that actually backs the data. The static PV
# binding is the bridge between the Terraform-owned storage and the
# chart-mounted PVC.

resource "kubernetes_secret" "n8n_files_credentials" {
  metadata {
    name      = "n8n-azurefiles-credentials"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  type = "Opaque"

  data = {
    azurestorageaccountname = var.storage_account_name
    azurestorageaccountkey  = var.storage_account_primary_access_key
  }
}

# `storage_class_name` is a literal sentinel `n8n-azurefile-static` on both
# this PV and the matching PVC below. Empty-string is the canonical k8s
# pattern for "no class" but the AKS DefaultStorageClass admission
# controller mutates an empty `storageClassName` on a NEW PVC into
# `"default"` (which doesn't match this empty-class PV), and the PVC
# stays Pending forever with
#   Warning  VolumeMismatch  ... Cannot bind to requested volume
#   "<friendly_name_prefix>-n8n-files": storageClassName does not match
# A literal non-empty class name on BOTH sides bypasses the mutation
# and forces explicit static binding via `volume_name` on the PVC.
resource "kubernetes_persistent_volume_v1" "n8n_files" {
  metadata {
    name = "${var.friendly_name_prefix}-n8n-files"
  }

  spec {
    capacity = {
      storage = "${var.storage_share_quota_gb}Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "n8n-azurefile-static"

    persistent_volume_source {
      azure_file {
        secret_name      = kubernetes_secret.n8n_files_credentials.metadata[0].name
        secret_namespace = kubernetes_namespace.n8n.metadata[0].name
        share_name       = var.storage_share_name
        read_only        = false
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "n8n_files" {
  metadata {
    name      = "n8n-binary-data"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "n8n-azurefile-static"
    volume_name        = kubernetes_persistent_volume_v1.n8n_files.metadata[0].name

    resources {
      requests = {
        storage = "${var.storage_share_quota_gb}Gi"
      }
    }
  }
}

# ── Helm release ─────────────────────────────────────────────────────────────
# n8n Enterprise multi-main topology. Uses the n8n-io OCI Helm chart at
# `oci://ghcr.io/n8n-io/n8n-helm-chart` — same chart as the AKS prototype
# and the AWS sibling. The chart's Redis-based leader election
# (`multiMain.setup`) plus this release running with
# `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true`
# absorb the multi-main migration race natively (registry-hardening US-002
# retired the legacy `null_resource.post_deploy_restart` workaround on this
# basis): only the elected leader runs migrations; followers wait; helm
# waits for `replicas == readyReplicas` before returning.
resource "helm_release" "n8n" {
  name            = "n8n"
  repository      = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  chart           = "n8n"
  version         = var.n8n_chart_version
  namespace       = kubernetes_namespace.n8n.metadata[0].name
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    license = {
      enabled       = true
      activationKey = var.n8n_license_key
    }

    multiMain = {
      enabled  = true
      replicas = var.n8n_main_replicas
      antiAffinity = {
        type = "preferred"
      }
    }

    queueMode = {
      enabled = true
    }

    webhookProcessor = {
      enabled                                = true
      replicaCount                           = 2
      disableProductionWebhooksOnMainProcess = true
    }

    # ── Database: Azure PostgreSQL Flexible Server ────────────────────────
    # SSL is required by Azure but `rejectUnauthorized = false` because the
    # Azure CA certificate is not in the n8n container's trust store. Inside
    # the VNet this is acceptable — the connection is private-only.
    database = {
      type        = "postgresdb"
      useExternal = true
      host        = var.postgres_fqdn
      port        = 5432
      database    = var.postgres_database_name
      schema      = "public"
      user        = var.postgres_admin_username
      ssl = {
        enabled            = true
        rejectUnauthorized = false
      }
      passwordSecret = {
        name = kubernetes_secret.n8n_db.metadata[0].name
        key  = "password"
      }
    }

    # ── Redis: Azure Cache for Redis ──────────────────────────────────────
    # Azure Redis exposes port 6380 for TLS only; `non_ssl_port_enabled` is
    # hardcoded false in modules/infra/redis.tf (US-017). Access key auth
    # via the n8n_redis Kubernetes Secret (also referenced by KEDA's
    # TriggerAuthentication in keda.tf, US-022).
    redis = {
      enabled     = true
      useExternal = true
      host        = var.redis_hostname
      port        = var.redis_ssl_port
      tls         = true
      passwordSecret = {
        name = kubernetes_secret.n8n_redis.metadata[0].name
        key  = "password"
      }
    }

    # ── Persistence: Azure Files PVC ──────────────────────────────────────
    # Bound to the pre-created storage_share via the static PV above.
    persistence = {
      enabled       = true
      existingClaim = kubernetes_persistent_volume_claim_v1.n8n_files.metadata[0].name
    }

    # ── Service account + workload identity ───────────────────────────────
    # The chart-created service account is annotated with the n8n_workload
    # UAMI's client_id; combined with `azure.workload.identity/use = "true"`
    # on the pod template (chart-default when workload identity is on) and
    # the AKS cluster's `workload_identity_enabled = true` setting
    # (modules/infra/aks.tf), n8n pods receive a federated token from
    # Azure AD without static credentials. The matching
    # `azurerm_federated_identity_credential.n8n_workload` resource lives
    # in modules/infra/iam.tf and binds this exact SA name to the n8n_workload
    # UAMI — see the comment block at the top of this file for why the
    # credential lives in the IaaS submodule rather than alongside the
    # chart-side resources here.
    serviceAccount = {
      create = true
      name   = "n8n-enterprise"
      annotations = {
        "azure.workload.identity/client-id" = var.n8n_workload_uami_client_id
      }
    }

    # ── Env from secrets ──────────────────────────────────────────────────
    # `secretRefs` mounts the n8n-encryption-secret as env (provides
    # `N8N_ENCRYPTION_KEY`). The license key is mounted inline above; the
    # n8n_license secret is created for future external-rotation tooling
    # but is not referenced by the chart today.
    secretRefs = {
      existingSecret = kubernetes_secret.n8n_encryption_key.metadata[0].name
    }

    service = {
      type = "ClusterIP"
      port = 5678
    }

    # ── Extra environment variables ───────────────────────────────────────
    # `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS = "false"` — Azure Files
    # mounts via CIFS, which does not support chmod. n8n's permission check
    # would fail on every startup if left enabled.
    config = {
      timezone = "UTC"
      extraEnv = [
        { name = "N8N_LOG_LEVEL", value = "info" },
        { name = "N8N_LOG_OUTPUT", value = "json" },
        { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "false" },
        { name = "WEBHOOK_URL", value = "https://${var.n8n_domain}" },
        # N8N_HOST / N8N_PORT / N8N_PROTOCOL are provided through the
        # chart's `n8n.coreSecretsEnv` template (sourced from
        # `kubernetes_secret.n8n_encryption_key`) when
        # `secretRefs.existingSecret` is set — putting them here too
        # would render them twice in the Pod spec.
      ]
    }

    pdb = {
      enabled      = true
      minAvailable = 1
    }

    # ── Task-runner sidecar ───────────────────────────────────────────────
    # Adds an `n8nio/runners` sidecar to main + worker pods that runs
    # user-supplied Code-node JS / Python code in an isolated process.
    # The chart auto-derives the runner image tag from the n8n image
    # tag (chart default `tag: ""`), so no separate version pin is
    # needed here. `nativePythonRunner = true` is a chart default at
    # this version; pinning it explicitly keeps the contract obvious
    # and survives a chart-default flip on upgrade.
    taskRunners = {
      enabled            = var.n8n_task_runners_enabled
      mode               = "external"
      nativePythonRunner = true
      authToken = {
        existingSecret    = kubernetes_secret.n8n_task_runners.metadata[0].name
        existingSecretKey = "N8N_RUNNERS_AUTH_TOKEN"
      }
    }

    # ── KEDA: worker `ScaledObject` (queue-depth-driven) ─────────────────────────
    # Tells the n8n chart's `templates/scaledobject-worker.yaml` to
    # render. The matching `TriggerAuthentication` CR
    # (`local.n8n_redis_keda_trigger_auth_name`) is installed by
    # `kubectl_manifest.keda_trigger_authentication` in keda.tf and
    # references the n8n_redis Secret's `password` key — KEDA receives
    # that as its `password` parameter when polling Azure Cache for
    # Redis. `enableTLS = "true"` is required because Azure Redis on
    # port 6380 is TLS-only (`non_ssl_port_enabled = false` in
    # `modules/infra/redis.tf`). `listName = "bull:jobs:wait"` is the
    # n8n-side BullMQ queue; the chart default `bull:default:wait`
    # would never match real n8n traffic. Setting `keda.enabled =
    # true` also disables the chart's stock worker + webhook-processor
    # HPAs (gated on `(not .Values.keda.enabled)`) — the worker is now
    # KEDA-driven and the webhook-processor is scaled by
    # `kubernetes_horizontal_pod_autoscaler_v2.webhook_processor` in
    # scaling.tf instead. Leaving `keda.webhookProcessor.enabled =
    # false` means no chart-rendered webhook ScaledObject lands, so
    # the two webhook autoscalers cannot fight.
    keda = {
      enabled = true
      worker = {
        pollingInterval = 15
        cooldownPeriod  = 300
        minReplicaCount = var.n8n_worker_keda_min_replicas
        maxReplicaCount = var.n8n_worker_keda_max_replicas
        triggers = [
          {
            type = "redis"
            metadata = {
              listName   = "bull:jobs:wait"
              listLength = tostring(var.n8n_worker_keda_target_list_length)
              enableTLS  = "true"
            }
            authenticationRef = {
              name = local.n8n_redis_keda_trigger_auth_name
            }
          }
        ]
      }
    }
  })]

  depends_on = [
    helm_release.keda,
    kubectl_manifest.keda_trigger_authentication,
    kubernetes_secret.n8n_task_runners,
    time_sleep.wait_for_aks_drain,
  ]
}

# ── Helm-release settle gate ─────────────────────────────────────────────────
# Replaces `null_resource.post_deploy_restart` (registry-hardening US-002).
# The chart's `multiMain.setup` block (Redis-based leader election) plus
# `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true` on
# `helm_release.n8n` above are sufficient on their own to absorb the
# multi-main migration race the original 60 s sleep + `kubectl rollout
# restart` workaround papered over: only the elected leader runs migrations;
# followers wait for the leader's signal; and helm waits for
# `replicas == readyReplicas` before returning. This `time_sleep` is kept
# as a small post-install settle window — it gates downstream resources
# (`kubernetes_ingress_v1.n8n`) so AGIC reconciles the Ingress against a
# fully-converged deployment rather than a still-rolling one. Configurable
# via `var.n8n_helm_post_install_settle_seconds`.
resource "time_sleep" "n8n_helm_settle" {
  create_duration = "${var.n8n_helm_post_install_settle_seconds}s"

  depends_on = [helm_release.n8n]
}

# ── Ingress (AGIC-managed) ───────────────────────────────────────────────────
# Translates this Kubernetes Ingress object into App Gateway routing rules.
# AGIC (the AKS Application Gateway Ingress Controller addon, wired in
# `modules/infra/aks.tf` + `modules/infra/ingress.tf`) reconciles the
# Ingress and writes the corresponding listener / backend pool / routing
# rule onto the App Gateway. All AGIC-mutated fields on the App Gateway
# are listed in `lifecycle.ignore_changes` (modules/infra/ingress.tf) so
# Terraform doesn't fight AGIC.
#
# Annotations:
#   - ssl-redirect = true                      → 80→443 redirect.
#   - backend-protocol = http                  → AGIC speaks HTTP to pods;
#                                                TLS terminates at the App
#                                                Gateway. Inside the VNet
#                                                the cluster traffic is
#                                                trusted.
#   - appgw-ssl-certificate = "appgw-ssl-cert" → the cert resource name on
#                                                the App Gateway, set by
#                                                modules/infra/ingress.tf.
#                                                AGIC tells the App
#                                                Gateway to use this cert
#                                                for the HTTPS listener.
#   - request-timeout = 300                    → covers long-running
#                                                workflow executions.
#   - connection-draining = true / 30 s        → graceful pod removal on
#                                                rollouts (lets in-flight
#                                                webhooks finish).
#   - cookie-based-affinity = Enabled          → pins each browser to a
#                                                single main pod.
#                                                WITHOUT this, n8n's
#                                                WebSocket connections
#                                                break when the App
#                                                Gateway round-robins
#                                                between main replicas.
#
# Routes:
#   - /webhook → n8n-webhook-processor:5678  (production webhook isolation)
#   - /        → n8n-main:5678                (UI, REST API, manual exec)
#
# `depends_on` references on the App Gateway + AGIC role assignments in the
# root module's pre-Phase-5 shape are NOT carried across into this
# submodule: those resources live in `modules/infra/` and are not visible
# here. The umbrella example (US-025) uses `depends_on = [module.infra]`
# on the workload module call so the IaaS layer's apply (including the
# AGIC role assignments) finishes before this submodule starts.
resource "kubernetes_ingress_v1" "n8n" {
  metadata {
    name      = "n8n-ingress"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    annotations = {
      "appgw.ingress.kubernetes.io/ssl-redirect"                = "true"
      "appgw.ingress.kubernetes.io/backend-protocol"            = "http"
      "appgw.ingress.kubernetes.io/appgw-ssl-certificate"       = "appgw-ssl-cert"
      "appgw.ingress.kubernetes.io/request-timeout"             = "300"
      "appgw.ingress.kubernetes.io/connection-draining"         = "true"
      "appgw.ingress.kubernetes.io/connection-draining-timeout" = "30"
      "appgw.ingress.kubernetes.io/cookie-based-affinity"       = "Enabled"
    }
  }

  spec {
    ingress_class_name = "azure-application-gateway"

    rule {
      host = var.n8n_domain

      http {
        path {
          path      = "/webhook"
          path_type = "Prefix"

          backend {
            service {
              name = "n8n-webhook-processor"
              port {
                number = 5678
              }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "n8n-main"
              port {
                number = 5678
              }
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "10m"
    delete = "10m"
  }

  depends_on = [
    helm_release.n8n,
    time_sleep.n8n_helm_settle,
  ]
}
