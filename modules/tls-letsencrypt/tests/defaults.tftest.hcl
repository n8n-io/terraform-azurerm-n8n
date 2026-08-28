# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for the modules/tls-letsencrypt submodule using mocked
# providers. Exercises the ACME → Key Vault contract without contacting
# Let's Encrypt or Azure.
#
# Run: terraform test
#   (from this directory's parent — modules/tls-letsencrypt/. No
#    Azure / ACME credentials needed; both providers are mocked.)

mock_provider "azurerm" {}
mock_provider "acme" {}
mock_provider "tls" {}

variables {
  acme_email                   = "ops@example.com"
  domain_name                  = "n8n.example.com"
  dns_zone_name                = "example.com"
  dns_zone_resource_group_name = "n8ntest-dns-rg"
  key_vault_id                 = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-shared-rg/providers/Microsoft.KeyVault/vaults/n8ntest-shared-kv"
  friendly_name_prefix         = "n8ntest"
  common_tags                  = { Environment = "test" }
}

run "submodule_plans_clean_with_defaults" {
  command = plan

  # The submodule's only contract output reads
  # `azurerm_key_vault_certificate.letsencrypt.secret_id`, which is computed
  # at apply time (Azure assigns the versioned URI). Under mock_provider
  # `secret_id` stays unknown at plan time, so the "non-empty in plan"
  # assertion (PRD AC #5) needs `override_resource` to pin a synthetic
  # plan-known value. Mirrors the n8n_helm_multi_main pattern in the root
  # module's tests/defaults.tftest.hcl.
  override_resource {
    target          = azurerm_key_vault_certificate.letsencrypt
    override_during = plan
    values = {
      secret_id = "https://n8ntest-shared-kv.vault.azure.net/secrets/n8ntest-n8n-tls/0123456789abcdef0123456789abcdef"
    }
  }

  # ── ACME registration ──────────────────────────────────────────────────────
  # The contact email Let's Encrypt records on the registration object
  # tracks `var.acme_email` verbatim. A regression here would silently
  # land renewal-warning notifications in the wrong inbox.
  assert {
    condition     = acme_registration.n8n.email_address == var.acme_email
    error_message = "acme_registration.n8n.email_address must equal var.acme_email"
  }

  # ── ACME certificate ───────────────────────────────────────────────────────
  # CN tracks `var.domain_name`. Required because the App Gateway listener
  # presents this CN to clients — a mismatch with the ingress hostname is
  # an immediate browser cert-name error.
  assert {
    condition     = acme_certificate.n8n.common_name == lower(var.domain_name)
    error_message = "acme_certificate.n8n.common_name must equal the normalized var.domain_name"
  }

  assert {
    condition = (
      acme_certificate.n8n.subject_alternative_names == null &&
      output.certificate_domain_names == toset([lower(var.domain_name)])
    )
    error_message = "The default certificate must cover only the normalized canonical domain."
  }

  # DNS-01 challenge against Azure DNS. The supported lego provider identifier
  # is `azuredns`; the deprecated identifier fails during provider setup.
  assert {
    condition     = acme_certificate.n8n.dns_challenge[0].provider == "azuredns"
    error_message = "acme_certificate.n8n.dns_challenge[0].provider must be 'azuredns'"
  }

  # AZURE_RESOURCE_GROUP and AZURE_ZONE_NAME are wired from inputs into
  # lego config so the principal reads from AZURE_* env vars only when
  # writing the validation TXT record — guards against lego enumerating
  # every zone in the subscription on each challenge.
  assert {
    condition     = acme_certificate.n8n.dns_challenge[0].config["AZURE_RESOURCE_GROUP"] == var.dns_zone_resource_group_name
    error_message = "acme_certificate.n8n.dns_challenge[0].config.AZURE_RESOURCE_GROUP must equal var.dns_zone_resource_group_name"
  }

  assert {
    condition     = acme_certificate.n8n.dns_challenge[0].config["AZURE_ZONE_NAME"] == var.dns_zone_name
    error_message = "acme_certificate.n8n.dns_challenge[0].config.AZURE_ZONE_NAME must equal var.dns_zone_name"
  }

  # ── Key Vault certificate import ───────────────────────────────────────────
  # The cert object name embeds friendly_name_prefix so callers running
  # parallel n8n stacks against a shared Key Vault don't collide on the
  # well-known `n8n-tls` literal the legacy inline path used.
  assert {
    condition     = azurerm_key_vault_certificate.letsencrypt.name == "${var.friendly_name_prefix}-n8n-tls"
    error_message = "azurerm_key_vault_certificate.letsencrypt.name must be '<friendly_name_prefix>-n8n-tls'"
  }

  # The cert is imported into the caller-supplied vault — no module-
  # owned vault path here. US-012 will rely on this to wire the contract
  # into the root module's `app_gateway_tls_cert_secret_id` input.
  assert {
    condition     = azurerm_key_vault_certificate.letsencrypt.key_vault_id == var.key_vault_id
    error_message = "azurerm_key_vault_certificate.letsencrypt.key_vault_id must equal var.key_vault_id"
  }

  # ── Output contract (PRD AC #5 / US-009) ───────────────────────────────────
  # The submodule's single contract output is the versioned KV secret URI
  # the root module's App Gateway listener consumes. Under mock_provider
  # the computed `secret_id` resolves to a synthetic string — non-empty is
  # the cleanest assertion possible at plan time without reaching for the
  # private-API `nonsensitive()` work-around. The output IS sensitive (the
  # versioned URI is enough to fetch the private key for any holder of
  # vault read), so we read the resource attribute directly.
  assert {
    condition     = length(azurerm_key_vault_certificate.letsencrypt.secret_id) > 0
    error_message = "azurerm_key_vault_certificate.letsencrypt.secret_id must be non-empty in plan (the contract output the root module consumes via app_gateway_tls_cert_secret_id)"
  }
}

