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
  zone_name           = local.private_dns_zone_name
  resource_group_name = local.private_dns_zone_resource_group_name
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
