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
  n8n_namespace                = "n8n"
  keda_namespace               = "keda"
  n8n_redis_secret_name        = "n8n-redis-secret"
  n8n_task_runners_secret_name = "n8n-task-runners-secret"
  n8n_redis_keda_auth_name     = "n8n-redis-keda-auth"
  n8n_service_port             = 5678

  n8n_webhook_path_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
    "/mcp",
  ]

  # The canonical host remains authoritative for n8n's advertised editor and
  # webhook URLs. Additional domains are routing aliases only. Normalize every
  # host once so the Ingress, section 12 DNS records, and certificate guidance
  # cannot drift on case or duplicate entries.
  n8n_ingress_domains = distinct(concat(
    [lower(var.n8n_domain)],
    [for domain in var.n8n_additional_domains : lower(domain)],
  ))

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
  # interpretation by Terraform.
  n8n_extra_volumes = [
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
  ]

  n8n_extra_volume_mounts = [
    for mount in var.n8n_extra_volume_mounts : merge(
      {
        name      = mount.name
        mountPath = mount.mount_path
        readOnly  = mount.read_only
      },
      mount.sub_path == null ? {} : { subPath = mount.sub_path },
    )
  ]

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
    "N8N_REINSTALL_MISSING_PACKAGES",
    "N8N_TEMPLATES_ENABLED",
    "N8N_WEBHOOK_TIMEOUT",
    "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS",
    "TZ",
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

  # Authentication remains optional for external Redis. Managed Redis always
  # has an access key. These booleans declassify only whether a credential is
  # present, never the credential itself, so Helm and KEDA can omit dead secret
  # references without exposing the value.
  redis_password_present       = var.create_redis ? true : nonsensitive(var.redis_external_password != null)
  redis_username_present       = var.create_redis ? false : var.redis_external_username != null
  redis_authentication_enabled = local.redis_password_present ? true : local.redis_username_present

  # KEDA resolves TriggerAuthentication in the ScaledObject's namespace. The
  # manifest contains secret references only. Redis credentials remain in the
  # Kubernetes Secret and are never embedded in this CR.
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
          name      = local.n8n_redis_secret_name
          key       = "password"
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
    account_name      = azurerm_storage_account.n8n.name
    container_name    = azurerm_storage_container.n8n.name
    endpoint          = var.azure_blob_endpoint == null ? azurerm_storage_account.n8n.primary_blob_endpoint : var.azure_blob_endpoint
    auth_auto_detect  = var.azure_blob_connection_string == null && var.azure_blob_account_key == null
    connection_string = var.azure_blob_connection_string
    account_key       = var.azure_blob_account_key
  }

  # Remove absent optional destination fields before JSON encoding. n8n expects
  # the documented flat webhook, syslog, and Sentry objects, not explicit nulls.
  n8n_log_streaming_destinations = [
    for destination in var.n8n_log_streaming_destinations : {
      for name, value in destination : name => value if value != null
    }
  ]

}
