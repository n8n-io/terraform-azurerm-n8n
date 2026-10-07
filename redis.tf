# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Azure Managed Redis topologies ────────────────────────────────────────
# Moved from `modules/infra/redis.tf` into this root concern file per
# align-azure-with-aws-capabilities section 4, gated behind `var.create_redis`
# so a caller can point n8n and KEDA at an external Redis endpoint instead
# of a module-managed one. Mirrors the `create_database` / `postgres_*`
# shape `database.tf` (section 3) already established.
#
# Replaces the legacy `azurerm_redis_cache` (Azure Cache for Redis) with
# `azurerm_managed_redis` (Azure Managed Redis / Redis Enterprise) per
# design.md decision 3 — this is a clean major-version deployment, so the
# resource-type replacement carries no migration burden.
#
# `azurerm_managed_redis.default_database` is configured with:
#   - `clustering_policy = "NoCluster"` — preserves the standard
#     non-clustered Redis endpoint semantics n8n's Bull queue client and
#     KEDA's Redis scaler expect (both assume a single logical keyspace,
#     not OSS/Enterprise-cluster key-slot routing). Verified against the
#     installed `hashicorp/azurerm` v4.81.0 provider that `NoCluster` is
#     accepted (GA'd August 2025 — see
#     https://learn.microsoft.com/en-us/azure/redis/whats-new#august-2025;
#     older provider releases (<4.60ish) reject it with `expected
#     default_database.0.clustering_policy to be one of ["EnterpriseCluster"
#     "OSSCluster"]` — hashicorp/terraform-provider-azurerm#30940). The
#     `>= 4.39.0, < 5.0.0` constraint in versions.tf allows 4.x releases
#     older than that; a caller pinned to a 4.x release before NoCluster
#     shipped will see that
#     same plan-time rejection from the provider itself.
#   - `client_protocol = "Encrypted"` — TLS-only, matching the legacy Redis
#     Cache's hardcoded `non_ssl_port_enabled = false`.
#   - `access_keys_authentication_enabled = true` — n8n and KEDA both
#     authenticate with the primary access key (design.md decision 3),
#     the same bearer-credential shape the legacy Redis Cache used.
#   - `eviction_policy = var.redis_eviction_policy` (default `"NoEviction"`).
#     The azurerm provider's own default is `VolatileLRU`, which can evict
#     any key carrying a TTL under memory pressure, including n8n's Bull
#     queue keys. `NoEviction` instead rejects writes with an OOM error when
#     Redis is full, so queue keys are never evicted to free memory. It
#     does not add persistence or stop TTL expiry. Unlike clustering_policy,
#     the provider changes eviction_policy in place (see the comment on the
#     attribute below).
# `public_network_access = "Disabled"` on the top-level resource matches
# the legacy Redis Cache's hardcoded `public_network_access_enabled = false`.
#
# NoCluster's documented size ceiling (Microsoft Learn, "Architecture" —
# https://learn.microsoft.com/en-us/azure/redis/architecture#cluster-policies):
# "This policy only applies to caches sized 25 GB and smaller." Rather than
# encode a full SKU-name-to-GB lookup table (Azure's SKU list spans four
# tiers and dozens of capacity points, and the mapping is not exposed by
# the provider schema), `redis_sku_name`'s validation block allowlists only
# the SKUs documented at 25 GB or smaller across the three tiers the
# `Balanced_B<N>` / `ComputeOptimized_X<N>` / `MemoryOptimized_M<N>` naming
# convention numbers in GB (`FlashOptimized_*` starts at 250 GB and is
# excluded entirely). This is what the "Reject an incompatible managed
# Redis SKU" spec scenario means by "a caller selects a SKU that does not
# support NoCluster or the selected capacity" — the module never offers a
# SKU where NoCluster is unavailable in the first place, rather than
# creating a database with a size/policy combination Azure would reject at
# apply time.

# ── Private DNS zone + VNet link (managed path only, unless caller-supplied) ──
# The DNS zone name MUST be `privatelink.redis.azure.net` verbatim. Azure
# Managed Redis retains the `Microsoft.Cache/redisEnterprise` ARM resource
# type and `redisEnterprise` private-link subresource, but its hostname and
# private DNS zone differ from legacy Azure Cache for Redis Enterprise. See
# https://learn.microsoft.com/azure/redis/private-link#azure-managed-redis-private-endpoint-private-dns-zone-value.
# Not created on the external path: an external Redis endpoint's DNS is the
# caller's responsibility. Also not created when
# `var.create_redis_private_dns_zone = false`: some landing zones centralize
# privatelink zones in a connectivity subscription (often under an Azure
# Policy DeployIfNotExists mandate), and a second same-named zone in the n8n
# resource group would conflict with that. The caller then owns the zone and
# its VNet link and passes its ID as `var.redis_private_dns_zone_id`. Gated
# on the boolean, never on the ID being null, so the ID may come from a
# resource created in the same apply (docs/customer-managed-infrastructure.md,
# rule 3).
resource "azurerm_private_dns_zone" "redis" {
  count = var.create_redis && var.create_redis_private_dns_zone ? 1 : 0

  name                = "privatelink.redis.azure.net"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-dns-zone" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  count = var.create_redis && var.create_redis_private_dns_zone ? 1 : 0

  name                  = "${var.friendly_name_prefix}-redis-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.redis[0].name
  virtual_network_id    = var.vnet_id

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-dns-link" })
}

