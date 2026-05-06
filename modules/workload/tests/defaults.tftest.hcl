# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for the modules/workload/ submodule using mocked providers.
# Asserts on the locals/variables surface the R5.2a (US-021) skeleton
# exposes; subsequent Phase 5 stories (US-022, US-023) layer in resource-
# specific assertions as resources are moved into this submodule.
#
# Run: terraform test
#   (from this directory's parent — modules/workload/. No live Kubernetes
#    or Azure credentials needed; every required provider is mocked.)
#
# Provider count under mock: 5 — kubernetes, helm, random, time, kubectl —
# matches the chart-only consumer's posture declared in versions.tf.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "kubectl" {}

variables {
  friendly_name_prefix               = "n8ntest"
  common_tags                        = { Environment = "test" }
  aks_cluster_name                   = "n8ntest-aks"
  aks_oidc_issuer_url                = "https://oidc.prod-aks.azure.com/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222/"
  postgres_fqdn                      = "n8ntest-postgres.postgres.database.azure.com"
  postgres_admin_username            = "n8n"
  postgres_admin_password            = "synthetic-test-postgres-password"
  postgres_database_name             = "n8n"
  redis_hostname                     = "n8ntest-redis.redis.cache.windows.net"
  redis_ssl_port                     = 6380
  redis_primary_access_key           = "synthetic-test-redis-key"
  storage_account_name               = "n8ntestn8nfiles"
  storage_account_primary_access_key = "synthetic-test-storage-key"
  storage_share_name                 = "n8n-binary-data"
  n8n_workload_uami_client_id        = "33333333-3333-3333-3333-333333333333"
  n8n_domain                         = "n8n.example.com"
  app_gateway_id                     = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/applicationGateways/n8ntest-appgw"
  app_gateway_tls_cert_secret_id     = "https://n8ntest-shared-kv.vault.azure.net/secrets/n8n-tls-cert/abc123"
  n8n_license_key                    = "synthetic-test-license-key"
}

run "skeleton_plans_clean_with_defaults" {
  command = plan

  # ── Namespace locals (mirrored from the root locals.tf, US-008) ────────────
  # The two namespace strings live in `local.<name>` so a future rename is a
  # single-local edit. Subsequent stories (US-022 / US-023) reference these
  # locals from the resources they move in; pinning the shape here means the
  # invariant is enforced before any consumer lands.
  assert {
    condition     = local.n8n_namespace == "n8n"
    error_message = "local.n8n_namespace must be 'n8n' (matches the root locals.tf shape and the chart's hardcoded namespace assumption)."
  }

  assert {
    condition     = local.keda_namespace == "keda"
    error_message = "local.keda_namespace must be 'keda' (matches the root locals.tf shape and the KEDA chart's default namespace)."
  }

  # ── common_tags shape ──────────────────────────────────────────────────────
  # The submodule-built-in `ManagedBy = terraform` and `Project = n8n` tags
  # must always be present, with caller-supplied tags merged on top. A
  # regression here would silently strip ownership tags from any taggable
  # resource a future story might surface in this submodule.
  assert {
    condition     = local.common_tags["ManagedBy"] == "terraform"
    error_message = "local.common_tags must always include ManagedBy = 'terraform'."
  }

  assert {
    condition     = local.common_tags["Project"] == "n8n"
    error_message = "local.common_tags must always include Project = 'n8n'."
  }

  assert {
    condition     = local.common_tags["Environment"] == "test"
    error_message = "local.common_tags must merge caller-supplied var.common_tags on top of the built-ins."
  }

  # ── Cross-tier inputs flow through verbatim ────────────────────────────────
  # The variables block above mirrors what `module.infra`'s outputs will
  # supply at the umbrella example layer (US-025). A regression here would
  # mean a caller-supplied value got lost or mutated by the variable
  # definition's `validation` blocks.
  assert {
    condition     = var.friendly_name_prefix == "n8ntest"
    error_message = "var.friendly_name_prefix must round-trip the caller-supplied value verbatim."
  }

  assert {
    condition     = var.n8n_main_replicas == 2
    error_message = "var.n8n_main_replicas must default to 2 (multi-main floor)."
  }

  assert {
    condition     = var.n8n_chart_version == "1.4.0"
    error_message = "var.n8n_chart_version must default to 1.4.0 (matches the root module pin)."
  }

  assert {
    condition     = var.key_vault_id == null
    error_message = "var.key_vault_id must default to null (the BYO-vault path is opt-in, not mandatory)."
  }
}

