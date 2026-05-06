# AGENTS.md — `modules/infra/`

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in
this submodule. Inherits the root [`AGENTS.md`](../../AGENTS.md) quality bar
in full — this file calls out the deltas specific to the IaaS-only scope.

## What this submodule is

The Azure IaaS layer for the production-grade n8n Enterprise deployment.
Everything **below** Kubernetes lives here: AKS cluster + node pool, the
PostgreSQL Flexible Server + private DNS zone, the Redis Cache + private
endpoint + private DNS zone, the Storage Account + Azure Files share, and
the Application Gateway + Public IP + Key Vault + IAM. The
Kubernetes-side workload (KEDA + n8n Helm release + manifests) lives in
sibling [`modules/workload/`](../workload/).

The Phase 5 split mirrors `terraform-azurerm-terraform-enterprise-hvd`
(HashiCorp Validated Design): IaaS owns a single provider tree
(`azurerm` + `random`); kubernetes / helm / kubectl never appear in this
submodule's `required_providers`. **Preserve that boundary** — adding a
Kubernetes-side resource here breaks the architectural contract that the
Phase 5 split exists to enforce.

## Quality bar (inherited from root)

- **Copywrite headers** are mandatory at the top of every `.tf` file:

  ```
  # Copyright n8n GmbH 2025
  # SPDX-License-Identifier: MIT
  ```

- **No `provider {}` blocks** in `versions.tf` or anywhere else.
  Provider configuration is the caller's job.
- **snake_case** for variable / output / resource / local names.
- **Tag every taggable `azurerm_*` resource** with
  `tags = merge(local.common_tags, { Name = "${var.friendly_name_prefix}-<purpose>" })`.
- **`description`, `type`, and at least one `validation {}` block on every
  variable.** Variables that legitimately can't validate (arbitrary
  string→string maps, optional null inputs already covered by paired-input
  validation) carry a `# no validation: <reason>` comment instead.
- **Plan-time tests under `tests/*.tftest.hcl`** with `mock_provider
  "azurerm" {}` and `mock_provider "random" {}`. No live Azure calls.
  `command = apply` is reserved for the `output_contract_complete` run
  (US-020) where output values that resolve from computed-at-apply
  attributes need apply-mode mocks to be non-null at assertion time —
  every other run stays on `command = plan`.
- **`terraform fmt -check -recursive`**, **`terraform validate`**, and
  **`terraform test`** all pass from inside this directory.

## What NOT to do

- **Don't add a `kubernetes`, `helm`, or `kubectl` provider here.** Those
  belong in `modules/workload/`. If a Phase-5 story tempts you to break
  this boundary (e.g. "the AKS resource needs to render a kubeconfig
  string for the workload submodule to consume"), expose an output from
  this submodule and let `modules/workload/` configure its kubernetes /
  helm providers from that output in the example wiring — don't reach
  across the split.
- **Don't add a `provider {}` block to `versions.tf`** even with empty
  `features {}`. Callers configure providers in their own `providers.tf`.
- **Don't create the resource group inside this submodule.** The caller
  supplies an existing RG via `var.resource_group_name`. Decoupling the
  RG lifecycle from any one Phase 5 submodule is intentional.
- **Don't introduce `null_resource` workarounds.** Phase 1–3 of the
  registry-hardening campaign retired all five `null_resource` workarounds
  the prototype shipped with; reintroducing one here would undo that
  work. Use `time_sleep` for declarative create/destroy gates and trust
  the providers' built-in retry for transient Azure-API conditions.

## Plan-time test conventions

Same conventions as the root tests/ — see the root AGENTS.md "Plan-time
tests" section. A few module-specific notes:

- This submodule's tests use only `mock_provider "azurerm" {}` and
  `mock_provider "random" {}`. There is no kubernetes / helm / kubectl
  surface to mock here.
- Computed-at-apply attributes (resource `id`, `principal_id`, etc.)
  resolve to synthetic strings under `mock_provider`. When a downstream
  resource gates on one of those (`count = var.x == null ? 0 : 1`),
  use an `override_resource` block in the run to pin a plan-known
  value. Same shape as the root tests/ pattern documented in the root
  AGENTS.md.
- `azurerm_key_vault.<name>.tenant_id` and `access_policy[*].tenant_id`
  are validated as UUIDs at plan time. Under `mock_provider "azurerm"`,
  `data.azurerm_client_config.current.{tenant_id,object_id}` resolves
  to a non-UUID synthetic string — pin UUIDs with an `override_data`
  block on `data.azurerm_client_config.current` at the top of the test
  file. Same pattern as the root tests use.
- The `output_contract_complete` run (US-020) is the canonical
  apply-mode example. Under `command = apply` with `mock_provider
  "azurerm"`, every resource whose `id` is consumed as an Azure
  resource ID elsewhere in the graph (role-assignment `scope`,
  postgres-database `server_id`, private-endpoint
  `private_connection_resource_id`, AKS-addon `gateway_id`, etc.) needs
  a per-resource `override_resource { values = { id = "/subscriptions/…/<type>/<name>" } }`
  pin — the auto-mocked `id` is a 6-char alphanumeric that fails Azure
  resource-ID parsing. For nested block lists with `MaxItems = 1`
  (e.g. AKS's `ingress_application_gateway` block), `override_resource.values`
  expects them as a SINGLE OBJECT at the top level but as a LIST OF
  OBJECTS at any inner level — mismatch yields cryptic "expected an
  object type for attribute .X[0] but found list of object" errors.

## Submodule terraform-docs

This submodule ships its own [`.terraform-docs.yml`](./.terraform-docs.yml)
mirroring the root config. terraform-docs has no inherit/extends
mechanism and only reads `.terraform-docs.yml` from its own working
directory, so without this local copy `terraform-docs --output-check .`
from inside this submodule diffs against lockfile-resolved provider
versions. **Bump in lockstep with the root file** when settings change.

Refresh the README from this directory:

```bash
terraform-docs .
```
