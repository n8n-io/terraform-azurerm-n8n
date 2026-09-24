# AGENTS.md

Guidance for AI coding agents (Claude Code, Cursor, Copilot, etc.) working in this
repository. Human contributors should also find this useful — it explains *what*
this module is and *what bar* it is held to.

This file is the Azure sibling of
[`terraform-aws-n8n/AGENTS.md`](https://github.com/n8n-io/terraform-aws-n8n/blob/main/AGENTS.md).
The shape, quality bar, and "what not to do" list are intentionally aligned;
the deltas below cover Azure-specific runtime hardening that the AWS module
doesn't need.

## `align-azure-with-aws-capabilities` internal iteration

This module used a two-tier composition (`modules/infra/` +
`modules/workload/`, no resources at the root) during internal development. The
`align-azure-with-aws-capabilities`
change (`openspec/changes/align-azure-with-aws-capabilities/`) flattened that
back into **one resource-bearing root module**, matching `terraform-aws-n8n`'s
shape, and ported the AWS sibling's PostgreSQL/Redis external-endpoint modes,
Azure Blob storage, full n8n runtime controls, autoscaling, ingress patterns,
and DNS/TLS integration onto the Azure-specific foundation. `modules/infra/`
and `modules/workload/` were deleted once every resource, control, and
safeguard they owned was represented at the root (section 15.5). The
subsequent `slim-first-release-surface` change removed Azure Files support,
the `filesystem` binary/execution-data storage modes, the two DNS-provider
examples, and the version-history framing ahead of the module's first public
release (`0.1.0`) — see [`CHANGELOG.md`](./CHANGELOG.md). The "What this repo
is" / "File layout" sections below describe the current shape.

## `add-customer-managed-modularity` in progress

This change (`openspec/changes/add-customer-managed-modularity/`) is adding
caller-managed AKS, Blob storage, namespace, KEDA, webhook HPA, and Kubernetes
Secret ownership. Its section 1 established the input contract convention every
later section follows: a non-nullable `create_*`/`install_*` switch defaults to
`true`, each corresponding `existing_*` reference or `*_prerequisites_confirmed`
attestation is required only when its switch is `false` (validated on the
reference variable itself, never inferred from a nullable reference), and a
non-failing `check` block in `locals.tf` warns when a reference is supplied
while the switch stays `true`. Caller-managed Kubernetes Secret references use
typed `object({ name = string, key = string })` variables that are mutually
exclusive with their literal/generated credential counterpart. Section 1 also
added `local.effective_*` selector locals (AKS cluster/resource group, Blob
account/container/ID/endpoint) whose module-managed branch still points at the
currently-unconditional resources — sections 2 and 6 gate those resources
behind `count` and update the selector locals to index into them. Until those
sections land, `tflint`'s `terraform_unused_declarations` rule flags the new
switches/locals as unused; this is expected mid-change and is resolved by the
sections that consume them, not by this section. Section 2 gated the AKS
cluster, node pool, API warm-up gate, and AGIC-dependent identities behind
`create_aks`, added the `data.azurerm_kubernetes_cluster.existing` lookup and
its `effective_aks_*` locals, and required `create_ingress = false` whenever
`create_aks = false` (the module cannot manage AGIC on a cluster it does not
own). A `check` block comparing a `list(string)` variable against a bracketed
literal (e.g. `var.aks_availability_zones == ["1", "2", "3"]`) always
evaluates false — Terraform's `==` requires matching concrete types, and a
bracketed literal is a tuple, not a list. Wrap the literal in `tolist(...)`
(or `toset(...)` when the attribute itself is a set) before comparing.
Checkov's graph-based checks (e.g. `CKV_AZURE_136`, `CKV2_AZURE_31`) can
report the same underlying resource under both its unindexed and `[0]`
addresses once a second top-level resource in the module gains a `count`
ternary; this is a soft-fail graph-rendering artifact, not a new curated
finding, and does not need a suppression. Section 3 extracted KEDA into
`modules/controllers/` (namespace + Helm release behind its own
`install_keda` switch) and replaced root `kubernetes_namespace.keda` /
`helm_release.keda` with an unconditional `module "controllers"` call —
`install_keda` (added in section 1) controls whether the submodule's own
resources exist, so the root's call shape never changes between the
module-managed and externally-installed paths. `kubectl_manifest
.keda_trigger_authentication` and `helm_release.n8n` both moved their
`depends_on` edge from `helm_release.keda` to `module.controllers` — a
direct submodule caller must add the same edge from its own CRD-backed
resources to its `module.controllers` call, since none of those resources
reference an output the submodule produces. Terraform test `run` blocks can
assert directly on `module.<name>.<output>` (e.g.
`module.controllers.keda_release_name`), which is cleaner than reaching into
the submodule's resource addresses from the root's own test suite. The
submodule's README and inputs/outputs tables are hand-maintained (matching
the existing `modules/tls-letsencrypt/` and `modules/tls-self-signed/`
pattern) because the `terraform-docs` CI matrix does not cover submodules
yet — section 9.1 adds `modules/controllers` (and the two TLS helpers) to
that matrix and to `openspec/init.sh`; don't add it earlier without also
wiring the generated-docs check, or the hand-written tables can drift
unnoticed.

**Storage and workload integration.** Root `storage.tf` owns the private
Azure Blob container, its private endpoint, and private DNS zone — Blob is
the module's only durable binary/execution-data backend. `shared_access_key_enabled`
on the storage account derives solely from the retained connection-string/
account-key compatibility inputs; workload identity is otherwise the only
authentication path. Root `helm_release.n8n` merges `local.n8n_extra_volumes` /
`local.n8n_extra_volume_mounts` at the chart's top level so every pod family
receives caller-supplied typed volumes. Section 6 gated every `storage.tf`
resource (account, container, private DNS zone/link, private endpoint,
lifecycle policy) behind `create_blob_storage`, matching the AKS `[0]`-index
shape from section 2. `azurerm_role_assignment.n8n_blob_data_contributor` is
scoped to `local.effective_blob_container_id` (module-managed container or
`existing_blob_container_id`) and gated on `local.azure_blob_connection.auth_auto_detect`
rather than on `create_blob_storage` — it exists whenever automatic
authentication is selected, on either branch, and is omitted only for the
connection-string/account-key compatibility modes. `local.azure_blob_connection.endpoint`
keeps `var.azure_blob_endpoint` as an override that short-circuits
`local.effective_blob_endpoint` on both branches — collapsing it into
`effective_blob_endpoint` directly breaks the existing sovereign-cloud
endpoint override test, since `effective_blob_endpoint`'s two branches key
off `create_blob_storage`, not off whether the override is set. A
`blob_tuning_requires_module_managed_blob_storage` check (mirroring
`aks_tuning_requires_module_managed_aks`) warns when `storage_account_replication_type`
or `azure_blob_binary_retention_days` is left non-default while
`create_blob_storage = false`, since neither has an effect in that mode.

**Combined provider graph.** The root declares all six providers the former
two-tier composition used across both submodules (`azurerm`, `kubernetes`,
`helm`, `random`, `time`, `kubectl`) in one `required_providers` block. AKS
and the Kubernetes/Helm controllers form one same-apply graph: namespace
creation depends on `time_sleep.aks_api_warmup`; KEDA installs before the
CRD-aware TriggerAuthentication; the n8n release installs after both. Mocked
plans and `terraform graph` verify those static edges, but they do not prove
live Azure lifecycle behavior — track cold create, no-op apply, Helm-only
update, AKS credential rotation, partial-apply recovery, AKS replacement
(known to fail at plan time because the caller's Kubernetes-side providers
are configured from `aks_kube_config`; see `docs/troubleshooting.md`),
normal destroy, and unavailable-API recovery per `openspec/changes/
align-azure-with-aws-capabilities/tasks.md` section 17.4 before treating the
one-apply contract as a release guarantee for a given release.

**Runtime controls.** Root `n8n.tf` owns the chart-native resource, execution,
lifecycle, task-runner, logging, template, personalization, community-package,
and floating-license settings. The chart's `config.extraEnv` is shared by
main, worker, and webhook containers. Keep feature variables omitted when
their defaults match n8n, but always render
`N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN=false` because n8n's upstream `true`
default can invalidate the shared floating certificate during a multi-main
rollout.

