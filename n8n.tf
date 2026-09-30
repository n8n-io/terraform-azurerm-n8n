# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── n8n workload ──────────────────────────────────────────────────────────────

# Generated fallback only — local.n8n_encryption_key prefers a caller-supplied
# var.n8n_encryption_key (database-restore path) and falls back to this
# resource on the module-managed path. Gated to zero when
# n8n_encryption_key_secret_ref selects a caller-managed Secret instead —
# Terraform then has no key value to generate a fallback for.
resource "random_password" "n8n_encryption_key" {
  count = (var.n8n_encryption_key == null && !local.n8n_encryption_key_uses_secret_ref) ? 1 : 0

  length           = 48
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

locals {
  # Single source of truth for the key that wraps every credential n8n stores.
  # Consumed by the encryption Secret below and the n8n_encryption_key output.
  # Explicitly null when n8n_encryption_key_secret_ref is set: the module
  # never reads the caller-managed Secret's value, so there is no effective
  # key value to expose.
  n8n_encryption_key = local.n8n_encryption_key_uses_secret_ref ? null : coalesce(var.n8n_encryption_key, try(random_password.n8n_encryption_key[0].result, null))
}

resource "random_password" "n8n_task_runners_token" {
  length  = 48
  special = false
}

# Gated on create_namespace so callers who already own the n8n namespace
# (platform-managed, or shared across teams) can point the module at it
# without Terraform ever creating or deleting it. Every namespaced resource
# below uses local.n8n_namespace (the caller-supplied or module-chosen name)
# rather than this resource's attribute, so nothing downstream depends on
# whether this module owns the namespace. The one exception is the
# n8n_namespace output (outputs.tf), which reads this resource on the
# module-managed path so caller-owned Secrets gain a dependency edge on it.
resource "kubernetes_namespace" "n8n" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = local.n8n_namespace
  }

  timeouts {
    delete = "5m"
  }

  depends_on = [time_sleep.aks_api_warmup]
}

# The chart does not render imagePullSecrets on pods or its ServiceAccount.
# When callers provide existing registry Secret names, Terraform creates a
# distinct ServiceAccount that carries those references and the Azure workload
# identity annotation. Secret contents remain caller-owned and never enter this
# module's inputs or state through this contract.
resource "kubernetes_service_account_v1" "n8n" {
  count = local.n8n_manages_service_account ? 1 : 0

  metadata {
    name      = local.n8n_service_account_name
    namespace = local.n8n_namespace
    annotations = {
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.n8n_workload.client_id
    }
  }

  automount_service_account_token = true

  dynamic "image_pull_secret" {
    for_each = var.n8n_image_pull_secrets

    content {
      name = image_pull_secret.value
    }
  }

  depends_on = [kubernetes_namespace.n8n]
}

# ── Secrets ───────────────────────────────────────────────────────────────────

# Gated to zero when postgres_password_secret_ref selects a caller-managed
# Secret instead: the external database path (create_database = false), or
# the module-managed write-only path (postgres_password_write_only = true),
# where the module never holds the password and cannot copy it into a
# Secret. postgres_password_secret_ref's validations in variables.tf reject
# the ref on the managed path otherwise, and reject reusing this Secret's
# name on the write-only path, since the same apply destroys it.
resource "kubernetes_secret" "n8n_db" {
  count = local.postgres_password_uses_secret_ref ? 0 : 1

  metadata {
    name      = "n8n-db-secret"
    namespace = local.n8n_namespace
  }

  data = {
    password = local.postgres_connection.password
  }

  depends_on = [kubernetes_namespace.n8n]
}

# Created whenever a username is present (module-managed Redis never has one;
# external Redis may) or the password itself is module-managed — i.e. skipped
# entirely only when redis_password_secret_ref selects a caller-managed
# Secret AND no username is configured, matching the "module SHALL not create
# a Redis credential Secret" scenario. The rare combination of a plain
# username alongside a caller-managed password Secret still gets this
# resource, holding only the username; local.redis_password_secret_name
# (locals.tf) points the password reference at the caller's Secret instead.
resource "kubernetes_secret" "n8n_redis" {
  count = (local.redis_username_present || !local.redis_password_uses_secret_ref) ? 1 : 0

  metadata {
    name      = local.n8n_redis_secret_name
    namespace = local.n8n_namespace
  }

  type = "Opaque"

  data = merge(
    local.redis_username_present ? { username = local.redis_connection.username } : {},
    (local.redis_password_present && !local.redis_password_uses_secret_ref) ? { password = local.redis_connection.password } : {},
  )

  depends_on = [kubernetes_namespace.n8n]
}

