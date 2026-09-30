# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Naming & tags ────────────────────────────────────────────────────────────
# Mirrors the root module's `local.common_tags`: the baseline ManagedBy /
# Project pair, with the caller's `common_tags` merged on top.

locals {
  certificate_name = "${var.friendly_name_prefix}-n8n-tls"

  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.common_tags,
  )
}