run "keda_resources_in_plan" {
  command = plan

  # ── KEDA namespace ─────────────────────────────────────────────────────────
  # `kubernetes_namespace.keda` is created explicitly (rather than via the
  # chart's `create_namespace = true`) so future stories can attach
  # cluster-level objects to it (NetworkPolicy / ResourceQuota) referencing
  # `kubernetes_namespace.keda.metadata[0].name`. The name reads
  # `local.keda_namespace` per the US-008 single-source-of-truth pattern.
  assert {
    condition     = kubernetes_namespace.keda.metadata[0].name == local.keda_namespace
    error_message = "kubernetes_namespace.keda.metadata[0].name must equal local.keda_namespace (registry-hardening US-008 single-source-of-truth pattern)."
  }

  # The 2-minute delete timeout is conservative — KEDA's controller pods are
  # small and the chart removes them quickly during destroy. Bumping it
  # above 2 m suggests something else (an orphaned CRD finalizer) is
  # stalling namespace deletion; tighten the dependency graph instead.
  # `timeouts` is a single block (not a list) on kubernetes_namespace, so
  # access via `.timeouts.delete` rather than `.timeouts[0].delete`.
  assert {
    condition     = kubernetes_namespace.keda.timeouts.delete == "2m"
    error_message = "kubernetes_namespace.keda.timeouts.delete must be '2m' (mirrors the root module + matches the KEDA chart's destroy footprint)."
  }

  # ── KEDA Helm release ──────────────────────────────────────────────────────
  # Chart pulled from the official KEDA repo at the caller-supplied pin so
  # plans stay deterministic across CI runs. The OCI variant is intentionally
  # not used here — the kedacore.github.io chart is the upstream-recommended
  # distribution path and avoids the OCI-credential edge cases the n8n chart
  # has to navigate.
  assert {
    condition     = helm_release.keda.name == "keda"
    error_message = "helm_release.keda.name must be 'keda' (matches the chart's default release name)."
  }

  assert {
    condition     = helm_release.keda.repository == "https://kedacore.github.io/charts"
    error_message = "helm_release.keda.repository must be the upstream KEDA chart repository."
  }

  assert {
    condition     = helm_release.keda.chart == "keda"
    error_message = "helm_release.keda.chart must be 'keda'."
  }

  assert {
    condition     = helm_release.keda.version == var.keda_chart_version
    error_message = "helm_release.keda.version must read var.keda_chart_version so the pin flows through from the umbrella example."
  }

  assert {
    condition     = helm_release.keda.namespace == kubernetes_namespace.keda.metadata[0].name
    error_message = "helm_release.keda.namespace must point at kubernetes_namespace.keda — implicit dependency keeps the namespace ahead of the release."
  }

  # `wait = true, atomic = true, timeout = 300, cleanup_on_fail = true`:
  # KEDA's Helm release is small enough that 300 s is sufficient; atomic +
  # cleanup_on_fail roll back failed installs cleanly so a half-installed
  # operator doesn't block subsequent applies.
  assert {
    condition     = helm_release.keda.wait == true
    error_message = "helm_release.keda.wait must be true (otherwise downstream resources race the operator's CRD installation)."
  }

  assert {
    condition     = helm_release.keda.atomic == true
    error_message = "helm_release.keda.atomic must be true (failed installs roll back cleanly)."
  }

  assert {
    condition     = helm_release.keda.cleanup_on_fail == true
    error_message = "helm_release.keda.cleanup_on_fail must be true (matches the atomic rollback intent)."
  }

  assert {
    condition     = helm_release.keda.timeout == 300
    error_message = "helm_release.keda.timeout must be 300 (KEDA chart fits comfortably in 5 minutes)."
  }

  # ── KEDA TriggerAuthentication YAML body ───────────────────────────────────
  # The yaml_body is rendered into a plan-known local so a regression here
  # (e.g. someone edits the body and breaks the apiVersion / kind / namespace
  # invariant) shows up at plan time rather than at apply time. yamlencode
  # quotes string keys/values, so substring assertions must include the
  # literal quotes (codebase pattern from the root tests).
  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"apiVersion\": \"keda.sh/v1alpha1\"")
    error_message = "local.keda_trigger_authentication_yaml must declare apiVersion keda.sh/v1alpha1 — the only version the n8n chart's worker ScaledObject template references."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"kind\": \"TriggerAuthentication\"")
    error_message = "local.keda_trigger_authentication_yaml must declare kind TriggerAuthentication."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"namespace\": \"${local.n8n_namespace}\"")
    error_message = "local.keda_trigger_authentication_yaml must place the CR in local.n8n_namespace (KEDA resolves the CR in the same namespace as the ScaledObject that references it)."
  }

  assert {
    condition     = strcontains(local.keda_trigger_authentication_yaml, "\"name\": \"${local.n8n_redis_secret_name}\"")
    error_message = "local.keda_trigger_authentication_yaml must read local.n8n_redis_secret_name so the CR points at US-023's kubernetes_secret.n8n_redis once it lands without a body rewrite."
  }

  # ── kubectl_manifest body wiring ───────────────────────────────────────────
  # The yaml_body argument reads `local.keda_trigger_authentication_yaml`
  # — round-trip-checked above. Plan-time assertions on the resource's
  # `yaml_body` attribute itself fall back to "(sensitive value)" under
  # `mock_provider "kubectl"` (the gavinbunney/kubectl provider marks the
  # field sensitive at the schema level), so the local-based assertions
  # above are the only stable check.
  #
  # `depends_on` is not an exported attribute on `kubectl_manifest`, so
  # the helm_release.keda ordering is enforced by the resource's source-
  # level `depends_on` block (keda.tf) rather than a plan-time test
  # condition. Same shape as the root module, where the equivalent
  # assertion isn't expressible either.
}

