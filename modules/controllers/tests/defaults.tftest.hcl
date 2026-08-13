# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# Plan-time tests for the modules/controllers submodule using mocked
# providers. Exercises both the module-managed and externally-installed KEDA
# paths without contacting a real Kubernetes cluster.
#
# Run: terraform test
#   (from this directory's parent — modules/controllers/. No cluster
#    credentials needed; both providers are mocked.)

mock_provider "kubernetes" {}
mock_provider "helm" {}

run "installs_keda_by_default" {
  command = plan

  assert {
    condition     = var.install_keda == true
    error_message = "install_keda must default to true."
  }

  assert {
    condition     = length(kubernetes_namespace.keda) == 1 && kubernetes_namespace.keda[0].metadata[0].name == "keda"
    error_message = "The default plan must create exactly one KEDA namespace named 'keda'."
  }

  assert {
    condition     = length(helm_release.keda) == 1 && helm_release.keda[0].namespace == "keda"
    error_message = "The default plan must create exactly one KEDA Helm release in the KEDA namespace."
  }

  assert {
    condition     = helm_release.keda[0].repository == "https://kedacore.github.io/charts" && helm_release.keda[0].version == "2.15.0"
    error_message = "The KEDA release must default to the public kedacore repository and pinned chart version."
  }

  assert {
    condition     = helm_release.keda[0].wait && helm_release.keda[0].atomic && helm_release.keda[0].cleanup_on_fail && helm_release.keda[0].timeout == 300
    error_message = "The KEDA release must preserve its wait/atomic/cleanup_on_fail safeguards and 300s default timeout."
  }
}

run "custom_namespace_and_chart_settings_are_honored" {
  command = plan

  variables {
    keda_namespace            = "keda-controllers"
    keda_chart_repository     = "https://mirror.example.com/keda-charts"
    keda_chart_version        = "2.16.1"
    keda_helm_timeout_seconds = 600
    keda_helm_wait            = false
    keda_helm_atomic          = false
    keda_helm_cleanup_on_fail = false
  }

  assert {
    condition     = kubernetes_namespace.keda[0].metadata[0].name == "keda-controllers"
    error_message = "The KEDA namespace must use the caller-supplied name."
  }

  assert {
    condition     = helm_release.keda[0].namespace == "keda-controllers"
    error_message = "The KEDA release must install into the caller-supplied namespace."
  }

  assert {
    condition     = helm_release.keda[0].repository == "https://mirror.example.com/keda-charts" && helm_release.keda[0].version == "2.16.1"
    error_message = "The KEDA release must use the caller-supplied chart repository and version."
  }

  assert {
    condition     = helm_release.keda[0].timeout == 600 && !helm_release.keda[0].wait && !helm_release.keda[0].atomic && !helm_release.keda[0].cleanup_on_fail
    error_message = "The KEDA release must use the caller-supplied Helm lifecycle settings."
  }
}

run "install_keda_false_creates_no_resources" {
  command = plan

  variables {
    install_keda = false
  }

  assert {
    condition     = length(kubernetes_namespace.keda) == 0
    error_message = "install_keda = false must create zero KEDA namespace resources."
  }

  assert {
    condition     = length(helm_release.keda) == 0
    error_message = "install_keda = false must create zero KEDA Helm release resources."
  }
}

run "outputs_reflect_the_installed_path" {
  command = plan

  assert {
    condition     = output.keda_installed == true
    error_message = "keda_installed must echo var.install_keda."
  }

  assert {
    condition     = output.keda_namespace == "keda"
    error_message = "keda_namespace output must equal var.keda_namespace."
  }

  assert {
    condition     = output.keda_release_name == "keda"
    error_message = "keda_release_name must equal the Helm release name when install_keda = true."
  }
}

run "outputs_are_null_on_the_externally_installed_path" {
  command = plan

  variables {
    install_keda   = false
    keda_namespace = "keda"
  }

  assert {
    condition     = output.keda_installed == false
    error_message = "keda_installed must echo install_keda = false."
  }

  assert {
    condition     = output.keda_namespace == "keda"
    error_message = "keda_namespace output must still equal var.keda_namespace when install_keda = false."
  }

  assert {
    condition     = output.keda_release_name == null && output.keda_release_status == null
    error_message = "Release outputs must be explicitly null when install_keda = false, since no release is managed here."
  }
}

run "rejects_malformed_keda_namespace" {
  command = plan

  variables {
    keda_namespace = "Not_Valid"
  }

  expect_failures = [var.keda_namespace]
}

run "rejects_malformed_keda_chart_repository" {
  command = plan

  variables {
    keda_chart_repository = "not-a-url"
  }

  expect_failures = [var.keda_chart_repository]
}

run "rejects_malformed_keda_chart_version" {
  command = plan

  variables {
    keda_chart_version = "latest"
  }

  expect_failures = [var.keda_chart_version]
}

run "rejects_nonpositive_helm_timeout" {
  command = plan

  variables {
    keda_helm_timeout_seconds = 0
  }

  expect_failures = [var.keda_helm_timeout_seconds]
}