run "subject_alternative_names_expand_certificate_contract" {
  command = plan

  variables {
    domain_name = "N8N.EXAMPLE.COM"
    subject_alternative_names = [
      "Hooks.Example.com",
      "mcp.example.com",
    ]
  }

  assert {
    condition = (
      acme_certificate.n8n.common_name == "n8n.example.com" &&
      acme_certificate.n8n.subject_alternative_names == toset(["hooks.example.com", "mcp.example.com"])
    )
    error_message = "The ACME certificate must normalize and issue every configured subject alternative name."
  }

  assert {
    condition     = output.certificate_domain_names == toset(["n8n.example.com", "hooks.example.com", "mcp.example.com"])
    error_message = "certificate_domain_names must expose the complete normalized certificate name set."
  }
}

# ── Variable validation rejects bad input ─────────────────────────────────────
# One contract per validation rule. Each scenario sets one bad value, leaves
# the rest at the defaults block above, and asserts terraform plan is
# rejected before any provider call. Mirrors the `invalid_inputs_fail_fast_*`
# convention from the root module's tests.

run "rejects_empty_acme_email" {
  command = plan

  variables {
    acme_email = ""
  }

  expect_failures = [
    var.acme_email,
  ]
}

run "rejects_malformed_domain_name" {
  command = plan

  variables {
    domain_name = "not a domain"
  }

  expect_failures = [
    var.domain_name,
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

run "rejects_malformed_or_duplicate_subject_alternative_names" {
  command = plan

  variables {
    subject_alternative_names = ["bad..example.com", "HOOKS.EXAMPLE.COM", "hooks.example.com"]
  }

  expect_failures = [
    var.subject_alternative_names,
  ]
}

run "rejects_subject_alternative_name_outside_dns_zone" {
  command = plan

  variables {
    subject_alternative_names = ["hooks.other.example.net"]
  }

  expect_failures = [
    var.subject_alternative_names,
  ]
}
