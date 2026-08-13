# Copyright n8n GmbH 2025
# SPDX-License-Identifier: MIT

# ── Controllers ────────────────────────────────────────────────────────────
# KEDA is the only Helm-installed infrastructure controller this module uses
# (AKS provides its own cluster autoscaler, and AGIC remains an AKS addon).
# `modules/controllers` owns the KEDA namespace and Helm release so an
# advanced caller can install KEDA once and share it across more than one
# workload root by calling that submodule directly and setting
# `install_keda = false` here — see that submodule's README for the
# `depends_on` contract and the destroy-time ScaledObject finalizer hazard of
# changing `install_keda` on an already-applied stack.
#
# The root always instantiates this module; `install_keda` controls whether
# it creates resources, keeping this call's shape identical for both the
# module-managed and externally-installed paths. It sits behind the AKS API
# warm-up gate so a cold create does not race Azure's delayed API readiness.
module "controllers" {
  source = "./modules/controllers"

  install_keda          = var.install_keda
  keda_namespace        = local.keda_namespace
  keda_chart_repository = var.keda_chart_repository
  keda_chart_version    = var.keda_chart_version

  depends_on = [time_sleep.aks_api_warmup]
}
