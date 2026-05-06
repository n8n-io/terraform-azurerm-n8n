# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for examples/complete/ — exercises the example end-to-end
# with mocked providers. Catches wiring mistakes between the example's hand-
# rolled VNet/subnets/RGs/DNS/KV, the modules/tls-self-signed/ submodule,
# and the two-tier `module.infra` + `module.workload` composition that the
# per-module test suites cannot see (those drive each module directly with
# literal fake IDs). Runs without Azure credentials.
#
# Run: cd examples/complete && terraform test
#   (no ARM_* env vars needed — every Azure / Kubernetes call is mocked.)

mock_provider "azurerm" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "kubectl" {}
mock_provider "time" {}
mock_provider "tls" {}

# `azurerm_key_vault.shared` validates `tenant_id` (and inline `access_policy[*]`
# `tenant_id` / `object_id`) as UUIDs at plan time. Under
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
  # Pin the friendly_name_prefix to the example's variable default rather
  # than rely on it. `terraform test` auto-loads `terraform.tfvars` if the
  # operator has one (e.g. from a live-apply rehearsal), and the
  # tfvars-supplied prefix would override the default and break every
  # name assertion below. Pinning here keeps the test self-contained
  # against any operator-side tfvars.
  friendly_name_prefix = "n8nlab"
}