run "n8n_resources_in_plan" {
  command = plan

  # ── n8n namespace (US-023) ─────────────────────────────────────────────────
  # `kubernetes_namespace.n8n` is created explicitly (rather than via the
  # chart's `create_namespace = true`) so the namespace is the unambiguous
  # source of truth for every cross-file namespace reference (the
  # kubectl_manifest TriggerAuthentication body in keda.tf, the HPA's
  # metadata.namespace in scaling.tf). Name reads local.n8n_namespace
  # (US-008 single-source-of-truth pattern).
  assert {
    condition     = kubernetes_namespace.n8n.metadata[0].name == local.n8n_namespace
    error_message = "kubernetes_namespace.n8n.metadata[0].name must equal local.n8n_namespace (registry-hardening US-008 single-source-of-truth pattern)."
  }

  # 5-minute delete timeout matches the keda namespace and the AWS sibling —
  # namespaces with stuck finalizers can hang `terraform destroy`
  # indefinitely otherwise.
  assert {
    condition     = kubernetes_namespace.n8n.timeouts.delete == "5m"
    error_message = "kubernetes_namespace.n8n.timeouts.delete must be '5m' (mirrors the root module + matches the AWS sibling's destroy-resilience window)."
  }

  # ── Chart-side Secrets ─────────────────────────────────────────────────────
  # Four secrets per the US-023 AC: DB password, Redis access key, license
  # key, encryption key. The n8n_redis name MUST equal local.n8n_redis_secret_name
  # because keda.tf's TriggerAuthentication body references that local; a
  # rename here breaks KEDA queue-depth scaling silently.
  assert {
    condition     = kubernetes_secret.n8n_db.metadata[0].name == "n8n-db-secret"
    error_message = "kubernetes_secret.n8n_db.metadata[0].name must be 'n8n-db-secret' (chart's database.passwordSecret reference)."
  }

  assert {
    condition     = kubernetes_secret.n8n_db.metadata[0].namespace == kubernetes_namespace.n8n.metadata[0].name
    error_message = "kubernetes_secret.n8n_db.metadata[0].namespace must reference kubernetes_namespace.n8n (implicit dependency)."
  }

  assert {
    condition     = kubernetes_secret.n8n_redis.metadata[0].name == local.n8n_redis_secret_name
    error_message = "kubernetes_secret.n8n_redis.metadata[0].name must equal local.n8n_redis_secret_name (KEDA TriggerAuthentication body in keda.tf reads the same local — a rename here without updating the local breaks queue-depth scaling silently)."
  }

  assert {
    condition     = kubernetes_secret.n8n_license.metadata[0].name == "n8n-license-secret"
    error_message = "kubernetes_secret.n8n_license.metadata[0].name must be 'n8n-license-secret'."
  }

  assert {
    condition     = kubernetes_secret.n8n_encryption_key.metadata[0].name == "n8n-encryption-secret"
    error_message = "kubernetes_secret.n8n_encryption_key.metadata[0].name must be 'n8n-encryption-secret' (chart's secretRefs.existingSecret reference)."
  }

  # ── Task-runner shared auth token ────────────────────────────────────────────────────
  # The chart's task-runner sidecar (`taskRunners.enabled` in the helm
  # values) authenticates against the n8n main process via this shared
  # secret. The secret's name is pinned in `local.n8n_task_runners_secret_
  # name` so the chart-values reference and the resource name cannot drift.
  assert {
    condition     = kubernetes_secret.n8n_task_runners.metadata[0].name == "n8n-task-runners-secret"
    error_message = "kubernetes_secret.n8n_task_runners.metadata[0].name must be 'n8n-task-runners-secret' (chart's taskRunners.authToken.existingSecret reference)."
  }

  # The chart looks up the env-var name `N8N_RUNNERS_AUTH_TOKEN` in the
  # secret keyed off `taskRunners.authToken.existingSecretKey`. A regression
  # on the data key (e.g. accidentally renaming it `auth-token`) would
  # cause runner pods to crash at startup with a missing-env error.
  assert {
    condition     = contains(keys(kubernetes_secret.n8n_task_runners.data), "N8N_RUNNERS_AUTH_TOKEN")
    error_message = "kubernetes_secret.n8n_task_runners.data must contain key 'N8N_RUNNERS_AUTH_TOKEN' (chart's taskRunners.authToken.existingSecretKey reference)."
  }

  # The token's source is `random_password.n8n_task_runners_token`.
  # `length = 48 special = false` matches the n8n docs' "random secure
  # shared secret" guidance and dodges the JSON-escape edge cases the
  # encryption_key's `special = true` would have here.
  assert {
    condition     = random_password.n8n_task_runners_token.length == 48
    error_message = "random_password.n8n_task_runners_token.length must be 48 (matches n8n's recommended shared-secret entropy)."
  }

  assert {
    condition     = random_password.n8n_task_runners_token.special == false
    error_message = "random_password.n8n_task_runners_token.special must be false (the token travels through env vars + JSON; special chars trip escape handling on the runner side)."
  }

  # The n8n-azurefiles-credentials secret holds the storage account name +
  # key for the in-tree azure_file PV driver. Type Opaque is required by
  # the driver; data keys must be `azurestorageaccountname` /
  # `azurestorageaccountkey` exactly (otherwise the driver silently fails
  # to mount).
  assert {
    condition     = kubernetes_secret.n8n_files_credentials.metadata[0].name == "n8n-azurefiles-credentials"
    error_message = "kubernetes_secret.n8n_files_credentials.metadata[0].name must be 'n8n-azurefiles-credentials'."
  }

  assert {
    condition     = kubernetes_secret.n8n_files_credentials.type == "Opaque"
    error_message = "kubernetes_secret.n8n_files_credentials.type must be 'Opaque' (the in-tree azure_file PV driver only accepts Opaque)."
  }

  # ── Static PV/PVC bound to the pre-existing Azure Files share ──────────────
  # Capacity reads var.storage_share_quota_gb so the PV's declared size and
  # the upstream Azure share quota stay in lockstep. The PV's
  # share_name reads var.storage_share_name (passthrough from
  # modules/infra/.storage_share_name).
  assert {
    condition     = kubernetes_persistent_volume_v1.n8n_files.metadata[0].name == "${var.friendly_name_prefix}-n8n-files"
    error_message = "PV name must embed friendly_name_prefix."
  }

  assert {
    condition     = kubernetes_persistent_volume_v1.n8n_files.spec[0].capacity.storage == "${var.storage_share_quota_gb}Gi"
    error_message = "PV capacity must match var.storage_share_quota_gb (so the cluster-side claim and the Azure-side share quota stay aligned)."
  }

  # access_modes is a `set(string)` on this resource — set elements are not
  # addressable by index, so use `contains()` rather than `[0]` to assert
  # membership.
  assert {
    condition     = contains(kubernetes_persistent_volume_v1.n8n_files.spec[0].access_modes, "ReadWriteMany")
    error_message = "PV access_modes must include 'ReadWriteMany' — every n8n pod (main, worker, webhook) mounts the share concurrently."
  }

  assert {
    condition     = kubernetes_persistent_volume_v1.n8n_files.spec[0].persistent_volume_reclaim_policy == "Retain"
    error_message = "PV reclaim policy must be 'Retain' — the share is owned by Terraform via modules/infra/, not by the cluster."
  }

  assert {
    condition     = kubernetes_persistent_volume_v1.n8n_files.spec[0].persistent_volume_source[0].azure_file[0].share_name == var.storage_share_name
    error_message = "PV.azure_file.share_name must equal var.storage_share_name (passthrough from modules/infra/.storage_share_name)."
  }

  assert {
    condition     = kubernetes_persistent_volume_claim_v1.n8n_files.metadata[0].name == "n8n-binary-data"
    error_message = "PVC name must be 'n8n-binary-data' (the chart's persistence.existingClaim references this name)."
  }

  assert {
    condition     = kubernetes_persistent_volume_claim_v1.n8n_files.spec[0].volume_name == kubernetes_persistent_volume_v1.n8n_files.metadata[0].name
    error_message = "PVC volume_name must reference the static PV (binds the claim to the pre-existing share)."
  }

  # ── n8n Helm release ───────────────────────────────────────────────────────
  # Chart pinned via var.n8n_chart_version. wait/atomic/timeout/cleanup_on_fail
  # together absorb the multi-main migration race the legacy null_resource
  # workaround papered over (registry-hardening US-002).
  assert {
    condition     = helm_release.n8n.name == "n8n"
    error_message = "helm_release.n8n.name must be 'n8n'."
  }

  assert {
    condition     = helm_release.n8n.repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "helm_release.n8n.repository must be the official n8n-io OCI chart repository."
  }

  assert {
    condition     = helm_release.n8n.chart == "n8n"
    error_message = "helm_release.n8n.chart must be 'n8n'."
  }

  assert {
    condition     = helm_release.n8n.version == var.n8n_chart_version
    error_message = "helm_release.n8n.version must read var.n8n_chart_version so the pin flows through from the umbrella example."
  }

  assert {
    condition     = helm_release.n8n.namespace == kubernetes_namespace.n8n.metadata[0].name
    error_message = "helm_release.n8n.namespace must point at kubernetes_namespace.n8n (implicit dependency keeps the namespace ahead of the release)."
  }

  assert {
    condition     = helm_release.n8n.wait == true
    error_message = "helm_release.n8n.wait must be true (chart-native multi-main migration absorption depends on it)."
  }

  assert {
    condition     = helm_release.n8n.atomic == true
    error_message = "helm_release.n8n.atomic must be true (failed installs roll back cleanly)."
  }

  assert {
    condition     = helm_release.n8n.cleanup_on_fail == true
    error_message = "helm_release.n8n.cleanup_on_fail must be true (matches the atomic rollback intent)."
  }

  assert {
    condition     = helm_release.n8n.timeout == 600
    error_message = "helm_release.n8n.timeout must be 600 (covers chart deploy + multi-main migration completion)."
  }

  # The chart values block is yamlencoded into helm_release.n8n.values[0].
  # Substring assertions catch regressions in the database/Redis/persistence
  # wiring without re-rendering the entire YAML in the test. yamlencode
  # quotes string keys/values, so substring patterns must include the
  # literal quotes (codebase pattern).
  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"host\": \"${var.postgres_fqdn}\"")
    error_message = "helm_release.n8n values must include the postgres_fqdn as the database host (PRD AC '#1: helm_release.n8n is in plan with set blocks containing postgres_fqdn')."
  }

  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"host\": \"${var.redis_hostname}\"")
    error_message = "helm_release.n8n values must include the redis_hostname (PRD AC '#1: helm_release.n8n is in plan with set blocks containing redis_hostname')."
  }

  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"existingClaim\": \"n8n-binary-data\"")
    error_message = "helm_release.n8n values.persistence.existingClaim must reference the static PVC name 'n8n-binary-data'."
  }

  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"azure.workload.identity/client-id\": \"${var.n8n_workload_uami_client_id}\"")
    error_message = "helm_release.n8n values.serviceAccount.annotations must wire the n8n_workload UAMI client_id (workload identity contract)."
  }

  # ── Task-runner sidecar wiring (chart-rendered, var-controlled) ────────────────
  # The chart's `taskRunners.enabled` switch controls whether the
  # `n8nio/runners` sidecar is added to main + worker pods. We pin
  # `taskRunners.enabled` to the variable so operators can disable the
  # sidecar without forking the module; the auth-token wiring is
  # always set (the chart simply ignores it when `enabled = false`).
  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"taskRunners\":")
    error_message = "helm_release.n8n values must include a 'taskRunners' block (chart-rendered sidecar that runs Code-node JS / Python)."
  }

  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"existingSecret\": \"n8n-task-runners-secret\"")
    error_message = "helm_release.n8n values.taskRunners.authToken.existingSecret must reference 'n8n-task-runners-secret' (the kubernetes_secret name pinned in local.n8n_task_runners_secret_name)."
  }

  # ── KEDA `ScaledObject` wiring (chart-rendered, queue-depth driven) ──────────────
  # The chart's `keda.enabled` switch is what makes
  # `templates/scaledobject-worker.yaml` render. Without it the
  # `kubectl_manifest.keda_trigger_authentication` CR (keda.tf) is dead
  # weight — KEDA never picks it up because no ScaledObject references
  # it. The smoke test in tests/scripts/smoke-test.sh fails on a missing
  # ScaledObject; this assert catches the same regression at plan time.
  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"keda\":")
    error_message = "helm_release.n8n values must include a 'keda' block (chart-rendered worker ScaledObject for queue-depth-driven autoscaling)."
  }

  # The trigger's `authenticationRef.name` must match the
  # `local.n8n_redis_keda_trigger_auth_name` literal that
  # `kubectl_manifest.keda_trigger_authentication` (keda.tf) installs the
  # CR under. KEDA looks up the CR by name in the same namespace as the
  # ScaledObject; a mismatch silently disables queue-depth scaling.
  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"name\": \"n8n-redis-keda-auth\"")
    error_message = "helm_release.n8n values.keda.worker.triggers[0].authenticationRef.name must reference 'n8n-redis-keda-auth' (the TriggerAuthentication CR name pinned in local.n8n_redis_keda_trigger_auth_name)."
  }

  # `bull:jobs:wait` is the actual BullMQ list n8n writes to (queue name
  # `jobs`, prefix `bull`). The chart's stock value `bull:default:wait`
  # would never match real n8n traffic — the autoscaler would sit at
  # min replicas regardless of queue depth.
  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"listName\": \"bull:jobs:wait\"")
    error_message = "helm_release.n8n values.keda.worker.triggers[0].metadata.listName must be 'bull:jobs:wait' (the chart default 'bull:default:wait' does not match n8n's actual queue)."
  }

  # Azure Cache for Redis on port 6380 is TLS-only
  # (`non_ssl_port_enabled = false` in modules/infra/redis.tf). KEDA's
  # Redis scaler needs `enableTLS = "true"` (string) to use the TLS
  # transport — without it, the connection times out and the autoscaler
  # logs `connection refused`.
  assert {
    condition     = strcontains(helm_release.n8n.values[0], "\"enableTLS\": \"true\"")
    error_message = "helm_release.n8n values.keda.worker.triggers[0].metadata.enableTLS must be the string 'true' (Azure Redis is TLS-only on port 6380)."
  }

  # ── time_sleep.n8n_helm_settle (US-002 successor) ──────────────────────────
  assert {
    condition     = time_sleep.n8n_helm_settle.create_duration == "${var.n8n_helm_post_install_settle_seconds}s"
    error_message = "time_sleep.n8n_helm_settle.create_duration must read var.n8n_helm_post_install_settle_seconds."
  }

  # 60 s default — matches the legacy null_resource.post_deploy_restart window.
  assert {
    condition     = time_sleep.n8n_helm_settle.create_duration == "60s"
    error_message = "time_sleep.n8n_helm_settle.create_duration default must be 60s (matches the legacy null_resource.post_deploy_restart window)."
  }

  # ── time_sleep.wait_for_aks_drain (US-005 successor) ───────────────────────
  # destroy_duration is configured (plan-known under mock_provider "time").
  # The PRD AC '#1' requires this resource to be in plan inside this
  # submodule because it gates namespace + helm_release destroy.
  assert {
    condition     = time_sleep.wait_for_aks_drain.destroy_duration == "${var.aks_destroy_drain_seconds}s"
    error_message = "time_sleep.wait_for_aks_drain.destroy_duration must read var.aks_destroy_drain_seconds."
  }

  assert {
    condition     = time_sleep.wait_for_aks_drain.destroy_duration == "120s"
    error_message = "time_sleep.wait_for_aks_drain.destroy_duration default must be 120s (covers the typical Azure Files CIFS detach window)."
  }

  # ── n8n Ingress (AGIC-managed) ─────────────────────────────────────────────
  # AGIC reconciles this Kubernetes Ingress into App Gateway listeners /
  # pools / rules. The annotation surface gates ssl-redirect, backend
  # protocol, the App Gateway TLS cert lookup, request timeout, connection
  # draining, and cookie-based affinity.
  assert {
    condition     = kubernetes_ingress_v1.n8n.metadata[0].name == "n8n-ingress"
    error_message = "Ingress name must be 'n8n-ingress'."
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n.metadata[0].namespace == kubernetes_namespace.n8n.metadata[0].name
    error_message = "Ingress namespace must reference kubernetes_namespace.n8n."
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n.spec[0].ingress_class_name == "azure-application-gateway"
    error_message = "Ingress ingress_class_name must be 'azure-application-gateway' (AGIC reconciles Ingresses with this class)."
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n.spec[0].rule[0].host == var.n8n_domain
    error_message = "Ingress rule.host must equal var.n8n_domain (AGIC writes the matching host: rule onto the App Gateway listener)."
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/cookie-based-affinity"] == "Enabled"
    error_message = "Ingress cookie-based-affinity annotation must be 'Enabled' — without it, n8n's WebSocket connections break when the App Gateway round-robins between main replicas."
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n.metadata[0].annotations["appgw.ingress.kubernetes.io/appgw-ssl-certificate"] == "appgw-ssl-cert"
    error_message = "Ingress appgw-ssl-certificate annotation must be 'appgw-ssl-cert' (matches the cert resource name on the App Gateway, set by modules/infra/ingress.tf)."
  }
}