# Gated to zero when n8n_license_key_secret_ref selects a caller-managed
# Secret instead.
resource "kubernetes_secret" "n8n_license" {
  count = local.n8n_license_key_uses_secret_ref ? 0 : 1

  metadata {
    name      = "n8n-license-secret"
    namespace = local.n8n_namespace
  }

  data = {
    license-key = var.n8n_license_key
  }

  depends_on = [kubernetes_namespace.n8n]
}

# Gated to zero when n8n_encryption_key_secret_ref selects a caller-managed
# Secret instead — the chart's secretRefs.existingSecret names one Secret for
# all four of these keys, so there is no way to keep this Secret around for
# N8N_HOST/N8N_PORT/N8N_PROTOCOL while pointing the encryption key at a
# caller-supplied Secret; the caller's own Secret must carry all four.
resource "kubernetes_secret" "n8n_encryption_key" {
  count = local.n8n_encryption_key_uses_secret_ref ? 0 : 1

  metadata {
    name      = "n8n-encryption-secret"
    namespace = local.n8n_namespace
  }

  data = {
    N8N_ENCRYPTION_KEY = local.n8n_encryption_key
    N8N_HOST           = var.n8n_domain
    N8N_PORT           = tostring(local.n8n_service_port)
    N8N_PROTOCOL       = "http"
  }

  depends_on = [kubernetes_namespace.n8n]
}

resource "kubernetes_secret" "n8n_task_runners" {
  metadata {
    name      = local.n8n_task_runners_secret_name
    namespace = local.n8n_namespace
  }

  data = {
    N8N_RUNNERS_AUTH_TOKEN = random_password.n8n_task_runners_token.result
  }

  depends_on = [kubernetes_namespace.n8n]
}