# Selects the zone by the create_redis_private_dns_zone switch, not by
# whether the caller's ID is null, so a supplied ID is ignored (and the
# redis_private_dns_zone_inputs_ignored check warns) while the module still
# owns the zone. Consumed by the private endpoint's `private_dns_zone_group`
# below.
locals {
  redis_private_dns_zone_id = var.create_redis ? (
    var.create_redis_private_dns_zone
    ? one(azurerm_private_dns_zone.redis[*].id)
    : var.redis_private_dns_zone_id
  ) : null
}

# ── Azure Managed Redis (managed path only) ──
resource "azurerm_managed_redis" "n8n" {
  count = var.create_redis ? 1 : 0

  name                = local.redis_name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku_name = var.redis_sku_name
  # ForceNew ("Changing this forces a new Managed Redis instance to be
  # created" per the azurerm provider docs) — toggling this destroys and
  # recreates the queue backend, dropping in-flight Bull jobs and breaking
  # multi-main leader election until the new instance is reachable. Drain
  # the queue (scale workers to zero, let in-flight executions finish)
  # before flipping this in a live deployment; see README -> "Redis high
  # availability".
  high_availability_enabled = var.redis_high_availability_enabled
  public_network_access     = "Disabled"

  default_database {
    # Changing clustering_policy forces database recreation (data loss,
    # queue outage) per the azurerm provider docs. The module always
    # requests NoCluster, so this never changes across applies unless a
    # future version of this module changes the hardcoded value itself.
    clustering_policy = "NoCluster"
    client_protocol   = "Encrypted"
    # Not ForceNew: azurerm (verified against v4.81.0) updates
    # eviction_policy in place with a PUT on the existing default database;
    # it does not delete or recreate the instance or database. Moving to
    # NoEviction changes behavior: a full Redis then rejects writes instead
    # of evicting keys.
    # See docs/redis.md -> "Eviction policy".
    eviction_policy                    = var.redis_eviction_policy
    access_keys_authentication_enabled = true
  }

  tags = merge(local.common_tags, { Name = local.redis_name })
}

# ── Private Endpoint (managed path only) ──
# The private endpoint NIC lands on `var.redis_subnet_id` (which the caller
# pre-configures with `private_endpoint_network_policies` disabled — Azure
# refuses to create a private endpoint when network policies are enforced
# on the subnet, see variables.tf). `subresource_names = ["redisEnterprise"]`
# is the group ID Azure Managed Redis's underlying ARM resource type
# (`Microsoft.Cache/redisEnterprise`) exposes for private endpoints —
# confirmed against the AVM `terraform-azurerm-avm-res-cache-redisenterprise`
# module's private-endpoint example, which is the only public reference for
# this subresource name since the azurerm provider docs for
# `azurerm_managed_redis` do not document private-endpoint wiring directly
# (the resource itself has no `private_endpoint` block; a companion
# `azurerm_private_endpoint` is required, same shape as Postgres/Redis
# Cache).
resource "azurerm_private_endpoint" "redis" {
  count = var.create_redis ? 1 : 0

  name                = "${var.friendly_name_prefix}-redis-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.redis_subnet_id

  private_service_connection {
    name                           = "${var.friendly_name_prefix}-redis-psc"
    private_connection_resource_id = azurerm_managed_redis.n8n[0].id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${var.friendly_name_prefix}-redis-dns-zone-group"
    private_dns_zone_ids = [local.redis_private_dns_zone_id]
  }

  # The VNet link must exist before the private endpoint registers its A
  # record so DNS resolves from inside the VNet on first apply. azurerm
  # cannot infer this dependency from `private_dns_zone_ids` alone — the
  # link is a sibling of the zone, not a child. Same shape as the Postgres
  # private DNS wiring in database.tf.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.redis]

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-pe" })
}