run "scaling_resources_in_plan" {
  command = plan

  # ── webhook-processor HPA ──────────────────────────────────────────────────
  # The chart's bundled webhook-processor HPA is suppressed when KEDA is on
  # (always, in this submodule), so the HPA is owned here. Targets the
  # n8n-webhook-processor Deployment that the n8n chart renders into the
  # n8n namespace; metadata.namespace must read local.n8n_namespace per
  # US-008.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.metadata[0].name == "n8n-webhook-processor"
    error_message = "HPA name must be 'n8n-webhook-processor' (matches the chart's Deployment name so the HPA's scale_target_ref resolves)."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.metadata[0].namespace == local.n8n_namespace
    error_message = "HPA metadata.namespace must equal local.n8n_namespace (registry-hardening US-008 single-source-of-truth pattern)."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].scale_target_ref[0].kind == "Deployment"
    error_message = "HPA scale_target_ref.kind must be 'Deployment' — the chart renders n8n-webhook-processor as a Deployment, not StatefulSet."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].scale_target_ref[0].name == "n8n-webhook-processor"
    error_message = "HPA scale_target_ref.name must be 'n8n-webhook-processor' (matches the chart's Deployment metadata.name)."
  }

  # min_replicas is hardcoded at 2 (multi-main floor — node-pool sizing in
  # modules/infra/aks.tf assumes this minimum). Only max_replicas is
  # caller-tunable.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].min_replicas == 2
    error_message = "HPA min_replicas must be 2 (multi-main topology floor — the AKS node-pool sizing in modules/infra/aks.tf assumes ≥2 webhook processors at minimum)."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].max_replicas == var.n8n_webhook_hpa_max_replicas
    error_message = "HPA max_replicas must read var.n8n_webhook_hpa_max_replicas so operators can size headroom for their expected webhook burst rate."
  }

  # 70% CPU is the canonical scale-out threshold per the n8n production
  # reference architecture. The metric type / resource shape is verified to
  # catch a regression where someone swaps to memory-based or external-metric
  # scaling silently.
  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].metric[0].type == "Resource"
    error_message = "HPA metric.type must be 'Resource' (CPU utilization, not external metrics)."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].metric[0].resource[0].name == "cpu"
    error_message = "HPA metric.resource.name must be 'cpu' (workers scale on Redis queue depth via KEDA; webhook processors scale on CPU)."
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.webhook_processor.spec[0].metric[0].resource[0].target[0].average_utilization == 70
    error_message = "HPA average_utilization must be 70 (canonical scale-out threshold per the n8n production reference architecture)."
  }
}