# ── Helm release ──────────────────────────────────────────────────────────────
# The chart is pinned to 1.14.0 (see var.n8n_chart_version for the delta
# since 1.11.0). The application and task-runner images are pinned to one n8n
# version so storage and runner protocol changes cannot drift between pod
# families. Explicit multiMain.setup, wait, atomic, cleanup, and timeout
# settings preserve the migration-leader and rollback safeguards from the
# former workload tier.
resource "helm_release" "n8n" {
  name            = "n8n"
  repository      = var.n8n_chart_repository
  chart           = "n8n"
  version         = var.n8n_chart_version
  namespace       = local.n8n_namespace
  wait            = true
  timeout         = var.n8n_helm_timeout
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode(merge({
    image = merge(
      { tag = var.n8n_image_tag },
      var.n8n_image_repository == null ? {} : { repository = var.n8n_image_repository },
    )

    license = {
      enabled = true
      existingSecret = {
        name = local.n8n_license_secret_name
        key  = local.n8n_license_secret_key
      }
    }

    # spec.replicas ownership differs per Deployment on chart 1.14.0:
    # - main: the chart renders it unconditionally (multiMain.replicas or
    #   replicaCount, selected by multiMain.enabled), so it is set to the HPA
    #   floor and a Helm upgrade at the floor never scales main down first.
    # - worker: the chart omits it whenever a KEDA ScaledObject renders for
    #   the worker (n8n.autoscalerOwnsReplicas, chart #201). This module always
    #   enables KEDA with non-empty triggers and a floor of at least 1, so the
    #   ScaledObject owns the count outright; workerReplicaCount below only
    #   gates whether the worker Deployment exists (0 would remove it).
    # - webhook-processor: still rendered unconditionally, because this module
    #   never enables the chart's own webhook KEDA scaler or HPA. scaling.tf's
    #   HPA targets the Deployment from outside the chart, so the chart has no
    #   way to know an autoscaler owns it.
    # The pinned schema requires multiMain.replicas >= 2 only while enabled,
    # so leaving it at the configured minimum is safe on both branches.
    multiMain = {
      enabled  = local.n8n_main_multi_enabled
      replicas = var.n8n_main_hpa_min_replicas
      antiAffinity = {
        type = "preferred"
      }
      setup = {
        keyTtl        = 10
        checkInterval = 3
      }
    }

    # Consumed only when multiMain is disabled (deployment-main.yaml's
    # ternary), but always set to the same effective floor for clarity.
    replicaCount = var.n8n_main_hpa_min_replicas

    # Single-main uses Recreate to avoid two main pods running briefly during
    # a rolling upgrade, which would duplicate scheduled-trigger and webhook
    # processing outside multi-main's leader election. Multi-main omits this
    # override ({} deep-merges as a no-op; null would delete the chart's
    # default and break `.Values.strategy.type`) and keeps the chart's default
    # rollout behavior. The chart exposes only this one top-level `strategy`,
    # consumed by the main, worker, and webhook-processor Deployments alike,
    # so single-main also rolls workers and webhook processors with Recreate.
    # This is not a general at-most-one guarantee: it does not protect against
    # manual pod deletion, node loss, or forced operations.
    strategy = local.n8n_main_multi_enabled ? {} : {
      type = "Recreate"
    }

    queueMode = merge(
      {
        enabled            = true
        workerReplicaCount = var.n8n_worker_keda_min_replicas
        workerConcurrency  = var.n8n_worker_concurrency
      },
      length(var.n8n_worker_extra_env) > 0 ? { workerExtraEnv = var.n8n_worker_extra_env } : {},
      # One additional worker Deployment and ScaledObject per pool. Omitted
      # entirely on the default path. See worker-pools.tf.
      length(local.n8n_worker_groups) > 0 ? { workerGroups = local.n8n_worker_groups } : {},
    )

    webhookProcessor = {
      enabled                                = true
      replicaCount                           = var.n8n_webhook_hpa_min_replicas
      disableProductionWebhooksOnMainProcess = true

      # The chart renders executions.data only on main and worker pods
      # (re-checked on 1.14.0: tests/scripts/check-n8n-chart.sh's duplicate
      # detector fails if the chart ever adds them to webhook pods too).
      # The webhook process also decides retention when a queued run finishes,
      # so it must receive the same defaults. Keep these role-specific to avoid
      # duplicating the chart-owned entries on main and worker containers.
      extraEnv = [
        { name = "EXECUTIONS_DATA_SAVE_ON_SUCCESS", value = var.n8n_executions_data_save_on_success },
        { name = "EXECUTIONS_DATA_SAVE_ON_ERROR", value = var.n8n_executions_data_save_on_error },
        { name = "EXECUTIONS_DATA_SAVE_ON_PROGRESS", value = tostring(var.n8n_executions_data_save_on_progress) },
        { name = "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS", value = tostring(var.n8n_executions_data_save_manual_executions) },
      ]
    }

    database = {
      type        = "postgresdb"
      useExternal = true
      host        = local.postgres_connection.host
      port        = local.postgres_connection.port
      database    = local.postgres_connection.database
      schema      = "public"
      user        = local.postgres_connection.username
      # ca is set only while postgres_ssl_ca_pem is set and the mode verifies
      # the certificate (local.postgres_ssl_ca_values in locals.tf). The chart
      # renders it into its ConfigMap as DB_POSTGRESDB_SSL_CA (PEM content),
      # so a Helm rollback restores the previous CA and a CA change rolls the
      # pods through the chart's checksum/config annotation.
      ssl = merge(
        {
          enabled            = local.postgres_connection.ssl_mode != "disable"
          rejectUnauthorized = contains(["verify-ca", "verify-full"], local.postgres_connection.ssl_mode)
        },
        local.postgres_ssl_ca_values,
      )
      passwordSecret = {
        name = local.postgres_password_secret_name
        key  = local.postgres_password_secret_key
      }
    }

    redis = merge({
      enabled     = true
      useExternal = true
      host        = local.redis_connection.host
      port        = local.redis_connection.port
      username    = local.redis_connection.username == null ? "" : local.redis_connection.username
      tls         = local.redis_connection.tls_enabled
      },
      local.redis_password_present ? {
        passwordSecret = {
          name = local.redis_password_secret_name
          key  = local.redis_password_secret_key
        }
      } : {},
      # Bull worker timing overrides (section 4) plus the graceful shutdown
      # timeout (redis.worker.timeout -> N8N_GRACEFUL_SHUTDOWN_TIMEOUT).
      # Empty when every input is null, so the chart's own redis.worker
      # defaults (60000/10000/30000 ms / 30s) apply unchanged. The chart
      # renders N8N_GRACEFUL_SHUTDOWN_TIMEOUT's ConfigMap entry
      # unconditionally and extraEnv is appended after it, so a caller
      # duplicate would silently win over the chart's value. Every extra_env
      # input rejects the name at plan time for that reason (see the
      # reservation in local.n8n_managed_env_names).
      length(local.n8n_queue_worker_settings) == 0 ? {} : {
        worker = local.n8n_queue_worker_settings
      },
    )

    podLabels = {
      "azure.workload.identity/use" = "true"
    }

    serviceAccount = {
      create = !local.n8n_manages_service_account
      name   = local.n8n_service_account_name
      annotations = {
        "azure.workload.identity/client-id" = azurerm_user_assigned_identity.n8n_workload.client_id
      }
    }

    secretRefs = {
      existingSecret = local.n8n_encryption_secret_name
    }

    service = {
      type = "ClusterIP"
      port = local.n8n_service_port
    }

    resources = {
      main = {
        requests = { cpu = var.n8n_main_cpu_request, memory = var.n8n_main_memory_request }
        limits   = { cpu = var.n8n_main_cpu_limit, memory = var.n8n_main_memory_limit }
      }
      worker = {
        requests = { cpu = var.n8n_worker_cpu_request, memory = var.n8n_worker_memory_request }
        limits   = { cpu = var.n8n_worker_cpu_limit, memory = var.n8n_worker_memory_limit }
      }
      webhookProcessor = {
        requests = { cpu = var.n8n_webhook_cpu_request, memory = var.n8n_webhook_memory_request }
        limits   = { cpu = var.n8n_webhook_cpu_limit, memory = var.n8n_webhook_memory_limit }
      }
    }

    executions = {
      timeout     = var.n8n_execution_timeout
      timeoutMax  = var.n8n_execution_timeout_max
      concurrency = { productionLimit = var.n8n_execution_concurrency_limit }
      data = {
        saveOnError          = var.n8n_executions_data_save_on_error
        saveOnSuccess        = var.n8n_executions_data_save_on_success
        saveOnProgress       = var.n8n_executions_data_save_on_progress
        saveManualExecutions = var.n8n_executions_data_save_manual_executions
      }
      pruning = {
        enabled            = true
        maxAge             = var.n8n_pruning_max_age
        maxCount           = var.n8n_pruning_max_count
        hardDeleteBuffer   = 1
        hardDeleteInterval = 15
        softDeleteInterval = 60
      }
    }

    config = {
      timezone = var.n8n_timezone
      extraEnv = concat(
        [
          { name = "N8N_LOG_LEVEL", value = var.n8n_log_level },
          { name = "N8N_LOG_OUTPUT", value = var.n8n_log_output },
          { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "true" },
          { name = "N8N_EDITOR_BASE_URL", value = local.n8n_editor_base_url },
        ],
        # N8N_WEBHOOK_URL, plus the legacy WEBHOOK_URL for images older than
        # n8n 2.30.0 (local.n8n_needs_legacy_webhook_url_env).
        local.n8n_webhook_url_env,
        [
          { name = "N8N_PROXY_HOPS", value = tostring(var.n8n_proxy_hops) },
          { name = "DB_POSTGRESDB_POOL_SIZE", value = tostring(local.postgres_connection.pool_size) },
          { name = "N8N_RUNNERS_TASK_REQUEST_TIMEOUT", value = tostring(var.n8n_task_runner_request_timeout) },
          { name = "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN", value = tostring(var.n8n_license_detach_floating_on_shutdown) },
        ],
        # PostgreSQL connection/health-check runtime tuning (section 3). Null
        # inputs contribute no entries and retain n8n's pinned defaults.
        local.n8n_postgres_runtime_env,
        # DB_POSTGRESDB_SSL_ENABLED works around a chart bug: the pinned
        # chart renders database.ssl.enabled into a ConfigMap key named
        # DB_POSTGRESDB_SSL, which n8n does not read (n8n-io/n8n-hosting#175
        # upstream), so verify-ca/verify-full without a CA connected in
        # plaintext. Setting the correct name here fixes that regardless of
        # chart version.
        local.n8n_postgres_ssl_enabled_env,
        # Optional shared V8 heap ceiling (section 6). Null contributes no
        # entries and leaves n8n/Node's own default and any caller NODE_OPTIONS
        # in n8n_extra_env in place.
        local.n8n_node_heap_env,
        # Storage-mode variables live in config.extraEnv because the chart has no
        # Azure-native values block. This shared list renders on main, worker,
        # and webhook containers, which queue mode requires. n8n reads each
        # object from the backend recorded in its ID; the Azure connection below
        # stays rendered while azure_blob_retain_read_access is true, so moving
        # writes to database does not strand existing Azure objects.
        [
          { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = var.n8n_binary_data_storage_mode },
          { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = var.n8n_execution_data_storage_mode },
        ],
        local.n8n_azure_storage_enabled ? concat(
          [
            { name = "N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME", value = local.azure_blob_connection.container_name },
          ],
          local.azure_blob_endpoint_env,
          local.azure_blob_connection.connection_string != null ? [
            { name = "N8N_EXTERNAL_STORAGE_AZURE_CONNECTION_STRING", value = local.azure_blob_connection.connection_string },
            ] : concat(
            [{ name = "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME", value = local.azure_blob_connection.account_name }],
            local.azure_blob_connection.account_key == null ? [] : [
              { name = "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_KEY", value = local.azure_blob_connection.account_key },
            ],
            local.azure_blob_connection.auth_auto_detect ? [
              { name = "N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT", value = "true" },
            ] : [],
          ),
        ) : [],
        var.n8n_metrics_enabled ? [
          { name = "N8N_METRICS", value = "true" },
        ] : [],
        var.n8n_reinstall_missing_packages ? [
          { name = "N8N_REINSTALL_MISSING_PACKAGES", value = "true" },
        ] : [],
        # OpenTelemetry settings are omitted as one block when disabled. When
        # enabled, null tuning inputs stay absent so n8n's own defaults apply.
        # OTLP headers are sensitive Terraform inputs but remain literal pod
        # environment values and therefore remain present in Terraform state.
        var.n8n_otel_enabled ? concat(
          [{ name = "N8N_OTEL_ENABLED", value = "true" }],
          var.n8n_otel_exporter_otlp_endpoint == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_OTLP_ENDPOINT", value = var.n8n_otel_exporter_otlp_endpoint },
          ],
          var.n8n_otel_exporter_otlp_headers == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_OTLP_HEADERS", value = var.n8n_otel_exporter_otlp_headers },
          ],
          var.n8n_otel_exporter_service_name == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_SERVICE_NAME", value = var.n8n_otel_exporter_service_name },
          ],
          var.n8n_otel_traces_sample_rate == null ? [] : [
            { name = "N8N_OTEL_TRACES_SAMPLE_RATE", value = tostring(var.n8n_otel_traces_sample_rate) },
          ],
          var.n8n_otel_traces_include_node_spans == null ? [] : [
            { name = "N8N_OTEL_TRACES_INCLUDE_NODE_SPANS", value = tostring(var.n8n_otel_traces_include_node_spans) },
          ],
          var.n8n_otel_traces_inject_outbound == null ? [] : [
            { name = "N8N_OTEL_TRACES_INJECT_OUTBOUND", value = tostring(var.n8n_otel_traces_inject_outbound) },
          ],
          var.n8n_otel_traces_production_only == null ? [] : [
            { name = "N8N_OTEL_TRACES_PRODUCTION_ONLY", value = tostring(var.n8n_otel_traces_production_only) },
          ],
        ) : [],
        # Enterprise log streaming uses n8n's environment-managed settings
        # activation pattern. Typed destination objects are stripped of absent
        # optional fields and JSON encoded once for every n8n process.
        var.n8n_log_streaming_managed_by_env ? concat(
          [{ name = "N8N_LOG_STREAMING_MANAGED_BY_ENV", value = "true" }],
          length(var.n8n_log_streaming_destinations) == 0 ? [] : [
            { name = "N8N_LOG_STREAMING_DESTINATIONS", value = jsonencode(local.n8n_log_streaming_destinations) },
          ],
        ) : [],
        var.n8n_community_packages_prevent_loading ? [
          { name = "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING", value = "true" },
        ] : [],
        var.n8n_community_packages_registry == null ? [] : [
          { name = "N8N_COMMUNITY_PACKAGES_REGISTRY", value = var.n8n_community_packages_registry },
        ],
        var.n8n_custom_extensions_path == null ? [] : [
          { name = "N8N_CUSTOM_EXTENSIONS", value = var.n8n_custom_extensions_path },
        ],
        !var.n8n_templates_enabled ? [
          { name = "N8N_TEMPLATES_ENABLED", value = "false" },
        ] : [],
        !var.n8n_personalization_enabled ? [
          { name = "N8N_PERSONALIZATION_ENABLED", value = "false" },
        ] : [],
        # File-based credential overwrites from a caller-managed Secret. The
        # matching volume and read-only mount are assembled in locals.tf and
        # rendered onto all three n8n pod types below. This is n8n's generic
        # "<VAR>_FILE" convention (readEnv in @n8n/config), not a dedicated
        # setting, and readEnv prefers CREDENTIALS_OVERWRITE_DATA over the
        # _FILE variant wherever it appears in the env list, so Kubernetes'
        # last-wins ordering is not the whole story here. The input validation
        # rejects both names in n8n_extra_env while this entry is active for
        # exactly that reason.
        local.n8n_credentials_overwrite_env,
        # Worker pools (n8n alpha). The feature is inert unless this is set on
        # the mains, which resolve a project's pool and enqueue to it, as well
        # as the workers, which read N8N_WORKER_POOL_NAME. Webhook pods ignore
        # it but are harmless to set, and config.extraEnv reaches all three.
        # Emitted only when pools are declared, so an untouched deployment sees
        # no diff. The name is reserved in n8n_managed_env_names, so declaring a
        # pool is the only way to switch the feature on. See worker-pools.tf.
        length(var.n8n_worker_pools) > 0 ? [
          { name = "N8N_WORKER_POOLS_ENABLED", value = "true" },
        ] : [],
        # Caller-supplied escape hatch, appended last. Kubernetes resolves
        # duplicate env names last-wins, so this would override anything above
        # it; var.n8n_extra_env is validated against local.n8n_managed_env_names
        # and local.n8n_managed_env_prefixes (variables.tf) so it cannot shadow
        # a module- or chart-managed connection/identity/storage/license var.
        var.n8n_extra_env,
      )
    }

    lifecycle = {
      main = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
      worker = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
      webhookProcessor = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
    }

    # Single-main allows voluntary eviction (minAvailable = 0) because
    # Recreate already accepts the resulting downtime; multi-main protects
    # one available replica during voluntary disruption.
    pdb = {
      enabled      = true
      minAvailable = local.n8n_main_multi_enabled ? 1 : 0
    }

    # Top-level chart values render on main, worker, and webhook-processor
    # application containers.
    extraVolumes      = local.n8n_extra_volumes
    extraVolumeMounts = local.n8n_extra_volume_mounts

    # Optional pod DNS configuration (port-aws-040-enhancements section 8).
    # local.n8n_dns_config_values is already null-stripped; {} renders as an
    # empty map that the chart's `with` guard treats as absent, so leaving
    # this unconditional keeps every default deployment's dnsConfig omitted.
    dnsConfig = local.n8n_dns_config_values

    taskRunners = {
      enabled            = var.n8n_task_runners_enabled
      mode               = "external"
      nativePythonRunner = var.n8n_task_runner_python_enabled
      # repository is merged in only when set, mirroring the top-level
      # image block above, so the chart's default n8nio/runners repository
      # stays the default for every caller who has not mirrored it.
      image = merge(
        { tag = coalesce(var.n8n_task_runner_image_tag, var.n8n_image_tag) },
        var.n8n_task_runner_image_repository == null ? {} : { repository = var.n8n_task_runner_image_repository },
      )
      authToken = {
        existingSecret    = kubernetes_secret.n8n_task_runners.metadata[0].name
        existingSecretKey = "N8N_RUNNERS_AUTH_TOKEN"
      }
      launcher = {
        logLevel            = "info"
        autoShutdownTimeout = var.n8n_task_runner_auto_shutdown_timeout
      }
      # Caller-owned ConfigMap; the module never creates or reads its
      # payload. Omitted (enabled = false) keeps the runner image's own
      # default launcher configuration file.
      customConfig = local.n8n_task_runner_custom_config_values
      resources = {
        requests = { cpu = var.n8n_task_runner_cpu_request, memory = var.n8n_task_runner_memory_request }
        limits   = { cpu = var.n8n_task_runner_cpu_limit, memory = var.n8n_task_runner_memory_limit }
      }
    }

    # The chart can render the main HPA while KEDA owns workers. Its webhook
    # HPA is suppressed whenever keda.enabled is true, so scaling.tf owns that
    # HPA directly instead.
    hpa = {
      main = {
        enabled                        = true
        minReplicas                    = var.n8n_main_hpa_min_replicas
        maxReplicas                    = local.n8n_main_hpa_effective_max_replicas
        targetCPUUtilizationPercentage = var.n8n_main_hpa_cpu_threshold
      }
    }

    # Workers scale on both waiting jobs and active jobs held while a task
    # runner is processing them. KEDA takes the maximum result across triggers.
    # Both triggers use the same canonical Redis connection and secret-backed
    # TriggerAuthentication contract.
    keda = {
      enabled = true
      worker = {
        pollingInterval = 15
        cooldownPeriod  = 300
        minReplicaCount = var.n8n_worker_keda_min_replicas
        maxReplicaCount = var.n8n_worker_keda_max_replicas
        # Rendered as ScaledObject annotations by the chart (autoscaling.keda.sh/
        # paused, paused-replicas). A null count renders as YAML null, which the
        # chart's kindIs "invalid" guard treats as unset; the schema types it
        # ["integer", "null"], so no conditional merge is needed.
        pause              = var.n8n_worker_keda_pause
        pausedReplicaCount = var.n8n_worker_keda_paused_replica_count
        triggers = [
          for list_name in local.n8n_bull_queue_keys : {
            type = "redis"
            metadata = {
              address    = "${local.redis_connection.host}:${local.redis_connection.port}"
              listName   = list_name
              listLength = tostring(var.n8n_worker_keda_jobs_per_replica)
              enableTLS  = tostring(local.redis_connection.tls_enabled)
            }
            authenticationRef = {
              name = local.redis_authentication_enabled ? local.n8n_redis_keda_auth_name : ""
            }
          }
        ]
      }
    }
  }))]

  lifecycle {
    # A hard stop rather than a check: a chart that predates
    # queueMode.workerGroups accepts the key and renders nothing, so with
    # pools declared this release would apply clean, switch
    # N8N_WORKER_POOLS_ENABLED on across every pod, and leave no pool
    # Deployment or ScaledObject behind it. A prerelease version is exempt
    # automatically (local.n8n_chart_renders_worker_pools takes it at the
    # caller's word), so a preview build still installs; a numbered version
    # is exempt only if the caller attests it via
    # n8n_worker_pools_chart_verified. See worker-pools.tf.
    precondition {
      condition     = length(var.n8n_worker_pools) > 0 ? local.n8n_chart_renders_worker_pools : true
      error_message = local.n8n_worker_pools_chart_error
    }
  }

  depends_on = [
    kubernetes_namespace.n8n,
    module.controllers,
    kubectl_manifest.keda_trigger_authentication,
    azurerm_federated_identity_credential.n8n_workload,
    kubernetes_service_account_v1.n8n,
    kubernetes_secret.n8n_task_runners,
    # n8n only exits on an Azure connection failure while Azure is a write
    # mode; for azure_blob_retain_read_access it logs nothing and starts
    # without the Azure reader. Create the grant before the release rolls
    # pods. Role propagation can still lag; see docs/data-storage.md.
    azurerm_role_assignment.n8n_blob_data_contributor,
  ]
}

