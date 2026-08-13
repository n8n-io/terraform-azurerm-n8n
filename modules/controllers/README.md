# `terraform-azurerm-n8n` — `modules/controllers/`

Install KEDA (the Kubernetes Event-driven Autoscaling operator) into a target
cluster. The root [`terraform-azurerm-n8n`](../../README.md) module calls this
submodule by default so KEDA is installed automatically alongside the rest of
the n8n deployment. Advanced callers who already manage KEDA — either through
a separate call of this same submodule shared across more than one workload
root, or through an entirely different process — can call this module
directly and point the root module at the result with `install_keda = false`.

Azure has no root-installed equivalents of the AWS Load Balancer Controller,
Cluster Autoscaler, metrics-server, or EBS CSI stack: AKS provides its own
cluster autoscaler and AGIC remains an AKS addon. KEDA is the only controller
`terraform-azurerm-n8n` installs with Helm, so it is the only one extracted
into a directly callable submodule.

## Provider wiring

This submodule declares the `kubernetes` and `helm` providers it uses but does
not configure them — the caller's job, same as the root module. When the root
module calls this submodule (the default), Terraform's implicit provider
inheritance passes the root's already-configured `kubernetes` and `helm`
providers through. A direct caller must configure both providers itself
against the target cluster before calling this module.

## The `depends_on` contract

KEDA's `TriggerAuthentication` and `ScaledObject` CRDs are installed by
`helm_release.keda` in this module. Any resource that creates a
`TriggerAuthentication`, a `ScaledObject`, or anything that assumes KEDA's
operator is running must be ordered after this module with an explicit
`depends_on = [module.controllers]` (or the equivalent module address a
direct caller chooses) — Terraform cannot infer that ordering from data flow
alone, because those CRD-backed resources don't reference any output this
module produces.

The root module's `kubectl_manifest.keda_trigger_authentication` and
`helm_release.n8n` both carry this `depends_on` edge. A direct caller composing
its own workload against a separately installed KEDA needs the same edge from
its own CRD-backed resources to this module's call.

## The ownership-change finalizer hazard

Changing `install_keda` from `true` to `false` (or the reverse) on an
already-applied stack does not migrate KEDA's ownership cleanly. If any
`ScaledObject` still references a `TriggerAuthentication` when this module's
`helm_release.keda` is destroyed, KEDA's operator can leave the `ScaledObject`
stuck on a Kubernetes finalizer with no controller left to remove it, blocking
the namespace's deletion. Delete or migrate every dependent `ScaledObject`
and `TriggerAuthentication` before changing `install_keda`, in either
direction.

## Usage

```hcl
module "controllers" {
  source = "github.com/n8n-io/terraform-azurerm-n8n//modules/controllers?ref=v0.1.0"

  install_keda   = true
  keda_namespace = "keda"
}

# A direct caller orders its own KEDA-dependent resources after this module:
resource "kubectl_manifest" "my_trigger_authentication" {
  yaml_body  = local.my_trigger_authentication_yaml
  depends_on = [module.controllers]
}
```

## Inputs

| Name | Description | Type | Default |
| ---- | ----------- | ---- | ------- |
| `install_keda` | When true (the default), this module creates the KEDA namespace and Helm release. Set to false when KEDA is already installed by another process or another call of this module. | `bool` | `true` |
| `keda_namespace` | Name of the Kubernetes namespace KEDA's operator and CRDs live in. | `string` | `"keda"` |
| `keda_chart_repository` | Helm chart repository URL for the KEDA chart. Ignored when `install_keda = false`. | `string` | `"https://kedacore.github.io/charts"` |
| `keda_chart_version` | KEDA Helm chart version from `keda_chart_repository`. Ignored when `install_keda = false`. | `string` | `"2.15.0"` |
| `keda_helm_timeout_seconds` | Timeout, in seconds, Helm waits for the KEDA release to become ready. Ignored when `install_keda = false`. | `number` | `300` |
| `keda_helm_wait` | Whether Helm waits for KEDA's resources to reach a ready state. Ignored when `install_keda = false`. | `bool` | `true` |
| `keda_helm_atomic` | Whether Helm rolls back the KEDA release automatically on failure. Ignored when `install_keda = false`. | `bool` | `true` |
| `keda_helm_cleanup_on_fail` | Whether Helm removes new resources it created for the KEDA release when the install or upgrade fails. Ignored when `install_keda = false`. | `bool` | `true` |

## Outputs

| Name | Description |
| ---- | ----------- |
| `keda_installed` | Echoes `var.install_keda`, for direct callers composing ordering logic. |
| `keda_namespace` | Effective KEDA namespace name, whether module-created or caller-managed. |
| `keda_release_name` | Name of the KEDA Helm release this module created, or `null` when `install_keda = false`. |
| `keda_release_status` | Status of the KEDA Helm release this module created, or `null` when `install_keda = false`. |

This submodule is not yet part of the repository's `terraform-docs` CI check
(see `openspec/changes/add-customer-managed-modularity/tasks.md` section 9.1) —
the tables above are hand-maintained until that section adds it to the
generated-documentation matrix alongside the two TLS helper submodules.
