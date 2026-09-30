# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

mock_provider "azurerm" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

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
  friendly_name_prefix = "n8nwpool"
  n8n_domain           = "n8n.test.example.com"
  public_dns_zone_name = "test.example.com"
  n8n_license_key      = "test-license-key-not-real"

  # Required by this example (see variables.tf). A prerelease, because at the
  # time of writing the only chart that renders queueMode.workerGroups is a
  # preview build of n8n-io/n8n-hosting#189, and the module's precondition on
  # helm_release.n8n takes a prerelease at the caller's word rather than
  # comparing it against a release that does not exist yet.
  n8n_chart_version = "1.11.0-preview.workerpools.1"
}

# Every run below overrides the self-signed certificate's computed secret_id
# the same way examples/small does: some downstream reference needs a known
# value at plan time, and this keeps every run's plan clean.

# ── Pool topology ─────────────────────────────────────────────────────────────
# The pool topology is what this example is for, so it is asserted rather than
# left to the plan alone. local.worker_pools in main.tf is the declaration
# these read; a literal at the module call site would not be reachable here.
# Coverage does not depend on whether module "n8n"'s own n8n_worker_pools line
# is currently commented out: local.worker_pools, and the output derived from
# it, exist either way.

run "example_declares_the_three_documented_pools" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nwpool-tls-test.vault.azure.net/secrets/n8nwpool-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = [for p in local.worker_pools : p.name] == ["heavy", "secteam", "itop"]
    error_message = "The example's pools drifted from the three the README documents: got ${join(", ", [for p in local.worker_pools : p.name])}."
  }

  # Every name has to satisfy the module's own rule, which is tighter than it
  # looks: 1-43 characters, lowercase alphanumerics and hyphens, and both ends
  # alphanumeric, because the chart names the pool's ScaledObject
  # n8n-worker-<name> and KEDA caps that at 54. Asserted here so the example
  # cannot ship a name that plans clean at the example layer and fails the
  # chart's render at apply.
  assert {
    condition = alltrue([
      for p in local.worker_pools :
      can(regex("^[a-z0-9]([a-z0-9-]{0,41}[a-z0-9])?$", p.name))
    ])
    error_message = "An example pool name does not satisfy the module's pool-name rule."
  }

  # verify-worker-pools.sh reads this output to know how many pools to expect
  # on the cluster. Pinned to the literal list rather than to local.worker_pools,
  # which is what outputs.tf already derives it from and would make the compare
  # tautological.
  assert {
    condition     = output.worker_pool_names == ["heavy", "secteam", "itop"]
    error_message = "output.worker_pool_names is ${jsonencode(output.worker_pool_names)}; the live verification script counts against this list, so update it together with the README."
  }

  assert {
    condition     = length(distinct([for p in local.worker_pools : p.name])) == length(local.worker_pools)
    error_message = "The example declares two pools with the same name; each pool is one Deployment and one queue, so they would collide."
  }
}

run "example_keeps_a_scale_to_zero_pool_and_a_resized_pool" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nwpool-tls-test.vault.azure.net/secrets/n8nwpool-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  # itop exists to show min_replicas = 0 is legal. If it stops being 0 the
  # example silently stops demonstrating scale-to-zero.
  assert {
    condition     = one([for p in local.worker_pools : p.min_replicas if p.name == "itop"]) == 0
    error_message = "The itop pool is the example's scale-to-zero case and must keep min_replicas = 0."
  }

  # heavy is the one pool that overrides sizing; the other two exist to show
  # the fallback to the module-wide worker defaults. Asserted on the values
  # the README's topology table quotes and the node-capacity arithmetic in
  # main.tf is derived from, so the two cannot drift apart silently.
  assert {
    condition     = one([for p in local.worker_pools : p.concurrency if p.name == "heavy"]) == 5
    error_message = "The heavy pool is the example's lower-concurrency case and must keep concurrency = 5, which is the value the README table quotes."
  }

  assert {
    condition     = one([for p in local.worker_pools : p.cpu_request if p.name == "heavy"]) == "1"
    error_message = "The heavy pool is the example's resized case and must keep cpu_request = \"1\"; the aks_node_count_max arithmetic in main.tf is derived from it."
  }
}