# ── Storage and observability diagnostics ────────────────────────────────────

# Compatibility credentials and custom endpoints are inert when neither an
# active nor historical storage mode uses Azure. This is a warning rather than
# a validation failure because callers may stage credentials before a rollout.
check "azure_blob_tuning_requires_an_azure_mode" {
  assert {
    condition = local.n8n_azure_storage_enabled ? true : (
      var.azure_blob_connection_string == null &&
      var.azure_blob_account_key == null &&
      var.azure_blob_endpoint == null &&
      var.azure_blob_binary_retention_days == null
    )
    error_message = "Azure Blob credentials, endpoint, or retention tuning is set while neither storage mode uses Azure and azure_blob_retain_read_access is false. The values are ignored by n8n. Select an Azure storage mode, set azure_blob_retain_read_access = true to keep historical Azure objects readable, or clear the inert settings."
  }
}

check "otel_tuning_requires_master_switch" {
  assert {
    condition = var.n8n_otel_enabled ? true : (
      var.n8n_otel_exporter_otlp_endpoint == null &&
      var.n8n_otel_exporter_otlp_headers == null &&
      var.n8n_otel_exporter_service_name == null &&
      var.n8n_otel_traces_sample_rate == null &&
      var.n8n_otel_traces_include_node_spans == null &&
      var.n8n_otel_traces_inject_outbound == null &&
      var.n8n_otel_traces_production_only == null
    )
    error_message = "One or more n8n_otel_* tuning inputs are set while n8n_otel_enabled is false, so no N8N_OTEL_* variables will reach the pods. Enable OpenTelemetry or clear the inert tuning inputs."
  }
}

