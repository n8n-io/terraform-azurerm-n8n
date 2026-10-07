# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Worker pools ──────────────────────────────────────────────────────────────
# EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE. This tracks two upstream
# features that are themselves alpha: n8n's own worker pools, and the chart
# support for them (queueMode.workerGroups, n8n-io/n8n-hosting#189), merged to
# the chart's preview/worker-pools branch but not released to a numbered chart
# version. This file's shape, defaults and guards may change to match either
# upstream, without the usual deprecation path.
#
# Maps var.n8n_worker_pools onto the chart's queueMode.workerGroups, which
# renders one worker Deployment per pool plus a KEDA ScaledObject watching that
# pool's own `jobs-<name>` queue.
#
# The module keeps its own input shape rather than passing the chart's through
# verbatim: pool names are validated at plan time (see variables.tf), the
# per-pool sizing knobs fall back to the module-wide worker defaults instead of
# the chart's, and a pool here is always a pool, whereas a chart worker group
# without a poolName is just an extra unlabelled worker deployment.
#
# Requires a chart version whose queueMode.workerGroups exists. n8n-hosting's
# own release-please cuts numbered releases from main independently of the
# preview/worker-pools branch that carries the feature, so no numbered
# version can be trusted as a floor: one that predates the feature ships
# under the same versioning scheme as one that would carry it, and a
# release cut from main can never prove the feature is present.
# Until n8n-io/n8n-hosting#189 merges to main and a numbered release
# actually carries it, only a prerelease build passes automatically, or a
# numbered build the caller attests with n8n_worker_pools_chart_verified
# (see that variable and locals.n8n_chart_renders_worker_pools below).
# n8n-io/n8n-hosting#191 registered a `Preview chart` GitHub Action on that
# repo's main branch that packages preview/worker-pools and publishes an
# official prerelease build to oci://ghcr.io/n8n-io/n8n-helm-chart (the
# default n8n_chart_repository) once someone with write access to that repo
# dispatches it against preview/worker-pools. A caller who cannot wait for
# that can push a self-built chart to a private mirror and point
# n8n_chart_repository at it. See n8n_chart_version, the
# precondition on helm_release.n8n, the n8n_image_tag floor validation in
# variables.tf, and examples/worker-pools/README.md for the exact command
# and a private-mirror fallback.

locals {
  # First n8n release that reads N8N_WORKER_POOLS_ENABLED and
  # N8N_WORKER_POOL_NAME (packages/@n8n/config, scaling-mode.config.ts, first
  # tagged in n8n@2.39.0). Older images accept both variables and ignore them:
  # mains never route to a pool and pool workers consume the default queue.
  # Enforced as a hard validation on var.n8n_image_tag (variables.tf), next to
  # the existing 2.19 and 2.29 feature floors on the same input.
  n8n_worker_pools_min_n8n_minor = 39

  # No numbered n8n-hosting release carries queueMode.workerGroups: the
  # feature is merged only to the preview/worker-pools branch, and main's own
  # release-please cuts ship independently of it. There is no real floor to
  # compare against yet, so a numbered version only passes if the caller
  # explicitly attests it with n8n_worker_pools_chart_verified -- for example
  # a private mirror serving a numbered build of the feature branch. A
  # prerelease passes automatically, taken at the caller's word via the
  # SemVer 2 "-prerelease" separator specifically, with no extra input
  # needed. n8n_chart_version's own validation rejects a bare
  # "+buildmetadata" suffix ("1.11.0+build.5") outright, so that form never
  # reaches this local; the hyphen check here is still written against the
  # separator rather than as "fails a strict X.Y.Z match" so that a future
  # loosening of the version regex cannot let a build-metadata-only string
  # fall through as if it were a prerelease (Helm ignores build metadata when
  # resolving from an HTTPS repository, so "1.11.0+build.5" can resolve to
  # plain "1.11.0", the exact silent no-render case this guard exists to
  # stop). Replace this whole local with a real floor and a numeric compare
  # once n8n-io/n8n-hosting#189 merges to main and a numbered release
  # carries the feature; n8n_worker_pools_chart_verified can retire at the
  # same time.
  n8n_chart_renders_worker_pools = (
    can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-", var.n8n_chart_version)) ||
    var.n8n_worker_pools_chart_verified
  )

  n8n_worker_groups = [
    for p in var.n8n_worker_pools : {
      # One group per pool, and the group is the pool: the chart allows a group
      # with no poolName (extra workers on the default queue), but this module
      # has n8n_worker_keda_{min,max}_replicas for sizing the default workers
      # and does not need a second way to do it.
      name     = p.name
      poolName = p.name

      concurrency = coalesce(p.concurrency, var.n8n_worker_concurrency)
      extraEnv    = p.extra_env

      resources = {
        requests = {
          cpu    = coalesce(p.cpu_request, var.n8n_worker_cpu_request)
          memory = coalesce(p.memory_request, var.n8n_worker_memory_request)
        }
        limits = {
          cpu    = coalesce(p.cpu_limit, var.n8n_worker_cpu_limit)
          memory = coalesce(p.memory_limit, var.n8n_worker_memory_limit)
        }
      }

      # The chart templates a pool's two default Redis triggers (wait/active
      # on the pool's own queue) itself; the module contributes the same
      # three pieces the default worker's hand-built triggers carry (n8n.tf):
      # the listLength threshold, enableTLS, and the shared
      # TriggerAuthentication reference. enableTLS is emitted unconditionally
      # ("true"/"false") exactly as the default worker does, so a live
      # comparison of the two ScaledObjects (tests/scripts/verify-worker-pools.sh)
      # is key-for-key. Without enableTLS a pool's scaler talks plaintext to a
      # TLS-only endpoint and the pool sits at min_replicas with nothing
      # crashing to announce it.
      #
      # Authentication goes through kubectl_manifest.keda_trigger_authentication
      # (keda.tf), the same namespaced CR the default worker's triggers
      # reference, so Redis credentials stay in the Kubernetes Secret and
      # never appear in ScaledObject metadata. On the unauthenticated
      # external-Redis path the key is omitted rather than sent as an empty
      # name: n8n.tf can send "" for the default worker because the chart
      # schema does not cover top-level keda, but workerGroups[].keda
      # .authenticationRef.name carries minLength 1 and Helm's schema
      # validation runs before the template's `and` guard, so "" fails the
      # render (verified against 1.11.0-preview.workerpools.1;
      # tests/scripts/check-n8n-chart.sh renders this exact path).
      keda = merge(
        {
          minReplicaCount = p.min_replicas
          maxReplicaCount = p.max_replicas
          # Same threshold the module gives the default worker's scaler, so a
          # pool's queue depth is read on the same scale as the default queue's.
          jobsPerReplica  = var.n8n_worker_keda_jobs_per_replica
          triggerMetadata = { enableTLS = tostring(local.redis_connection.tls_enabled) }
        },
        local.redis_authentication_enabled ? {
          authenticationRef = { name = local.n8n_redis_keda_auth_name }
        } : {},
      )
    }
  ]
}