run "example_pool_ceilings_match_the_node_max_arithmetic" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nwpool-tls-test.vault.azure.net/secrets/n8nwpool-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  # local.tier.aks_node_count_max is a literal 7 in main.tf, raised from
  # small's 6 purely to hold these pools at their maxima on top of the main,
  # default-worker and webhook ceilings. aks_node_count_max is not reachable
  # from here, so this guards the other half: if the pool ceilings grow, the
  # arithmetic behind that 7 (and aks_node_vm_size = Standard_D4s_v5) no
  # longer holds and the module's advisory capacity check starts warning on
  # the example this repo ships.
  assert {
    condition     = sum([for p in local.worker_pools : p.max_replicas]) == 10
    error_message = "The example's pool maxima changed (now ${sum([for p in local.worker_pools : p.max_replicas])} pods). Re-check aks_node_count_max and aks_node_vm_size against the arithmetic in main.tf before updating this assertion."
  }
}

# ── Chart version ─────────────────────────────────────────────────────────────
# The example cannot be applied against the module's default chart, because
# that chart renders no pools once local.worker_pools is wired in. The
# variable is required rather than defaulted so a caller has to choose; these
# pin that it stays required and stays strict.

run "chart_version_is_required_and_must_be_exact" {
  command = plan

  variables {
    n8n_chart_version = "~> 1.12"
  }

  expect_failures = [var.n8n_chart_version]
}

run "rejects_malformed_chart_repository" {
  command = plan

  variables {
    n8n_chart_repository = "not-a-url"
  }

  expect_failures = [var.n8n_chart_repository]
}

run "chart_repository_defaults_to_upstream" {
  command = plan

  assert {
    condition     = var.n8n_chart_repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "n8n_chart_repository must default to the same upstream registry the official preview build publishes to."
  }
}

# No assert on purpose beyond the default check above: main.tf wires
# n8n_chart_repository straight through to module "n8n"'s own input of the
# same name, and the root module's own test suite
# (passes_custom_n8n_chart_repository_to_the_helm_release in
# tests/defaults.tftest.hcl) already proves that input reaches
# helm_release.n8n.repository. A non-default value here has nothing further
# to assert on from outside the module, so the coverage is that the plan
# still succeeds with it set.
run "chart_repository_accepts_a_private_mirror" {
  command = plan

  variables {
    n8n_chart_repository = "oci://n8nchartmirror.azurecr.io/n8n-helm-chart"
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nwpool-tls-test.vault.azure.net/secrets/n8nwpool-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }
}

# No assert on purpose: the coverage is that the plan succeeds. A prerelease
# has to pass this example's own format validation, and a run whose plan
# errors fails the run.
run "chart_version_accepts_a_prerelease_build" {
  command = plan

  variables {
    n8n_chart_version = "1.11.0-preview.workerpools.3"
  }

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nwpool-tls-test.vault.azure.net/secrets/n8nwpool-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }
}

# ── Baseline plan ─────────────────────────────────────────────────────────────
# Confirms the example plans cleanly end to end (VNet, DNS zone, Key Vault,
# TLS cert, module "n8n") with the pool-related inputs at their documented
# defaults, the same way examples/small's own baseline run does.

run "worker_pools_example_plan" {
  command = plan

  override_resource {
    target          = module.tls_self_signed.azurerm_key_vault_certificate.self_signed
    override_during = plan
    values = {
      secret_id = "https://n8nwpool-tls-test.vault.azure.net/secrets/n8nwpool-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "The root module URL output must preserve the canonical domain."
  }

  assert {
    condition     = output.tier_configuration.aks_node_vm_size == "Standard_D4s_v5" && output.tier_configuration.aks_node_count_max == 7
    error_message = "The worker-pools example must preserve its documented node capacity sizing."
  }
}