check "log_streaming_destinations_require_managed_by_env" {
  assert {
    condition     = var.n8n_log_streaming_managed_by_env ? true : length(var.n8n_log_streaming_destinations) == 0
    error_message = "n8n_log_streaming_destinations is set while n8n_log_streaming_managed_by_env is false, so the destination JSON will not reach the pods. Enable environment management or clear the inert destinations."
  }
}

# ── Custom image and extension diagnostics ───────────────────────────────────
# These combinations can be intentional, so checks emit plan warnings instead
# of rejecting the configuration. Hard failures remain in variable validation
# for paths, volume references, image references, and environment collisions.

check "custom_image_tag_needs_a_task_runner_tag" {
  assert {
    condition = var.n8n_image_repository != null ? (
      var.n8n_task_runners_enabled ? var.n8n_task_runner_image_tag != null : true
    ) : true
    error_message = "n8n_image_repository is set with task runners enabled, but n8n_task_runner_image_tag is null. Set the runner tag to the underlying n8n version used by the custom application image so n8nio/runners resolves to an existing, protocol-compatible image."
  }
}

check "task_runner_image_tag_matches_application_version" {
  assert {
    condition = var.n8n_task_runner_image_tag == null ? true : (
      var.n8n_task_runner_image_tag == join(".", regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)", var.n8n_image_tag))
    )
    error_message = "n8n_task_runner_image_tag does not match the semantic n8n version at the start of n8n_image_tag. Runner and application protocols are versioned together; use the underlying application version without a custom image suffix."
  }
}