# ── Variable-level validation runs ────────────────────────────────────────────
# Mirrors the `invalid_inputs_fail_fast_*` convention from `modules/infra/`'s
# tests/. Each run flips a single variable to an invalid value and asserts
# Terraform rejects the plan at variable-validation time. Subsequent
# Phase-5 stories (US-023) extend this list as new variables land.

run "rejects_malformed_friendly_name_prefix" {
  command = plan

  variables {
    friendly_name_prefix = "Has-Capitals"
  }

  expect_failures = [
    var.friendly_name_prefix,
  ]
}

run "rejects_invalid_n8n_main_replicas" {
  command = plan

  variables {
    n8n_main_replicas = 1
  }

  expect_failures = [
    var.n8n_main_replicas,
  ]
}

run "rejects_invalid_n8n_chart_version" {
  command = plan

  variables {
    n8n_chart_version = "latest"
  }

  expect_failures = [
    var.n8n_chart_version,
  ]
}

run "rejects_placeholder_n8n_license_key" {
  command = plan

  variables {
    n8n_license_key = "REPLACE_ME_WITH_YOUR_N8N_LICENSE_KEY"
  }

  expect_failures = [
    var.n8n_license_key,
  ]
}

run "rejects_malformed_n8n_domain" {
  command = plan

  variables {
    n8n_domain = "not a domain"
  }

  expect_failures = [
    var.n8n_domain,
  ]
}

