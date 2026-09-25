# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Locals ────────────────────────────────────────────────────────────────
# Shared values: the common tag set merged onto every taggable resource and
# deterministic resource names derived from `var.friendly_name_prefix`. Every
# name embeds the prefix so sibling deployments in the same subscription /
# region don't collide on the globally-unique Azure namespaces (storage
# account, Key Vault, App Gateway public-IP DNS label).
#
# Ported from `modules/infra/locals.tf` (the resource-name shape stays
# stable as resources move out of the two submodules and into this root per
# align-azure-with-aws-capabilities sections 2–6) plus the n8n namespace
# local from `modules/workload/locals.tf`. `redis_name` renames the former
# `redis_cache_name` local: section 4 replaces `azurerm_redis_cache` with
# `azurerm_managed_redis`, so the generic name avoids re-introducing the
# legacy resource type into the name.
#
# Azure name-length limits the names below must respect:
#   - Storage Account   3–24 chars (lowercase alnum only — no hyphens)
#   - PostgreSQL FS     3–63 chars (lowercase + digits + hyphens)
#   - AKS cluster       1–63 chars (alnum + hyphens)
#   - Redis             1–63 chars (alnum + hyphens)
#   - Key Vault         3–24 chars (alnum + hyphens)
#
# `friendly_name_prefix` is validated as ^[a-z0-9]{2,12}$ in variables.tf, so
# every suffix below fits within the tightest 24-char Storage Account / Key
# Vault limit. `substr()` is defensive truncation in case that validation is
# ever loosened.

locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.common_tags,
  )

  cluster_name         = "${var.friendly_name_prefix}-aks"
  postgres_server_name = "${var.friendly_name_prefix}-postgres"
  redis_name           = "${var.friendly_name_prefix}-redis"
  storage_account_name = substr("${var.friendly_name_prefix}n8nfiles", 0, 24)
  app_gateway_name     = "${var.friendly_name_prefix}-appgw"
  appgw_pip_name       = "${var.friendly_name_prefix}-appgw-pip"
  appgw_nsg_name       = "${var.friendly_name_prefix}-appgw-nsg"

  # Namespace names and chart-rendered service coordinates stay centralized so
  # Kubernetes resources, KEDA manifests, outputs, and caller-owned ingress can
  # share one contract.
  n8n_namespace                = var.n8n_namespace
  keda_namespace               = var.keda_namespace
  n8n_redis_secret_name        = "n8n-redis-secret"
  n8n_task_runners_secret_name = "n8n-task-runners-secret"
  n8n_redis_keda_auth_name     = "n8n-redis-keda-auth"
  n8n_service_port             = 5678

  # ── Main topology selection ──────────────────────────────────────────────
  # n8n_main_hpa_min_replicas is the only topology selector (design.md
  # decision 2): a minimum of 1 selects single-main queue mode, which does
  # not require feat:multipleMainInstances; a minimum above 1 selects
  # multi-main, the default. A caller-configured higher main maximum stays
  # valid input in single-main but has no effect — the effective ceiling
  # below clamps to 1 so the chart HPA and scaling.tf's capacity model never
  # exceed what the single-replica path renders.
  n8n_main_multi_enabled              = var.n8n_main_hpa_min_replicas > 1
  n8n_main_hpa_effective_max_replicas = local.n8n_main_multi_enabled ? var.n8n_main_hpa_max_replicas : 1

  n8n_webhook_path_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
    "/mcp",
  ]

  # Editor test-mode endpoints are served by main pods only. AGIC renders a
  # pathType=Prefix rule as an Application Gateway string-prefix pattern
  # (`/webhook*`), which also matches `/webhook-test/...`, and the gateway
  # evaluates path rules in declared order. These prefixes therefore have to
  # be routed to the main Service ahead of the production prefixes above, or
  # test webhooks, Form Trigger test mode, and MCP test mode land on
  # webhook-processor pods that return 404.
  n8n_test_webhook_path_prefixes = [
    "/webhook-test",
    "/form-test",
    "/mcp-test",
  ]

  # The canonical host remains authoritative for n8n's advertised editor and
  # webhook URLs. Additional domains are routing aliases only. Normalize every
  # host once so the Ingress, section 12 DNS records, and certificate guidance
  # cannot drift on case or duplicate entries.
  n8n_ingress_domains = distinct(concat(
    [lower(var.n8n_domain)],
    [for domain in var.n8n_additional_domains : lower(domain)],
  ))

  # Editor identity always stays on n8n_domain (design.md decision 8): REST
  # and OAuth2 credential callbacks must return to the same host that serves
  # the editor UI. The webhook base is independently overridable so a caller
  # can advertise production webhooks on a different public host (e.g.
  # examples/split-ingress) without moving editor traffic. Null retains the
  # prior single-host behavior.
  n8n_editor_base_url       = "https://${var.n8n_domain}"
  n8n_effective_webhook_url = coalesce(var.n8n_webhook_url, local.n8n_editor_base_url)

  appgw_frontend_ip_configuration_name = "appgw-frontend-ip"
  appgw_ingress_default_annotations = merge(
    {
      "appgw.ingress.kubernetes.io/ssl-redirect"                = "true"
      "appgw.ingress.kubernetes.io/backend-protocol"            = "http"
      "appgw.ingress.kubernetes.io/appgw-ssl-certificate"       = "appgw-ssl-cert"
      "appgw.ingress.kubernetes.io/request-timeout"             = "300"
      "appgw.ingress.kubernetes.io/connection-draining"         = "true"
      "appgw.ingress.kubernetes.io/connection-draining-timeout" = "30"
      "appgw.ingress.kubernetes.io/cookie-based-affinity"       = "true"
    },
    var.appgw_frontend_mode == "internal" ? {
      "appgw.ingress.kubernetes.io/use-private-ip" = "true"
    } : {},
  )
  appgw_ingress_annotations = merge(local.appgw_ingress_default_annotations, var.ingress_annotations)
  appgw_ingress_control_annotation_names = toset(concat(
    keys(local.appgw_ingress_default_annotations),
    ["appgw.ingress.kubernetes.io/use-private-ip"],
  ))

  # The chart creates the workload-identity service account by default. It does
  # not expose imagePullSecrets, so the module takes ownership only when callers
  # provide existing registry Secret names. A distinct name avoids colliding
  # with the chart-owned account while one apply switches ownership.
  n8n_manages_service_account = length(var.n8n_image_pull_secrets) > 0
  n8n_service_account_name    = local.n8n_manages_service_account ? "n8n-enterprise-pull" : "n8n-enterprise"

  # Translate typed snake_case volume inputs to the Kubernetes camelCase shape
  # accepted by the chart's all-pod extra volume values. Kubernetes expects an
  # integer defaultMode, while callers supply an octal string to avoid decimal
  # interpretation by Terraform. Caller entries keep their order; the managed
  # credential-overwrite Secret volume and its read-only mount are appended
  # last when n8n_credentials_overwrite_secret_ref is set. That volume projects
  # only the selected key, so the pod never sees the Secret's other keys, and
  # the module never reads the payload itself.
  n8n_extra_volumes = concat(
    [
      for volume in var.n8n_extra_volumes : merge(
        { name = volume.name },
        volume.config_map == null ? {} : {
          configMap = merge(
            { name = volume.config_map.name },
            volume.config_map.default_mode == null ? {} : {
              defaultMode = parseint(volume.config_map.default_mode, 8)
            },
          )
        },
        volume.secret == null ? {} : {
          secret = merge(
            { secretName = volume.secret.secret_name },
            volume.secret.default_mode == null ? {} : {
              defaultMode = parseint(volume.secret.default_mode, 8)
            },
          )
        },
        volume.persistent_volume_claim == null ? {} : {
          persistentVolumeClaim = merge(
            { claimName = volume.persistent_volume_claim.claim_name },
            volume.persistent_volume_claim.read_only == null ? {} : {
              readOnly = volume.persistent_volume_claim.read_only
            },
          )
        },
      )
    ],
    var.n8n_credentials_overwrite_secret_ref == null ? [] : [
      {
        name = "credentials-overwrite"
        secret = {
          secretName = var.n8n_credentials_overwrite_secret_ref.name
          items = [
            {
              key  = var.n8n_credentials_overwrite_secret_ref.key
              path = var.n8n_credentials_overwrite_secret_ref.key
            },
          ]
        }
      },
    ],
  )

  n8n_extra_volume_mounts = concat(
    [
      for mount in var.n8n_extra_volume_mounts : merge(
        {
          name      = mount.name
          mountPath = mount.mount_path
          readOnly  = mount.read_only
        },
        mount.sub_path == null ? {} : { subPath = mount.sub_path },
      )
    ],
    var.n8n_credentials_overwrite_secret_ref == null ? [] : [
      {
        name      = "credentials-overwrite"
        mountPath = "/etc/n8n/credentials-overwrite"
        readOnly  = true
      },
    ],
  )

  # CREDENTIALS_OVERWRITE_DATA_FILE is deliberately absent from
  # local.n8n_managed_env_names below: the variable validation on
  # n8n_credentials_overwrite_secret_ref rejects it (and
  # CREDENTIALS_OVERWRITE_DATA) in n8n_extra_env only while the reference is
  # set, so callers who already deliver the file through the escape hatches
  # keep working until they opt into the dedicated input.
  n8n_credentials_overwrite_env = var.n8n_credentials_overwrite_secret_ref == null ? [] : [
    {
      name  = "CREDENTIALS_OVERWRITE_DATA_FILE"
      value = "/etc/n8n/credentials-overwrite/${var.n8n_credentials_overwrite_secret_ref.key}"
    },
  ]

  # PostgreSQL connection/health-check runtime tuning (port-aws-040-enhancements
  # section 3): four nullable inputs rendered as one shared list so main,
  # worker, and webhook containers stay in sync and the offline chart-rendering
  # check can assert on this local directly instead of re-deriving the
  # null-filtering logic by hand. Null omits the entry and keeps n8n's pinned
  # application default.
  n8n_postgres_runtime_env = concat(
    var.postgres_connection_timeout_ms == null ? [] : [
      { name = "DB_POSTGRESDB_CONNECTION_TIMEOUT", value = tostring(var.postgres_connection_timeout_ms) },
    ],
    var.postgres_ping_timeout_ms == null ? [] : [
      { name = "DB_PING_TIMEOUT_MS", value = tostring(var.postgres_ping_timeout_ms) },
    ],
    var.postgres_ping_interval_seconds == null ? [] : [
      { name = "DB_PING_INTERVAL_SECONDS", value = tostring(var.postgres_ping_interval_seconds) },
    ],
    var.postgres_ping_max_failures_before_recovery == null ? [] : [
      { name = "DB_PING_MAX_FAILURES_BEFORE_RECOVERY", value = tostring(var.postgres_ping_max_failures_before_recovery) },
    ],
  )

  # Optional application heap ceiling (port-aws-040-enhancements section 6):
  # one shared entry rendered on main, worker, and webhook application
  # containers. Null omits the entry and leaves any caller NODE_OPTIONS in
  # n8n_extra_env (validated as non-conflicting on the variable itself) in
  # place.
  n8n_node_heap_env = var.n8n_node_max_old_space_size_mb == null ? [] : [
    { name = "NODE_OPTIONS", value = "--max-old-space-size=${var.n8n_node_max_old_space_size_mb}" },
  ]

  # Caller-managed task-runner launcher configuration (port-aws-040-enhancements
  # section 7): mirrors the chart's taskRunners.customConfig shape so n8n.tf
  # and plan-time tests share one source. Null keeps customConfig disabled,
  # which leaves the runner image's own default launcher file in place.
  n8n_task_runner_custom_config_values = {
    enabled       = var.n8n_task_runner_custom_config != null
    configMapName = try(var.n8n_task_runner_custom_config.config_map_name, "")
    configMapKey  = try(var.n8n_task_runner_custom_config.config_map_key, "n8n-task-runners.json")
  }

  # Optional pod DNS configuration (port-aws-040-enhancements section 8):
  # strips null attributes/option values before rendering and collapses a
  # null or effectively empty input to {}. The chart applies dnsConfig via
  # Helm's `with`, which treats an empty map as absent, so {} correctly
  # omits the block on all three pod families without a separate ternary.
  # Built as one flat object-for-comprehension (not merge()) over pre-computed
  # per-key locals: combining merge() with this for-expression's dynamically
  # shaped option elements produces a spurious "Inconsistent conditional
  # result types" error from Terraform's type unification, even though every
  # branch evaluates to a well-formed object at runtime.
  n8n_dns_config_options = (
    var.n8n_dns_config == null || var.n8n_dns_config.options == null ? null : [
      for opt in var.n8n_dns_config.options : {
        for k, v in { name = opt.name, value = opt.value } : k => v if v != null
      }
    ]
  )

  n8n_dns_config_values = {
    for k, v in {
      nameservers = try(var.n8n_dns_config.nameservers, null)
      searches    = try(var.n8n_dns_config.searches, null)
      options     = local.n8n_dns_config_options
    } : k => v if v != null
  }

  # Bull worker timing (port-aws-040-enhancements section 4): one inner map
  # with only non-null keys, merged into the chart's redis.worker block in
  # n8n.tf. A shallow merge of separate worker maps would lose values, so
  # this local composes them together up front. n8n_graceful_shutdown_timeout
  # (timeout key) has no per-setting `{{- if }}` guard in the chart, unlike
  # the three QUEUE_WORKER_* settings: templates/configmap.yaml renders
  # N8N_GRACEFUL_SHUTDOWN_TIMEOUT unconditionally, so omitting this key when
  # the variable is null does not disable anything, Helm just falls back to
  # the chart's own values.yaml default (30s) for redis.worker.timeout.
  n8n_queue_worker_settings = merge(
    var.n8n_queue_worker_lock_duration == null ? {} : { lockDuration = var.n8n_queue_worker_lock_duration },
    var.n8n_queue_worker_lock_renew_time == null ? {} : { lockRenewTime = var.n8n_queue_worker_lock_renew_time },
    var.n8n_queue_worker_stalled_interval == null ? {} : { stalledInterval = var.n8n_queue_worker_stalled_interval },
    var.n8n_graceful_shutdown_timeout == null ? {} : { timeout = var.n8n_graceful_shutdown_timeout },
  )

  # The chart appends config.extraEnv after its own environment variables, and
  # Kubernetes resolves duplicates last-wins. Reserve every current module and
  # chart-owned connection, identity, storage, license, runner, and topology
  # name so the arbitrary environment escape hatch cannot replace them.
  n8n_managed_env_names = [
    "EXECUTIONS_MODE",
    "N8N_AVAILABLE_BINARY_DATA_MODES",
    "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING",
    "N8N_COMMUNITY_PACKAGES_REGISTRY",
    "N8N_CONCURRENCY_PRODUCTION_LIMIT",
    "N8N_CUSTOM_EXTENSIONS",
    "N8N_DEFAULT_BINARY_DATA_MODE",
    "N8N_DISABLE_PRODUCTION_MAIN_PROCESS",
    "N8N_EDITOR_BASE_URL",
    "N8N_ENCRYPTION_KEY",
    "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS",
    "N8N_EXECUTION_DATA_STORAGE_MODE",
    "N8N_GRACEFUL_SHUTDOWN_TIMEOUT",
    "N8N_HOST",
    "N8N_LICENSE_ACTIVATION_KEY",
    "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN",
    "N8N_LOG_LEVEL",
    "N8N_LOG_OUTPUT",
    "N8N_METRICS",
    "N8N_NATIVE_PYTHON_RUNNER",
    "N8N_PERSONALIZATION_ENABLED",
    "N8N_PORT",
    "N8N_PROTOCOL",
    "N8N_PROXY_HOPS",
    "N8N_REINSTALL_MISSING_PACKAGES",
    "N8N_TEMPLATES_ENABLED",
    "N8N_WEBHOOK_URL",
    "N8N_WEBHOOK_TIMEOUT",
    "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS",
    "TZ",
    # Owned by var.n8n_worker_pools. N8N_WORKER_POOLS_ENABLED is emitted only
    # when pools are declared, and N8N_WORKER_POOL_NAME is set per worker group
    # by the chart. Reached through config.extraEnv (all pods), an override here
    # would either turn the feature on with no pool to route to, or put every
    # worker, main and webhook pod into one pool at once, which is not a
    # topology the feature has.
    #
    # This list also gates n8n_worker_extra_env, which reaches workers alone, so
    # a pool name there is not the same mistake. It is still refused: pool
    # membership comes with a queue and a KEDA scaler that n8n_worker_pools
    # builds together, and pinning the chart's own worker deployment to a pool
    # through the escape hatch would leave those workers on a pool queue nothing
    # scales. See worker-pools.tf.
    "N8N_WORKER_POOLS_ENABLED",
    "N8N_WORKER_POOL_NAME",
    # Keep the deprecated name reserved so callers cannot configure both forms.
    "WEBHOOK_URL",
  ]

  n8n_managed_env_prefixes = [
    "AWS_",
    "AZURE_",
    "DB_",
    "EXECUTIONS_",
    "N8N_EXTERNAL_STORAGE_",
    "N8N_LICENSE_",
    "N8N_LOG_STREAMING_",
    "N8N_MULTI_MAIN_",
    "N8N_OTEL_",
    "N8N_RUNNERS_",
    "QUEUE_",
  ]

  # The two Bull list keys workers hold jobs in. KEDA's worker ScaledObject
  # (n8n.tf) and the optional Redis exporter's REDIS_EXPORTER_CHECK_SINGLE_KEYS
  # (observability.tf) both read this one list, so a future prefix or key
  # change moves both call sites together and the exporter's observed queue
  # keys stay identical to KEDA's by construction (design.md decision 6).
  n8n_bull_queue_keys = ["bull:jobs:wait", "bull:jobs:active"]

  # Authentication remains optional for external Redis. Managed Redis always
  # has an access key. These booleans declassify only whether a credential is
  # present, never the credential itself, so Helm and KEDA can omit dead secret
  # references without exposing the value. A password also counts as present
  # when it is sourced from a caller-managed Secret reference (section 5) —
  # Terraform does not know the value in that case, but Redis still requires
  # AUTH, so the TriggerAuthentication and Helm redis.passwordSecret block
  # below must still render.
  redis_password_present       = var.create_redis ? true : nonsensitive(var.redis_external_password != null || var.redis_password_secret_ref != null)
  redis_username_present       = var.create_redis ? false : var.redis_external_username != null
  redis_authentication_enabled = local.redis_password_present ? true : local.redis_username_present

  # KEDA resolves TriggerAuthentication in the ScaledObject's namespace. The
  # manifest contains secret references only. Redis credentials remain in the
  # Kubernetes Secret and are never embedded in this CR. The password entry
  # points at whichever Secret currently backs it — the module-managed one or
  # a caller-managed reference (local.redis_password_secret_name/_key,
  # redis.tf) — while the username entry always uses the module-managed
  # Secret because kubernetes_secret.n8n_redis (n8n.tf) exists whenever a
  # username is present, regardless of the password source.
  keda_trigger_authentication_yaml = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata = {
      name      = local.n8n_redis_keda_auth_name
      namespace = local.n8n_namespace
    }
    spec = {
      secretTargetRef = concat(
        local.redis_username_present ? [{
          parameter = "username"
          name      = local.n8n_redis_secret_name
          key       = "username"
        }] : [],
        local.redis_password_present ? [{
          parameter = "password"
          name      = local.redis_password_secret_name
          key       = local.redis_password_secret_key
        }] : [],
      )
    }
  })

  # Storage mode selection stays separate from connection configuration. Azure
  # credentials remain rendered while Azure is an active or historical binary
  # backend, or the active execution backend.
  n8n_azure_storage_enabled = (
    contains(var.n8n_available_binary_data_modes, "azure") ||
    var.n8n_execution_data_storage_mode == "azure"
  )

  # One canonical Azure Blob connection object for all-pod environment wiring.
  # With no compatibility credential supplied, auth_auto_detect is true and n8n
  # uses DefaultAzureCredential through the federated workload identity. The
  # endpoint override is passed through verbatim; accepting a sovereign Blob
  # endpoint does not certify the full module for that cloud.
  azure_blob_connection = {
    account_name      = local.effective_blob_storage_account_name
    container_name    = local.effective_blob_container_name
    endpoint          = var.azure_blob_endpoint == null ? local.effective_blob_endpoint : var.azure_blob_endpoint
    auth_auto_detect  = var.azure_blob_connection_string == null && var.azure_blob_account_key == null
    connection_string = var.azure_blob_connection_string
    account_key       = var.azure_blob_account_key
  }

  # Managed public-cloud storage can rely on the Azure SDK's account-derived
  # default endpoint. Customer-managed storage must render its required
  # existing endpoint, while an explicit override renders on either path.
  azure_blob_endpoint_env = var.create_blob_storage && var.azure_blob_endpoint == null ? [] : [{
    name  = "N8N_EXTERNAL_STORAGE_AZURE_ENDPOINT"
    value = local.azure_blob_connection.endpoint
  }]

  # Remove absent optional destination fields before JSON encoding. n8n expects
  # the documented flat webhook, syslog, and Sentry objects, not explicit nulls.
  n8n_log_streaming_destinations = [
    for destination in var.n8n_log_streaming_destinations : {
      for name, value in destination : name => value if value != null
    }
  ]

  # ── Customer-managed infrastructure effective references ─────────────────
  # (add-customer-managed-modularity sections 1–2 and 6) Selects one
  # effective value per potentially customer-managed layer so downstream
  # resources and outputs can read a single contract regardless of which
  # side of each create_* switch is active. The "true" branch of each pair
  # indexes into the corresponding `count`-gated managed resource. The
  # "false" branch values come only from validated existing-resource inputs
  # or, for AKS, the read-only `data.azurerm_kubernetes_cluster.existing`
  # lookup (aks.tf) — the module never inspects a customer-managed Azure
  # resource beyond that one documented exception (design.md decision 2).
  effective_aks_cluster_id   = var.create_aks ? azurerm_kubernetes_cluster.n8n[0].id : data.azurerm_kubernetes_cluster.existing[0].id
  effective_aks_cluster_name = var.create_aks ? azurerm_kubernetes_cluster.n8n[0].name : var.existing_aks_cluster_name

  # No root resource or output currently needs the effective AKS resource
  # group name (every module-owned resource that needs a resource group uses
  # var.resource_group_name directly, since UAMIs and role assignments live
  # in the module's own resource group regardless of which AKS resource group
  # is in scope). Kept on the contract, and asserted by
  # tests/defaults.tftest.hcl's `existing_aks_plan_creates_no_managed_resources`
  # run, so a future consumer (e.g. an AKS-resource-group-scoped diagnostic)
  # can read it without re-deriving the create_aks ternary.
  # tflint-ignore: terraform_unused_declarations
  effective_aks_resource_group_name = var.create_aks ? var.resource_group_name : var.existing_aks_resource_group_name

  effective_aks_oidc_issuer_url = var.create_aks ? azurerm_kubernetes_cluster.n8n[0].oidc_issuer_url : data.azurerm_kubernetes_cluster.existing[0].oidc_issuer_url
  effective_aks_kube_config     = var.create_aks ? azurerm_kubernetes_cluster.n8n[0].kube_config : data.azurerm_kubernetes_cluster.existing[0].kube_config

  effective_blob_storage_account_name = var.create_blob_storage ? azurerm_storage_account.n8n[0].name : var.existing_blob_storage_account_name
  effective_blob_container_name       = var.create_blob_storage ? azurerm_storage_container.n8n[0].name : var.existing_blob_container_name
  effective_blob_container_id         = var.create_blob_storage ? azurerm_storage_container.n8n[0].id : var.existing_blob_container_id
  effective_blob_endpoint             = var.create_blob_storage ? azurerm_storage_account.n8n[0].primary_blob_endpoint : var.existing_blob_endpoint

  # Declassify only whether a caller-managed Secret reference replaces a
  # module-generated or literal credential source — never the credential
  # value itself. Section 5 gates the corresponding generated/Kubernetes
  # Secret resources and renders the chart and KEDA TriggerAuthentication
  # from these selections without reading any caller-managed Secret value
  # into Terraform.
  n8n_license_key_uses_secret_ref    = var.n8n_license_key_secret_ref != null
  n8n_encryption_key_uses_secret_ref = var.n8n_encryption_key_secret_ref != null
  postgres_password_uses_secret_ref  = var.postgres_password_secret_ref != null
  redis_password_uses_secret_ref     = var.redis_password_secret_ref != null

  # Effective Secret name and key each credential-consuming resource renders
  # into the chart or the KEDA TriggerAuthentication — the module-managed
  # Secret's coordinates (name always known statically; the resource itself
  # is `count`-gated to zero on the caller-managed branch, so `try()` reads
  # around the absent instance) or the caller-supplied reference's coordinates
  # verbatim. None of these ever read a caller-managed Secret's value.
  n8n_license_secret_name = local.n8n_license_key_uses_secret_ref ? var.n8n_license_key_secret_ref.name : try(kubernetes_secret.n8n_license[0].metadata[0].name, null)
  n8n_license_secret_key  = local.n8n_license_key_uses_secret_ref ? var.n8n_license_key_secret_ref.key : "license-key"

  n8n_encryption_secret_name = local.n8n_encryption_key_uses_secret_ref ? var.n8n_encryption_key_secret_ref.name : try(kubernetes_secret.n8n_encryption_key[0].metadata[0].name, null)

  postgres_password_secret_name = local.postgres_password_uses_secret_ref ? var.postgres_password_secret_ref.name : try(kubernetes_secret.n8n_db[0].metadata[0].name, null)
  postgres_password_secret_key  = local.postgres_password_uses_secret_ref ? var.postgres_password_secret_ref.key : "password"

  redis_password_secret_name = local.redis_password_uses_secret_ref ? var.redis_password_secret_ref.name : try(kubernetes_secret.n8n_redis[0].metadata[0].name, null)
  redis_password_secret_key  = local.redis_password_uses_secret_ref ? var.redis_password_secret_ref.key : "password"
}