**Custom workload configuration.** The chart does not render image pull
Secrets, so root Terraform takes over the n8n ServiceAccount only when
`n8n_image_pull_secrets` is non-empty. It uses the distinct
`n8n-enterprise-pull` name to avoid colliding with the chart-owned account and
moves the workload-identity federated subject with it. Inputs contain existing
Secret names only, never registry credentials. Keep `local.n8n_managed_env_names` and
`local.n8n_managed_env_prefixes` synchronized with every environment variable
the module or chart owns before adding to `config.extraEnv`. The one deliberate
exception is `CREDENTIALS_OVERWRITE_DATA_FILE`: `n8n_credentials_overwrite_secret_ref`
(ported from `terraform-aws-n8n` PR #119) appends a `credentials-overwrite`
Secret volume, a read-only mount at `/etc/n8n/credentials-overwrite`, and that
env var after the caller's `n8n_extra_volumes` / `n8n_extra_volume_mounts`
entries, but its conflict checks (`CREDENTIALS_OVERWRITE_DATA[_FILE]` in
`n8n_extra_env`, the reserved volume name and mount path) live as validations on
the new variable and fire only while it is non-null, so callers already
delivering the file through the escape hatches keep working. The module never
reads the Secret's payload, so Secret rotation needs a manual rollout restart.

**Data and observability configuration.** Root `n8n.tf` renders binary mode,
historical binary modes, execution-data mode, Azure connection, metrics,
OpenTelemetry, and log-streaming settings through the shared `config.extraEnv`
list so main, worker, and webhook processes stay aligned. Binary-data modes are
restricted to `database`/`azure` for both binary and execution data — 0.1.0 has
neither n8n's inline-memory `default` binary mode nor a shared-filesystem path.
Azure binary and execution storage have
separate Enterprise entitlements. Mode changes never backfill data, so keep
historical modes and their backends configured until retained objects have
expired or moved. The Azure Key Vault
external-secrets integration is caller-configured in n8n and uses a client
secret, not the Blob workload identity or App Gateway identity. The pinned
n8n path currently constructs the public Azure vault endpoint and does not
expose sovereign vault or authority settings.

**Workload scaling and capacity.** The chart owns the main HPA and worker KEDA
ScaledObject, while root `scaling.tf` owns the webhook HPA because the chart
suppresses that object whenever KEDA is enabled. Helm replica counts must
remain tied to the three autoscaler floors. The CPU capacity check models
both untainted AKS pools, subtracts documented AKS and fixed system workload
allowances, warns only for reviewed Dsv4, Dsv5, and Dsv7 SKUs, and stays silent for
unknown valid SKUs. Keep the SKU map and reservation comments current when
AKS or example sizing changes. The warning is advisory and does not replace
live capacity testing.

**Managed ingress.** Root `ingress.tf` owns the conditional public or
private-only Application Gateway, subnet NSG, WAF policy, AGIC permissions,
and Kubernetes Ingress. `create_ingress = false` must also remove the AKS
AGIC addon while preserving the resource-derived service-discovery outputs.
Keep the three `local.n8n_test_webhook_path_prefixes` entries (main
Service) before all five `local.n8n_webhook_path_prefixes` entries (webhook
processors) before `/` for every host: AGIC renders `Prefix` rules as
string-prefix patterns and Application Gateway evaluates them in declared
order, so `/webhook*` would otherwise capture `/webhook-test`. Do not add
`ssl_certificate` back to the gateway's `ignore_changes`; that silently
turns `app_gateway_tls_cert_secret_id` rotations into no-ops. The subnet NSG must retain `GatewayManager` access on
65200-65535 and `AzureLoadBalancer` probe access before its deny rule. Source
restrictions apply to the editor and webhook paths together.

**DNS and certificate integration.** Root `dns.tf` accepts at most one
caller-owned public or private Azure DNS zone ID with a matching explicit,
plan-known record toggle. It parses the zone name and resource group from
that ID, creates an A record for every value in `local.n8n_ingress_domains`,
and targets the matching public or internal Application Gateway frontend.
Every host must live in the selected zone, and `create_ingress = false` must
omit all records. Root `keyvault.tf` grants only `Key Vault Secrets User` to
the gateway TLS identity when explicitly enabled, waits for RBAC propagation,
and stays behind the same ingress gate. The Let's Encrypt helper normalizes
its canonical name and subject alternative names to lowercase and requires
every name to use its one Azure DNS challenge zone.

**Documentation and contributor contracts.** Section 8 added
[`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md) —
the single place documenting the ownership convention (non-nullable
`create_*`/`install_*` switch, required `existing_*`/`*_prerequisites_confirmed`
inputs, never-inferred-from-nullable-reference), every layer's exact
reference contract, direct `modules/controllers` composition, the
existing-AKS provider-wiring rule (wire `kubernetes`/`helm`/`kubectl` against
the caller's own cluster resource or data source, never against
`module.n8n.aks_kube_config`, when `create_aks = false`), the excluded
AWS-only capabilities (keyless n8n Azure Key Vault external secrets, IAM
permission boundaries, AWS KMS controls, RDS snapshot restoration, EBS CSI
ownership), and the pre-release state-breaking upgrade boundary (no `moved`
blocks; back up the encryption key and durable data; recreate). Root
`README.md` gained a "Customer-managed infrastructure" section that
summarizes the same convention and links that doc, and the Blob-storage row
of the managed-service-topologies table now shows the `create_blob_storage =
false` reference inputs instead of the stale "Always module-managed" text
from before section 6. `docs/troubleshooting.md`, `docs/destroy-cleanup.md`,
`docs/post-deployment.md`, and `docs/data-storage.md` each gained a
customer-managed cross-reference at the point where their existing content's
assumption (module-owned AKS, module-owned namespace, module-owned Blob)
stops holding, rather than restating the whole contract inline.

**Sizing examples.** `examples/small`, `examples/medium`, and `examples/large`
call the resource-bearing root directly and own their Azure foundations. Keep
each example self-contained. The large tier intentionally owns PostgreSQL so
n8n can use the external database contract through the example-owned
two-replica PgBouncer service, and pins an explicit storage replication type.
Keep each tier's mocked test and
`examples/README.md` comparison table synchronized with sizing changes.
`examples/split-ingress` demonstrates `create_ingress = false` plus two
caller-owned Application Gateways. Non-Azure DNS-01 validation (Cloudflare,
GoDaddy) is documented, not demonstrated by a runnable example — see the
"DNS-01 providers" section of `modules/tls-letsencrypt/README.md`.

**Offline verification (section 9).** `openspec/init.sh` and every job matrix
in `.github/workflows/terraform-tests.yml` (`docs`, `validate`, `test`,
`tflint`) enumerate `modules/controllers` and all four
`examples/customer-managed-*` roots alongside the existing sizing examples
and TLS submodules — `checkov` needs no matrix entry since it always scans
the whole repo from `.`. `modules/controllers`, like the two TLS helpers, is
intentionally absent from the `docs` matrix (hand-maintained README, no
`<!-- BEGIN_TF_DOCS -->` block). tflint's `terraform_unused_declarations`
rule only inspects `.tf` files, so a local read solely by a
`tests/*.tftest.hcl` assertion (e.g. `local.effective_aks_resource_group_name`,
kept for a future AKS-resource-group-scoped consumer) reads as unused from
tflint's perspective even though `terraform test` exercises it — suppress
with a `# tflint-ignore: terraform_unused_declarations` comment (see the
precedent in both TLS submodules' `variables.tf`) rather than deleting a
local a test still asserts on. All four new provider-lock refreshes
(`examples/customer-managed-*`) needed a real `terraform providers lock
-platform=...` run — they were created with only the host platform's hashes
tracked, unlike every pre-existing root/example/submodule lock file, which
already carried all three platforms.

## `port-aws-040-enhancements` in progress

This change (`openspec/changes/port-aws-040-enhancements/`) ports the
applicable parts of `terraform-aws-n8n` 0.4.0 (single-main queue mode,
PostgreSQL/Bull/execution-save runtime tuning, a V8 heap ceiling,
caller-managed task-runner launcher configuration, pod DNS, an optional
Redis exporter, AKS OS-disk sizing, and the editor/webhook URL split) —
see its `design.md` for the full per-item applicability table and the
decisions each Azure adaptation is based on. Section 1 added
`tests/scripts/check-n8n-chart.sh`, an offline Helm chart-rendering
regression check with no Azure/Kubernetes-credential dependency, run
locally via `terraform init -backend=false && tests/scripts/check-n8n-chart.sh`.
`terraform console`, when fed a heredoc via a pipe (non-interactive stdin,
as every shell script must), evaluates **one line per expression** —
unlike the interactive REPL, it does not accept a multi-line HCL
expression spanning several heredoc lines and instead reports
"Missing expression" once the input ends mid-expression. Any script
building a `jsonencode({...})` fixture through `terraform console` must
keep that whole expression on a single line. Separately, `terraform
console` (and `terraform plan`) does not require live provider
credentials merely because the configuration declares a data source:
an unconfigured provider's data-source read (e.g. `data.azurerm_resource_group.n8n`
in `iam.tf`) is deferred and reported as `(known after apply)` rather than
erroring the whole plan, as long as the console expression being
evaluated doesn't itself depend on that unresolved value. This is what
lets a chart-check script pull real `var.*`/`local.*` values from the
root module via `terraform console` without any Azure auth, provided the
expression only touches plan-time-known inputs (variables and literals,
not managed-resource attributes like a Flexible Server FQDN). Section 4
added the three nullable `n8n_queue_worker_*` Bull timing inputs, composed
into one `local.n8n_queue_worker_settings` map merged into the chart's
`redis.worker` block only when non-empty. The pinned chart's own
`values.yaml` already ships non-zero `redis.worker.lockDuration` /
`lockRenewTime` / `stalledInterval` defaults (60000/10000/30000 ms) and its
`_configmap-env.tpl` guards each `QUEUE_WORKER_*` entry with a truthy check
on that same value — so those three ConfigMap keys and pod env references
render unconditionally with the chart's own defaults even when this module's
inputs are null and contributes no override. "Omitted by default" for these
three inputs means the module-owned local list is empty, not that the
rendered manifest lacks the keys; `check-n8n-chart.sh`'s default-fixture
assertion checks for the chart's literal default values, not key absence.
The effective-renewal-below-duration cross-variable validation lives on
`n8n_queue_worker_lock_renew_time` only, using `coalesce(var, pinned_default)`
on both sides so an omitted duration or renewal still resolves against the
chart's real default before comparing. Section 5 added the four
non-nullable `n8n_executions_data_save_*` inputs (mapping to
`executions.data.saveOnSuccess`/`saveOnError`/`saveOnProgress`/`saveManualExecutions`),
replacing the literals previously hardcoded in `n8n.tf`. Terraform's
null-falls-back-to-default substitution (assigning `null` to an input that
has a `default` yields that default instead of an error) only fires when
the variable is declared `nullable = false` **and** is being evaluated at
the root module boundary the way `terraform test`'s `variables` block and
`-var`/tfvars assign it. A plain nullable `string`/`bool` variable with a
non-null default does **not** get this treatment at the root: assigning it
an explicit `null` runs the variable's own `validation` block against `null`
itself and fails, exactly as if no default existed. (The commonly cited
null-substitution behavior applies unconditionally only to child *module
call* arguments, not to a root module's own inputs.) A `terraform test` run
block that intends to assert "explicit `null` falls back to the default"
therefore requires `nullable = false` on the variable, not just a `default`.
The existing broad `"EXECUTIONS_"` entry in `local.n8n_managed_env_prefixes`
(added before this change) already reserves all four raw
`EXECUTIONS_DATA_SAVE_*` names in `var.n8n_extra_env`, so section 5 needed
no new guard, only a regression test proving the existing guard still
rejects them. Section 8 added nullable `n8n_dns_config` (nameservers,
searches, options), rendered unconditionally as the chart's top-level
`dnsConfig` value — the pinned chart applies it via Helm's `{{- with
.Values.dnsConfig }}`, which Go templates treat an empty map as falsy, so
`local.n8n_dns_config_values = {}` already omits the block on all three pod
families without a separate ternary in `n8n.tf`. Combining `merge()` with a
`for` expression whose elements have a data-dependent attribute set (here,
each DNS option optionally carrying `value`) produces a spurious
"Inconsistent conditional result types" error from Terraform's static type
unification — it fires only when that dynamically-shaped list is merged
alongside other fixed-shape object keys (e.g. `nameservers`/`searches`),
not when the list stands alone, and the reported error location is
misleading (it blames an unrelated top-level ternary against `{}`). The fix
omits `merge()` entirely: precompute the options list in its own local
(ternary between `null` and the list, never between `{}` and an object —
`null` unifies with any type), then build the effective object with one
`{ for k, v in {...} : k => v if v != null }` comprehension over a plain map
literal holding all three keys, using `try(var.x.field, null)` instead of a
null-guarded ternary to avoid ever evaluating a `null`-vs-`{}` branch pair.
Add a regression test that combines all three `n8n_dns_config` attributes in
one fixture — a test exercising only pairs of attributes will not catch this
class of type-unification failure.

Section 9 added the new root `observability.tf` (non-nullable
`redis_exporter_enabled = false` / `redis_exporter_image`, one
`kubernetes_deployment_v1` plus `kubernetes_service_v1` pair, opt-in) and a
shared `local.n8n_bull_queue_keys = ["bull:jobs:wait", "bull:jobs:active"]`
in `locals.tf` that both the exporter's `REDIS_EXPORTER_CHECK_SINGLE_KEYS`
(`db0=<key>` per entry, database 0 only) and the pre-existing KEDA worker
`ScaledObject` triggers loop (`n8n.tf`) now read, so the two can never
observe different queue names. The exporter reuses `local.redis_connection`
(`redis.tf`), `local.redis_username_present`/`redis_password_present`
(`locals.tf`), and `local.redis_password_secret_name`/`_key` exactly as n8n's
own `redis.passwordSecret` chart value does — it creates no second password
Secret and never reads a caller-managed Secret's payload. An earlier version
of this file claimed checkov's Terraform framework registers `CKV_K8S_*`
checks against unsuffixed `kubernetes_deployment`/`kubernetes_service`
resource types only, not the `_v1` variants used throughout this root, and
that a clean checkov run therefore said nothing about this file. That
diagnosis was wrong (`port-aws-050-enhancements`, matching the AWS
sibling's own correction): checkov does register the `_v1`/`_v2` Kubernetes
resource types. What actually hid this exporter is that checkov evaluates
`count` from variable defaults and answers every check on a count-0
resource with UNKNOWN, which it drops from the report — `redis_exporter_enabled`
is `false` in the module defaults and in every example, so the exporter
drew zero results under the default configuration. Scanned with the toggle
on (`tests/checkov/opt-in.tfvars`, `tests/scripts/check-checkov.sh`), the
resource draws the full set of `CKV_K8S_*` checks; the pod hardening below
still needs direct test assertions for the fields checkov has no
Terraform-side check for (e.g. exact UID, exact capability list), not
because checkov cannot see the resource. `terraform test`'s mocked `kubernetes`
provider represents at least `spec.replicas` and
`security_context.run_as_user` as quoted strings in assertion failure
output even though the provider schema types them numeric — compare with
`tostring(...)` on both sides rather than a bare `== 1` / `== 59000`, or the
assertion fails with a type mismatch that has nothing to do with the actual
rendered value. A `local` built from a managed resource's own computed
attribute (e.g. `local.redis_exporter_addr`, which reads
`azurerm_managed_redis.n8n[0].hostname`/`.port` through
`local.redis_connection`) is unknown under `command = plan` unless that
resource has an `override_resource` supplying the value — unlike a
config-supplied attribute (`sku_name`, `name`), which stays known from the
variable itself. Existing `tests/defaults.tftest.hcl` coverage for the
module-managed Redis path therefore only asserts presence/shape of
`REDIS_ADDR`, not its exact value; the external-Redis runs (fully
variable-driven host/port/TLS) assert the exact `redis://`/`rediss://`
string instead. `terraform graph`'s default transitive reduction drops a
`depends_on` edge that is already implied by another edge in the same DOT
output (e.g. exporter → `kubernetes_namespace.n8n` disappears once exporter
→ `kubernetes_secret.n8n_redis` → `kubernetes_namespace.n8n` exists) — a
missing edge in `terraform graph` output is not proof the `depends_on` entry
itself is missing from the resource block; check the `.tf` source, not just
the rendered graph, and use the graph output only to confirm the absence of
an unwanted reverse edge (e.g. no `n8n`/`KEDA` → exporter edge).

Section 12 exposed `n8n_main_hpa_min_replicas` as a validated passthrough
variable in all eight examples (three sizing tiers, `split-ingress`, and the
four `customer-managed-*` examples), defaulting to each example's documented
floor (2, except medium's 3 and large's 6). For `small`/`medium`/`large`,
which already carry a `local.tier` map surfaced through a `tier_configuration`
output, the cleanest wiring sets the map's `main_min_replicas` entry directly
to `var.n8n_main_hpa_min_replicas` — the existing `main.tf` reference to
`local.tier.main_min_replicas` needs no further change, and the effective
value is already visible through the existing output. Examples without a tier
map gained a dedicated `main_hpa_min_replicas` (or `output.main_hpa_min_replicas`)
output exposing `var.n8n_main_hpa_min_replicas` directly, matching the existing
`webhook_base_url` pattern in `split-ingress/outputs.tf`. A `terraform test`
`assert` block cannot reference a resource nested inside a child module
(`module.n8n.helm_release.n8n...`, `module.n8n.some_local`) — only that
module's own declared outputs are visible from the calling root's test file;
confirmed by probing with `override_resource`-style addressing against
`module.n8n.helm_release.n8n`, which Terraform rejects as `Unsupported
attribute`. This is why every example needed its own thin output rather than
reaching into the root module's Helm values to prove the passthrough. Local
`terraform.tfvars` files (gitignored, used for a contributor's own prior live
tests) and gitignored `*_override.tf` scratch files (e.g. a leftover
`examples/small/pr2_override.tf` declaring a stray `provider "acme"` block)
are picked up automatically by `terraform init`/`terraform test` and can break
an otherwise-correct example; move them aside before running tests locally
and restore them afterward — they are intentionally untracked and must never
be committed or deleted on someone else's behalf.

Section 13.1 made `detect_topology()` and `check_deployment()` in
`tests/scripts/smoke-test.sh` standalone functions (defined right after the
script's `pass`/`fail`/`warn`/`skip`/`info` helpers, before `Preflight`)
specifically so an `SMOKE_TEST_SELF_TEST=1` guard placed in that same spot
can stub `kubectl` with synthetic fixtures and exercise both functions for
single-main, healthy multi-main, and degraded multi-main (one ready pod of
two desired) without `az login`, Terraform state, or a live cluster — the
guard block runs and `exit`s before `Preflight`'s `require_cmd`/`az account
show` checks, so it is unreachable during a real post-apply run. Topology
detection reads the *rendered* `n8n-main` HorizontalPodAutoscaler
(`minReplicas == maxReplicas == 1` selects single-main) rather than the
current main pod count, which can transiently disagree with the configured
floor mid-rollout; Deployment `strategy.type` and the main
`PodDisruptionBudget`'s `minAvailable` are read only as consistency
cross-checks against that same topology. The chart's `n8n.fullname` template
resolves to the bare `n8n` release name (no suffix), so every rendered
resource the smoke test inspects by name uses the `n8n-<component>`
convention (`n8n-main` HPA/Deployment/PDB, `n8n-worker`,
`n8n-webhook-processor`) — confirmed by pulling the pinned chart's raw
templates rather than assuming naming from the module side.

Section 13.2 added a `## Main topology: multi-main and single-main` section
to the root `README.md` (linked from the table of contents, from
`docs/post-deployment.md`'s license-activation step, and from
`docs/data-storage.md`'s new database-only recipe) plus a dedicated
`docs/troubleshooting.md` entry for the specific failure mode of raising
`n8n_main_hpa_min_replicas` without the `feat:multipleMainInstances`
entitlement: the additional main pod(s) fail their license check,
`helm_release.n8n`'s existing `wait = true` blocks until `timeout`, and
`atomic = true` / `cleanup_on_fail = true` (already present before this
change, not new behavior) roll the release back automatically — this needed
only documentation, not a new safeguard. A caller-managed Blob container
(`create_blob_storage = false`) is independent of the
`feat:binaryDataAz`/`feat:executionDataAz` entitlements gating the Azure
storage modes, so `docs/customer-managed-infrastructure.md`'s Blob section
cross-references the same database-only recipe rather than implying ownership
of the container substitutes for the entitlement.


## `port-aws-050-enhancements`: worker pools (early alpha)

This change (`openspec/changes/port-aws-050-enhancements/`) ports the
applicable parts of `terraform-aws-n8n` 0.5.0 onto this module; most of it
(the `n8n_credentials_overwrite_secret_ref` conflict check extended to pool
`extra_env`, the two new reserved names in `local.n8n_managed_env_names`,
and the pool-CPU accounting folded into `scaling.tf`'s capacity model) is
narrow enough that `CHANGELOG.md`'s Unreleased entry is the fuller record.
The headline addition is `n8n_worker_pools` (new `worker-pools.tf`),
**EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE**, tracking two upstream
features that are themselves alpha: n8n's own worker pools, and the chart
support for them (`queueMode.workerGroups`, n8n-io/n8n-hosting#189), merged
to the chart's `preview/worker-pools` branch but not released to a numbered
chart version.

**Chart-values-only.** The feature creates zero new Terraform resources.
Every pool declared in `var.n8n_worker_pools` maps onto one entry of the
chart's own `queueMode.workerGroups` Helm value, which the chart itself
renders into a worker Deployment and a KEDA `ScaledObject`; this module's
contribution is entirely `worker-pools.tf`'s locals (validated pool names
at plan time, sizing knobs that fall back to the module-wide `n8n_worker_*`
defaults instead of the chart's, `N8N_WORKER_POOLS_ENABLED` on
`config.extraEnv`) plus the merge in `n8n.tf`'s `helm_release.n8n`. The
default `[]` omits `queueMode.workerGroups` from the values entirely rather
than sending an empty list, so an untouched deployment sees no Helm diff.

**Pool scalers reuse the default worker's `TriggerAuthentication`.** Every
KEDA scaler this module renders, the default worker's and each pool's,
authenticates through the one `kubectl_manifest.keda_trigger_authentication`
CR (`keda.tf`) via `authenticationRef = { name = local.n8n_redis_keda_auth_name }`
when `local.redis_authentication_enabled`. When it is false the pool omits
the `authenticationRef` key entirely, unlike `n8n.tf`, which sends `""` for
the default worker: the chart schema puts `minLength: 1` on
`workerGroups[].keda.authenticationRef.name` (top-level `keda` is not in the
schema), and Helm validates the schema before the template's `and` guard
runs, so an empty name fails the render. `tests/scripts/check-n8n-chart.sh`
renders that exact path against the preview chart. The chart's
`queueMode.workerGroups[].keda` exposes both `triggerMetadata` (merged into
the pool's two chart-templated Redis triggers) and `authenticationRef`
(verified against the `preview/worker-pools` branch schema and against the
published `1.11.0-preview.workerpools.1` build's
`templates/scaledobject-worker-group.yaml`). The module puts only
`enableTLS = tostring(local.redis_connection.tls_enabled)` into
`triggerMetadata`, rendered unconditionally (`"true"`/`"false"`) exactly as
`n8n.tf` does for the default worker, so the two ScaledObjects compare
key-for-key and Redis credentials never appear in ScaledObject metadata. An
earlier draft of this change used a flat `passwordFromEnv`/`username`
metadata merge instead (the shape `terraform-aws-n8n` uses, where the
default worker also carries flat metadata) on the mistaken belief that the
chart had no per-group `authenticationRef`; that shape is functional (KEDA
resolves `secretKeyRef` env from `containers[0]`, which is `n8n-worker`)
but inconsistent with this module's own default worker, and it made
`tests/scripts/verify-worker-pools.sh`'s baseline comparison fail on every
authenticated deployment. Do not reintroduce it. Get `enableTLS` wrong
against a TLS-only Redis endpoint and the pool's scaler fails closed
silently: it sits at `min_replicas` with nothing crashing to announce it,
the same failure mode `README.md`'s KEDA troubleshooting section already
documents for the default worker's scaler.

**Two guards, both hard stops.** A chart that predates
`queueMode.workerGroups` has no `additionalProperties: false` on
`queueMode`, so Helm accepts the key, renders nothing for it, and the
release succeeds: `N8N_WORKER_POOLS_ENABLED` lands on every pod, no pool
Deployment or `ScaledObject` exists, and every project pinned to a pool
quietly runs on the default queue. Mocked plan-time tests cannot see this,
and neither can a real plan, so the chart pairing is a `lifecycle.precondition`
on `helm_release.n8n`: it fails the plan whenever `n8n_worker_pools` is
non-empty and the pinned `n8n_chart_version` is a numbered release, unless
`n8n_worker_pools_chart_verified` attests it for a private mirror. A
prerelease version (one carrying a SemVer 2 `-` segment) is exempt
automatically, which is how the official preview build installs. The image
pairing is a `validation` block on `n8n_image_tag` (2.39.0 floor while
`n8n_worker_pools` is non-empty), next to the existing 2.19 and 2.29 floors
on the same variable. It was first drafted as an advisory `check` on the
AWS sibling's premise that `n8n_image_tag` is usually `null` (the chart's
floating `stable` tag); in this module the variable defaults to a pinned
version and its regex validation rejects `null`, so the floor is fully
decidable at plan time and there was no reason to let it through as a
warning. An old image does not fail loudly: it silently accepts and ignores
`N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME`, so pool workers come
up healthy while consuming the default queue and every pool queue stays
empty (wrong capacity, not a no-op). `tests/scripts/verify-worker-pools.sh`
is what catches the chart-side silent outcome after a live apply, plus an
image that drifted from the pinned tag. When porting from
`terraform-aws-n8n`, check both of these premises (`n8n_image_tag` default,
default worker KEDA auth shape) before copying a guard's severity or a
scaler's metadata shape.

**Alpha caveats.** The `feat:workerPools` licence entitlement is required,
and unlike the two guards above, its absence is not silent: a worker
started with `N8N_WORKER_POOL_NAME` it is not licensed for exits 1, so the
pool pods crash-loop and `helm_release.n8n`'s existing `atomic = true`
rolls the release back, failing the apply. Terraform cannot see licence
entitlements at plan. Scale-from-zero has one bootstrap gap: n8n only
offers a pool for assignment in a project's Worker Pools setting while one
of its workers is registered, so a pool declared at `min_replicas = 0`
cannot be assigned to any project yet; start it at `1`, assign the
project(s), then lower it back to `0` (the assignment is stored and
survives the scale-down; KEDA then scales it 0 to 1 within one polling
interval on the next job). Every pool worker also opens up to
`postgres_pool_size` PostgreSQL connections the same as the default
worker does, so raising a pool's ceiling grows the aggregate connection
count against the Flexible Server's `max_connections` exactly like raising
`n8n_worker_keda_max_replicas` does; budget the pool ceilings into the same
arithmetic, not on top of it unaccounted for.

## Chart 1.13.0 bump (`feat/chart-1.13.0`)

`n8n_chart_version` defaults to `1.13.0`, matching the AWS sibling after
`terraform-aws-n8n` #145. Run `tests/scripts/chart-values-diff.sh
<candidate>` before any future bump, but also diff `templates/` directly:
the values diff for 1.11.0 to 1.13.0 showed only the pause keys and the
`image.tag` default, while the template diff carried the two changes that
actually mattered here. First, `n8n.autoscalerOwnsReplicas`
(n8n-hosting #201) drops `spec.replicas` from the worker and webhook-processor
Deployments whenever a KEDA `ScaledObject` renders for that component, or
the chart's own HPA is on with KEDA off. In this module that predicate is
unconditionally true for the worker (KEDA always on, non-empty triggers,
`n8n_worker_keda_min_replicas >= 1` by validation) and unconditionally false
for the webhook processor (the module never sets `keda.webhookProcessor.enabled`
or `hpa.webhookProcessor.enabled`; `scaling.tf`'s HPA is invisible to the
chart), so `queueMode.workerReplicaCount` now only gates whether the worker
Deployment exists and `check-n8n-chart.sh` asserts the field is absent on
the worker and present on the webhook processor. The first upgrade dips the
worker Deployment to 1 replica until the KEDA-created HPA restores
`minReplicas`; that is upstream's documented behavior, not something to
gate. Second, `n8n.mainTaskRunnersEnabled` (n8n-hosting #179) renders the
task-runner sidecar, its env, and the launcher ConfigMap mount on main only
in standalone mode; this module always runs queue mode, so only workers
carry the sidecar, `scaling.tf`'s capacity model drops the sidecar request
from the main ceiling only for the verified upstream charts `1.12.0` and
`1.13.0` (`local.n8n_chart_has_worker_only_runners`, the same version-gated
shape as `terraform-aws-n8n` minus its repository check, since this module
hardcodes the OCI repository; the `1.11.0`-based worker-pools preview
chart therefore still counts the main sidecar), and the launcher-config
assertions in `check-n8n-chart.sh` expect no sidecar on main. `keda.worker.pause` /
`pausedReplicaCount` are exposed as `n8n_worker_keda_pause` /
`n8n_worker_keda_paused_replica_count`, with
`check.worker_keda_pause_requires_a_supported_chart` warning on any chart
older than `1.13.0` (`local.n8n_worker_keda_pause_supported` in
`scaling.tf`, a numeric major.minor floor on the prerelease-stripped
version core, so the `1.11.0`-based worker-pools preview warns). AWS pairs
it with a worker-floor-of-0 check; Azure needs none because
`n8n_worker_keda_min_replicas >= 1` is validated. The chart's
webhook-processor pause is intentionally not exposed because no webhook `ScaledObject` exists here
for the annotation to land on. The typed `keda` schema (#202) types
`pausedReplicaCount` as `["integer", "null"]` and `authenticationRef.name`
as a plain string, so rendering `null` and `""` from Terraform is fine; the
default fixture in `tests/chart-values.tftest.hcl` already uses an
unauthenticated external Redis, so the `""` case is exercised on every
`check-n8n-chart.sh` run. `queueMode.workerGroups` remains unreleased
(preview branch only), so nothing in `worker-pools.tf` or
`examples/worker-pools` changed, and pools callers on the `1.11.0`-based
preview chart get neither #201 nor #179 until a new preview build exists.

A `run` block in `tests/defaults.tftest.hcl` that decodes
`helm_release.n8n.values[0]` must set `create_database = false` /
`create_redis = false` with external hosts and the `azurerm_user_assigned_identity.n8n_workload`
`override_resource`, or the plan-time value is unknown (the module-managed
Redis hostname is a post-apply attribute) and the assertion fails with
"Unknown condition value"; the base run's `values` are unknown for that
reason, so new default-shape assertions belong in their own run. In jq, `|`
binds looser than `and`, so `[...] | length == 0 and (.spec...)` evaluates
the right-hand side against the filtered array, not the document;
parenthesize each side.

## What this repo is

`terraform-azurerm-n8n` is a Terraform module that deploys a **production-grade,
multi-main [n8n Enterprise](https://n8n.io) installation on Microsoft Azure**. A
single `terraform apply` brings up the full stack:

- **Azure Kubernetes Service (AKS)** cluster with OIDC issuer and workload
  identity enabled, availability-zone-spread node pools, optional API-server
  authorized IP ranges, and an autoscaler-owned node count (default
  `Standard_D4s_v4`).
- **Multiple n8n main pods** plus dedicated **worker** and **webhook-processor**
  pods (queue mode) — the Enterprise multi-main topology, each independently
  autoscaled (main/webhook HPA, worker KEDA `ScaledObject`).
- **PostgreSQL — Flexible Server**, on a delegated subnet with the `uuid-ossp`
  extension allow-listed via `azure.extensions`, or an external PostgreSQL
  endpoint (`create_database = false`).
- **Azure Managed Redis** behind a private endpoint (`NoCluster`, encrypted
  protocol, access-key auth) for the Bull queue backing workers, or an
  external Redis endpoint (`create_redis = false`).
- **Private Azure Blob Storage** for binary and execution data, authenticated
  via AKS workload identity by default, with PostgreSQL as the durable
  non-Azure binary and execution-data backend.
- **Application Gateway (WAF_v2 by default)** with **AGIC** (Application
  Gateway Ingress Controller) and **KEDA** for ingress, queue-driven worker
  scaling, and HPA-driven main/webhook-processor scaling — or
  `create_ingress = false` for a caller-owned ingress topology.
- **Azure Key Vault**-backed TLS for the App Gateway listener via a single
  BYO-secret contract: the caller supplies a Key Vault Secret URI as
  `var.app_gateway_tls_cert_secret_id`. The two `modules/tls-letsencrypt/`
  and `modules/tls-self-signed/` submodules expose this exact value as
  their `app_gateway_tls_cert_secret_id` output for callers who don't
  already have a cert. Pair the URI with `app_gateway_keyvault_id` so
  this module grants the App Gateway UAMI `Key Vault Secrets User` on
  the vault holding the cert.
- **Optional public or private Azure DNS** A-records for the canonical domain
  and every additional domain, when the caller passes a zone ID and the
  matching record toggle.

An **n8n Enterprise license key** is required (`var.n8n_license_key`) — the
module does not provision a community-edition deployment.

The module **expects a pre-existing VNet** and five pre-sized subnets. The
`examples/small`, `examples/medium`, and `examples/large` roots create those
Azure foundations and call the resource-bearing root directly.

### Architecture at a glance

```text
              ┌──────── Azure DNS (optional, public or private) ────┐
              │                                                     │
   user ──► App Gateway (AGIC, WAF_v2) ──► AKS ──► n8n mains ──► PostgreSQL Flex
                                              │             │     (delegated subnet,
                                              │             │      private DNS zone)
                                              │             │
                                              │             └──► Azure Managed Redis
                                              │                   (private endpoint,
                                              │                   TLS-only) ◄── workers (KEDA-scaled)
                                              │
                                              └──► Azure Blob Storage (private endpoint,
                                                   workload identity) for binary /
                                                   execution data
```

### File layout

The module follows the [standard module
structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
expected by the Terraform Registry: one resource-bearing root, one file per
concern, and one deliberate nested call to the directly composable
`modules/controllers` KEDA submodule.

| File / dir                        | Purpose                                                     |
| --------------------------------- | ----------------------------------------------------------- |
| `versions.tf`                     | `required_providers` (`azurerm`, `kubernetes`, `helm`, `random`, `time`, `kubectl`), `required_version = ">= 1.9"`. **No `provider {}` blocks.** |
| `variables.tf` / `locals.tf` / `outputs.tf` | Root input, naming/tag, and output contract. |
| `aks.tf`, `iam.tf`                | AKS cluster + node pool, workload/AGIC UAMIs, AKS API warm-up gate, workload-identity federated credential. No dormant identities: a kubelet UAMI (private-ACR pulls, CMK disks) is added only when a story binds it. |
| `database.tf`                     | Managed PostgreSQL Flexible Server or external-endpoint contract; `local.postgres_connection`. |
| `redis.tf`                        | Managed Azure Managed Redis or external-endpoint contract; `local.redis_connection`. |
| `storage.tf`                      | Private Azure Blob container, private endpoint, private DNS. |
| `controllers.tf`, `keda.tf`, `n8n.tf` | KEDA + namespace + Secrets + n8n Helm release + post-install settle gate. |
| `scaling.tf`                      | Webhook-processor HPA and the advisory AKS capacity diagnostic. |
| `ingress.tf`, `keyvault.tf`, `dns.tf` | Conditional Application Gateway + AGIC + NSG + Kubernetes Ingress, Key Vault role assignment, public/private Azure DNS A-records. |
| `modules/tls-self-signed/`        | Lab-grade self-signed cert issued via `tls_self_signed_cert` and imported into a caller-owned Key Vault. |
| `modules/tls-letsencrypt/`        | Production-grade Let's Encrypt cert issued via `vancluever/acme` (DNS-01, with subject alternative names) and imported into a caller-owned Key Vault. |
| `examples/small/`, `examples/medium/`, `examples/large/` | End-to-end sizing examples with caller-owned Azure foundations, a Key Vault certificate helper, and one root `module "n8n"` call. |
| `examples/split-ingress/` | Single-decision topology example — module ingress fully disabled in favor of two caller-owned Application Gateways. |
| `tests/scripts/smoke-test.sh`     | Post-`apply` smoke test for live deployments.               |
| `tests/scripts/preflight-region-check.sh` | Pre-`apply` region/subscription capability check (AKS SKU zones, PostgreSQL Flexible Server versions/SKU, optional Managed Redis capacity probe); reads region and SKUs from the caller's own `terraform plan`. |
| `docs/`                           | Long-form supplementary docs (upgrading n8n and the chart, troubleshooting, post-deploy, cleanup, TLS rotation, Redis, data storage, observability, Azure Key Vault external secrets, topology maintenance). `docs/qualification-runs/` holds one filled-in copy of `docs/manual-azure-qualification.md` per live run; never edit the template's Result rows in place. |
| `README.md`                       | Human entry point — architecture, prerequisites, usage, and the auto-generated Reference block. |
| `LICENSE`                         | MIT. Required for registry publication.                     |
| `.copywrite.hcl`                  | Enforces the `# Copyright n8n GmbH 2025` / `# SPDX-License-Identifier: MIT` header on every `.tf`. |
| `.github/workflows/`              | CI: fmt, validate, test, tflint, checkov, terraform-docs.   |
| `openspec/`                       | OpenSpec change artifacts (proposal, design, delta specs, tasks) for in-flight and recently shipped changes. Intentionally tracked — this file references them — and ships in release tags as contributor documentation. |
| `.agents/skills/`                 | Vendored agent skills used by AI contributors working in this repo. Intentionally tracked; inert for module consumers. Loop-runner state (`progress.txt`, `skills-lock.json`, `logs/`) is gitignored and must never be committed. |

### Azure-specific deltas vs `terraform-aws-n8n`

These are the things the AWS module does **not** need but this module
**does** — they exist because Azure managed services have specific failure
modes the prototype encountered. **Preserve them when restructuring.**

Only **two** genuine deltas remain. Everything else either matches the AWS
sibling's pattern with a different parameter or has been retired — see
"Historical retirements" below.

1. **`azure.extensions = UUID-OSSP` allowlist on Flex Server**
   (`azurerm_postgresql_flexible_server_configuration.uuid_ossp` in
   `database.tf`) — Flex Server requires server-level allowlisting before
   any client (n8n's migrations or an operator's `psql`) can run
   `CREATE EXTENSION "uuid-ossp"`. The configuration resource is the only
   Terraform-side requirement; no in-cluster bootstrap Job is needed because
   n8n's current migrations don't depend on `uuid_generate_v4()` (verified
   against `packages/@n8n/db/AGENTS.md`). HVD takes the same shape with
   `azure.extensions = "CITEXT,HSTORE,UUID-OSSP"`. AWS RDS has no equivalent
   allowlist requirement, so this delta has no sibling.
2. **KEDA `TriggerAuthentication` CRD-aware install**
   (`kubectl_manifest.keda_trigger_authentication` in `keda.tf`) — KEDA's
   `TriggerAuthentication` CRD is installed by `helm_release.keda` on first
   apply, but `hashicorp/kubernetes_manifest` validates CRDs at plan time,
   which would force a two-pass apply. The module installs the CR via
   `gavinbunney/kubectl_manifest`, which defers schema resolution to apply
   time and lets a single-pass apply succeed against a fresh cluster.

Azure Managed Redis (this module's Redis backend) replacing legacy Azure
Cache for Redis is a resource-type change, not a structural delta vs AWS —
AWS ElastiCache doesn't require the equivalent authentication contract, so
there's no shared pattern to compare against either way.

#### Historical retirements

All five `null_resource` workarounds the prototype shipped with were
replaced with declarative idioms that are **not** Azure-specific in shape
(only in parameter values), and the legacy three-mode TLS surface
(`var.tls_mode = self_signed | letsencrypt | custom_pfx`) was collapsed into
a single BYO-secret contract. The internal two-tier split (`modules/infra/` +
`modules/workload/`, 0 providers at the root) was itself later reverted by
`align-azure-with-aws-capabilities` back into one resource-bearing root:

- **AKS API warm-up** — `time_sleep.aks_api_warmup` in `aks.tf`
  (`var.aks_api_warmup_seconds`, default 90 s, range 30..600). Replaced the
  `null_resource.wait_for_aks_api` `/healthz` poll-loop. The kubernetes /
  helm providers' built-in retry handles any post-gate 503s.
- **uuid-ossp bootstrap Job** — deleted entirely; the server-level
  `azure.extensions` allowlist (delta #1 above) is now the only
  Terraform-side artefact.
- **Post-deploy migration rollout-restart** — chart-native Redis multi-main
  leader election (`multiMain.setup`) plus `helm_release.n8n` running with
  `wait = true, atomic = true, timeout = 600, cleanup_on_fail = true`
  together absorb the `CREATE INDEX CONCURRENTLY` race natively. A small
  `time_sleep.n8n_helm_settle` (default 60 s, configurable via
  `var.n8n_helm_post_install_settle_seconds`) gates the Ingress so AGIC
  reconciles against a fully-converged deployment.
- **KEDA TriggerAuthentication apply-time `kubectl`** —
  `kubectl_manifest.keda_trigger_authentication` in `keda.tf` (delta #2
  above). The chart-native path is unavailable because the n8n-io chart at
  the pinned version does not expose `keda.triggerAuthentication.*` values
  nor `extraManifests` / `extraObjects` hooks (verified upstream
  `values.yaml`).
- **Destroy-time Azure Files CIFS-detach drain** — `time_sleep.wait_for_aks_drain`
  in `cleanup.tf` existed only to absorb the asynchronous SMB detach after Helm
  uninstalled pods mounting the Azure Files share. Removed by
  `slim-first-release-surface` alongside Azure Files support itself — no
  shared-filesystem mount means no CIFS detach to wait on. If a live destroy
  qualification surfaces a different teardown race, reintroduce a gate with
  that failure mode documented; do not resurrect the CIFS rationale.
- **Three-mode TLS surface (`var.tls_mode`) + module-owned Key Vault** —
  collapsed into a single BYO-secret contract: `var.app_gateway_tls_cert_secret_id`
  + the optional `var.app_gateway_keyvault_id` (role-assignment scope). The
  `acme_*` and `tls_*` helper trees live in `modules/tls-letsencrypt/` and
  `modules/tls-self-signed/`.
- **Two-tier composition (`modules/infra/` + `modules/workload/`)** — every
  resource, control, and safeguard both submodules owned now lives at the
  root in the concern files listed under [File layout](#file-layout) above.

## Quality bar: HashiCorp Terraform Registry & Partner Premier Tier

This module targets the same quality criteria HashiCorp publishes for
partner modules in the Terraform Registry as the AWS sibling — specifically
the [Partner Premier
Tier](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
and the broader [Terraform partnerships
guidelines](https://developer.hashicorp.com/terraform/docs/partnerships).

> Module quality is ensured through a varied set of standards focused on
> HashiCorp-defined, best-in-class infrastructure as code principles. This
> includes:
>
> - Successfully passing TFLint, Checkov, or another static code analysis tool
>   and reporting the result to HashiCorp
> - Traditional unit and integration testing via Terraform test
> - Adherence to Terraform's official naming conventions
> - Clear module documentation
> - Inclusion of all standard module files

Concretely, in this repo:

### 1. Static analysis (TFLint + Checkov)

`.github/workflows/terraform-tests.yml` runs both on every PR and push to `main`:

- **`terraform fmt -check -recursive`** — canonical formatting.
- **`terraform validate`** against the root, both TLS submodules, and every
  example.
- **`tflint`** against the same set, with the **azurerm** ruleset initialized
  via `tflint --init`. The ruleset comes from `.tflint.hcl` at the module
  root, which pins `terraform-linters/tflint-ruleset-azurerm`.
- **`checkov`**, installed at the pinned `CHECKOV_VERSION` (`.github/workflows/terraform-tests.yml`)
  rather than via `bridgecrewio/checkov-action`'s own floating `@v12` tag,
  and run through `tests/scripts/check-checkov.sh`. Two passes: the
  configuration as written (reported, not gating; a pre-existing,
  uncurated backlog exists across every sizing example, tracked for a
  dedicated curation pass), and the same scan with
  `tests/checkov/opt-in.tfvars` applied so count-0 resources (e.g. the
  disabled-by-default Redis exporter) are actually evaluated, which is
  the one thing this job hard-fails on: a rename or a broken toggle that
  stops a listed opt-in resource from being reached. **When you add new
  resources, do not regress curated findings; prefer fixing them over
  adding suppressions.**

### 2. Unit + integration tests via `terraform test`

- `tests/defaults.tftest.hcl` exercises every resource, output, and
  diagnostic the root module owns. Uses `mock_provider` for all six
  declared providers.
- `modules/tls-letsencrypt/tests/*.tftest.hcl` and
  `modules/tls-self-signed/tests/*.tftest.hcl` cover the two TLS helpers.
- Each of `examples/small`, `examples/medium`, `examples/large`, and
  `examples/split-ingress` carries its own `tests/*.tftest.hcl` suite
  asserting the example's distinguishing decisions (sizing, split-ingress
  routing).

`tests/scripts/smoke-test.sh` is the **integration / post-apply** check used
against a real cluster — kept out of CI on purpose (it needs live Azure
credentials and an applied stack).

All Terraform test suites run **without Azure credentials** and are safe to
run in CI.

When you add a feature, add an `assert` for it in the relevant
`.tftest.hcl` file. Use `command = plan` unless you specifically need
apply semantics.

**Combined wall-clock budget:** every `terraform test` suite in this repo
(root + both TLS submodules + all six examples) must complete in **under 5
minutes** on a clean GitHub Actions runner. If you add a run that pushes the
budget, profile it.

### 3. Naming conventions

This module follows the [Terraform module
conventions](https://developer.hashicorp.com/terraform/language/modules/develop/structure):

- Repository name is **`terraform-<PROVIDER>-<NAME>`** → `terraform-azurerm-n8n`.
- Resource names use **`snake_case`**. The "main" resource of a kind in this
  module is named `n8n` (e.g. `azurerm_kubernetes_cluster.n8n`,
  `azurerm_postgresql_flexible_server.n8n`, `azurerm_managed_redis.n8n`) —
  this matches the registry convention of using a short, descriptive label
  rather than repeating the resource type.
- Variables and outputs use **`snake_case`** with a leading noun
  (`location`, `friendly_name_prefix`, `n8n_domain`, `aks_subnet_id`,
  `appgw_fqdn`).
- Every variable has a `description` and a `type`. Most have a `validation`
  block that fails fast with a useful error message — preserve this when
  adding new inputs. If a variable genuinely doesn't need validation, leave a
  `# no validation: <reason>` comment immediately above it so the
  `invalid_inputs_fail_fast` test sweep stays honest.
- Every output has a `description`. Outputs containing secrets are marked
  `sensitive = true`.
- All taggable `azurerm_*` resources receive `local.common_tags`, which
  always includes `ManagedBy = "terraform"` and `Project = "n8n"` and merges
  `var.common_tags` on top. Resources also set a `Name` tag derived from
  `var.friendly_name_prefix`.

### 4. Clear documentation

- `README.md` is the entry point. The `## Reference` section between
  `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is **auto-generated**
  — do not hand-edit it. All rendering options (formatter, output template,
  `lockfile: false` to keep providers shown as constraints) live in
  `.terraform-docs.yml`, so refreshing the README is one command:

  ```bash
  brew install terraform-docs   # or: see the install step in .github/workflows/terraform-tests.yml
  terraform-docs .
  ```

  CI installs the same version (`v0.24.0`, tracking the brew default) and
  runs `terraform-docs --output-check .`. If your local version differs
  from CI's, the markdown table whitespace will drift and the check will
  fail; bump both together when upgrading.

- `examples/README.md` compares the sizing tiers; each tier has its own generated README reference.
- `docs/troubleshooting.md`, `docs/post-deployment.md`, `docs/destroy-cleanup.md`,
  `docs/tls-rotation.md`, `docs/redis.md`, `docs/data-storage.md`,
  `docs/observability.md`, `docs/azure-key-vault-external-secrets.md`,
  `docs/versioning.md`, and `docs/deletion-safety.md` cover operator-facing
  concerns that don't belong inline in `README.md`.
- Inline comments in `.tf` files use the `# ── Section ──` banner style.
  Match it when adding new sections.
- The `kubectl_manifest.keda_trigger_authentication` defer-rendered manifest
  carries a comment block above the resource documenting the failure mode
  prevented and a link to the relevant troubleshooting doc.

### 5. Standard module files

All of the following are present and should stay present:

- `README.md`, `LICENSE`, `versions.tf`, `variables.tf`, `outputs.tf`
- `examples/` with at least one runnable example
- `tests/` with at least one `.tftest.hcl` suite
- `.github/workflows/` with the CI pipeline above
- `.copywrite.hcl` enforcing the MIT header on every `.tf`

## How to work in this repo (agent quick reference)

### Local development loop

```bash
terraform fmt -recursive        # before committing (covers the root + both TLS submodules + every example)

# Root module
terraform init -backend=false
terraform validate
terraform test -verbose         # plan-time, no Azure creds needed
tflint --init && tflint --format compact

# Helper submodules
for dir in modules/controllers modules/tls-self-signed modules/tls-letsencrypt; do
  terraform -chdir="$dir" init -backend=false
  terraform -chdir="$dir" validate
  terraform -chdir="$dir" test -verbose
done

# Examples
for dir in examples/small examples/medium examples/large examples/split-ingress \
  examples/customer-managed-cluster examples/customer-managed-redis \
  examples/customer-managed-storage examples/customer-managed-everything; do
  terraform -chdir="$dir" init -backend=false
  terraform -chdir="$dir" validate
  terraform -chdir="$dir" test -verbose
done

# Static analysis (matches CI; requires checkov at the pinned CHECKOV_VERSION):
tests/scripts/check-checkov.sh

# Refresh the README reference blocks (matches CI's --output-check):
terraform-docs .
terraform-docs examples/small
terraform-docs examples/medium
terraform-docs examples/large
terraform-docs examples/split-ingress
terraform-docs examples/customer-managed-cluster
terraform-docs examples/customer-managed-redis
terraform-docs examples/customer-managed-storage
terraform-docs examples/customer-managed-everything
```

`./openspec/init.sh` runs the offline subset of this loop (fmt, init, validate,
test) across the root, all three submodules, and all eight examples in one
command — safe to run repeatedly, no Azure credentials required.

After running any `terraform init`, clean up `.terraform/` before committing
— it is gitignored and `init` will recreate it. `.terraform.lock.hcl` is the
opposite: it is intentionally tracked (not gitignored) at the root and every
example/submodule, per module-verification's "Provider lock coverage"
requirement. After adding or bumping a provider, refresh every lock file for
all three supported platforms and commit the result:

```bash
for dir in . modules/controllers modules/tls-self-signed modules/tls-letsencrypt \
  examples/small examples/medium examples/large \
  examples/split-ingress examples/customer-managed-cluster \
  examples/customer-managed-redis examples/customer-managed-storage \
  examples/customer-managed-everything; do
  terraform -chdir="$dir" providers lock \
    -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
done
```

A real deployment uses `terraform apply` from the selected sizing example with
a populated `terraform.tfvars`, but **never apply from CI** in this repo.

### Running `tests/scripts/preflight-region-check.sh` before a live apply

Three failures only surface 10-20 minutes into an apply and are region or
subscription gaps, not module bugs: AKS `AvailabilityZoneNotSupported`,
PostgreSQL Flexible Server `ParameterOutOfRange 'Version' ... in: []`, and
Managed Redis `InsufficientCapacity` (see the first three entries of
`docs/troubleshooting.md`). Run the preflight from the root you will apply;
with no flags it plans that root (`-refresh=false`) and reads the region, VM
size, zones, PostgreSQL version/SKU, and Redis SKU the plan would request, so
the check matches the caller's configuration rather than the module defaults:

```bash
az login
cd examples/small
terraform init                                          # populated terraform.tfvars
../../tests/scripts/preflight-region-check.sh            # reads region + SKUs from the plan
../../tests/scripts/preflight-region-check.sh --probe-redis   # also creates+deletes a throwaway Managed Redis cluster
```

Every value can be overridden (`--region`, `--vm-size`, `--zones`,
`--pg-version`, `--pg-sku`, `--redis-sku`); `--region` alone skips the plan.
Azure has no capacity API for Managed Redis, so only the probe answers that
question, and only for the moment it runs. It needs `jq` and Azure CLI
`>= 2.75` (enforced by the script: older releases nest the PostgreSQL
capability payload differently, and the on-demand `redisenterprise` extension
declares the same floor). Like the smoke test it needs live credentials for
every real check; CI runs `bash -n`, `shellcheck`, and `--help` against it,
and `openspec/init.sh` does the same (`shellcheck` only when installed).
The plan reader filters `.mode == "managed"` so
`data.azurerm_kubernetes_cluster.existing` cannot hijack region detection,
and refuses a plan spanning several regions. Note that `az aks list-vm-skus` does exist (in the `aks-preview`
extension); the script uses the core-CLI `az vm list-skus` so it works
without extensions, not because the AKS command is missing.

### Running `tests/scripts/smoke-test.sh` against a live deployment

The smoke test is intentionally **not** wired into CI. Run it manually from
a machine that has `az login`'d to the target subscription:

```bash
az login
cd examples/small
terraform init && terraform apply               # populated terraform.tfvars
../../tests/scripts/smoke-test.sh               # uses `terraform output` to discover the cluster
```

The script asserts: AKS API responds, n8n namespace exists, main/worker/
webhook-processor pods meet their autoscaler floors, PostgreSQL and Redis
connectivity, Azure Blob access, App Gateway reachable, HTTPS GET on
`n8n_url` returns 200, license is valid. Non-zero exit on any failed
assertion.

### When adding a new input

1. Add it to `variables.tf` with `description`, `type`, sensible `default`
   (if any), and a `validation` block (or a `# no validation: <reason>`
   comment).
2. Surface it on the resource(s) that consume it.
3. If it's a structural change, add an `assert` in `tests/defaults.tftest.hcl`.
4. If it can be misused, add an `expect_failures` case to the
   `invalid_inputs_fail_fast` run.
5. Re-run `terraform-docs .` to refresh the `README.md` reference table.

### When adding a new resource

1. Put it in the existing `.tf` file matching its concern (e.g. anything
   PostgreSQL → `database.tf`). Create a new file only for a genuinely new
   concern.
2. Open the file with the copywrite header (`# Copyright n8n GmbH 2025` /
   `# SPDX-License-Identifier: MIT`) — `.copywrite.hcl` enforces this.
3. Tag it with `tags = merge(local.common_tags, { Name = "..." })` if the
   resource supports tags.
4. Reference it from the relevant output, if it's user-facing.
5. Add a plan-time assertion if the resource encodes a non-obvious default.
6. Run `tflint` and `checkov` locally before pushing — CI will run them
   anyway, but failing fast saves a round trip.

### What *not* to do

- Don't configure providers inside the module. `versions.tf` declares
  `required_providers`; provider configuration is the caller's job (see
  `examples/small/providers.tf`).
- Don't introduce nested `module` calls inside the module root beyond the
  deliberate `modules/controllers` KEDA composition in `controllers.tf`. Keep
  all other concerns flat so registry consumers can read the root top to bottom.
- Don't drop networking into the module root. The caller passes `vnet_id`
  and the five subnet IDs; only the private DNS zones (Postgres, Redis, Blob)
  are module-owned.
- Don't reintroduce a `null_resource` workaround. All five the prototype
  shipped with have been replaced — see "Historical retirements" above for
  what shipped where. If you need to apply CRD-aware Kubernetes manifests,
  use the `gavinbunney/kubectl` provider's `kubectl_manifest` resource
  (already in `versions.tf`); if you need a destroy-time wait, use
  `time_sleep` with `destroy_duration`.
- Don't commit `terraform.tfstate*`, `*.tfplan`, `apply*.log`, or
  `terraform.tfvars`. The `.gitignore` already covers these; check before
  committing if you ran `apply` locally inside an example directory.
- Don't hand-edit the `<!-- BEGIN_TF_DOCS -->` block in `README.md`.
- Don't widen `soft_fail` or silence lint rules without a comment explaining
  why and a follow-up TODO.
- Don't use `hashicorp/kubernetes_manifest` for resources whose CRD is
  installed by the module itself (e.g. KEDA `TriggerAuthentication`) —
  `kubernetes_manifest` validates against the CRD's OpenAPI schema **at
  plan time**, which forces a two-pass apply against a fresh cluster (the
  CRD doesn't exist yet on the first plan). Use
  `gavinbunney/kubectl_manifest` instead — it defers schema resolution to
  apply time, so a single-pass apply works. The KEDA TriggerAuthentication
  in `keda.tf` is the canonical example.
- Don't reintroduce a two-tier `modules/infra` + `modules/workload` split.
  The root is intentionally the single resource-bearing module again after
  `align-azure-with-aws-capabilities` — see the "Historical retirements"
  section above for why the split was reverted.

## References

- [`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) — sibling
  module; this repo's quality bar mirrors its AGENTS.md, layout, and CI
  shape.
- [Terraform module structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Publishing modules to the Terraform Registry](https://developer.hashicorp.com/terraform/registry/modules/publish)
- [Terraform partnerships guidelines](https://developer.hashicorp.com/terraform/docs/partnerships)
- [Announcing the new Partner Premier Tier for the Terraform Registry](https://www.hashicorp.com/en/blog/announcing-the-new-partner-premier-tier-for-the-terraform-registry)
- [`terraform test` framework](https://developer.hashicorp.com/terraform/language/tests)
- [`terraform-docs`](https://terraform-docs.io/)
- [TFLint](https://github.com/terraform-linters/tflint) ·
  [tflint-ruleset-azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm) ·
  [Checkov](https://www.checkov.io/)
- [`Azure/avm-res-network-virtualnetwork/azurerm`](https://registry.terraform.io/modules/Azure/avm-res-network-virtualnetwork/azurerm/latest)
  — AVM module used by the sizing examples to build the five subnets with
  the required delegations / network-policy settings.
