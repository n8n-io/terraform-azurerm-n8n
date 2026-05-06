# AGENTS.md — `modules/workload/`

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in
this submodule. Inherits the root [`AGENTS.md`](../../AGENTS.md) quality bar
in full — this file calls out the deltas specific to the chart-only,
Kubernetes-side scope.

## What this submodule is

The Kubernetes-side workload that runs **on top of** the IaaS layer
provisioned by [`modules/infra/`](../infra/):

- The KEDA Helm release (`helm_release.keda`) and the KEDA `ScaledObject`s
  the chart does not own (US-022).
- The n8n + KEDA Kubernetes namespaces.
- The n8n Helm release (`helm_release.n8n`, OCI chart
  `oci://ghcr.io/n8n-io/n8n-helm-chart`) plus the chart-side Secrets the
  chart consumes (database credentials, Redis credentials, Azure Files
  credentials, n8n Enterprise license key) — US-023.
- The n8n Ingress object the AKS-managed AGIC reconciles into App Gateway
  listeners / pools / rules.
- The HPAs the chart does not own (`webhook-processor`).
- The federated identity credential resource itself
  (`azurerm_federated_identity_credential.n8n_workload`) lives in
  [`modules/infra/iam.tf`](../infra/iam.tf), not here, to preserve the
  chart-only consumer posture (see "What NOT to do" below). The
  credential's only Kubernetes-side metadata is two literal strings
  (the namespace `local.n8n_namespace = "n8n"` and the chart's
  hardcoded `n8n-enterprise` ServiceAccount name) — neither is a
  cross-tier resource reference, so the resource sits cleanly in
  `modules/infra/` next to the UAMI it federates without breaking
  graph hygiene. The lockstep contract: a rename of either string on
  this side requires the matching edit in `modules/infra/iam.tf`.
- The KEDA `TriggerAuthentication` CR wiring the chart's `ScaledObject`
  to the Redis primary access key (registry-hardening US-007 took the
  R3.2 fall-back; the CR is rendered via
  `gavinbunney/kubectl_manifest`).

The IaaS layer (AKS, Postgres, Redis, Storage, App Gateway, IAM) lives
in sibling [`modules/infra/`](../infra/). Both submodules are wired
together by the root [`terraform-azurerm-n8n`](../../README.md) module's
`examples/complete/` (US-025) end-to-end.

The Phase 5 split mirrors `terraform-azurerm-terraform-enterprise-hvd`
(HashiCorp Validated Design): IaaS owns a single Azure provider tree;
the workload owns the kubernetes / helm / kubectl provider tree.
**Preserve that boundary** — adding an `azurerm_*` resource here breaks
the architectural contract that the Phase 5 split exists to enforce.

## Quality bar (inherited from root)

- **Copywrite headers** are mandatory at the top of every `.tf` file:

  ```
  # Copyright n8n GmbH 2025
  # SPDX-License-Identifier: MIT
  ```

- **No `provider {}` blocks** in `versions.tf` or anywhere else.
  Provider configuration is the caller's job — the umbrella example
  wires the kubernetes / helm / kubectl providers from
  `module.infra.aks_kube_config` so the same certificate-based auth
  shape the root module uses today carries through to this submodule.
- **snake_case** for variable / output / resource / local names.
- **`description`, `type`, and at least one `validation {}` block on every
  variable.** Variables that legitimately can't validate (arbitrary
  string→string maps, optional null inputs already covered by paired-input
  validation) carry a `# no validation: <reason>` comment instead.
- **Plan-time tests under `tests/*.tftest.hcl`** with `mock_provider` for
  every required provider. No live Kubernetes API calls; every Helm /
  kubernetes / kubectl resource resolves under mocks.
- **`terraform fmt -check -recursive`**, **`terraform validate`**, and
  **`terraform test`** all pass from inside this directory.

## What NOT to do

- **Don't add an `azurerm` provider here.** That belongs in
  `modules/infra/`. If a Phase-5 story tempts you to break this boundary
  (e.g. "the n8n Secret needs to fetch the Redis primary access key
  directly"), expose an output from `modules/infra/` and let this
  submodule consume it through a typed input — don't reach across the
  split.
- **Don't add a `provider {}` block to `versions.tf`** — callers
  configure providers in their own `providers.tf`.
- **Don't introduce `null_resource` workarounds.** Phase 1–3 of the
  registry-hardening campaign retired all five `null_resource`
  workarounds the prototype shipped with; reintroducing one here would
  undo that work. Use `time_sleep` for declarative create/destroy gates
  and `gavinbunney/kubectl_manifest` for CRD-aware Kubernetes resources
  the helm chart does not own.
- **Don't hardcode the n8n / keda namespace strings inline.** Reference
  `local.n8n_namespace` / `local.keda_namespace` (defined in
  `locals.tf`). This invariant is enforced module-wide by the root
  registry-hardening US-008 outcome.

## Plan-time test conventions

Same conventions as the root tests/ — see the root AGENTS.md "Plan-time
tests" section. A few module-specific notes:

- This submodule's tests use `mock_provider "kubernetes" {}`,
  `mock_provider "helm" {}`, `mock_provider "random" {}`,
  `mock_provider "time" {}`, and `mock_provider "kubectl" {}`. There
  is no `azurerm` surface to mock here — every cross-tier value flows
  in through this submodule's typed inputs.
- The `gavinbunney/kubectl` provider's `kubectl_manifest.X.yaml_body`
  is sensitive-marked at the schema level AND replaced with a
  synthetic `(sensitive value)` placeholder under `mock_provider
  "kubectl"`. To assert on the rendered string in plan-time tests,
  extract the `yamlencode`'d content to a `local` and reference the
  local from BOTH the resource AND the test condition (per the
  codebase pattern for the existing
  `kubectl_manifest.keda_trigger_authentication`).
- Plan-time `output.X != null` assertions on computed-at-apply
  attributes (e.g. `helm_release.n8n.id`,
  `kubernetes_namespace.n8n.metadata[0].uid`) collapse to "could not be
  evaluated at this time" under `command = plan`. When US-024 lands the
  outputs contract, the `output_contract_complete` run in
  `tests/defaults.tftest.hcl` will switch that single run to `command =
  apply` (mirrors the `modules/infra/` US-020 pattern).

## Submodule terraform-docs

This submodule will ship its own `.terraform-docs.yml` once US-024
finalises the outputs contract and we publish a `<!-- BEGIN_TF_DOCS -->`
block in `README.md`. terraform-docs has no inherit/extends mechanism
and only reads `.terraform-docs.yml` from its own working directory.
**Bump in lockstep with the root file** when settings change.

For the R5.2a (US-021) skeleton there is no auto-generated block yet —
the README is hand-written; the inputs / outputs surface is small and
flux-prone while resources move in over US-022 / US-023.