# ── Ignored-input diagnostics ────────────────────────────────────────────────
# Non-failing warnings for existing-resource references or attestations
# supplied while the corresponding layer remains module-managed. Hard
# failures for incomplete customer-managed contracts live on the
# existing_* variables themselves in variables.tf.
check "existing_aks_reference_ignored_when_module_managed" {
  assert {
    condition = var.create_aks ? (
      var.existing_aks_cluster_name == null &&
      var.existing_aks_resource_group_name == null &&
      !var.existing_aks_cluster_prerequisites_confirmed
    ) : true
    error_message = "existing_aks_cluster_name, existing_aks_resource_group_name, or existing_aks_cluster_prerequisites_confirmed is set while create_aks is true, so the module creates and uses its own AKS cluster and these references are ignored. Set create_aks = false to target the existing cluster, or clear the inert references."
  }
}

check "existing_blob_reference_ignored_when_module_managed" {
  assert {
    condition = var.create_blob_storage ? (
      var.existing_blob_storage_account_name == null &&
      var.existing_blob_container_name == null &&
      var.existing_blob_container_id == null &&
      var.existing_blob_endpoint == null &&
      !var.existing_blob_prerequisites_confirmed
    ) : true
    error_message = "An existing_blob_* reference or existing_blob_prerequisites_confirmed is set while create_blob_storage is true, so the module creates and uses its own Blob storage account and container and these references are ignored. Set create_blob_storage = false to target the existing container, or clear the inert references."
  }
}

check "existing_keda_prerequisites_ignored_when_module_managed" {
  assert {
    condition     = var.install_keda ? !var.existing_keda_prerequisites_confirmed : true
    error_message = "existing_keda_prerequisites_confirmed is set while install_keda is true, so the module installs and manages KEDA itself and the attestation is ignored. Set install_keda = false to use the existing installation, or clear the inert attestation."
  }
}
