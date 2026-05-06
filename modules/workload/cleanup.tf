# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Pre-destroy Azure Files drain gate ───────────────────────────────────────
# Replaces `null_resource.drain_n8n_pods` (registry-hardening US-005).
#
# Failure mode prevented: when `terraform destroy` runs `helm_release.n8n`'s
# uninstall, Helm waits for every pod to terminate before reporting success.
# Azure Files volumes mount via CIFS and the in-tree `azure_file` driver's
# detach operation can stall for several minutes per pod when the SMB share
# is still busy — pods sit in `Terminating` state and Helm eventually times
# out with "context deadline exceeded". Subsequent `terraform destroy` runs
# then hit a half-uninstalled release that requires manual `helm uninstall
# --no-hooks` recovery.
#
# Solution: a deterministic destroy-time pause that lets Azure Files finish
# its asynchronous detach AFTER `helm_release.n8n` has uninstalled (pods are
# already on their way out) and BEFORE `kubernetes_namespace.n8n` is removed
# (which would trigger PV/PVC deletion and force the storage account to
# release its share lock). With `helm_release.n8n` running with
# `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true`
# (n8n.tf), Helm itself drives the pod scale-down inside the release; this
# gate then absorbs the post-uninstall CIFS detach window. Mirrors the
# `time_sleep.wait_for_alb_cleanup` pattern in `terraform-aws-n8n/n8n.tf`.
#
# Dependency chain (create order, reversed for destroy):
#   kubernetes_namespace.n8n → time_sleep.wait_for_aks_drain → helm_release.n8n
# Destroy order:
#   1. helm_release.n8n              ← Helm uninstalls; pods scale to 0
#   2. time_sleep.wait_for_aks_drain ← `destroy_duration` pause for SMB detach
#   3. kubernetes_namespace.n8n      ← namespace + remaining objects removed
#
# Configuration: `var.aks_destroy_drain_seconds` (default 120 s, range
# 30..600). Operators with larger Azure Files shares (>50 GiB) or many
# concurrent pods may want to extend this; the floor (30 s) is below
# which the CIFS detach is rarely complete; the ceiling (600 s) matches
# the legacy null_resource's 24×5 s wait-loop upper bound. No `kubectl` /
# `az` dependency on the apply host — the helm provider's wait semantics
# already guarantee pods are gone before this gate fires; the gate's only
# job is to wait out the asynchronous Azure-side share detach.
resource "time_sleep" "wait_for_aks_drain" {
  destroy_duration = "${var.aks_destroy_drain_seconds}s"

  depends_on = [kubernetes_namespace.n8n]
}
