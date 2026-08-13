# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# The large tier owns PostgreSQL outside the root n8n module so n8n can reach it
# through the two-replica PgBouncer service. The server remains standard Azure
# PostgreSQL Flexible Server, not a PostgreSQL-compatible derivative.
resource "random_password" "postgres" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.n8n.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.friendly_name_prefix}-postgres-link"
  resource_group_name   = azurerm_resource_group.n8n.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.n8n.id
  tags                  = local.common_tags
}

resource "azurerm_postgresql_flexible_server" "n8n" {
  name                = "${var.friendly_name_prefix}-postgres"
  resource_group_name = azurerm_resource_group.n8n.name
  location            = var.location

  version  = "16"
  sku_name = local.tier.postgres_sku_name

  storage_mb                   = local.tier.postgres_storage_mb
  backup_retention_days        = 35
  geo_redundant_backup_enabled = true

  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  administrator_login    = "n8n"
  administrator_password = random_password.postgres.result
  zone                   = "1"

  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "2"
  }

  maintenance_window {
    day_of_week  = 0
    start_hour   = 3
    start_minute = 0
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone,
    ]
  }
}

resource "azurerm_postgresql_flexible_server_configuration" "uuid_ossp" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.n8n.id
  value     = "UUID-OSSP"
}

resource "azurerm_postgresql_flexible_server_database" "n8n" {
  name      = "n8n"
  server_id = azurerm_postgresql_flexible_server.n8n.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