check "task_runner_image_tag_requires_task_runners" {
  assert {
    condition     = var.n8n_task_runner_image_tag != null ? var.n8n_task_runners_enabled : true
    error_message = "n8n_task_runner_image_tag is set while n8n_task_runners_enabled is false, so the tag is inert. Enable task runners or clear the tag."
  }
}

check "worker_keda_paused_replica_count_requires_pause" {
  assert {
    condition     = var.n8n_worker_keda_paused_replica_count != null ? var.n8n_worker_keda_pause : true
    error_message = "n8n_worker_keda_paused_replica_count is set while n8n_worker_keda_pause is false. The chart only renders autoscaling.keda.sh/paused-replicas while the ScaledObject is paused, so the count is inert. Set n8n_worker_keda_pause = true or clear the count."
  }
}

# Pause is only reliable from chart 1.13.0 (local.n8n_worker_keda_pause_supported
# in scaling.tf). A chart older than 1.12.0, including the 1.11.0-based
# worker-pools preview, does not read keda.worker.pause at all, so the pause
# silently never takes effect and workers keep consuming jobs. Chart 1.12.0
# reads it but still renders the worker's spec.replicas on every upgrade, so
# any later apply that changes the release while paused writes the floor back
# over KEDA's held count. No companion worker-floor check is needed (unlike
# terraform-aws-n8n): n8n_worker_keda_min_replicas is validated to >= 1, so the
# worker ScaledObject always renders.
check "worker_keda_pause_requires_a_supported_chart" {
  assert {
    condition     = (var.n8n_worker_keda_pause || var.n8n_worker_keda_paused_replica_count != null) ? local.n8n_worker_keda_pause_supported : true
    error_message = "n8n_worker_keda_pause or n8n_worker_keda_paused_replica_count is set, but n8n_chart_version predates 1.13.0. Charts older than 1.12.0 (including the 1.11.0-based worker-pools preview) do not read keda.worker.pause at all, so workers keep consuming jobs. Chart 1.12.0 reads it but still sets the worker Deployment's spec.replicas on every Helm upgrade, so a later apply while paused can write the replica floor back over the held count. Use n8n_chart_version 1.13.0 or newer, or clear these inputs."
  }
}