run "rejects_malformed_app_gateway_tls_cert_secret_id" {
  command = plan

  variables {
    app_gateway_tls_cert_secret_id = "https://example.com/secrets/cert"
  }

  expect_failures = [
    var.app_gateway_tls_cert_secret_id,
  ]
}

run "rejects_malformed_app_gateway_id" {
  command = plan

  variables {
    app_gateway_id = "not-a-resource-id"
  }

  expect_failures = [
    var.app_gateway_id,
  ]
}

run "rejects_malformed_key_vault_id" {
  command = plan

  variables {
    key_vault_id = "not-a-resource-id"
  }

  expect_failures = [
    var.key_vault_id,
  ]
}

run "rejects_invalid_keda_chart_version" {
  command = plan

  variables {
    keda_chart_version = "latest"
  }

  expect_failures = [
    var.keda_chart_version,
  ]
}

run "rejects_n8n_webhook_hpa_max_replicas_below_floor" {
  command = plan

  variables {
    n8n_webhook_hpa_max_replicas = 1
  }

  expect_failures = [
    var.n8n_webhook_hpa_max_replicas,
  ]
}

run "rejects_n8n_worker_keda_min_replicas_below_floor" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 0
  }

  expect_failures = [
    var.n8n_worker_keda_min_replicas,
  ]
}

