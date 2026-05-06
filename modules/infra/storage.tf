# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Storage (Azure Files) ─────────────────────────────────────────────────────
# Shared filesystem for n8n binary data: uploaded files, attachments, anything
# the n8n binary-data manager writes to disk. All n8n pods (main, workers,
# webhook processors) mount this share read-write-many so every replica sees
# the same files — the Azure-native equivalent of the S3 bucket in
# `terraform-aws-n8n`, with POSIX semantics so n8n needs no cloud-specific
# upload code path.
#
# Moved into `modules/infra/` as part of Phase 5 R5.1e (registry-hardening
# US-018). The `modules/workload/` tier (US-023) consumes the outputs defined
# in `outputs.tf` to build the chart-side static PV / PVC + Azure Files
# credentials Secret.
#
# Hardened defaults applied unconditionally (not toggleable):
#   - https_traffic_only_enabled = true     (reject plain-HTTP REST calls)
#   - min_tls_version            = "TLS1_2"
#
# Account tier is Standard / StorageV2 with caller-tunable replication type
# (default LRS — Azure Files Standard tier, 1–5120 GB per share, transactional
# billing). Premium Files would require `account_kind = "FileStorage"` and is
# out of scope here. The `account_replication_type` is the only knob that
# escaped beyond the root's hardcoded "LRS" — geo-redundant / zone-redundant
# replication is a follow-up DR story.
#
# Deferred wiring:
#   - The optional CMK toggle (UserAssigned identity + customer_managed_key
#     dynamic blocks) is NOT moved here. The `storage_cmk` UAMI lives in the
#     root iam.tf which migrates with App Gateway in US-019; that story can
#     re-introduce the CMK toggle as a follow-on input + dynamic blocks once
#     the identity is local to this submodule. Same shape decision US-016
#     took for the postgres_cmk dynamic blocks.
#
# Destroy ordering: deleting the storage account deletes every share inside
# it, so no equivalent of S3's `force_destroy` is needed. The pre-destroy pod
# drain (`time_sleep.wait_for_aks_drain` in modules/workload/, US-005) is what
# keeps `terraform destroy` from hanging on Azure Files volume-detach delays
# — without that drain, pods still mounting the share block the storage
# account from being deleted.

resource "azurerm_storage_account" "n8n" {
  name                = local.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = var.storage_account_replication_type
  account_kind             = "StorageV2"

  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  tags = merge(local.common_tags, { Name = local.storage_account_name })
}

# Single share that holds n8n binary data. Name is fixed (not caller-tunable)
# because the chart-side wiring in modules/workload/ (US-023) references it
# directly — a variable here would just shift the coupling without removing
# it. Mirrors the root module's `azurerm_storage_share.n8n` but renamed to
# `n8n_binary` per the US-018 AC's literal naming (same Phase 5 rename pattern
# US-015 used for `aks_node_sku → aks_node_vm_size`).
resource "azurerm_storage_share" "n8n_binary" {
  name               = "n8n-binary-data"
  storage_account_id = azurerm_storage_account.n8n.id
  quota              = var.storage_share_quota_gb
}

# ── Workload identity → storage account access key ────────────────────────────
# Storage Account Key Operator Service Role grants the n8n_workload UAMI the
# `listKeys` API on the storage account. The workload tier (modules/workload/
# US-023) can then resolve the storage account access key at apply / runtime
# via the workload-identity-federated token rather than embedding the static
# key in a long-lived Kubernetes Secret. This is the canonical Azure pattern
# for Azure Files + workload identity — narrower blast radius than handing
# the workload tier a snapshot of the access key as a Terraform output.
#
# The legacy `storage_account_primary_access_key` output stays available for
# callers / examples that prefer the static-key path (e.g. the umbrella
# example before US-025 finalises the workload-identity wiring); both paths
# coexist until the workload tier lands.
resource "azurerm_role_assignment" "n8n_workload_storage_account_key_operator" {
  scope                = azurerm_storage_account.n8n.id
  role_definition_name = "Storage Account Key Operator Service Role"
  principal_id         = azurerm_user_assigned_identity.n8n_workload.principal_id
}
