# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

variable "install_keda" {
  description = "When true (the default), this module creates the KEDA namespace and Helm release. Set to false when KEDA is already installed by another process or another call of this module — the caller is then responsible for KEDA's readiness before any dependent resource applies."
  type        = bool
  default     = true
  nullable    = false
}

variable "keda_namespace" {
  description = "Name of the Kubernetes namespace KEDA's operator and CRDs live in. Created when install_keda = true (the default); when install_keda = false, KEDA must already be running in this namespace."
  type        = string
  default     = "keda"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.keda_namespace)) && length(var.keda_namespace) <= 63
    error_message = "keda_namespace must be a valid Kubernetes namespace name: 1-63 lowercase alphanumeric characters or hyphens, starting and ending with an alphanumeric character."
  }
}

variable "keda_chart_repository" {
  description = "Helm chart repository URL for the KEDA chart. Override for a private mirror of the kedacore charts (for example an internal ChartMuseum or ACR Helm registry) when the cluster cannot reach the public kedacore.github.io repository. Ignored when install_keda = false."
  type        = string
  default     = "https://kedacore.github.io/charts"
  nullable    = false

  validation {
    condition     = can(regex("^(https|oci)://[^[:space:]]+$", var.keda_chart_repository))
    error_message = "keda_chart_repository must be an https:// or oci:// URL with no whitespace."
  }
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version from keda_chart_repository. Pinning the controller keeps the CRD shape any TriggerAuthentication or ScaledObject caller relies on deterministic. Ignored when install_keda = false."
  type        = string
  default     = "2.15.0"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-.+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be a semantic version such as 2.15.0 or 2.15.0-rc1."
  }
}

variable "keda_helm_timeout_seconds" {
  description = "Timeout, in seconds, Helm waits for the KEDA release to become ready. Ignored when install_keda = false."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.keda_helm_timeout_seconds > 0 && var.keda_helm_timeout_seconds == floor(var.keda_helm_timeout_seconds)
    error_message = "keda_helm_timeout_seconds must be a positive whole number."
  }
}

variable "keda_helm_wait" {
  description = "When true (the default), Helm waits for KEDA's resources to reach a ready state before the release is considered successful. Ignored when install_keda = false."
  type        = bool
  default     = true
  nullable    = false
}

variable "keda_helm_atomic" {
  description = "When true (the default), Helm rolls back the KEDA release automatically if the install or upgrade fails. Ignored when install_keda = false."
  type        = bool
  default     = true
  nullable    = false
}

variable "keda_helm_cleanup_on_fail" {
  description = "When true (the default), Helm removes any new resources it created for the KEDA release when the install or upgrade fails. Ignored when install_keda = false."
  type        = bool
  default     = true
  nullable    = false
}