# The plan succeeds and the example's wiring (RG / VNet / subnets / shared
# KV / self-signed submodule cert / module.infra / module.workload) all
# flow through.
run "example_produces_valid_plan" {
  command = plan

  # The submodule's `azurerm_key_vault_certificate.self_signed.secret_id`
  # is computed-at-apply (Azure assigns the versioned URI). Under
  # `mock_provider "azurerm"` `secret_id` stays unknown at plan time, which
  # would fail the App Gateway listener's `key_vault_secret_id`
  # var-pass-through assertion below. Pin a synthetic plan-known value via
  # override_resource so the passthrough resolves.
  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nlab-tls-kv.vault.azure.net/secrets/n8nlab-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  # Regression test for the count-on-unknown bug fixed in this PR:
  # `azurerm_key_vault.shared.id` is fed into `module.infra` as
  # `app_gateway_keyvault_id`. Under `mock_provider "azurerm"` the KV id is
  # computed-at-apply, so any `count = ... == null ? 0 : 1` driven off the
  # ID would fail at plan time. Pre-fix this test had to pin
  # `azurerm_key_vault.shared.id` via `override_resource` to make the count
  # resolve — hiding the bug from CI when callers wired the same ID into
  # the module from a real (i.e. live, computed-at-apply) Azure provider.
  #
  # Post-fix the count is gated on the explicit
  # `app_gateway_keyvault_role_assignment_enabled` bool toggle (a plan-time
  # literal in `examples/complete/main.tf`), so this override is no longer
  # needed. Leaving it OUT keeps the regression: if a future change wires
  # `count` (or `for_each`) back to the unknown KV id, the plan here will
  # fail with "The 'count' value depends on resource attributes that
  # cannot be determined until apply" — catching the regression in CI
  # before it reaches consumers.

  # ── Resource-group split ───────────────────────────────────────────────────
  # The example creates TWO RGs — a network RG (VNet/DNS/shared KV) and a
  # workload RG that flows into module.infra via var.resource_group_name.
  # Mirrors the typical platform-team / workload-team split.
  assert {
    condition     = azurerm_resource_group.network.name == "n8nlab-n8n-network-rg"
    error_message = "azurerm_resource_group.network.name should embed the example's friendly_name_prefix default (n8nlab) and the -n8n-network-rg suffix"
  }

  assert {
    condition     = azurerm_resource_group.n8n.name == "n8nlab-n8n-rg"
    error_message = "azurerm_resource_group.n8n.name should embed the example's friendly_name_prefix default (n8nlab) and the -n8n-rg suffix"
  }

  # ── Subnet wiring ──────────────────────────────────────────────────────────
  # Each subnet feeds a specific module.infra input. Asserting the
  # address_prefixes here verifies the example created the subnet AND the
  # module's plan saw it (otherwise the assertion target would be unknown).
  assert {
    condition     = azurerm_subnet.aks.address_prefixes[0] == "10.0.0.0/22"
    error_message = "azurerm_subnet.aks must be 10.0.0.0/22 — sized for the default 2–6 node AKS pool with Azure CNI"
  }

  assert {
    condition     = azurerm_subnet.appgw.address_prefixes[0] == "10.0.4.0/24"
    error_message = "azurerm_subnet.appgw must be 10.0.4.0/24 — App Gateway v2 minimum sizing"
  }

  # PostgreSQL subnet wiring AND delegation — the postgres flexible server
  # apply fails with a confusing "subnet not delegated" error if the
  # example's subnet is missing the Microsoft.DBforPostgreSQL/flexibleServers
  # delegation. The delegation block must use the exact service name.
  assert {
    condition     = azurerm_subnet.postgres.address_prefixes[0] == "10.0.5.0/24"
    error_message = "azurerm_subnet.postgres must be 10.0.5.0/24"
  }

  assert {
    condition     = azurerm_subnet.postgres.delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers"
    error_message = "azurerm_subnet.postgres.delegation must be 'Microsoft.DBforPostgreSQL/flexibleServers' — Azure rejects any other delegation at apply time"
  }

  # Redis private-endpoint subnet wiring — the network-policy attribute MUST
  # be 'Disabled' (azurerm 4.x string form) or Azure refuses to create the
  # private endpoint with a confusing "network policies are enforced" error.
  # Used by module.infra for both `redis_subnet_id` and
  # `private_endpoint_subnet_id` in this consolidated layout.
  assert {
    condition     = azurerm_subnet.redis_pe.address_prefixes[0] == "10.0.6.0/24"
    error_message = "azurerm_subnet.redis_pe must be 10.0.6.0/24"
  }

  assert {
    condition     = azurerm_subnet.redis_pe.private_endpoint_network_policies == "Disabled"
    error_message = "azurerm_subnet.redis_pe.private_endpoint_network_policies must be 'Disabled' — Azure refuses to create a private endpoint in a subnet with policies enforced"
  }

  # VNet uses 10.0.0.0/16 deliberately — the modules/infra/ submodule
  # hardcodes the AKS cluster Service CIDR to 172.16.0.0/16 to dodge the
  # azurerm default 10.0.0.0/16 collision; the VNet must NOT use
  # 172.16.0.0/16 either. address_space is a set(string), so use contains() —
  # set elements have no index in HCL.
  assert {
    condition     = contains(azurerm_virtual_network.n8n.address_space, "10.0.0.0/16")
    error_message = "azurerm_virtual_network.n8n.address_space must contain 10.0.0.0/16 — must not collide with the AKS Service CIDR (172.16.0.0/16)"
  }

  # ── Shared Key Vault wiring ────────────────────────────────────────────────
  # The submodule's cert destination + module.infra's role-assignment scope
  # via var.app_gateway_keyvault_id. Lives in the example's network RG and
  # embeds the friendly_name_prefix.
  assert {
    condition     = azurerm_key_vault.shared.resource_group_name == "n8nlab-n8n-network-rg"
    error_message = "azurerm_key_vault.shared must land in the example's network RG, not the workload RG"
  }

  assert {
    condition     = azurerm_key_vault.shared.name == "n8nlab-tls-kv"
    error_message = "azurerm_key_vault.shared.name must embed the example's friendly_name_prefix default (n8nlab) and the -tls-kv suffix"
  }

  # ── module.infra wiring ────────────────────────────────────────────────────
  # The AKS cluster name flows back out via module.infra.aks_cluster_name
  # and embeds the example's friendly_name_prefix verbatim. Proves the
  # example's friendly_name_prefix → module.infra.var.friendly_name_prefix
  # → modules/infra/locals.tf.cluster_name → outputs round-trip is intact.
  assert {
    condition     = module.infra.aks_cluster_name == "n8nlab-aks"
    error_message = "module.infra.aks_cluster_name must be 'n8nlab-aks' — proves the example's friendly_name_prefix flows through to the infra submodule's locals.tf and back out via outputs.tf"
  }

  # ── module.workload wiring ─────────────────────────────────────────────────
  # The chart-side n8n namespace + the public n8n URL flow back out via
  # module.workload's outputs. Proves the workload submodule sees the
  # example-supplied n8n_domain and the chart's namespace literal is honored.
  assert {
    condition     = module.workload.n8n_namespace == "n8n"
    error_message = "module.workload.n8n_namespace must be 'n8n' — the literal namespace name is part of the workload submodule's contract"
  }

  assert {
    condition     = module.workload.n8n_url == "https://n8n.test.example.com"
    error_message = "module.workload.n8n_url must be 'https://${var.n8n_domain}' — proves var.n8n_domain flows through the example to module.workload's outputs.tf"
  }

  # ── Public DNS zone wiring ─────────────────────────────────────────────────
  # The example owns the public DNS zone AND writes the A-record locally
  # (no Phase-2 dns.tf inside the modules — registry-hardening US-025
  # moved the A-record into the example so the modules stay free of
  # caller-owned DNS state).
  assert {
    condition     = azurerm_dns_zone.public.name == "test.example.com"
    error_message = "azurerm_dns_zone.public.name must equal var.public_dns_zone_name — the zone the example creates is what azurerm_dns_a_record.n8n writes into"
  }

  assert {
    condition     = azurerm_dns_zone.public.resource_group_name == "n8nlab-n8n-network-rg"
    error_message = "azurerm_dns_zone.public must land in the network RG, not the workload RG"
  }

  # The A-record's `name` is the leftmost-label of var.n8n_domain relative
  # to the zone — `n8n.test.example.com` in zone `test.example.com` → `n8n`.
  assert {
    condition     = azurerm_dns_a_record.n8n.name == "n8n"
    error_message = "azurerm_dns_a_record.n8n.name must be 'n8n' (the leftmost label of n8n_domain relative to the zone)"
  }

  assert {
    condition     = azurerm_dns_a_record.n8n.zone_name == "test.example.com"
    error_message = "azurerm_dns_a_record.n8n.zone_name must equal azurerm_dns_zone.public.name"
  }

  # ── Example output passthrough ─────────────────────────────────────────────
  # Re-exports module.workload.n8n_url — proves outputs.tf is wired through
  # the example to the module's outputs.
  assert {
    condition     = output.n8n_url == "https://n8n.test.example.com"
    error_message = "example output.n8n_url must pass through module.workload.n8n_url unchanged"
  }

  # Example output re-exports the zone name from the resource (not the var
  # directly), confirming the zone resource is in the plan and its name
  # attribute is plan-known.
  assert {
    condition     = output.public_dns_zone_name == "test.example.com"
    error_message = "example output.public_dns_zone_name must equal the var the user supplied — proves the resource's .name attribute is plan-known"
  }

  # Submodule output passthrough — proves `module.tls_self_signed` is wired
  # in and its `app_gateway_tls_cert_secret_id` output is non-null at plan
  # time (override_resource above pins the underlying secret_id).
  assert {
    condition     = output.tls_cert_secret_id != null
    error_message = "example output.tls_cert_secret_id must be wired through from module.tls_self_signed.app_gateway_tls_cert_secret_id"
  }

  # AKS resource group output reflects the workload RG (not the network RG).
  assert {
    condition     = output.aks_resource_group == "n8nlab-n8n-rg"
    error_message = "example output.aks_resource_group must be the workload RG (n8nlab-n8n-rg) — module.infra resources land here"
  }
}
