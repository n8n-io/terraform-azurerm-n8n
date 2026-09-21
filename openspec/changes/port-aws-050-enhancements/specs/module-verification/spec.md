## ADDED Requirements

### Requirement: Provider and pin currency reporting

The offline verification suite SHALL include a version-drift report
covering every declared Terraform provider, the CI toolchain pins, the
`n8n_chart_version` default, and the `aks_kubernetes_version` default,
using an AKS-specific supported-versions source rather than a generic
Kubernetes end-of-life table. The report SHALL run without cloud
credentials, SHALL NOT modify any pin, and SHALL exit successfully whether
or not drift is found. A scheduled workflow SHALL publish the report to a
single tracking issue.

#### Scenario: Report drift without live credentials

- **WHEN** `tests/scripts/check-version-drift.sh` runs against the current
  repository
- **THEN** it SHALL report currency for every declared provider, CI
  toolchain pin, and the chart default using only public sources and exit
  zero

#### Scenario: Use an AKS-specific Kubernetes reference

- **WHEN** the report evaluates `aks_kubernetes_version`
- **THEN** it SHALL consult an AKS supported-versions source, not a
  cross-platform end-of-life table

### Requirement: Chart values diff helper

The offline verification suite SHALL include a script that diffs the
pinned n8n chart's `values.yaml` against a candidate version via
`helm show values`, exiting zero once both fetches and the diff ran, and
non-zero on usage error, missing tool, or a failed fetch. It SHALL never
write or bump a pin.

#### Scenario: Diff a candidate chart version

- **WHEN** the script is invoked with a candidate version that exists
- **THEN** it SHALL print the values diff and exit zero regardless of
  whether differences were found

### Requirement: Example variable-name parity check

The offline verification suite SHALL include a script that diffs the set
of variable names declared by every example's `variables.tf` against
`examples/small`'s, failing on any name present on one side only that is
not covered by that example's allowlist, and failing on a stale allowlist
entry.

#### Scenario: Fail on an undocumented one-sided variable

- **WHEN** an example declares a variable absent from `examples/small` and
  from its allowlist
- **THEN** the script SHALL fail naming the variable and example

#### Scenario: Pass on the current example set

- **WHEN** the script runs against the unmodified example set
- **THEN** it SHALL exit zero

### Requirement: Static analysis reaches opt-in resources

The checkov verification SHALL run a second pass with every opt-in switch
that gates a `count`-controlled Kubernetes resource enabled, and SHALL
fail if that pass does not evaluate each listed opt-in resource, so that
checkov's UNKNOWN-and-drop behavior for count-0 resources cannot hide a
finding. Contributor documentation SHALL describe this behavior correctly
and SHALL NOT claim checkov ignores `_v1` Kubernetes resource types.

#### Scenario: Evaluate the disabled-by-default exporter

- **WHEN** the second checkov pass runs with `redis_exporter_enabled = true`
- **THEN** `kubernetes_deployment_v1.redis_exporter` and its Service SHALL
  appear in the results and any failing `CKV_K8S_*` check SHALL be fixed or
  annotated at the resource

### Requirement: Markdown documentation lint

CI SHALL lint `README.md`, `AGENTS.md`, `docs/**/*.md`, and every example
README with a pinned markdownlint version. Generated `terraform-docs`
blocks SHALL be wrapped in disable/restore comments placed outside the
generated block so the generated content is never hand-edited.

#### Scenario: Lint passes on generated content

- **WHEN** `terraform-docs` regenerates a README reference block
- **THEN** markdownlint SHALL still pass without edits inside the block

### Requirement: Pin inventory documentation

The repository SHALL document every version it pins (providers, Terraform
floor, n8n chart, `aks_kubernetes_version`, PostgreSQL version, Redis
SKU, CI toolchain), the file each lives in, and its bump tier, linked from
a README `Compatibility` section and from `AGENTS.md`.

#### Scenario: Find where a pin lives

- **WHEN** a contributor needs to bump any pinned version
- **THEN** `docs/versioning.md` SHALL name the file and the verification
  tier the bump requires
