# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Application DNS ─────────────────────────────────────────────────────────
# DNS is optional and follows the module-managed Application Gateway frontend.
# A public Azure DNS zone targets the static public IP. A private Azure DNS
# zone targets the internal frontend IP. Variable validation makes the two
# paths mutually exclusive, requires the matching frontend mode, and keeps
# every managed host inside the selected zone.
#
# create_ingress = false deliberately creates no records even when a zone ID
# remains configured. The caller then owns both ingress and application DNS;
# check.dns_requires_module_managed_ingress reports the inert zone setting.

# The provider's own subscription ID, exactly as azurerm 4.x used it when it
# created private DNS records (it ignored the zone ID's subscription and
# built the record ID from this value). Read only on the private DNS path.
data "azurerm_client_config" "current" {
  count = local.private_dns_records_managed ? 1 : 0
}

locals {
  public_dns_zone_name = var.public_dns_zone_id == null ? null : lower(reverse(split("/", var.public_dns_zone_id))[0])
  public_dns_zone_resource_group_name = var.public_dns_zone_id == null ? null : split(
    "/",
    var.public_dns_zone_id,
  )[4]

  private_dns_zone_name = var.private_dns_zone_id == null ? null : lower(reverse(split("/", var.private_dns_zone_id))[0])
  private_dns_zone_resource_group_name = var.private_dns_zone_id == null ? null : split(
    "/",
    var.private_dns_zone_id,
  )[4]
  # azurerm 5.x addresses a private DNS record by zone ID, and that argument
  # forces replacement with an exact string compare. On refresh, 5.x rebuilds
  # the zone ID verbatim from the record's own ID, which azurerm 4.x created
  # from the provider's subscription ID, the zone ID's resource group segment,
  # and the lowercased zone name. Rebuild the same string, so records created
  # by 4.x are not replaced when the caller's zone ID differs only in casing.
  # A zone in another subscription keeps that subscription: 5.x can target it
  # (4.x always wrote into the provider's subscription).
  private_dns_zone_subscription_id = var.private_dns_zone_id == null ? null : (
    local.private_dns_records_managed && lower(split("/", var.private_dns_zone_id)[2]) == lower(try(data.azurerm_client_config.current[0].subscription_id, ""))
    ? data.azurerm_client_config.current[0].subscription_id
    : split("/", var.private_dns_zone_id)[2]
  )
  private_dns_zone_canonical_id = var.private_dns_zone_id == null ? null : format(
    "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/privateDnsZones/%s",
    local.private_dns_zone_subscription_id,
    local.private_dns_zone_resource_group_name,
    local.private_dns_zone_name,
  )

  public_dns_records_managed  = var.create_ingress && var.create_public_dns_record
  private_dns_records_managed = var.create_ingress && var.create_private_dns_record
}

resource "azurerm_dns_a_record" "n8n" {
  for_each = local.public_dns_records_managed ? toset(local.n8n_ingress_domains) : toset([])

  name = each.value == local.public_dns_zone_name ? "@" : trimsuffix(
    each.value,
    ".${local.public_dns_zone_name}",
  )
  zone_name           = local.public_dns_zone_name
  resource_group_name = local.public_dns_zone_resource_group_name
  ttl                 = 300
  records             = [azurerm_public_ip.appgw[0].ip_address]

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-${replace(each.value, ".", "-")}-public-a" })
}

resource "azurerm_private_dns_a_record" "n8n" {
  for_each = local.private_dns_records_managed ? toset(local.n8n_ingress_domains) : toset([])

  name = each.value == local.private_dns_zone_name ? "@" : trimsuffix(
    each.value,
    ".${local.private_dns_zone_name}",
  )
  private_dns_zone_id = local.private_dns_zone_canonical_id
  ttl                 = 300
  records             = [azurerm_application_gateway.n8n[0].frontend_ip_configuration[0].private_ip_address]

  tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-${replace(each.value, ".", "-")}-private-a" })
}

check "dns_requires_module_managed_ingress" {
  assert {
    condition     = var.create_ingress ? true : !var.create_public_dns_record && !var.create_private_dns_record
    error_message = "A module-managed DNS record toggle is enabled while create_ingress is false, so the module creates no application DNS records. Create records for the caller-owned ingress target or disable the DNS record toggle."
  }
}
