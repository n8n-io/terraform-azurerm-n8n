# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

output "keda_installed" {
  description = "Echoes var.install_keda. Direct callers composing ordering logic can branch on this instead of re-deriving it from their own copy of the input."
  value       = var.install_keda
}

output "keda_namespace" {
  description = "Effective KEDA namespace name. Equals var.keda_namespace whether this module created it (install_keda = true) or the caller manages it externally (install_keda = false)."
  value       = var.keda_namespace
}

output "keda_release_name" {
  description = "Name of the KEDA Helm release this module created, or null when install_keda = false and no release is managed here."
  value       = var.install_keda ? helm_release.keda[0].name : null
}

output "keda_release_status" {
  description = "Status of the KEDA Helm release this module created, or null when install_keda = false and no release is managed here."
  value       = var.install_keda ? helm_release.keda[0].status : null
}