# ── Guards ───────────────────────────────────────────────────────────────────
# Two plan-time hard stops, because the failure each catches is silent in
# every other place it could be caught.
#
# Chart pairing: a chart that predates queueMode.workerGroups has no
# additionalProperties: false on queueMode, so Helm accepts the key, renders
# nothing for it, and the release succeeds: N8N_WORKER_POOLS_ENABLED lands on
# every pod, no pool Deployment or ScaledObject exists, and every project
# pinned to a pool quietly runs on the default queue. Mocked plan-time tests
# cannot see any of that, and neither can a real plan; only counting the
# rendered Deployments after apply can (tests/scripts/verify-worker-pools.sh).
# Enforced as a precondition on helm_release.n8n (n8n.tf) because it is a
# property of that resource. A prerelease version is exempt automatically,
# which is how the official preview build (see the top of this file and
# examples/worker-pools/README.md) is installed while no release carries
# the feature; a numbered version passes only if the caller sets
# n8n_worker_pools_chart_verified, for a private mirror serving a numbered
# build it has already verified.
#
# Image pairing: an n8n image older than 2.39 accepts and ignores
# N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME, so the pods come up
# healthy while pool workers consume the default queue and every pool queue
# stays empty. var.n8n_image_tag always carries a validated X.Y.Z prefix in
# this module (its default is a pinned version, never the chart's floating
# tag, and its own regex rejects null), so the floor is fully decidable at
# plan time and lives as a validation block on that variable next to the
# existing 2.19 (log streaming) and 2.29 (Azure blob modes) floors.
#
# A missing feat:workerPools licence entitlement is the one pool-related
# failure that *is* loud (the pooled workers exit 1 and helm_release.n8n's
# atomic = true rolls the release back), but Terraform cannot see it at plan
# either.

locals {
  n8n_worker_pools_chart_error = join("", [
    "n8n_worker_pools declares ${length(var.n8n_worker_pools)} pool(s) but n8n_chart_version = \"${var.n8n_chart_version}\" ",
    "is a numbered release that n8n_worker_pools_chart_verified does not attest, and no numbered ",
    "n8n-hosting release carries queueMode.workerGroups yet: the feature (n8n-io/n8n-hosting#189) is ",
    "merged only to the chart's preview/worker-pools branch. That chart accepts the key and renders ",
    "nothing for it, so the release would apply cleanly with N8N_WORKER_POOLS_ENABLED switched on and no ",
    "pool Deployment or ScaledObject behind it, and every project pinned to a pool would run on the ",
    "default queue. Pin n8n_chart_version to a prerelease build that carries the feature (a version with ",
    "a hyphen is taken at your word, e.g. an official preview build such as ",
    "1.11.0-preview.workerpools.1 published to oci://ghcr.io/n8n-io/n8n-helm-chart via n8n-io/n8n-hosting's ",
    "Preview chart GitHub Action; see examples/worker-pools/README.md), set ",
    "n8n_worker_pools_chart_verified = true if this numbered version is a private mirror you have already ",
    "confirmed renders queueMode.workerGroups, or remove the pools.",
  ])
}