# Warning half of the shutdown-window rule. An explicit
# n8n_graceful_shutdown_timeout that does not fit is a hard validation error on
# that variable. Left null, the chart still renders its own default, which must
# fit the same way, but this was never checked before that input existed, so a
# hard error here would break configurations that already plan. Skipped
# entirely for a custom n8n_chart_repository (local.n8n_graceful_shutdown_default_applies),
# whose values.yaml default this module cannot verify.
check "graceful_shutdown_fits_grace_period" {
  assert {
    condition     = local.n8n_graceful_shutdown_default_applies ? local.n8n_chart_default_graceful_shutdown_timeout + var.n8n_prestop_sleep < var.n8n_termination_grace_period : true
    error_message = "n8n_graceful_shutdown_timeout is unset, so n8n uses the chart's default shutdown timeout of ${local.n8n_chart_default_graceful_shutdown_timeout}s. That plus n8n_prestop_sleep (${var.n8n_prestop_sleep}s) does not stay below n8n_termination_grace_period (${var.n8n_termination_grace_period}s), so Kubernetes can SIGKILL a pod before n8n finishes shutting down and interrupt running executions. Set n8n_graceful_shutdown_timeout to a value that fits, lower n8n_prestop_sleep, or raise n8n_termination_grace_period."
  }
}

