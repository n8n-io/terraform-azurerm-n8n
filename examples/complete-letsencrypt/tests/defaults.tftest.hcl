# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for examples/complete-letsencrypt/ — exercises the example
# end-to-end with mocked providers. Catches wiring mistakes between the
# example, the modules/tls-letsencrypt/ submodule, and the two-tier
# `module.infra` + `module.workload` composition that the per-module test
# suites cannot see (those drive each module directly with literal fake
# IDs). Runs without Azure / ACME credentials.
#
# Run: cd examples/complete-letsencrypt && terraform test
#   (no ARM_* / AZURE_* env vars needed — every external call is mocked.)

mock_provider "azurerm" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "tls" {}
mock_provider "acme" {}
mock_provider "random" {}
mock_provider "time" {}

# `azurerm_key_vault` validates `tenant_id` (and inline `access_policy[*]`
# block's `tenant_id` / `object_id`) as UUIDs at plan time. Under
# `mock_provider "azurerm"`, `data.azurerm_client_config.current.*` resolves
# to synthetic non-UUID alphanumerics, which fails that validation. Pin
# UUID-shaped values here so the plan converges.
override_data {
  target = data.azurerm_client_config.current
  values = {
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    object_id       = "11111111-1111-1111-1111-111111111111"
    subscription_id = "22222222-2222-2222-2222-222222222222"
    client_id       = "33333333-3333-3333-3333-333333333333"
  }
}

variables {
  n8n_domain           = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
  public_dns_zone_name = "test.example.com"
  acme_email           = "ops@test.example.com"
}

run "example_produces_valid_plan" {
  command = plan

  # The submodule's `azurerm_key_vault_certificate.letsencrypt.secret_id` is
  # computed-at-apply (Azure assigns the versioned URI). Under
  # `mock_provider "azurerm"` `secret_id` stays unknown at plan time, which
  # would fail any non-null check on the example's
  # `output.tls_letsencrypt_cert_secret_id` passthrough. Pin a synthetic
  # plan-known value via override_resource so the passthrough resolves.
  override_resource {
    target          = module.tls_letsencrypt.azurerm_key_vault_certificate.letsencrypt
    override_during = plan
    values = {
      secret_id = "https://n8nlab-tls-kv.vault.azure.net/secrets/n8nlab-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  # Regression test for the count-on-unknown bug: post-fix the
  # `azurerm_role_assignment.appgw_kv_secrets_user` count is gated on the
  # explicit `app_gateway_keyvault_role_assignment_enabled` bool toggle
  # (a plan-time literal in `main.tf`), not on the unknown
  # `azurerm_key_vault.shared.id`. Leaving the override OUT keeps the
  # regression: if a future change re-wires the count to the unknown KV
  # id, this plan will fail with "The 'count' value depends on resource
  # attributes that cannot be determined until apply" — catching it in
  # CI before consumers see the same failure.

  # ── VNet / subnet wiring (same contract as examples/complete/) ──────────────
  assert {
    condition     = azurerm_subnet.aks.address_prefixes[0] == "10.0.0.0/22"
    error_message = "azurerm_subnet.aks must be 10.0.0.0/22 — sized for the default 2–6 node AKS pool with Azure CNI"
  }

  assert {
    condition     = azurerm_subnet.appgw.address_prefixes[0] == "10.0.4.0/24"
    error_message = "azurerm_subnet.appgw must be 10.0.4.0/24 — App Gateway v2 minimum sizing"
  }

  assert {
    condition     = azurerm_subnet.postgres.delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "azurerm_subnet.postgres.delegation must be 'Microsoft.DBforPostgreSQL/flexibleServers'"
  }

  assert {
    condition     = azurerm_subnet.redis_pe.private_endpoint_network_policies == "Disabled"
    error_message = "azurerm_subnet.redis_pe.private_endpoint_network_policies must be 'Disabled'"
  }

  # ── Public DNS zone wiring ──────────────────────────────────────────────────
  # Used by both the example's A-record AND the LE submodule's DNS-01
  # challenge.
  assert {
    condition     = azurerm_dns_zone.public.name == "test.example.com"
    error_message = "azurerm_dns_zone.public.name must equal var.public_dns_zone_name"
  }

  # ── Resource-group split ───────────────────────────────────────────────────
  assert {
    condition     = azurerm_resource_group.network.name == "n8nlab-n8n-network-rg"
    error_message = "azurerm_resource_group.network must hold the network plumbing (VNet/DNS/shared KV)"
  }

  assert {
    condition     = azurerm_resource_group.n8n.name == "n8nlab-n8n-rg"
    error_message = "azurerm_resource_group.n8n must hold the workload resources (passed to module.infra via var.resource_group_name)"
  }

  # ── Shared Key Vault (submodule cert destination) ──────────────────────────
  assert {
    condition     = azurerm_key_vault.shared.resource_group_name == "n8nlab-n8n-network-rg"
    error_message = "azurerm_key_vault.shared must land in the example's network RG, not the workload RG"
  }

  assert {
    condition     = azurerm_key_vault.shared.name == "n8nlab-tls-kv"
    error_message = "azurerm_key_vault.shared.name must embed the example's friendly_name_prefix default (n8nlab) and the -tls-kv suffix"
  }

  # ── Submodule wiring (Phase 4 R4.1 / US-009) ───────────────────────────────
  assert {
    condition     = output.tls_letsencrypt_cert_secret_id != null
    error_message = "example output.tls_letsencrypt_cert_secret_id must be wired through from module.tls_letsencrypt.app_gateway_tls_cert_secret_id"
  }

  # ── Two-tier module wiring (registry-hardening US-014..US-026) ─────────────
  assert {
    condition     = module.infra.aks_cluster_name == "n8nlab-aks"
    error_message = "module.infra.aks_cluster_name must be 'n8nlab-aks' — proves the example's friendly_name_prefix flows through modules/infra/"
  }

  assert {
    condition     = module.workload.n8n_url == "https://n8n.test.example.com"
    error_message = "module.workload.n8n_url must be 'https://${var.n8n_domain}' — proves the example's n8n_domain flows through modules/workload/"
  }

  # ── Output passthroughs ─────────────────────────────────────────────────────
  assert {
    condition     = output.n8n_url == "https://n8n.test.example.com"
    error_message = "example output.n8n_url must pass through module.workload.n8n_url unchanged"
  }

  assert {
    condition     = output.public_dns_zone_name == "test.example.com"
    error_message = "example output.public_dns_zone_name must equal the var the user supplied"
  }

  # ── Auto-managed A-record ───────────────────────────────────────────────────
  assert {
    condition     = azurerm_dns_a_record.n8n.name == "n8n"
    error_message = "azurerm_dns_a_record.n8n.name must be the leftmost label of var.n8n_domain relative to var.public_dns_zone_name (test config: 'n8n')"
  }

  assert {
    condition     = azurerm_dns_a_record.n8n.zone_name == "test.example.com"
    error_message = "azurerm_dns_a_record.n8n.zone_name must equal var.public_dns_zone_name"
  }
}