run "rejects_n8n_worker_keda_max_replicas_below_floor" {
  command = plan

  variables {
    n8n_worker_keda_max_replicas = 0
  }

  expect_failures = [
    var.n8n_worker_keda_max_replicas,
  ]
}

run "rejects_n8n_worker_keda_target_list_length_below_floor" {
  command = plan

  variables {
    n8n_worker_keda_target_list_length = 0
  }

  expect_failures = [
    var.n8n_worker_keda_target_list_length,
  ]
}

run "rejects_storage_share_quota_below_floor" {
  command = plan

  variables {
    storage_share_quota_gb = 0
  }

  expect_failures = [
    var.storage_share_quota_gb,
  ]
}

run "rejects_storage_share_quota_above_ceiling" {
  command = plan

  variables {
    storage_share_quota_gb = 5121
  }

  expect_failures = [
    var.storage_share_quota_gb,
  ]
}

run "rejects_n8n_helm_post_install_settle_seconds_below_floor" {
  command = plan

  variables {
    n8n_helm_post_install_settle_seconds = 10
  }

  expect_failures = [
    var.n8n_helm_post_install_settle_seconds,
  ]
}

run "rejects_aks_destroy_drain_seconds_above_ceiling" {
  command = plan

  variables {
    aks_destroy_drain_seconds = 601
  }

  expect_failures = [
    var.aks_destroy_drain_seconds,
  ]
}

