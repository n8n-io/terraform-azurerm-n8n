# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Cache (Azure Cache for Redis) ─────────────────────────────────────────────
# Private-only Redis Cache moved into modules/infra/ as part of Phase 5 R5.1d
# (registry-hardening US-017). Used as n8n's queue backend (worker dispatch)
# and multi-main coordination bus. Reachable from the AKS pods via a private
# endpoint on `var.redis_subnet_id` and the Azure private DNS zone created
# here (`privatelink.redis.cache.windows.net`, linked to `var.vnet_id`). With
# this wiring the cache's hostname resolves to its private IP from inside the
# VNet — no public endpoint is ever exposed.
#
# Hardened defaults applied unconditionally (not toggleable):
#   - public_network_access_enabled = false
#   - non_ssl_port_enabled          = false   (TLS-only on 6380)
#   - minimum_tls_version           = "1.2"
# `var.redis_sku_name` is constrained to {Standard, Premium} in variables.tf
# — Basic is excluded because the module always provisions a private endpoint
# and Basic does not support that.

# ── Private DNS zone + VNet link ──
# The DNS zone name MUST be `privatelink.redis.cache.windows.net` verbatim —
# the private endpoint's auto-registered A record only resolves correctly
# when the zone matches that exact name. Do not prefix with
# `friendly_name_prefix` or otherwise customize.
resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = var.resource_group_name

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-dns-zone" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "${var.friendly_name_prefix}-redis-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = var.vnet_id

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-dns-link" })
}

# ── Redis Cache ──
resource "azurerm_redis_cache" "n8n" {
  name                = local.redis_cache_name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku_name = var.redis_sku_name
  family   = var.redis_family
  capacity = var.redis_capacity

  non_ssl_port_enabled          = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false

  tags = merge(local.common_tags, { Name = local.redis_cache_name })
}

# ── Private Endpoint ──
# The private endpoint NIC lands on `var.redis_subnet_id` (which the caller
# pre-configures with `private_endpoint_network_policies` disabled — Azure
# refuses to create a private endpoint when network policies are enforced on
# the subnet, see variables.tf). The `private_dns_zone_group` block wires the
# endpoint's auto-registered A record into the
# `privatelink.redis.cache.windows.net` zone above — equivalent in effect to
# a standalone `azurerm_private_dns_a_record`, but managed by the platform
# (Azure rewrites the record on cache rebuild without operator intervention).
resource "azurerm_private_endpoint" "redis" {
  name                = "${var.friendly_name_prefix}-redis-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.redis_subnet_id

  private_service_connection {
    name                           = "${var.friendly_name_prefix}-redis-psc"
    private_connection_resource_id = azurerm_redis_cache.n8n.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${var.friendly_name_prefix}-redis-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }

  # The VNet link must exist before the private endpoint registers its A
  # record so DNS resolves from inside the VNet on first apply. azurerm
  # cannot infer this dependency from `private_dns_zone_ids` alone — the
  # link is a sibling of the zone, not a child. Same shape as the postgres
  # private DNS wiring in database.tf.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.redis]

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-redis-pe" })
}
