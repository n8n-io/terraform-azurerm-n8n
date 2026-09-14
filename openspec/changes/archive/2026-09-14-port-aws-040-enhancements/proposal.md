## Why

Azure operators lack several runtime controls and maintenance safeguards added in [terraform-aws-n8n 0.4.0](https://github.com/n8n-io/terraform-aws-n8n/releases/tag/0.4.0). Port the applicable changes without copying AWS service semantics or treating AWS load measurements as Azure sizing evidence.

## What changes

- Support optional single-main queue mode for licenses without `feat:multipleMainInstances`, including Business licenses. Keep multi-main as the default. Clamp the single-main HPA to one replica, use `Recreate` for main upgrades, and permit main eviction with documented downtime. Other selected features retain their own license requirements.
- Expose PostgreSQL connection and health-check timing, Bull lock and stall-check timing, execution-data save policies, a shared V8 heap ceiling, caller-managed task-runner launcher configuration, and pod DNS configuration. Keep existing runtime defaults when inputs are unset.
- Add an optional Redis exporter using Azure's effective Redis endpoint, TLS setting, Secret references, and the same queue keys as KEDA. Do not install a monitoring backend.
- Adapt EKS root-disk sizing to an optional AKS OS-disk size input for both module-managed node pools, including rotation prerequisites and disruption warnings. Leave disk sizing unset by default.
- Set the editor base URL explicitly and add the missing webhook URL override for split ingress. Azure already emits `N8N_WEBHOOK_URL`; retain that convention without adding the deprecated `WEBHOOK_URL` alias.
- Expose main replica-floor selection in the eight existing examples while preserving their current defaults. Keep all Azure VM, pod, database, Redis, PgBouncer, storage, and autoscaler sizing defaults unchanged.
- Preserve existing credential-overwrite support and environment collision guards. Do not port AWS-only `apply_immediately` controls, AWS sizing values, or AWS-specific TLS documentation corrections.
- Require offline Terraform/static checks and pinned Helm rendering checks. Document manual Azure validation separately; live deployment is not required to complete implementation.

## Capabilities

### New capabilities

None. Extend the existing capability boundaries.

### Modified capabilities

- `n8n-workload-configuration`: Add runtime tuning, launcher configuration, pod DNS, and optional Redis metrics export.
- `autoscaling-and-capacity`: Add single-main topology safeguards and AKS disk sizing; use effective main capacity and optional exporter demand in the advisory model.
- `ingress-dns-and-tls`: Define separate editor and webhook URL behavior without changing ingress ownership.
- `deployment-examples`: Demonstrate topology selection and correct split-host URLs while retaining Azure sizing defaults.
- `module-verification`: Add chart-rendering acceptance and topology-aware smoke checks; define the offline completion boundary.

## Impact

Implementation will affect root `variables.tf`, `locals.tf`, `n8n.tf`, `aks.tf`, `scaling.tf`, a new root `observability.tf`, relevant tests and scripts, the eight existing examples, operator documentation, generated README references, and CI/local verification entry points. It will not change provider ownership, add a nested module, bump the n8n/chart/provider pins, or create cloud resources by default beyond the existing deployment.

The editor URL fix changes Helm values and can trigger a rollout. Single-main selection changes availability and maintenance behavior; it is not a general at-most-one guarantee. Existing configurations retain their defaults, and credential-overwrite references keep their current behavior. The design records the complete release applicability assessment and source evidence.