# ── Outputs contract (US-024) ─────────────────────────────────────────────────
# Mirrors the modules/infra/ US-020 pattern: `command = apply` is required for
# `output.<name> != null` checks because computed-at-apply attributes
# (helm_release.metadata[0].revision in particular) stay unknown in plan mode
# and collapse the assertion to "could not be evaluated at this time". Apply
# mode under `mock_provider` materialises every computed attribute with a
# synthesised non-null placeholder, exactly the contract this run locks in.
#
# `helm_release.n8n.metadata` is a computed-at-apply nested-block list under
# `mock_provider "helm"`: the synthesised value is an empty list, so any read
# of `metadata[0].<attr>` from `outputs.tf` fails with "Invalid index". The
# fix is the same shape modules/infra/'s output_contract_complete uses for
# the AKS cluster's `ingress_application_gateway` block — pin a synthetic
# populated `metadata` list via `override_resource.values`. Top-level
# nested-block lists with `MaxItems = 1` are an object under
# `override_resource.values`; `helm_release.metadata` is a normal list and
# accepts the wrapped-list shape.
run "output_contract_complete" {
  command = apply

  override_resource {
    target = helm_release.n8n
    values = {
      metadata = [
        {
          name           = "n8n"
          namespace      = "n8n"
          chart          = "n8n"
          version        = "1.4.0"
          app_version    = "1.0.0"
          values         = ""
          revision       = 1
          first_deployed = 0
          last_deployed  = 0
          notes          = ""
        }
      ]
    }
  }

  assert {
    condition     = output.n8n_url != null
    error_message = "output.n8n_url must be non-null."
  }

  assert {
    condition     = output.n8n_url == "https://${var.n8n_domain}"
    error_message = "output.n8n_url must be 'https://<var.n8n_domain>' (computed-from-input passthrough; locks in the scheme and the no-trailing-slash shape)."
  }

  assert {
    condition     = output.n8n_namespace != null
    error_message = "output.n8n_namespace must be non-null."
  }

  assert {
    condition     = output.n8n_namespace == local.n8n_namespace
    error_message = "output.n8n_namespace must equal local.n8n_namespace (single-source-of-truth pattern carried over from US-008)."
  }

  assert {
    condition     = output.n8n_helm_release_name != null
    error_message = "output.n8n_helm_release_name must be non-null."
  }

  assert {
    condition     = output.n8n_helm_release_name == "n8n"
    error_message = "output.n8n_helm_release_name must be 'n8n' (the chart's release name; reads helm_release.n8n.name)."
  }

  assert {
    condition     = output.n8n_helm_release_revision != null
    error_message = "output.n8n_helm_release_revision must be non-null (revision number bumps on every chart upgrade; consumed by callers gating post-apply reconciliation on rollout completion)."
  }
}