# ── Canonical Redis connection ────────────────────────────────────────────
# Single source of truth for "what does n8n (and KEDA) connect to",
# selecting between the module-managed Managed Redis database and the
# caller-supplied external endpoint based on `var.create_redis`. Section 6
# (controllers/n8n Helm values) and, once ported from
# `modules/workload/keda.tf`, the KEDA `TriggerAuthentication` wiring both
# read from this local exclusively rather than re-branching on
# `var.create_redis` themselves — this is what design.md decision 3 means
# by "Locals select one canonical connection object consumed by both Helm
# and KEDA, preventing drift between execution and scaling clients." Both
# resources that would consume the shared Kubernetes Secret this local
# feeds (`kubernetes_secret.n8n_redis` and
# `kubectl_manifest.keda_trigger_authentication`) do not exist at the root
# yet — they move from `modules/workload/` into root controller files in
# section 6 — so this section only establishes the connection contract;
# section 6 wires it into the Secret both n8n and KEDA reference (mirrors
# how section 3's `local.postgres_connection` predates the n8n Helm release
# that reads it).
#
# `username = null` on the managed path: Azure Managed Redis access-key
# authentication (Redis's legacy `AUTH <password>` form) has no username
# concept — only Redis 6+ ACL-based auth (`AUTH <username> <password>`)
# does, and this module does not use ACL auth. External Redis deployments
# that use ACL auth can still supply `redis_external_username`.
locals {
  redis_connection = {
    host        = var.create_redis ? azurerm_managed_redis.n8n[0].hostname : var.redis_external_host
    port        = var.create_redis ? azurerm_managed_redis.n8n[0].default_database[0].port : var.redis_external_port
    tls_enabled = var.create_redis ? true : var.redis_external_tls_enabled
    username    = var.create_redis ? null : var.redis_external_username
    password    = var.create_redis ? azurerm_managed_redis.n8n[0].default_database[0].primary_access_key : var.redis_external_password
  }
}

# ── Diagnostics: incompatible / ignored Redis settings ────────────────────
# Mirrors the two-direction check pair `database.tf` (section 3) already
# established: one direction is a hard error via the `redis_external_*`
# variables' own `validation` blocks (required when `create_redis = false`);
# the other direction — settings that plan and apply cleanly while quietly
# being ignored — only a `check` block can catch, because neither
# `terraform validate` nor a `count`-gated resource's absence surfaces it.

# A caller who sets redis_external_* while create_redis defaults to true (or
# stays true) gets a module-managed Managed Redis instance anyway, and n8n +
# KEDA connect to that — both a managed database and the (unused) external
# inputs exist, the apply succeeds, and the queue lands somewhere the
# caller isn't watching. Mirrors
# `external_postgres_inputs_require_create_database_false`.
check "external_redis_inputs_require_create_redis_false" {
  assert {
    condition = var.create_redis ? (
      var.redis_external_host == null &&
      var.redis_external_username == null &&
      var.redis_external_password == null
    ) : true
    error_message = join("", [
      "redis_external_host, redis_external_username, or redis_external_password is set while ",
      "create_redis = true, so all three are ignored: the module creates its own Azure Managed Redis ",
      "instance and points n8n and KEDA at that, not at the Redis you supplied. Set create_redis = ",
      "false to use an external Redis endpoint.",
    ])
  }
}

# The inverse: managed-instance sizing/HA inputs left at anything other than
# their documented defaults while create_redis = false have no effect —
# azurerm_managed_redis.n8n does not exist in that mode. Mirrors
# `postgres_tuning_requires_module_managed_database`. KEEP THESE LITERALS IN
# LOCKSTEP WITH variables.tf defaults: a default bumped there without
# updating this check makes every create_redis = false caller who left the
# input alone warn spuriously.
check "redis_tuning_requires_module_managed_redis" {
  assert {
    condition = var.create_redis ? true : (
      var.redis_sku_name == "Balanced_B1" &&
      var.redis_high_availability_enabled == false &&
      var.redis_eviction_policy == "NoEviction"
    )
    error_message = join("", [
      "redis_sku_name, redis_high_availability_enabled, or redis_eviction_policy is set while create_redis ",
      "= false. The module creates no Azure Managed Redis instance in that mode, so none of these apply. ",
      "Sizing, high availability, and eviction policy are properties of the Redis you supply via ",
      "redis_external_host.",
    ])
  }
}

# Same contract as database.tf's postgres_private_dns_zone_inputs_ignored:
# the zone inputs only take effect with create_redis = true and
# create_redis_private_dns_zone = false. Warn, do not fail, on any other
# combination that changes either input from its default.
check "redis_private_dns_zone_inputs_ignored" {
  assert {
    # Keep this a single-line ternary, matching the same check in
    # database.tf and storage.tf, where the multi-line form made checkov
    # 3.3.17 silently drop findings. Equivalent to "valid only when the
    # module manages the redis resource and not its zone, or when nothing
    # was supplied".
    condition = var.create_redis_private_dns_zone ? var.redis_private_dns_zone_id == null : var.create_redis
    error_message = join("", [
      "redis_private_dns_zone_id or create_redis_private_dns_zone is set but has no effect. ",
      var.create_redis
      ? "With create_redis_private_dns_zone left at true the module creates and uses its own zone and never reads redis_private_dns_zone_id. Set create_redis_private_dns_zone = false to attach the private endpoint to the zone you supplied."
      : "With create_redis = false the module creates no Azure Managed Redis instance or private endpoint, so neither private DNS zone input applies. Configure DNS for the external Redis you supply via redis_external_host.",
    ])
  }
}