check "custom_extensions_path_requires_a_source" {
  assert {
    condition = var.n8n_custom_extensions_path != null ? (
      var.n8n_image_repository != null ? true : anytrue([
        for mount in var.n8n_extra_volume_mounts :
        mount.mount_path == var.n8n_custom_extensions_path ? true : startswith(var.n8n_custom_extensions_path, "${mount.mount_path}/")
      ])
    ) : true
    error_message = "n8n_custom_extensions_path is set, but no custom image or extra volume mount puts files at that path. Supply n8n_image_repository, mount a declared volume over the path, or clear the path."
  }
}

check "extra_volumes_should_be_mounted" {
  assert {
    condition = alltrue([
      for volume in var.n8n_extra_volumes :
      contains([for mount in var.n8n_extra_volume_mounts : mount.name], volume.name)
    ])
    error_message = "An n8n_extra_volumes entry has no matching n8n_extra_volume_mounts entry, so the volume is inert. Add a mount or remove the volume."
  }
}

check "image_pull_secrets_need_a_custom_image" {
  assert {
    condition     = length(var.n8n_image_pull_secrets) > 0 ? var.n8n_image_repository != null || var.n8n_task_runner_image_repository != null : true
    error_message = "n8n_image_pull_secrets is set while both n8n_image_repository and n8n_task_runner_image_repository are null, so registry Secrets are attached to the ServiceAccount but every pod still uses its public chart image. Set one of the private custom repositories or clear the inert Secret names."
  }
}

# ── Helm-release settle gate ──────────────────────────────────────────────────
resource "time_sleep" "n8n_helm_settle" {
  create_duration = "${var.n8n_helm_post_install_settle_seconds}s"

  depends_on = [helm_release.n8n]
}
