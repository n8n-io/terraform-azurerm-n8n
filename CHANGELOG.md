# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0.0, minor versions are the breaking-change boundary; see
[README.md, Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Added

- Seven opt-in AKS network and identity inputs, all defaulting to the
  module's current behavior so an existing caller sees no plan diff
  ([#28](https://github.com/n8n-io/terraform-azurerm-n8n/issues/28)):
  - `aks_private_cluster_enabled` and `aks_private_dns_zone_id`: private
    API server. The zone is `"System"` (also what `null` sends on a private
    cluster) or a caller-owned zone ID. `"None"` is rejected because Azure
    does not support it while the public FQDN is disabled. A caller-owned
    zone switches the cluster to a module-created user-assigned identity
    granted `Private DNS Zone Contributor` on the zone and
    `Network Contributor` on `vnet_id` before cluster create.
    `aks_private_dns_zone_custom_identity` selects that identity path with a
    plan-known literal when the zone ID is unknown until apply (for example
    a zone created in the same apply). Changing `aks_private_cluster_enabled`
    or `aks_private_dns_zone_id` later forces replacement of the AKS
    cluster, so decide before the first apply.
  - `aks_entra_rbac`: Entra ID integration and Azure RBAC for Kubernetes
    authorization. Once set, `aks_kube_config` is an Entra (kubelogin
    `exec`) kubeconfig with an empty `client_certificate` and `client_key`,
    even while local accounts stay enabled. The README shows the `exec`
    wiring for the `kubernetes`, `helm`, and `kubectl` providers. Entra
    integration cannot be disabled once enabled.
  - `aks_local_account_disabled`: requires `aks_entra_rbac`. On an existing
    cluster it does not revoke admin certificates issued earlier, including
    the one previously stored in state through `aks_kube_config`; rotate
    the cluster certificates (`az aks rotate-certs`) to revoke them.
  - `aks_outbound_type`: `loadBalancer` or `userDefinedRouting` egress. The
    description lists two domains that Microsoft's AKS and Azure Firewall
    FQDN list misses for the default n8n image (found in live testing).
  - `aks_network_policy`: `null`, `azure`, `calico`, or `cilium`, with
    `network_data_plane` set to `cilium` automatically for `cilium`.
    Enabling an engine is one-way: setting it back to `null` keeps the
    existing engine (or forces replacement from `cilium`).

- `aks_system_pool_critical_addons_only`: opt-in bool (default false) that
  applies AzureRM's `only_critical_addons_enabled` to the system
  `default_node_pool`, tainting it `CriticalAddonsOnly=true:NoSchedule`.
  Neither n8n, KEDA, nor the Redis exporter set a nodeSelector or
  toleration, so enabling this moves all of them onto the `n8nuser` pool,
  and the advisory capacity check then counts only that pool.
  Enabling it on an existing cluster cycles the system pool through
  `temporary_name_for_rotation` (`systemtemp`); this is not a
  cordon-and-drain operation. The AKS-managed AGIC add-on carries its own
  `CriticalAddonsOnly` toleration, so `create_ingress = true` remains
  supported. `time_sleep.aks_api_warmup` now also waits for the `n8nuser`
  pool, so Kubernetes and Helm resources are not created before the pool
  they schedule onto exists; see
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#enabling-aks_system_pool_critical_addons_only-moves-module-installed-workloads-to-the-user-pool)
  ([#20](https://github.com/n8n-io/terraform-azurerm-n8n/issues/20)).

- `docs/shared-responsibility.md`: a single table summarizing what the
  module does versus what the caller owns across cluster security add-ons,
  network egress and DNS, secrets and Terraform state custody, TLS
  certificates, backup and restore, upgrades, and monitoring/alerting,
  linked from the README docs index and "Out of scope" section
  ([#32](https://github.com/n8n-io/terraform-azurerm-n8n/issues/32)).

- `aks_sku_tier`: AKS cluster SKU tier (`"Free"`, `"Standard"`, or
  `"Premium"`, default `"Free"`, matching the provider default, so existing
  callers see no plan change). The Free tier has no financially backed SLA
  for the API server. The `medium` and `large` examples now set
  `aks_sku_tier = "Standard"`: an existing deployment of either example
  gets an in-place Free-to-Standard update and a recurring per-cluster
  control-plane charge. Premium is a prerequisite for AKS Long Term
  Support, but this module does not set `support_plan`. Changing the tier
  on an existing cluster can make the AKS API server unavailable for up
  to about a minute, so change it in its own apply; see
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#changing-aks_sku_tier-briefly-interrupts-the-aks-api-server).
  Like the other AKS-only inputs, a non-default value warns when
  `create_aks = false`
  ([#19](https://github.com/n8n-io/terraform-azurerm-n8n/issues/19)).

- `pg_storage_auto_grow_enabled` (bool, default `false`) enables Azure
  PostgreSQL Flexible Server storage autogrow, which doubles disk space
  automatically as usage approaches the limit, which helps keep the server
  from going read-only when full. Azure does not autogrow across the
  4,096 GiB boundary; a server that reaches it needs a manual, offline
  resize. The examples leave it off. Autogrow only grows
  storage, never shrinks it: after it fires, raise `pg_storage_mb` to at
  least the live size before the next apply, or a stale `pg_storage_mb`
  plans to **destroy and recreate the entire server** (data loss), since
  azurerm forces replacement when `storage_mb` decreases.
  `pg_storage_drift_guard_enabled` (bool, default `false`) adds a
  best-effort early warning: while it is `true` (and `create_database` is
  `true`), the module reads the live server's actual `storage_mb` via a data
  source and fails with a precondition error if `pg_storage_mb` has fallen
  behind it. The guard only protects a plan in which that data source is
  read at plan time. When Terraform defers the read to apply (for example
  because of a `depends_on` on the calling `module` block), the plan can
  proceed without resolving the precondition, and Terraform may destroy the
  old server before it evaluates the create-side precondition. It is not a
  deletion control: review plans for a PostgreSQL replace action and hold an
  existing caller-owned `CanNotDelete` management lock on the server, with
  `lifecycle.prevent_destroy` on the lock resource itself (see
  `docs/deletion-safety.md`).
  This check runs independently of the current `pg_storage_auto_grow_enabled`
  value, since Azure never shrinks storage back down: a server that already
  auto-grew stays larger than a stale `pg_storage_mb` even after autogrow is
  later turned off. Leave the guard `false` on the apply that first creates
  the server (the data source has nothing to read yet); enable it on the
  next apply for ongoing drift protection. The guard's lookup fails with a
  not-found error whenever it runs while the server is not at the
  configured name and resource group (rename, move, out-of-band deletion,
  or a partially completed destroy). A plan-time lookup blocks the plan; a
  deferred one fails during apply. Set the guard to `false` for those
  applies.
  Triggers a non-blocking check warning when `create_database = false`,
  alongside the other managed-server sizing inputs
  ([#27](https://github.com/n8n-io/terraform-azurerm-n8n/issues/27)).

- `postgres_managed_ssl_mode` lets the module-managed PostgreSQL Flexible
  Server path use `verify-ca` or `verify-full` instead of the previously
  hardcoded `require`, which encrypts the connection but does not validate
  the server certificate. `verify-ca` and `verify-full` validate the
  certificate chain and the hostname (n8n's driver does not separate the
  two). Default stays `require`.
- `postgres_ssl_ca_pem` accepts a PEM-encoded CA bundle for either the
  managed or external PostgreSQL path, needed for `verify-ca` /
  `verify-full` unless the pod image's trust store already covers the
  server's issuing CA. When the effective mode is `verify-ca` or
  `verify-full`, the module passes the trimmed PEM to the n8n chart's
  `database.ssl.ca` value, which the chart renders into its ConfigMap as
  `DB_POSTGRESDB_SSL_CA` for main, worker, and webhook-processor pods.
  Because the CA is part of the Helm release, changing it rolls the pods,
  and a failed upgrade's rollback restores the previous CA. In any other
  mode the input is ignored and a plan-time warning fires; with `disable`,
  delivering a CA would make n8n turn on verified TLS. See
  [`docs/postgresql-tls.md`](./docs/postgresql-tls.md) for mode
  selection, the CA bundle, what happens when a CA change fails, rollout
  behavior on single-main vs. multi-main, and Azure's CA rotation schedule
  ([#25](https://github.com/n8n-io/terraform-azurerm-n8n/issues/25)).

- `docs/build-time-decisions.md`: inputs and hardcoded values that are
  hard or impossible to change after the first `terraform apply`. One
  table lists changes that force replacement or have no in-place path
  (resource names and location, the AKS service CIDR and subnet size,
  the PostgreSQL subnet, admin username, geo-redundant backup, and
  version or storage decreases, Redis high availability, Blob
  replication across the zonal and non-zonal groups, the Blob container
  name, and the n8n encryption key). A second table lists in-place
  changes that still disrupt workloads (AKS zones, VM size, OS disk
  size, the system-pool taint, and the SKU tier), and notes that the
  PostgreSQL HA zone inputs are ignored after the server exists.
  Provider behavior is cited against the `hashicorp/azurerm` v4.81.0
  source. The page also covers the available protections and how to move
  a layer to a caller-owned resource without losing data. Linked from
  `README.md` and every example README. The `aks_availability_zones` and
  `storage_account_replication_type` descriptions now state what a
  change on an existing deployment does, and the `pg_version`
  description and `docs/versioning.md` no longer say a major version
  upgrade is not in-place
  ([#31](https://github.com/n8n-io/terraform-azurerm-n8n/issues/31)).

- `create_postgres_private_dns_zone`, `create_redis_private_dns_zone`, and
  `create_blob_private_dns_zone` (each `true` by default, so existing callers
  see no plan change), with `postgres_private_dns_zone_id`,
  `redis_private_dns_zone_id`, and `blob_private_dns_zone_id`, let a caller
  attach the module-managed PostgreSQL Flexible Server and the Redis/Blob
  private endpoints to an existing private DNS zone instead of a
  module-created one. This is for landing zones that keep these zones in a
  central connectivity subscription, often under an Azure Policy
  `DeployIfNotExists` assignment. Setting a switch to `false` requires the
  matching zone ID and skips that service's zone and VNet link. Ownership
  follows the switch, never the ID being null, so the ID may come from a
  zone created in the same configuration. A supplied ID that has no effect
  raises a warning, not an error. PostgreSQL accepts any zone name ending in
  `.postgres.database.azure.com` except the server's own FQDN
  (`<friendly_name_prefix>-postgres.postgres.database.azure.com`), which
  Azure rejects; Redis and Blob require their `privatelink`
  zone names. The caller owns the zone's VNet link and needs Private DNS
  Zone Contributor on it. Switching an existing deployment to a
  caller-supplied zone destroys the module's own zone and link, interrupts
  name resolution for a few minutes per service (about 3 to 4 minutes in a
  live test), and fails for a PostgreSQL server with high
  availability enabled; see
  [`docs/customer-managed-infrastructure.md`](docs/customer-managed-infrastructure.md#caller-supplied-private-dns-zones)
  for the requirements and migration steps
  ([#22](https://github.com/n8n-io/terraform-azurerm-n8n/issues/22)).

- `postgres_password_write_only`, `postgres_admin_password_wo`, and
  `postgres_admin_password_wo_version` let the module-managed PostgreSQL
  Flexible Server (`create_database = true`) accept its administrator
  password through azurerm's write-only `administrator_password_wo`
  argument instead of a `random_password` resource whose result Terraform
  stores in plain text in state. `postgres_admin_password_wo` is an
  `ephemeral` module variable, so the value you pass never lands in a plan
  or state file. This mode requires `postgres_password_secret_ref` (the
  module cannot copy a write-only value into the Kubernetes Secret it would
  otherwise manage), makes the `postgres_admin_password` output `null`, and
  is fully opt-in — the default (`postgres_password_write_only = false`)
  behavior is unchanged. `postgres_admin_password_wo` is checked at plan
  time for the Flexible Server length (8 to 128) and character-category
  rules. Azure's rule against a password containing the login name
  (`pg_admin_username`) is not checked at plan time; Azure rejects such a
  password during apply. `postgres_password_secret_ref` must not name the module-managed
  `n8n-db-secret` on this path, because the same apply destroys it. A
  rotation (`postgres_admin_password_wo_version` bump) does not restart
  n8n; restart the Deployments after the apply. See "Secrets that remain
  in Terraform state" in
  [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md)
  for the full contract, the steps to switch an existing deployment over
  (with its current password first, then rotate), rotation, switching
  back, and the Redis access key and other credentials that still remain
  in state on every managed path. To downgrade to an earlier module
  version, first switch back to the generated password, then remove all
  three new inputs from the module call, even when they are set to their
  defaults: earlier versions do not declare them.
  **Upgrade note:** with `postgres_password_write_only` left at `false`, the
  first plan after upgrading shows one in-place update on
  `azurerm_postgresql_flexible_server.n8n` with no visible attribute change.
  It comes from the new write-only argument's sensitivity marking, not from
  a value change: in a live test it applied in 0 seconds with no Azure
  change, and the next plan was empty. Downgrading shows the same update in
  reverse
  ([#26](https://github.com/n8n-io/terraform-azurerm-n8n/issues/26)).

- `aks_system_node_vm_size`, `aks_system_node_count_min`, and
  `aks_system_node_count_max` let the system (default) AKS node pool be
  sized independently of the n8n-facing user (`n8nuser`) pool. Each
  defaults to `null`, falling back to the matching shared `aks_node_vm_size`
  / `aks_node_count_min` / `aks_node_count_max` value, so every existing
  caller's plan is unchanged. The advisory CPU capacity check
  (`autoscaling_maxima_fit_aks_capacity`) models each pool's effective VM
  size and ceiling separately, and still counts only the user pool when
  `aks_system_pool_critical_addons_only = true` taints the system pool.
  A smaller system pool is safest with that taint, since n8n pods
  otherwise also schedule on the system pool. Changing the system pool's
  VM size on an existing cluster rotates it through
  `temporary_name_for_rotation` without a cordon or drain.
  `tests/scripts/preflight-region-check.sh` gains `--system-vm-size` and
  `--system-node-count-max` flags and checks vCPU quota per VM family
  across every planned node pool
  ([#21](https://github.com/n8n-io/terraform-azurerm-n8n/issues/21)).
- New `docs/ingress-options.md` documents why the module uses Application
  Gateway v2 with AGIC instead of Application Gateway for Containers (which
  does not support a private frontend, checked 2026-10-07) or the
  application routing add-on with the Gateway API. It also covers what
  switching an existing deployment to `create_ingress = false` destroys and
  how to cut over with minimal downtime, the gateway and Ingress settings a
  replacement must review, and the routing contract (path-prefix ordering,
  session affinity, `N8N_PROXY_HOPS`) a caller-owned ingress must reproduce
  ([#33](https://github.com/n8n-io/terraform-azurerm-n8n/issues/33)).
- New `n8n_proxy_hops` input (default `1`) renders `N8N_PROXY_HOPS` on every
  n8n pod, previously hardcoded to `1`, so existing deployments see no
  change. Count every proxy on the client's path that adds an
  `X-Forwarded-For` entry, whatever `create_ingress` is set to: an
  Application Gateway alone is `1`, Azure Front Door in front of it is `2`,
  and a layer 4 Azure Load Balancer does not count. `0` is accepted for a
  deployment with no HTTP proxy in front of n8n. A value above `1` is only
  safe when the inner proxy accepts traffic from the outer one alone,
  otherwise a client can forge its IP. Rejects negative or fractional
  values at plan time. The name was already reserved, so `n8n_extra_env`,
  `n8n_worker_extra_env`, and `n8n_worker_pools[*].extra_env` still cannot
  set it ([#33](https://github.com/n8n-io/terraform-azurerm-n8n/issues/33)).
- `n8n_chart_repository` overrides the n8n Helm chart's repository (default
  `oci://ghcr.io/n8n-io/n8n-helm-chart`), and `n8n_task_runner_image_repository`
  overrides the `n8nio/runners` task-runner sidecar's image repository
  (default null, chart default), so a caller with no egress to the public
  registries can point both at a private mirror. `docs/customer-managed-infrastructure.md`
  gained an "External artifacts and private-registry mirrors" section listing
  every chart and image this module pulls and its override input, plus how
  to authenticate the Terraform runner to a private OCI chart mirror.
  `n8n_chart_repository` rejects URLs with embedded `user:password@`
  credentials or no host. Matching `terraform-aws-n8n` and
  `terraform-google-n8n`, any value other than the upstream default counts as
  an unverifiable chart: `check.graceful_shutdown_fits_grace_period` and
  `check.worker_keda_pause_requires_a_supported_chart` are skipped, and the
  advisory capacity model keeps the task-runner sidecar request on main
  pods. `check.image_pull_secrets_need_a_custom_image` now also passes when
  only `n8n_task_runner_image_repository` is set with task runners enabled,
  so a runner-only private mirror no longer falsely flags
  `n8n_image_pull_secrets` as unused. Two new warnings cover the runner
  mirror: `check.task_runner_image_repository_requires_task_runners` (set
  while task runners are off) and
  `check.custom_task_runner_repository_needs_an_explicit_tag` (no explicit
  runner tag, so the sidecar inherits `n8n_image_tag`)
  ([#23](https://github.com/n8n-io/terraform-azurerm-n8n/issues/23)).
- `n8n_image_repository` and `n8n_task_runner_image_repository` now apply
  Docker's 255-character limit to the normalized repository path, as
  `terraform-aws-n8n` does, instead of to the whole reference. A 255-character
  path behind a registry host is now accepted, and a bare Docker Hub name
  whose implicit `library/` prefix pushes it over the limit is now rejected
  at plan time instead of failing with `InvalidImageName` on the pods.
- Optional AKS Key Vault Secrets Provider add-on
  (`aks_key_vault_secrets_provider_enabled`, `aks_key_vault_secrets_provider_secret_rotation_enabled`,
  `aks_key_vault_secrets_provider_secret_rotation_interval`)
  and an optional role assignment granting the add-on's identity `Key
  Vault Secrets User` on a caller-named vault
  (`aks_key_vault_secrets_provider_role_assignment_enabled`,
  `aks_key_vault_secrets_provider_keyvault_id`). Lets a caller sync Key
  Vault objects into the Kubernetes Secrets the `*_secret_ref` inputs
  already read, without adding a static credential to Terraform state.
  `aks_key_vault_secrets_provider_role_assignment_enabled = true` requires
  `aks_key_vault_secrets_provider_enabled = true`, or the role assignment
  fails planning against the add-on's not-yet-rendered identity. The grant
  covers every secret in the vault, so use a vault that holds only the
  secrets you sync. New outputs `aks_key_vault_secrets_provider_identity_client_id`
  and `aks_key_vault_secrets_provider_identity_object_id` expose the
  add-on's identity.
- Optional AKS KMS etcd encryption (legacy AKS KMS experience) with a
  caller-owned Key Vault key (`aks_kms_key_vault_key_id`, which must be a
  versioned key identifier). Key vault network access is always `Public`:
  private vault access needs API Server VNet Integration, which this module
  does not configure. KMS needs one of two plan-known toggles, which switch
  the cluster identity from `SystemAssigned` to the module-managed
  `UserAssigned` `aks_cluster` identity (the same one a caller-owned private
  DNS zone uses) and grant it `Network Contributor` on the AKS subnet:
  `aks_kms_role_assignment_enabled` (with `aks_kms_key_vault_id`) also grants
  `Key Vault Crypto User` on the vault and waits 120 seconds for it to
  propagate, and `aks_kms_cluster_identity_enabled` leaves the Key Vault
  grant to the caller. New outputs `aks_cluster_identity_principal_id` and
  `aks_cluster_identity_client_id` expose that identity. The cluster depends
  on the grant, but Azure RBAC can take longer to take effect, so the
  documented procedure turns KMS on in a second apply. After turning KMS on,
  rotating the key, or turning KMS off, rewrite every existing Secret; turn
  KMS off by clearing only `aks_kms_key_vault_key_id` and keep the toggle,
  the grant, and the key. **Turning KMS on cannot be undone:** setting both
  KMS toggles back to `false`, or rolling back to a module version without
  them, leaves the cluster `Failed` (confirmed in a live test), because AKS
  keeps checking the key permissions of the cluster identity. See
  [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md#turning-kms-on-cannot-be-undone)
  and the matching
  [troubleshooting entry](./docs/troubleshooting.md#terraform-apply-aks-update-fails-with-azurekeyvaultkmsvalidateidentitypermissioncustomererror-after-removing-the-kms-toggles).
- Setting `aks_key_vault_secrets_provider_enabled`,
  `aks_kms_key_vault_key_id`, `aks_kms_role_assignment_enabled`, or
  `aks_kms_cluster_identity_enabled` while `create_aks = false` warns and
  the input is ignored, like other AKS-only inputs. The other add-on inputs
  have no effect without these, so they are ignored silently.
- `examples/medium` now enables the Key Vault Secrets Provider add-on
  (without a vault grant, because its vault holds the TLS certificate) and
  prepares KMS with a key in a dedicated, purge-protected vault. Applying it
  to an existing deployment of the example switches the cluster identity to
  `UserAssigned` in place, adds the identity's role assignments, and creates
  the new vault, whose purge protection Azure cannot turn off again. See
  [`examples/medium/README.md`](./examples/medium/README.md).
- Both add-ons are documented in
  [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md#delivering-secrets-from-azure-key-vault)
  and demonstrated in [`examples/medium/`](./examples/medium/)
  ([#29](https://github.com/n8n-io/terraform-azurerm-n8n/issues/29)).
- A plan-time advisory `check.postgres_pool_size_fits_known_max_connections`
  (`database.tf`) warns when `postgres_pool_size` times the modeled main,
  worker, webhook-processor, and `n8n_worker_pools` replica ceilings would
  exceed the default maximum user connections Microsoft publishes for the
  selected `pg_sku_name`. While `n8n_worker_keda_pause = true`, the worker
  term uses `n8n_worker_keda_paused_replica_count` when that is larger than
  the worker maximum. The table covers Burstable B1ms to B4ms, General
  Purpose D2 to D16, and Memory Optimized E2 to E8, each in the `s_v3`,
  `ds_v4`, `ds_v5`, and `ads_v5` series. The check stays silent for other SKUs and when
  `create_database = false`. It models the SKU default, not the live
  server: Azure computes `max_connections` when the server is provisioned
  and does not update it on a later SKU change, so after resizing, adjust
  the `max_connections` server parameter and restart. A silent check
  therefore does not prove the pools fit; confirm the live budget
  (`SHOW max_connections`, reserved connections, and other clients). This
  is documented in the new [`docs/sandbox.md`](./docs/sandbox.md),
  alongside a cheaper single-main sandbox profile built from existing
  inputs ([#30](https://github.com/n8n-io/terraform-azurerm-n8n/issues/30)).
- `n8n_license_cert_secret_ref` supports offline license activation
  (`N8N_LICENSE_CERT`) for air-gapped or egress-restricted clusters that
  cannot reach n8n's license server. It is mutually exclusive with
  `n8n_license_key` and `n8n_license_key_secret_ref` — exactly one of the
  three must be set. The certificate renders through the shared
  `config.extraEnv` list as a `secretKeyRef`, not through the chart's
  `license.existingSecret` block, which only ever maps to
  `N8N_LICENSE_ACTIVATION_KEY`. `license.enabled` stays `true` on this path
  because the chart also gates `N8N_MULTI_MAIN_SETUP_ENABLED` on
  `license.enabled`, not on which credential backs it. The Secret name must
  be a valid Kubernetes Secret name and the key a valid Secret key; both are
  checked at plan time. The certificate must match n8n's instance ID; pin it
  with `N8N_INSTANCE_ID` through `n8n_extra_env` rather than changing the
  encryption key. `examples/small` passes `n8n_license_cert_secret_ref` and
  `n8n_extra_env` through, and its `n8n_license_key` is now nullable (default
  `null`) so the example can select the certificate path. See ["Offline license
  activation"](./README.md#offline-license-activation)
  ([#24](https://github.com/n8n-io/terraform-azurerm-n8n/issues/24)).

### Changed

- **AKS node pools now follow `aks_kubernetes_version`**
  ([#85](https://github.com/n8n-io/terraform-azurerm-n8n/issues/85)).
  Minor-required (see [`docs/versioning.md`](./docs/versioning.md)). The
  new `aks_node_pools_follow_cluster_version` input (default `true`) sets
  `orchestrator_version` on both node pools (`system` and `n8nuser`) to
  `aks_kubernetes_version`, passed through verbatim. Before, neither pool
  set it, so a version change upgraded only the control plane and the
  nodes stayed on their old version until someone ran
  `az aks nodepool upgrade`. **Upgrade note:** a version change now
  upgrades the control plane first and then each pool in place, in the
  same apply (the provider upgrades the default pool after the control
  plane, and the `n8n_user` pool references the cluster, so Terraform
  upgrades it last). AKS surge-upgrades each pool: it adds
  `aks_node_upgrade_max_surge` nodes (one per pool at the default sizing,
  so keep vCPU quota headroom for one extra node of each pool's VM size),
  then cordons, drains, and replaces every node, so n8n pods restart. With
  `n8n_main_hpa_min_replicas = 1` the editor is briefly unavailable. A
  minor alias such as `1.36` resolves to the latest GA patch at upgrade
  time; a later patch release neither upgrades the nodes nor changes the
  plan. A cluster whose version has not changed plans no change: a pool
  created without `orchestrator_version` already stores the cluster's
  `kubernetes_version`. A cluster whose control plane was upgraded before
  this change, with pools left behind, plans only the two pool upgrades.
  Set `aks_node_pools_follow_cluster_version = false` to keep the
  control-plane-only behavior and upgrade the pools out of band; switching
  to `false` plans no change. With `create_aks = false` the input has no
  effect, and `false` triggers the non-failing
  `check.aks_tuning_requires_module_managed_aks` warning. See
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#changing-aks_kubernetes_version-upgrades-the-control-plane-and-both-node-pools).
- **Breaking: the `hashicorp/helm` provider requirement is now `~> 3.0`**
  (was `~> 2.12`; 3.3.0 is locked) in the root module,
  `modules/controllers`, and every example, so the weekly drift report
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)) is
  current. Minor-required (see [`docs/versioning.md`](./docs/versioning.md)).
  The 3.x provider moved to the Terraform Plugin Framework, which turns
  blocks into attributes. **Upgrade note:** before `terraform init
  -upgrade`, widen any `helm` constraint you declare to `~> 3.0` and change
  your `provider "helm"` configuration from `kubernetes { ... }` to
  `kubernetes = { ... }` (and a nested `exec { ... }` to `exec = { ... }`;
  `registry { ... }` blocks become `registries = [{ ... }]`). Your own
  `helm_release` resources need `set = [{ name = ..., value = ... }]`
  instead of `set { ... }` blocks (likewise `set_list` and
  `set_sensitive`), `postrender = { ... }` instead of a block, and
  `metadata.<field>` instead of `metadata[0].<field>`. The module's own
  `n8n_helm_release_revision` output now reads `metadata.revision`; its
  value does not change. Every example's `providers.tf` uses the new
  syntax, and `examples/split-ingress`, `examples/customer-managed-cluster`,
  and `examples/customer-managed-everything` convert their AGIC `set`
  blocks. No state step is needed: the 3.x provider upgrades each
  `helm_release` from the 2.x schema on the first plan (`UpgradeState
  Triggered` warning). That first plan shows every `helm_release` updated
  in place (never replaced): `metadata` and `id` become
  `(known after apply)`, `postrender`, `set_list`, `set_sensitive`, and
  `set_wo_revision` go to null, `upgrade_install` goes from null to
  `false`, and `set` goes from `[]` to null (or, for a release with `set`
  entries, they are reordered from 2.x's sorted order to configuration
  order). The apply runs one Helm upgrade per release with unchanged
  values, which raises each revision by one and should not roll any pod.
  The following plan is clean. The state upgrade is one-way: the 2.x
  provider cannot read 3.x state, and only restoring a backup taken before
  the first 3.x apply goes back. Back up state first, and decide before
  that apply: callers who must stay on helm provider 2.x should pin this
  module to `~> 0.1.0` before upgrading. Exception for
  callers' own `helm_release` resources (the module and examples set
  neither): helm provider 3.3.0 bug
  [hashicorp/terraform-provider-helm#1695](https://github.com/hashicorp/terraform-provider-helm/issues/1695)
  fails the first plan with "Provider produced invalid plan" for a
  `keyring` argument while `verify` is false (the default), and for
  `description = ""` when the 2.x state holds no description. Remove those
  arguments before the first 3.x plan and leave them out until an upstream
  fix (#1714 or #1739) is released. A non-empty `description`, and a
  `keyring` with `verify = true`, are not affected; keep a keyring that
  chart signature verification needs. See
  [README.md, Moving the helm provider from 2.x to 3.x](./README.md#moving-the-helm-provider-from-2x-to-3x).

- **Breaking: `modules/tls-letsencrypt` requires the `vancluever/acme`
  provider `~> 3.0`** (was `~> 2.16`; latest is `3.2.1`)
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)). A
  calling root that pins acme `2.x` must widen its constraint; with an
  existing 2.x certificate, follow the upgrade note below before widening
  it to `~> 3.0`. The `provider "acme"` block and every module
  input are unchanged. Of the 3.0 breaking changes, only the `key_type`
  rename (`2048` to `RSA2048`) touches this module; it never set
  `disable_complete_propagation` (now `disable_authoritative_propagation`),
  and it uses the `azuredns` DNS-01 provider, not the `azure` one lego v5
  removed. The module now sets `key_type = "RSA2048"`, the provider's own
  default, so the issued key stays RSA 2048 if that default changes again.
  **Upgrade note:** acme `3.1.1` and later cannot migrate an
  `acme_certificate` stored by 2.x. Upgrading straight to them makes the
  next plan replace the certificate (`key_type = "2048" -> "RSA2048"`),
  which revokes it, orders a new one against Let's Encrypt's rate limits,
  and imports a new Key Vault version, which the Application Gateway
  listener follows on the next apply.
  Pin acme `3.1.0` in the calling root (`3.0.0` and `3.0.1` also carry the
  migration; one apply with any one of them is enough), then widen the pin; see
  [`modules/tls-letsencrypt/README.md`](./modules/tls-letsencrypt/README.md#upgrading-from-acme-provider-2x).
  New deployments are not affected.
- **Breaking (minor-required): the `azurerm` provider requirement is now
  `>= 5.5.0, < 6.0.0`** (was `>= 4.39.0, < 5.0.0` in the root and
  `>= 4.75.0, < 5.0.0` in the examples; locks resolve `5.9.0`;
  [#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)). No
  configuration works on both majors, so move the module and the provider
  together. 5.5.0 is the first release with
  `azurerm_storage_account.public_network_access`. The module now addresses
  its private DNS VNet links and the private DNS A record by
  `private_dns_zone_id` (the A record's zone ID is rebuilt the way 4.x
  stored it: the provider's subscription ID when the zone ID's subscription
  matches it ignoring case, and the zone name lowercased; a zone ID that
  names a different subscription now targets that subscription, where 4.x
  always wrote into the provider's subscription, so records 4.x created for
  such a zone ID are replaced), sets AKS
  `node_provisioning_profile { mode = "Manual" }` (required in 5.0), uses
  `public_network_access = "Disabled"` on the storage account, ignores PostgreSQL `storage_type`
  (new in 5.4.0, ForceNew with no state migration: a refreshed plan fills it
  in from Azure, but a `-refresh=false` plan would otherwise plan a
  replacement that destroys the database), and pins
  the WAF policy's `file_upload_enforcement = false`, the value 4.x always
  sent. The examples make the same changes to the resources they own, use
  the subnet `service_endpoint` block, and list
  `resource_providers_to_register` because 5.x registers no resource
  providers by default. `modules/tls-letsencrypt` and
  `modules/tls-self-signed` accept `>= 4.0, < 6.0.0`. **Upgrade steps:**
  back up state (`terraform state pull`), since 4.x cannot read state 5.x
  writes; allow `>= 5.5.0, < 6.0.0` in your root and run `terraform init
  -upgrade`; register the resource providers listed in the examples (or set
  `resource_provider_registrations = "legacy"`) on a fresh subscription;
  fix your own azurerm resources against the provider's 5.0 upgrade guide;
  then run `terraform plan` with a normal refresh. Never use
  `-refresh=false` for this plan: without a refresh, every private DNS link
  (and any private DNS A record) shows as replaced, because the new
  `private_dns_zone_id` is only filled in from Azure on refresh. The
  refreshed plan shows no such replacement. The expected plan is no
  changes, or one in-place AKS update; do not apply anything that replaces
  a resource. See
  [docs/upgrading-azurerm-5.md](./docs/upgrading-azurerm-5.md) for the
  expected plan per resource and a live checklist.

- **Breaking: `n8n_image_tag` now defaults to `null`** (was `"2.35.0"`),
  matching terraform-aws-n8n and terraform-google-n8n
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)). With
  a null tag the module sends no `image.tag` (and no
  `taskRunners.image.tag`), so the chart's own default runs: its
  `appVersion` on upstream charts from `1.12.0` (`2.41.4` at chart
  `1.14.0`, `2.42.4` at `1.15.0`). A later `n8n_chart_version` bump
  therefore also upgrades n8n for unpinned callers. **Upgrade note:** a
  caller that relied on the old default moves from n8n `2.35.0` to the
  chart's appVersion on the next apply. That crosses n8n's forward-only
  database migrations, and `atomic = true` rolls back Kubernetes objects,
  not migrations. To keep the current version, set
  `n8n_image_tag = "2.35.0"` before upgrading the module, then follow
  [docs/upgrading-n8n.md](./docs/upgrading-n8n.md#moving-to-the-chart-default-image-tag).
  A caller that already pins `n8n_image_tag` renders byte-identical values.
  The 2.19 and 2.29 floors and the `WEBHOOK_URL` cutover treat a null tag
  on an upstream numbered chart at `1.12.0` or later as current
  (`local.n8n_chart_default_image_current`, the AWS sibling's predicate
  plus a prerelease exclusion). On any other chart (older, prerelease
  including the worker-pools preview, or a custom `n8n_chart_repository`),
  the new `check.n8n_image_version_is_known` warns, `WEBHOOK_URL` is still
  rendered, and `n8n_worker_pools` fails the plan until the tag is pinned.
  New warning: `check.custom_image_repository_needs_an_explicit_tag`, for
  `n8n_image_repository` with a null tag (ported from terraform-aws-n8n).
  `check.custom_image_tag_needs_a_task_runner_tag` now fires only with an
  explicit tag. `check.task_runner_image_tag_matches_application_version`
  now warns when the runner tag is pinned but the application tag is null.
  New root output `n8n_image_tag` reports the tag sent (null when the
  chart's default runs). `examples/small`, `examples/medium`, and
  `examples/large` gain an `n8n_image_tag` passthrough (default null) so
  production callers can pin the version there.
  `tests/scripts/check-n8n-chart.sh` now asserts the pinned chart's
  `appVersion` is a concrete version at or above `2.39.0` and that the
  default fixture renders `docker.n8n.io/n8nio/n8n:<appVersion>` and
  `n8nio/runners:<appVersion>`.

- **Breaking: `n8n_available_binary_data_modes` removed, replaced by
  `azure_blob_retain_read_access`** (bool, default `false`). The list only
  rendered `N8N_AVAILABLE_BINARY_DATA_MODES`, which n8n 2.x never reads
  (`BinaryDataConfig.availableModes` has no `@Env` binding, and n8n logs the
  variable as safe to remove). n8n registers the Azure backend whenever
  the Azure container is configured, so what the list really controlled
  was whether the module kept the Azure connection and Blob role
  assignment after writes moved to `database`. The new flag controls that
  directly, for binary and execution data alike. The input stays declared
  for one release as a tombstone: any non-null value fails the plan with a
  migration message instead of a bare "Unsupported argument" error.
  Migration: delete `n8n_available_binary_data_modes`. If it contained
  `azure` and both `n8n_binary_data_storage_mode` and
  `n8n_execution_data_storage_mode` are `database`, set
  `azure_blob_retain_read_access = true` in the same change. Deleting the
  list alone removes the Azure connection (and, with the default
  workload-identity authentication, the role assignment), and n8n does
  not fail at startup; reads of the retained Azure objects fail later.
  An Azure write mode already keeps the connection, so no flag is needed
  then. See `docs/data-storage.md`.
- `azurerm_role_assignment.n8n_blob_data_contributor` is now gated on
  Azure being in use (an Azure storage mode, or
  `azure_blob_retain_read_access = true`). A deployment where both modes
  are `database` and `azure_blob_retain_read_access` is `false` no longer
  grants the workload identity Storage Blob Data Contributor; the next
  apply destroys that role assignment.
  `helm_release.n8n` now also depends on that role assignment, so a newly
  granted role exists before n8n pods roll.
- **Default `n8n_chart_version` bumped to `1.14.0`** (was `1.13.0`),
  matching `terraform-aws-n8n` #160. Every n8n pod rolls once, for the
  removed `N8N_AVAILABLE_BINARY_DATA_MODES` env entry. See
  `docs/upgrading-n8n.md`.
  - Chart `appVersion` moves from n8n `2.40.5` to `2.41.4` (n8n-hosting
    #213). Inert here: this module always pins `n8n_image_tag` (default
    stays `2.35.0`).
  - No changes to the replica, KEDA, or task-runner templates;
    `deployment-main.yaml` is unchanged, so `1.14.0` joins
    `local.n8n_chart_has_worker_only_runners`.
  - #185: the chart stops rendering `N8N_AVAILABLE_BINARY_DATA_MODES`. The
    module no longer sets it either, so n8n's deprecation warning on every
    start is gone. `n8n_extra_env`, `n8n_worker_extra_env`, and
    `n8n_worker_pools[*].extra_env` reject it at plan time through the new
    `local.n8n_deprecated_env_names`, and `tests/scripts/check-n8n-chart.sh`
    fails if any rendered manifest carries it. Callers who set it through
    one of those inputs get a plan-time error until they remove the entry.
  - #184 (missing from the upstream release notes): the chart's ConfigMap
    now emits `N8N_WEBHOOK_URL` instead of `WEBHOOK_URL`. No effect here:
    the chart emits it only from `webhook.url` or chart ingress, which this
    module sets neither of, and the module renders `N8N_WEBHOOK_URL` itself
    through `config.extraEnv`.
  - #209: chart values validation now reports every failure in one render.
- **Default `keda_chart_version` bumped to `2.21.0`** (was `2.15.0`) in the
  root module and `modules/controllers`, matching `terraform-aws-n8n` #159
  (`terraform-google-n8n` #37 makes the same bump and is still open).
  Minor-required (see [`docs/versioning.md`](./docs/versioning.md)).
  `2.21.0` is the first patched release for KEDA's critical CVE-2026-77524
  (see Security below). KEDA 2.15 is tested only on
  Kubernetes 1.28 to 1.30, outside the module's `aks_kubernetes_version`
  default at the time (`1.35`); 2.21 is tested on 1.34 to 1.36, which also
  covers the new `1.36` default, but not `1.37`. **Upgrade note:**
  with `install_keda = true` (the default), a caller that does not pin
  `keda_chart_version` gets one in-place change on the next apply,
  `module.controllers.helm_release.keda[0]`, which
  upgrades the KEDA controller and its CRDs in place (the chart renders the
  CRDs from `templates/`; every KEDA CRD still serves and stores only
  `keda.sh/v1alpha1`; the upgrade from 2.15 adds
  `clustercloudeventsources.eventing.keda.sh`, shipped since 2.16).
  KEDA's pods roll once; nothing in the n8n namespace is replaced. Since
  2.20 the CRDs carry schema validation (`minimum`, `minLength`,
  `minItems`, `enum`, `minReplicaCount <= maxReplicaCount`), which the
  module's `TriggerAuthentication` and the n8n chart's worker
  `ScaledObject` satisfy. The breaking changes between 2.16 and 2.21 touch
  scalers and authentication modes the module does not use; the Redis
  scaler still reads `address`, `listName`, `listLength`, and `enableTLS`
  unchanged. In 2.21 a `ScaledObject`'s `Ready` condition no longer
  reflects HPA health, which moved to a new `HPAActive` condition. KEDA is
  cluster-wide, so the upgrade also affects every other `ScaledObject` and
  `ScaledJob` in the cluster, which matters most with `create_aks = false`.
  With `install_keda = false` the module installs no KEDA and ignores
  `keda_chart_version`: nothing changes on apply, and whoever owns that
  KEDA install upgrades it. When the module installs KEDA, compare the pin
  with the Kubernetes version of the cluster it runs on
  (`aks_kubernetes_version` only when `create_aks = true`, otherwise the
  caller-managed cluster's own version). Below 1.34, pin `"2.20.2"`
  (1.33), `"2.19.0"` (1.32), or `"2.18.3"` (1.31) as a temporary hold,
  noting that none of them carries the CVE-2026-77524 fix.
  `modules/controllers` gains a `keda_chart_version` output (the installed
  chart version, or `null` when `install_keda = false`). See
  `docs/upgrading-n8n.md`, "Moving from KEDA chart 2.15.0 to 2.21.0"
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).
- **Default `aks_kubernetes_version` bumped to `1.36`** (was `1.35`)
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).
  Verification-required (see [`docs/versioning.md`](./docs/versioning.md)).
  AKS made `1.36` GA in June 2026 and supports it until
  June 2027 (long-term support to June 2028). The `2.21.0` KEDA default is
  tested on Kubernetes 1.34 to 1.36, the pinned n8n and KEDA charts accept
  it, and Kubernetes 1.36 removes no API version they render. **Upgrade
  note:** a module-managed cluster (`create_aks = true`) that does not pin
  `aks_kubernetes_version` upgrades from `1.35` to `1.36` on the next apply.
  With the new `aks_node_pools_follow_cluster_version` default (`true`, see
  below) the plan shows three in-place updates, `kubernetes_version` and
  `default_node_pool[0].orchestrator_version` on
  `azurerm_kubernetes_cluster.n8n` and `orchestrator_version` on
  `azurerm_kubernetes_cluster_node_pool.n8n_user`, and the apply upgrades
  the control plane, then the system pool, then the user pool: a surge
  upgrade that drains every node and restarts n8n pods. The API server can
  be briefly unavailable during the control plane step, so apply it on its
  own: to take the rest of this release first, pin
  `aks_kubernetes_version = "1.35"`, then remove the pin in a separate
  apply. With `aks_node_pools_follow_cluster_version = false` only the
  control plane moves: observed live on 2026-10-14 (`examples/small`,
  `swedencentral`, `azurerm` 4.81.0; see
  `docs/qualification-runs/2026-10-14-aks-1.36-swedencentral.md`), the plan
  was one in-place change, `kubernetes_version` `1.35` to `1.36`, the apply
  took 177 s, both pools and every node stayed on `1.35.8`, and the next
  plan was clean
  ([#85](https://github.com/n8n-io/terraform-azurerm-n8n/issues/85)). The
  module sets no `automatic_upgrade_channel` (none) and no maintenance
  windows, and leaves `node_os_upgrade_channel` at its `NodeImage` default,
  so the cluster is not opted into routine Kubernetes auto-upgrades. The
  exception is a version that is out of support: from June 1, 2027, AKS
  upgrades a cluster still on an unsupported version after its 60-day
  platform support grace period, regardless of channel and outside
  maintenance windows. A cluster that pins `aks_kubernetes_version` sees no
  change. With `create_aks = false`
  the input has no effect, but an explicit `"1.35"` now triggers the
  non-failing `check.aks_tuning_requires_module_managed_aks` warning;
  remove it. See
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#changing-aks_kubernetes_version-upgrades-the-control-plane-and-both-node-pools).
- **Default `n8n_chart_version` bumped to `1.16.0`** (was `1.15.0`)
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).
  Minor-required: the module sends the same Helm values as on `1.15.0`,
  but every n8n pod rolls once on the upgrade. With
  `n8n_image_tag = null` (the default) the upgrade also moves n8n to the
  chart's new `appVersion`, `2.43.5` (was `2.42.4`), across its database
  migrations; pin `n8n_image_tag` to upgrade n8n separately. See
  `docs/upgrading-n8n.md`, "Moving from chart 1.15.0 to 1.16.0", for the
  post-upgrade checks.
  - #228: the chart renders no main PodDisruptionBudget while main runs one
    replica, so single-main (`n8n_main_hpa_min_replicas = 1`) loses its
    `minAvailable: 0` budget, which already permitted every eviction.
    Multi-main keeps `minAvailable: 1`. `tests/scripts/smoke-test.sh` now
    accepts no PDB or `minAvailable: 0` for single-main (it failed on a
    missing PDB before), tells a missing PDB apart from a failed lookup,
    and still requires `minAvailable: 1` for multi-main;
    `tests/scripts/check-n8n-chart.sh` expects no single-main PDB from
    chart `1.16.0`.
  - #223: the worker task-runner sidecar gains a liveness probe on the
    launcher's `/healthz`, port 5680. The module sets nothing that moves
    that port; `check-n8n-chart.sh` asserts the probe.
  - #229: more than one main now requires `multiMain.enabled` and a
    license at render time. Every configuration the module accepts
    already passes.
  - The task-runner sidecar moved into a shared template with the same
    placement and resources, so `1.16.0` joins
    `local.n8n_chart_has_worker_only_runners`.
  - #243 `editor.url`, #167 `hostAliases`, #240 image digests and PVC
    annotations, #236 per-role security contexts, #183
    `N8N_ENCRYPTION_KEY_FILE`, and `taskRunners.probes` are new and not
    exposed. The module keeps rendering its own `N8N_EDITOR_BASE_URL`.
- **Default `n8n_chart_version` bumped to `1.15.0`** (was `1.14.0`), the
  same pin as `terraform-aws-n8n` #190 and `terraform-google-n8n` #39
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).
  Minor-required: every n8n pod rolls once on the upgrade. See
  `docs/upgrading-n8n.md` for the post-upgrade checks.
  - #175: the chart now renders `database.ssl.enabled` as
    `DB_POSTGRESDB_SSL_ENABLED`, the name n8n reads, instead of
    `DB_POSTGRESDB_SSL`. The module set `DB_POSTGRESDB_SSL_ENABLED` itself
    through `config.extraEnv` to work around the old name, so on `1.15.0`
    every n8n container would have carried it twice. The module now omits
    its own entry when the chart is the upstream repository at a numbered
    `1.15.0` or newer (`local.n8n_chart_renders_postgres_ssl_enabled`),
    and, while TLS is on, keeps it for older charts, prereleases (including
    the worker-pools preview), and a custom `n8n_chart_repository`. The rendered value
    stays `"true"` whenever TLS is on, and
    `tests/scripts/check-n8n-chart.sh` now fails if any n8n container
    carries the name other than exactly once, from the source that gate
    selects. The in-place Helm upgrade from `1.14.0` swaps the module's
    literal for the chart's `configMapKeyRef`: observed once on a live
    `examples/small` upgrade (upstream repository, TLS on, multi-main)
    with no rollback and exactly one entry per container. Run the
    post-upgrade checks in `docs/upgrading-n8n.md` on your own deployment.
  - No `deployment-*.yaml` template changed, so `1.15.0` joins
    `local.n8n_chart_has_worker_only_runners`.
  - #219 `extraObjects` and #222 `database.ssl.existingSecret` are new and
    not exposed. Chart `appVersion` moves to `2.42.4`; inert here, since
    `n8n_image_tag` stays pinned (`2.35.0`).
- **Breaking:** `modules/tls-self-signed` replaces `validity_period_hours`
  with `validity_in_months` (whole number, 1 to 120, default 12), matching
  the Key Vault certificate policy's own unit. The old input was converted
  with `floor(hours / 730)`, so values below 730 planned as
  `validity_in_months = 0` and others were silently rounded down (e.g.
  `1000` to 1 month). To keep the lifetime an existing value produced,
  set `validity_in_months = floor(validity_period_hours / 730)` (the old
  default 8760 is 12; 1000 is 1). A value below 730 hours produced 0
  months, so replace it with at least 1. Changing the value on an
  existing certificate issues a new certificate version with a new
  versioned Secret URI, which the App Gateway listener picks up on the
  following `terraform apply`
  ([#14](https://github.com/n8n-io/terraform-azurerm-n8n/issues/14)).
- **Breaking:** `required_version` is now `>= 1.13` (0.1.0 declared
  `>= 1.9`) and the `azurerm` provider requirement is now
  `>= 4.39.0, < 5.0.0` (was `~> 4.0`) for the root module and every
  example. Three Terraform releases set the new floor:
  - **1.11:** `postgres_password_write_only`'s `ephemeral` variable and
    write-only `administrator_password_wo` argument (see "Added" above)
    need Terraform 1.10's ephemeral values and 1.11's write-only
    arguments. Terraform parses that syntax from this module's HCL
    unconditionally, so the floor applies whether or not you set the
    variable ([#26](https://github.com/n8n-io/terraform-azurerm-n8n/issues/26)).
  - **1.12:** the `var.x == null || var.x.attr` validations in
    `variables.tf` rely on `||` short-circuiting, which Terraform added in
    1.12. On 1.11 and earlier both sides are evaluated, so the plan fails
    with "Attempt to get attribute from null value" as soon as such an
    input is null. `pg_maintenance_window` defaults to `null`, so this hits
    almost every plan of the root module on those versions. 0.1.0 already
    had that validation, so its own `>= 1.9` was too low.
  - **1.13:** on Terraform 1.12.x and older, `terraform test` keeps about
    one provider plugin process alive per run block until the command
    exits, so memory grows with every run of the root suite (594 runs
    today; the same leak got `terraform-aws-n8n`'s suite OOM-killed on a
    16 GB runner). The leak is specific to `terraform test`, not to `plan`
    or `apply`, but the floor makes `init` reject 1.12 as well. 1.13.0 does
    not leak in those measurements; the upstream 1.13.0 changelog does not
    list the fix
    ([#63](https://github.com/n8n-io/terraform-azurerm-n8n/issues/63)).

  The `azurerm` floor is 4.39.0 because `administrator_password_wo`
  shipped in 4.21.0, but earlier releases sent an empty administrator
  password when `pg_admin_username` changed with write-only enabled
  ([hashicorp/terraform-provider-azurerm#29475](https://github.com/hashicorp/terraform-provider-azurerm/issues/29475)).
  `modules/controllers` and the two TLS helper modules keep their existing
  constraints. CI runs every `terraform test` suite on Terraform `1.13.0`
  as well as on `TF_VERSION`, so the floor stays tested. Module inputs do
  not change: upgrade the Terraform CLI to 1.13 or newer locally and in
  automation, adjust any caller `required_version` or runtime pin that
  excludes 1.13 (for example `~> 1.12.0`), and let the `azurerm` provider
  resolve within the new range before applying.

- **Breaking:** `appgw_frontend_mode = "internal"` now requires the new
  `appgw_private_ip_address` and creates a static private frontend. The module
  used to request a dynamic address, which Application Gateway v2 rejects
  (`ApplicationGatewayFrontendIpPrivateIpAddressInvalidAllocationType`, seen
  live), so the internal mode had never been qualified. A private-only gateway
  also needs the `Microsoft.Network/EnableApplicationGatewayNetworkIsolation`
  feature, a subnet delegated to `Microsoft.Network/applicationGateways`, and
  private access to the certificate's Key Vault (a `Microsoft.KeyVault` service
  endpoint on that subnet, or a private endpoint for the vault with its
  `privatelink.vaultcore.azure.net` zone linked to the VNet); without either
  Azure fails the create with a bare `InternalServerError`. The address is
  required only while `create_ingress = true`: with caller-owned ingress the
  frontend settings are inert, so internal mode without an address plans with
  only the existing inert-tuning warning. Verified live: the
  gateway created at the static address with no public IP, served HTTPS from
  inside the VNet, and carried the `X-Forwarded-For` rewrite. Callers who
  never used the internal mode are unaffected. To upgrade an internal-mode
  configuration, set `appgw_private_ip_address` to a free address inside
  `appgw_subnet_id` (not one of the five Azure reserves) and add the subnet
  delegation and Key Vault access above before applying
  ([docs/troubleshooting.md](./docs/troubleshooting.md)).
- `aks_node_count_min`'s description now states that it sizes both the
  system and user AKS node pools (matching `aks_node_count_max`'s
  description), not just "the AKS default node pool"
  ([#21](https://github.com/n8n-io/terraform-azurerm-n8n/issues/21)).
- `.github/workflows/version-drift.yml` (contributor tooling) keeps one
  tracking issue, identified by the `version-drift` label plus its exact
  title, so another issue carrying the label is never edited. It comments
  only when the set of `DRIFT:` or `ERROR:` lines changes (it used to edit
  the body silently every week), closes the issue when a report is clean,
  and reopens it when the findings change while it is closed instead of
  opening a duplicate. Closing the issue by hand while the findings stay the
  same is respected: later reports only refresh the body. An incomplete
  report writes nothing to GitHub (body, state, and labels stay as they
  were) and fails the run. The decision lives in
  `tests/scripts/drift-issue-sync.sh`, whose offline self-test runs in CI,
  and `tests/scripts/test-version-drift-workflow.sh` covers the lookups
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).

- **Checkov is now a hard gate, matching `terraform-aws-n8n`.** The `checkov`
  CI job no longer uses `continue-on-error`, and `tests/scripts/check-checkov.sh`
  fails on any finding. The 167 findings that were previously reported but not
  gating are each annotated at their resource with
  `checkov:skip=<ID>:<reason>`; real gaps are prefixed `Known gap:`.
  `check-checkov.sh` also unsets every exported `TF_VAR_*`: on checkov 3.3.20
  any one of them makes checkov ignore `--var-file`, so pass 2 never
  evaluated the opt-in resources and its coverage check failed with a
  misleading message (found in terraform-aws-n8n#199). `CKV_AZURE_115` on the
  module's own AKS, which only appears when the root module is scanned
  directly, is annotated as well. No module behavior or default changed.

### Fixed

- The two AGIC `Reader` role assignments no longer take their scope from
  `data.azurerm_resource_group.n8n`. A caller's module-level `depends_on`
  with any pending change deferred that read to apply time, the scope
  became unknown at plan time, and because `scope` forces replacement both
  assignments were planned for destroy and recreate with the resource group
  unchanged, opening a short permission gap for AGIC. The scope is now the
  `/subscriptions/<sub>/resourceGroups/<rg>` prefix of the AGIC identity's
  resource ID, which is known from state. The data source is removed. On
  azurerm 4.54.0 and later, both the removed lookup and the identity build
  that ID from `resource_group_name` as written, so the scope string does
  not change. Older azurerm releases returned the lookup's ID in the casing
  Azure stores, so if `resource_group_name` differs from it only in letter
  case, the first plan after upgrading on such a release can replace the
  two assignments, leaving AGIC without `Reader` on the resource group
  until the new assignments exist. Review the upgrade plan for those two
  replacements. Do not change the casing of `resource_group_name` to avoid
  them: that input forces replacement of every module resource that uses it
  ([#59](https://github.com/n8n-io/terraform-azurerm-n8n/issues/59)).
- The advisory capacity check `autoscaling_maxima_fit_aks_capacity` now
  sizes the worker term from `n8n_worker_keda_paused_replica_count` while
  `n8n_worker_keda_pause` holds workers above `n8n_worker_keda_max_replicas`,
  the same figure the PostgreSQL connection-budget check already used
  ([#64](https://github.com/n8n-io/terraform-azurerm-n8n/issues/64)). The
  advice in both checks now names `n8n_worker_keda_paused_replica_count`,
  and only when the paused count is what raises the worker term
  ([#65](https://github.com/n8n-io/terraform-azurerm-n8n/issues/65)).
- `postgres_ssl_ca_pem` now rejects values over 131050 bytes in UTF-8 after
  trimming (CRLF line endings count two bytes per line break). The chart
  passes it to every n8n container as the single environment variable
  `DB_POSTGRESDB_SSL_CA`, and Linux refuses to start a process whose
  environment string exceeds 131072 bytes, so in `verify-ca` and
  `verify-full` an oversized bundle used to pass the plan and then fail
  every pod with `argument list too long`. The limit applies in every
  `ssl_mode`: in `disable`, `allow`, `prefer`, and `require` the module
  ignores the CA, so an oversized bundle there used to plan and run with
  only a warning, and now fails the plan. Remove it or trim it to the roots
  you need
  ([#62](https://github.com/n8n-io/terraform-azurerm-n8n/issues/62)).
- `examples/split-ingress` now works on current Azure. Each gateway has its own
  delegated subnet and NSG (a shared subnet could only carry one, so the
  VNet-only admin rule and the internet-facing webhook rule applied to both
  gateways), the admin gateway has a static private address, and both subnets
  have the Key Vault service endpoint. The AGIC federated identity subjects
  now match the chart's `<release>-sa-ingress-azure` service accounts, both
  AGIC releases leave the cluster-scoped IngressClass alone, each AGIC
  identity has `Managed Identity Operator` on its gateway's TLS identity, and
  both Ingresses terminate TLS (the admin Ingress also sets `use-private-ip`).
  It requires the `EnableApplicationGatewayNetworkIsolation` feature (see its
  README). The example is a reference, not a state-compatible upgrade path:
  an existing deployment of it replaces its gateway subnet, NSG and NSG
  association (`appgw` becomes `appgw_webhook` plus `appgw_admin`) and moves
  both Application Gateways to the new subnets, so plan the change as a
  redeploy.
- **Breaking (examples only):** every example's `azurerm` provider block sets
  `persist_id_on_create_before_polling_for_completion = true`, and the examples
  now require azurerm `>= 4.75.0` (was `>= 4.39.0`), so an existing example
  configuration pinned below 4.75.0 must upgrade its provider. A gateway whose
  create fails on Azure's side used to be orphaned outside Terraform state,
  where it blocked the next create, the subnet delete, and the resource-group
  delete. It is now kept as tainted and replaced or destroyed by the next run.
  The root module configures no provider and keeps its `>= 4.39.0` floor;
  callers can set the flag in their own `features` block (see the README).
- Application Gateways in the module and the examples set
  `timeouts { delete = "20m" }` as a precaution. The azurerm default is 90
  minutes per operation, and in one live run `terraform destroy` kept polling
  a gateway for over an hour after Azure had marked the delete failed. That
  hang was not reproduced and its cause is not established, so the timeout
  only bounds how long such a stall can last. Create and update keep the
  provider default. The value applies to gateways created after the upgrade;
  an existing gateway keeps the provider's 90-minute delete default until its
  next real update, because an apply that changes only `timeouts` is a no-op
  and does not store the new value in state.
- n8n's per-IP rate limiter and request logs no longer see the client's
  source port. Application Gateway v2 writes `X-Forwarded-For` as `IP:port`,
  so with `N8N_PROXY_HOPS=1` Express reported `req.ip` as `ip:port`, n8n's
  `express-rate-limit` logged `ERR_ERL_INVALID_IP_ADDRESS` once per main pod,
  and the per-IP key most likely never grouped one client's requests. The
  module now creates an AGIC `AzureApplicationGatewayRewrite` that sets
  `X-Forwarded-For` to `{var_add_x_forwarded_for_proxy}` and references it
  from the managed Ingress, which keeps entries an upstream proxy such as
  Azure Front Door added so `n8n_proxy_hops = 2` still resolves the right
  client. `examples/customer-managed-cluster`,
  `examples/customer-managed-everything`, and `examples/split-ingress` carry
  the same rewrite on their Helm-installed AGIC; any other caller-owned AGIC
  Ingress (`create_ingress = false`) needs it too, see `docs/ingress-options.md`
  ([#60](https://github.com/n8n-io/terraform-azurerm-n8n/issues/60)). AGIC
  attaches one rewrite rule set per Ingress, so a `rewrite-rule-set` or
  `rewrite-rule-set-custom-resource` entry in `ingress_annotations` replaces
  the module's rewrite (the module drops its own reference when you set
  `rewrite-rule-set`, since AGIC attaches neither when both are present) and
  raises the `ingress_annotations_override_module_controls` warning.
- `examples/customer-managed-cluster`, `examples/customer-managed-everything`,
  and `examples/split-ingress` now match the root module's Ingress defaults
  on their caller-owned AGIC Ingress: `request-timeout = "300"` and 30 s
  connection draining on every Ingress, and `cookie-based-affinity = "true"`
  on every Ingress that serves the editor (not on the split-ingress public
  webhook gateway). Before, they ran with AGIC's defaults of a 30 s request
  timeout, no connection draining, and no affinity, so long webhook, form,
  and MCP requests were cut off, rollouts dropped in-flight requests, and
  multi-main deployments lacked the session persistence n8n requires
  ([#33](https://github.com/n8n-io/terraform-azurerm-n8n/issues/33)).

- PostgreSQL `verify-ca` / `verify-full` on the external path connected
  in plaintext. Charts before `1.15.0` render `database.ssl.enabled` as
  `DB_POSTGRESDB_SSL`, which n8n does not read (fixed upstream by
  [n8n-io/n8n-hosting#175](https://github.com/n8n-io/n8n-hosting/pull/175)
  in chart `1.15.0`, now the default; see the bump entry above).
  `require`, `allow`, and `prefer` were not affected: the chart also sets
  `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false` for them, which makes n8n
  use TLS anyway. On those charts the module now sets
  `DB_POSTGRESDB_SSL_ENABLED` directly whenever the effective mode is not
  `disable`. **Upgrade impact:**
  every deployment not on `disable` gets a Helm values diff and one pod
  rollout. Connection behavior is unchanged for `require`, `allow`, and
  `prefer`. External `verify-ca` / `verify-full` callers move from
  plaintext to TLS with certificate verification: if the server does not
  accept TLS, uses a CA the pod image does not trust (supply it with
  `postgres_ssl_ca_pem`), or presents a certificate that does not match
  `postgres_external_host`, the pods fail to connect and Helm rolls the
  release back. See
  [`docs/postgresql-tls.md`](./docs/postgresql-tls.md#upgrading-an-existing-deployment)
  ([#25](https://github.com/n8n-io/terraform-azurerm-n8n/issues/25)).
- Webhook URLs on n8n images older than `2.30.0`. Those images do not read
  `N8N_WEBHOOK_URL`, which was the only webhook variable the module
  rendered, so they advertised `http://<n8n_domain>:5678/` instead of the
  public HTTPS URL. The module now also renders the legacy `WEBHOOK_URL`,
  with the same value, when `n8n_image_tag` is older than `2.30.0`.
  `2.30.0` and later images get only `N8N_WEBHOOK_URL`, so the default
  `2.35.0` deployment renders no new variable. Same cut-over as
  `terraform-aws-n8n` #160.
- `modules/tls-self-signed` now tags its Key Vault certificate with
  `ManagedBy = terraform`, `Project = n8n`, the caller's `common_tags`,
  and `Name = <friendly_name_prefix>-n8n-tls`, matching the root module.
  Before, `common_tags` was accepted but ignored. Existing certificates
  get an in-place tag update on the next apply; they are not replaced.
  In a legacy access-policy vault, the principal running `terraform
  apply` now also needs the `Update` certificate permission for that
  tag update.
- `modules/tls-letsencrypt` applies the same tags to its imported Key
  Vault certificate: `ManagedBy = terraform`, `Project = n8n`, the
  caller's `common_tags`, and `Name = <friendly_name_prefix>-n8n-tls`.
  Before, `common_tags` was accepted but ignored. Existing certificates
  get an in-place tag update on the next apply; they are not replaced,
  so when tags are the only change the versioned Secret URI stays the
  same. In a legacy access-policy vault, the principal running
  `terraform apply` now also needs the `Update` certificate permission.
  `common_tags` now fails at plan when it would push the certificate
  past Key Vault's limit of 15 tags. The documented access-policy
  permissions are corrected to `Get`, `Import`, and `Update` (plus
  `Delete` and `Purge` for destroy); `Create` was never used
  ([#16](https://github.com/n8n-io/terraform-azurerm-n8n/issues/16)).

- The module-managed Azure Managed Redis instance now sets
  `eviction_policy = "NoEviction"` on `default_database` (new
  `redis_eviction_policy` input, default `"NoEviction"`, validated against
  the azurerm provider's enum). The provider's own default is
  `VolatileLRU`, which can evict keys carrying a TTL under memory
  pressure, including n8n's Bull queue keys, so jobs could disappear
  without an error. `NoEviction` instead rejects writes with an
  out-of-memory error on enqueue; set an alert on used memory to catch it
  (see [`docs/redis.md`](./docs/redis.md#eviction-policy)). **Upgrade
  impact:** existing instances get an in-place update of
  `default_database.eviction_policy` from `VolatileLRU` to `NoEviction` on
  the next apply. For this change alone, the azurerm provider (v4.81.0)
  updates the existing database; it does not replace the instance or
  delete and recreate the database. Review the plan before applying.
  After the
  update, a full Redis rejects writes instead of evicting keys. Set
  `redis_eviction_policy = "VolatileLRU"` to keep the previous behavior.
  `redis_eviction_policy` has no effect when `create_redis = false`;
  configure eviction on your own Redis
  ([#18](https://github.com/n8n-io/terraform-azurerm-n8n/issues/18)).

- `tests/scripts/check-version-drift.sh` (contributor tooling, no module
  change) now evaluates each provider constraint against the latest
  registry release instead of printing both side by side, so a constraint
  that already admits the latest release reports `OK` and only a release
  outside it reports `DRIFT`. It also covers the `modules/controllers` and
  `modules/tls-*` constraints and the KEDA chart, reads AKS support dates
  from endoflife.date instead of scraping every `1.2x`-`1.4x` string from
  Microsoft's HTML page, prints `DRIFT:`/`OK:`/`ERROR:`/`INFO:` lines with a
  summary, and exits 2 when a lookup fails instead of printing
  `unavailable` and exiting 0. It no longer needs python3. The new offline
  `tests/scripts/test-version-drift-constraints.sh` runs in CI.
  `.github/workflows/version-drift.yml` records that exit code instead of
  failing its report step on it, still syncs the report (with its `ERROR:`
  lines) to the tracking issue, and fails the run afterwards. A report cut
  short before its summary line is not synced; the new
  offline `tests/scripts/test-version-drift-workflow.sh` runs the workflow's
  own steps to check this
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).

### Security

- The new `keda_chart_version` default, `2.21.0` (see Changed above), is the
  first patched release for KEDA's critical CVE-2026-77524
  ([GHSA-637c-6jxx-4rwm](https://github.com/advisories/GHSA-637c-6jxx-4rwm)):
  a namespace admin could escalate to cluster admin through a
  `TriggerAuthentication`. Every earlier KEDA release, including the old
  `2.15.0` default, is affected. Callers who pin an older
  `keda_chart_version`, or who manage KEDA themselves with
  `install_keda = false`, must move to `2.21.0` or later to get the fix
  ([#57](https://github.com/n8n-io/terraform-azurerm-n8n/issues/57)).

## [0.1.0] - 2026-09-29

Initial release of `terraform-azurerm-n8n`: a single resource-bearing
root module that deploys a production-grade, multi-main [n8n](https://n8n.io)
Enterprise installation on Microsoft Azure. The module's shape mirrors its
[`terraform-aws-n8n`](https://github.com/n8n-io/terraform-aws-n8n) sibling —
one root, `versions.tf`/`variables.tf`/`locals.tf`/`outputs.tf` plus one file
per concern, and one deliberate nested call to `modules/controllers` (KEDA).

Ports the applicable parts of `terraform-aws-n8n` 0.4.0 onto this module's
existing Azure foundation (see `openspec/changes/archive/2026-09-14-port-aws-040-enhancements/`
for the full per-item applicability assessment and source evidence). Ported
as Azure adaptations, not copied AWS semantics: `db_apply_immediately` and
other AWS maintenance-window controls are excluded (Flexible Server and
Managed Redis have no equivalent argument); AWS sizing values, load-test
measurements, and TPS/pool-sizing rules of thumb are excluded (Azure keeps
its own example sizing and pool-size guidance); the legacy AWS Redis TLS
input name is not introduced (Azure already uses `redis_external_tls_enabled`
against Managed Redis's always-on TLS). Every tuning input below defaults
to the n8n or chart behavior it overrides, so none of it changes a
deployment unless set.

Also ports the applicable parts of `terraform-aws-n8n` 0.5.0 onto this
module (see `openspec/changes/port-aws-050-enhancements/` for the full
applicability assessment and source evidence), including its alpha
`n8n_worker_pools` feature (see the **Early Alpha** entry below). Excluded:
the `metrics_server_chart_version` bump (this module installs no
metrics-server; AKS ships one as a managed addon), the RDS
`db_engine_version` bump (PostgreSQL Flexible Server version currency is
tracked separately), and `docs/istio-ingress.md` (`examples/split-ingress`
already documents the `create_ingress = false` contract).

**Note for pre-release test deployments.** No earlier version of this
module was ever tagged. The `Fixed`, `Changed`, and `Security` sections
below describe differences from earlier untagged commits, for stacks (for
example qualification runs) created from one of those commits. A new
installation of `0.1.0` can skip them. See
[`docs/upgrading-n8n.md`](./docs/upgrading-n8n.md) for the chart upgrade
and
[`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md#upgrading-a-pre-release-deployment)
for the resource-address changes from the modularity refactor.

**Live qualification.** The offline test matrix (mocked `terraform test`,
chart rendering, static analysis) does not prove live Azure behavior. Three
disposable live runs back this release, each on one region and SKU set and
none a release guarantee:
[`2026-09-16`](./docs/qualification-runs/2026-09-16-pr4-pr4cm-germanywestcentral.md)
(`examples/small` and `examples/customer-managed-everything`, chart `1.10.0`),
[`2026-09-22`](./docs/qualification-runs/2026-09-22-pr6-swedencentral.md)
(`examples/worker-pools` on the preview chart), and
[`2026-09-23`](./docs/qualification-runs/2026-09-23-chart-1.13.0-swedencentral.md)
(the chart `1.11.0` to `1.13.0` upgrade on `examples/small`). No run covered
this exact release commit end to end. Run
[`docs/manual-azure-qualification.md`](./docs/manual-azure-qualification.md)
in your own subscription before relying on the one-apply lifecycle.

### Fixed

- **Editor test-mode routing through the managed Ingress.** AGIC renders
  `pathType: Prefix` rules as Application Gateway string-prefix patterns, so
  the `/webhook`, `/form`, and `/mcp` rules also captured `/webhook-test`,
  `/form-test`, and `/mcp-test` and sent test webhooks, Form Trigger test
  mode, and MCP test mode to webhook-processor pods, which answered 404. The
  root Ingress now declares the three test-mode prefixes first, targeting the
  main Service, and exposes them as the new `n8n_test_webhook_path_prefixes`
  output. The caller-owned ingress examples (`split-ingress`,
  `customer-managed-cluster`, `customer-managed-everything`) apply the same
  ordering.
- **TLS certificate rotation via `app_gateway_tls_cert_secret_id` was a
  no-op on an existing gateway.** `azurerm_application_gateway.n8n` listed
  `ssl_certificate` in `lifecycle.ignore_changes`, so a new versioned Key
  Vault secret URI never reached the listener and the gateway kept serving
  the old pinned version. The block is no longer ignored (AGIC references the
  gateway certificate by name and never rewrites it), and
  `docs/tls-rotation.md` now describes the versioned-URI behavior and the
  Key Vault `Self` issuer the self-signed helper actually uses. The
  caller-owned gateways in `examples/split-ingress`,
  `examples/customer-managed-cluster`, and
  `examples/customer-managed-everything` carried the same ignore and were
  corrected too. Callers who rotated out-of-band with
  `az network application-gateway ssl-cert update` should expect one plan
  that repoints the listener at the Terraform-declared URI.
- **`n8n_image_pull_secrets` entries are now also capped at 63 characters
  per dot-separated label**, on top of the existing 253-character total.
  This module-side limit is stricter than the Kubernetes API's own
  Secret-name check, which caps only the total length.
  `examples/split-ingress`'s `webhook_subdomain`, a DNS host label, gets
  the same 63-character bound folded into its existing single-label
  validation, matching the DNS label limit.
- **`pg_backup_retention_days` failed on an explicit `null`** instead of
  falling back to its default of 7 (missing `nullable = false`).
- **checkov never evaluated the disabled-by-default Redis exporter.**
  checkov answers every check on a `count = 0` resource with UNKNOWN and
  drops it from the report, and `redis_exporter_enabled` is `false` in
  every default and example, so `kubernetes_deployment_v1.redis_exporter`
  and its Service drew zero findings under any prior CI run.
  `tests/scripts/check-checkov.sh` now runs a second pass with
  `tests/checkov/opt-in.tfvars` and fails if that pass does not reach both
  resources, closing the same class of gap `terraform-aws-n8n` found and
  fixed in its own 0.5.0. `AGENTS.md`'s prior diagnosis (that checkov
  ignores `_v1`/`_v2` Kubernetes resource types) was incorrect and is
  corrected.

### Added

- **Azure Kubernetes Service (AKS)** with the OIDC issuer and workload
  identity enabled, availability-zone-spread node pools, optional API-server
  authorized IP ranges, a configurable node-image upgrade `max_surge`, and an
  autoscaler-owned node count.
- **Multiple n8n main pods** plus dedicated **worker** and
  **webhook-processor** pods (queue mode) — the Enterprise multi-main
  topology — each independently autoscaled (main/webhook HPA, worker KEDA
  `ScaledObject`).
- **PostgreSQL — Flexible Server**, on a delegated subnet with the
  `uuid-ossp` extension allow-listed via `azure.extensions`, or an external
  PostgreSQL endpoint (`create_database = false`).
- **Azure Managed Redis** behind a private endpoint (`NoCluster`, encrypted
  protocol, access-key auth) for the Bull queue backing workers, or an
  external Redis endpoint (`create_redis = false`).
- **Private Azure Blob Storage** for binary and execution data, authenticated
  via AKS workload identity by default, with `database`/`azure` binary-data
  modes and `database`/`azure` execution-data modes.
- **Application Gateway (WAF_v2 by default)** with **AGIC** and **KEDA** for
  ingress, queue-driven worker scaling, and HPA-driven main/webhook-processor
  scaling — or `create_ingress = false` for a caller-owned ingress topology.
- **Azure Key Vault**-backed TLS for the App Gateway listener via a single
  BYO-secret contract (`var.app_gateway_tls_cert_secret_id`), paired with
  `var.app_gateway_keyvault_id` for the optional role assignment.
- **Optional public or private Azure DNS** A-records for the canonical domain
  and every additional domain.
- The full n8n runtime, execution, lifecycle, task-runner, logging,
  template, personalization, community-package, and floating-license
  control surface, plus custom image/pull-secret/extra-volume/extra-env
  support and OpenTelemetry/log-streaming observability.
- A main HPA, a webhook HPA, and worker KEDA floors/ceilings tied to Helm
  replica counts, plus an advisory AKS capacity diagnostic.
- **Customer-managed infrastructure.** Non-nullable ownership switches
  `create_aks`, `create_blob_storage`, `create_namespace`, `install_keda`,
  and `n8n_webhook_hpa_enabled`, each defaulting to module-managed. For
  AKS, Blob, and KEDA, turning the switch off also requires the documented
  `existing_*` references and `existing_*_prerequisites_confirmed`
  attestation (KEDA needs only the attestation). Caller-managed
  Kubernetes Secret references (`n8n_license_key_secret_ref`,
  `n8n_encryption_key_secret_ref`, `postgres_password_secret_ref`,
  `redis_password_secret_ref`) are mutually exclusive with their literal
  counterparts, and the module never reads their values. See
  [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md).
- `modules/controllers/`: the KEDA namespace and Helm release as a directly
  composable submodule, called by the root behind `install_keda`.
- `examples/small`, `examples/medium`, `examples/large`,
  `examples/split-ingress`, and the four caller-owned-layer examples
  `examples/customer-managed-cluster`, `examples/customer-managed-redis`,
  `examples/customer-managed-storage`, and
  `examples/customer-managed-everything`.
- `modules/tls-letsencrypt/` and `modules/tls-self-signed/` TLS helper
  submodules.
- `docs/redis.md`, `docs/data-storage.md`, `docs/observability.md`,
  `docs/azure-key-vault-external-secrets.md`, `docs/post-deployment.md`,
  `docs/troubleshooting.md`, `docs/destroy-cleanup.md`,
  `docs/tls-rotation.md`, `docs/customer-managed-infrastructure.md`,
  `docs/topology-maintenance.md`, and `docs/upgrading-n8n.md`.
- **`tests/scripts/preflight-region-check.sh`**: a pre-`apply` check for the
  three region/subscription gaps that otherwise surface 10-20 minutes into a
  live apply: AKS `AvailabilityZoneNotSupported` (VM SKU not offered or
  zone-less in the region), PostgreSQL Flexible Server `ParameterOutOfRange
  'Version' ... in: []` (no versions offered), and Azure Managed Redis
  `InsufficientCapacity`. With no flags it plans the caller's own root
  (`-refresh=false`) and reads the region, VM size, zones, PostgreSQL
  version/SKU, and Redis SKU the plan would request; every value can be
  overridden, and `--probe-redis` creates and deletes a throwaway Managed
  Redis cluster because Azure exposes no capacity API. `docs/troubleshooting.md`
  gained entries for the PostgreSQL and Redis failures, the zone entry now
  covers the zone-less (`''`) variant, and its `az aks list-vm-skus` reference
  (which needs the `aks-preview` CLI extension) is replaced with the core-CLI
  `az vm list-skus`. `tests/scripts/README.md` documents the script; CI runs
  `bash -n`, `shellcheck`, and `--help` against it, and `openspec/init.sh`
  does the same (`shellcheck` when available).
- **`tests/scripts/preflight-region-check.sh` now checks subscription vCPU
  quota headroom**, a fourth region/subscription gap that surfaces the same
  way as the three above: `helm_release.n8n` times out after
  `n8n_helm_timeout` (default 600s) and rolls back because the AKS
  autoscaler is stuck in `Backoff` on `OperationNotAllowed`, unable to add a
  node either pool needs. Reads `az vm list-usage` for both the VM family
  (e.g. `standardDSv5Family`) and the aggregate `cores` cap against
  worst-case demand: the planned `max_count` of every node pool of that VM
  size, summed (`2 x aks_node_count_max` with the module's system and user
  pools, which each scale `aks_node_count_min..aks_node_count_max`). New
  `--node-count-max` flag (per-pool ceiling, integer from 1 to 1000, root
  default 6). A shortfall fails the run when every AKS cluster and node pool
  change in the plan is a pure create, and is a warning (`RESULT: PASS with
  warnings`) otherwise, since `currentValue` may already count those nodes.
  An invalid `--node-count-max` or planned `max_count` is a usage error
  (exit 2). A new
  `PREFLIGHT_SELF_TEST=1` mode exercises the validation and quota logic
  against synthetic fixtures and runs in CI and `openspec/init.sh`.
  `docs/troubleshooting.md` gained a fourth entry; the intro line on both it
  and `README.md` now says "four" instead of "three".
- **Optional single-main queue mode** (`n8n_main_hpa_min_replicas = 1`): a
  Business-compatible topology for licenses without
  `feat:multipleMainInstances`. Clamps the main HPA to 1/1 regardless of
  `n8n_main_hpa_max_replicas`, switches the rollout strategy to `Recreate`
  (the chart's one shared `strategy` value, so worker and webhook-processor
  Deployments roll with `Recreate` too), and
  relaxes the main `PodDisruptionBudget` to `minAvailable = 0`. Multi-main
  (`n8n_main_hpa_min_replicas > 1`) remains the default. See ["Main topology:
  multi-main and single-main"](./README.md#main-topology-multi-main-and-single-main).
  `tests/scripts/smoke-test.sh` now detects the deployed topology from the
  rendered chart resources (not the observed pod count) and branches its
  main-replica, HPA, strategy, PDB, and leader-election checks accordingly.
- PostgreSQL connection and health-check timing: `postgres_connection_timeout_ms`,
  `postgres_ping_timeout_ms`, `postgres_ping_interval_seconds`, and
  `postgres_ping_max_failures_before_recovery`. All four are nullable and
  render through the shared main/worker/webhook application environment;
  unset inputs preserve n8n's existing pinned defaults.
- Bull worker timing: `n8n_queue_worker_lock_duration`,
  `n8n_queue_worker_lock_renew_time`, and `n8n_queue_worker_stalled_interval`,
  merged into the chart's `redis.worker` map. `n8n_queue_worker_lock_renew_time`
  validates against the effective (possibly default) lock duration so a
  configured renewal can never equal or exceed it.
- Execution-save policy inputs `n8n_executions_data_save_on_success`,
  `n8n_executions_data_save_on_error`, `n8n_executions_data_save_on_progress`,
  and `n8n_executions_data_save_manual_executions`, replacing the module's
  previously hardcoded `executions.data` literals with the same default
  values. The four settings are also rendered into the webhook-processor
  containers (`webhookProcessor.extraEnv`): the pinned chart only renders
  `executions.data` on main and worker pods, yet the webhook process decides
  retention when a queued webhook run finishes, so without this the
  configured success/error policy was silently ignored for webhook-triggered
  executions.
- `n8n_node_max_old_space_size_mb`: an opt-in V8 heap ceiling rendered as
  `NODE_OPTIONS=--max-old-space-size=<value>` on every application container
  (main, worker, webhook processor). Rejects a caller-supplied `NODE_OPTIONS`
  in `n8n_extra_env` only while this input is active.
- `n8n_task_runner_custom_config`: references a caller-managed ConfigMap
  mounted read-only at `/etc/n8n-task-runners.json` on the task-runner
  sidecars via `taskRunners.customConfig`. With the default chart `1.13.0`
  only workers carry that sidecar (see the chart bump under `Changed`). The
  module never reads or hashes the ConfigMap's contents; rotate it and
  manually restart the affected deployments.
- `n8n_dns_config`: optional pod `dnsConfig` (nameservers, search domains,
  options) applied identically to main, worker, and webhook-processor pods,
  validated against Kubernetes' supported DNS-config contract. Leaves
  `dnsPolicy` and CoreDNS untouched.
- Optional Redis exporter (`redis_exporter_enabled`, `redis_exporter_image`)
  in the new `observability.tf`: one `Recreate` Deployment plus a `ClusterIP`
  Service on port 9121, reusing the module's effective Redis connection and
  password/ACL references without reading a caller-managed Secret's payload
  or granting it the n8n workload identity. Shares its `bull:jobs:wait` /
  `bull:jobs:active` queue-key list with the existing KEDA worker
  `ScaledObject` triggers so the two can never observe different queue
  names. Independent of `n8n_metrics_enabled`; installs no monitoring
  backend.
- `aks_node_os_disk_size_gb`: optional OS-disk size (GB) for both
  module-managed AKS node pools. AzureRM cycles the affected pool on change
  and does not cordon/drain first — see
  [`docs/troubleshooting.md`](./docs/troubleshooting.md#changing-aks_node_os_disk_size_gb-on-an-existing-cluster-disrupts-workloads).
- `n8n_webhook_url`: an independently overridable webhook base URL, distinct
  from the editor identity (`n8n_domain`). `examples/split-ingress` now
  passes its public webhook host through this input. `N8N_EDITOR_BASE_URL`
  is now also rendered explicitly rather than relying on chart/n8n defaults
  for editor identity. Azure already emitted and reserved `N8N_WEBHOOK_URL`;
  this release does not add the deprecated `WEBHOOK_URL` alias.
- A main-replica-floor passthrough (`n8n_main_hpa_min_replicas`) surfaced in
  all nine examples (`small`, `medium`, `large`, `split-ingress`,
  `worker-pools`, and the four `customer-managed-*` roots), defaulting to each example's existing
  floor (2, except medium's 3 and large's 6).
- `tests/scripts/check-n8n-chart.sh`: an offline Helm chart-rendering
  regression check with no Azure/Kubernetes-credential dependency, wired
  into CI and `openspec/init.sh`.
- [`docs/manual-azure-qualification.md`](./docs/manual-azure-qualification.md):
  a manual, non-blocking checklist for live Azure lifecycle evidence (fresh
  install, topology transitions, node/disk maintenance, Secret/ConfigMap
  rotation, split-host OAuth/webhook behavior, DNS, Redis TLS/ACL access,
  unavailable-API recovery) that the offline test matrix cannot prove.
- `n8n_credentials_overwrite_secret_ref`: mounts one key from a
  caller-managed Kubernetes Secret read-only on main, worker, and webhook
  processor pods and points `CREDENTIALS_OVERWRITE_DATA_FILE` at it. The module
  accepts only the Secret name and key, so the credential overwrite JSON does
  not enter its Helm values or managed resources. The input defaults to `null`,
  preserving existing behavior.

  When set, plan-time validation rejects `CREDENTIALS_OVERWRITE_DATA` and
  `CREDENTIALS_OVERWRITE_DATA_FILE` in `n8n_extra_env`, the managed
  `credentials-overwrite` volume name in `n8n_extra_volumes`, and the managed
  `/etc/n8n/credentials-overwrite` path in `n8n_extra_volume_mounts`. These
  names remain available through the escape hatches while the new input is
  null, preserving existing configurations.

  n8n reads overwrite data at startup. Rotating the caller-managed Secret does
  not roll pods because the module deliberately does not read or hash the
  payload. Restart the `n8n-main`, `n8n-worker`, and
  `n8n-webhook-processor` deployments manually after rotation.
- `n8n_worker_extra_env`: worker-only environment variables (chart
  `queueMode.workerExtraEnv`), reaching the chart's own default worker
  deployment and, since the **Early Alpha** `n8n_worker_pools` entry below,
  every labelled pool as well. Reuses `n8n_extra_env`'s reserved-name guard,
  and `n8n_credentials_overwrite_secret_ref`'s conflict check now also
  covers this input.
- `blob_delete_retention_days`: optional soft-delete retention window
  (1-365 days) for the module-managed Blob storage account
  (`blob_properties.delete_retention_policy` and
  `container_delete_retention_policy`). The nearest Azure analog to AWS's
  `s3_force_destroy`. One-way from Terraform's side: reverting to `null`
  after an apply plans no change (azurerm treats `blob_properties` as
  Optional+Computed); disable soft delete out of band if needed. See
  [`docs/deletion-safety.md`](./docs/deletion-safety.md) for how AWS's
  four RDS deletion-time controls map onto PostgreSQL Flexible Server: a
  caller-owned `CanNotDelete` management lock with `prevent_destroy` is
  the deletion-protection analog, and a dropped server's backup survives
  5 days only.
- `postgres_server_id` and `storage_account_id` outputs (null on the
  respective `create_* = false` path), so a caller can scope an
  `azurerm_management_lock` to the module-managed server or account.
- `tests/scripts/chart-values-diff.sh` and `tests/scripts/lib/tf-defaults.sh`:
  diffs the pinned n8n chart's `values.yaml` against a candidate version
  via `helm show values`, sharing a `read_default` helper with the new
  version-drift script below.
- `tests/scripts/check-version-drift.sh`, wired into a report-only
  `version-drift` CI job (runs with the rest of the workflow on push,
  pull request, and manual dispatch): currency for every Terraform
  provider, the CI toolchain, and the pinned n8n chart against public
  release feeds, and `aks_kubernetes_version` against Azure's published
  AKS supported-versions page (not `endoflife.date`, which has no
  AKS-specific entry). See [`docs/versioning.md`](./docs/versioning.md)
  for the full pin inventory.
- `scripts/check-example-parity.sh`, wired into a new `example-parity` CI
  job: fails when an example declares a variable name absent from
  `examples/small` and from that example's allowlist.
- markdownlint CI job (`.markdownlint.yml`) over `README.md`, `AGENTS.md`,
  `docs/**/*.md`, and every example/submodule README.
- **`n8n_worker_pools` (EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE)**:
  labelled n8n worker pools, one per entry, each rendered by the chart's
  `queueMode.workerGroups` as a worker Deployment carrying
  `N8N_WORKER_POOL_NAME=<name>` plus a KEDA `ScaledObject` watching that
  pool's own `jobs-<name>` queue. Per-pool replica bounds, concurrency,
  resources, and extra env each fall back to the module-wide worker
  setting when null. Declaring any pool also emits
  `N8N_WORKER_POOLS_ENABLED=true` on every pod. Default `[]`, which omits
  `queueMode.workerGroups` from the Helm values entirely rather than
  sending an empty list, so a deployment that declares no pool sees no
  `helm_release` diff at all. Pool names are validated at plan to the
  pattern n8n itself only warns about, capped at 43 characters because the
  ScaledObject name `n8n-worker-<name>` must fit KEDA's 54, and `"default"`
  is refused since `jobs-default` is not the default queue. The node
  capacity check in `scaling.tf` now counts every pool at its ceiling.

  **Upstream dependency, alpha on both sides.** n8n's own worker pools
  feature is alpha, and the chart support for it
  (`queueMode.workerGroups`, n8n-io/n8n-hosting#189) is merged to the
  chart's `preview/worker-pools` branch but not released to a numbered
  chart version, so a chart that predates it accepts the key and silently
  renders nothing. A `lifecycle.precondition` on `helm_release.n8n` fails
  the plan when the pinned `n8n_chart_version` is a numbered release,
  since no numbered release carries the feature yet (a prerelease version
  is taken at the caller's word, which is how a preview build installs;
  the new `n8n_worker_pools_chart_verified` input lets a caller attest a
  numbered release instead, for a private mirror already verified to carry
  the feature), and a validation on `n8n_image_tag` fails the plan when
  pools are declared and the pinned tag is below `2.39.0`, the first n8n
  release that reads the pool variables (the module's own default,
  `2.35.0`, predates it, so declaring a pool also means pinning the image).
  Each pool's KEDA `ScaledObject` authenticates through the same
  `TriggerAuthentication` CR the default worker's scaler references; only
  `enableTLS` goes into scaler metadata. The `feat:workerPools` licence entitlement is
  required as well, and its absence is not silent: a worker started with
  `N8N_WORKER_POOL_NAME` it is not licensed for exits 1, so the pool pods
  crash-loop and the Helm release rolls back, failing the apply. Terraform
  cannot see entitlements at plan. `tests/scripts/verify-worker-pools.sh`
  counts the rendered pools after a live apply, which is the only place
  the silent case (a chart too old to render pools) is visible. A pool
  started at `min_replicas = 0` cannot be assigned to a project until it
  has been raised to 1 once, since n8n only offers a pool for assignment
  while one of its workers is registered; the stored assignment then
  survives a later scale-down. Documented on the input and in the example.

- `examples/worker-pools/` (EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE):
  topology variant of `small` that documents three pools beside the default
  worker deployment, sized so `aks_node_count_max` clears their combined
  ceiling. The pools are not wired into `module "n8n"` by default: a plain
  apply creates none until the `n8n_worker_pools` line in `main.tf` is
  uncommented. `n8n_chart_version` is a required input there, since the module
  default renders no pools, and its README documents the official
  preview-build path and the private-mirror fallback plus an end-to-end
  routing test. Covered by `scripts/check-example-parity.sh`, whose
  allowlist explains the chart inputs it declares beyond `small`'s. Draft
  until the chart and n8n releases both ship.

- `tests/scripts/verify-worker-pools.sh`: post-apply check for
  `n8n_worker_pools`. Reads the pool names and namespace from the
  example's outputs and asserts, per pool, the Deployment and ScaledObject
  exist and are labelled, the ScaledObject is `READY=True`, its triggers
  watch `jobs-<pool>` with the default worker's `enableTLS` flag and
  `TriggerAuthentication` reference (and no credential in trigger
  metadata), pods carry `N8N_WORKER_POOL_NAME`, and the mains carry
  `N8N_WORKER_POOLS_ENABLED`.
- **`n8n_worker_keda_pause` and `n8n_worker_keda_paused_replica_count`**
  (chart `keda.worker.pause` / `pausedReplicaCount`, n8n-hosting #177).
  `pause = true` annotates the worker `ScaledObject` with
  `autoscaling.keda.sh/paused` so workers hold their current count; a
  `paused_replica_count` (0 included) adds `paused-replicas` and holds
  workers at that count instead. Pause freezes scaling, not processing:
  only a count of 0 leaves jobs waiting in Redis. A count set without `pause`
  draws a plan-time warning (`check.worker_keda_paused_replica_count_requires_pause`)
  since the chart ignores it, and either input on an `n8n_chart_version`
  older than `1.13.0` draws another (`check.worker_keda_pause_requires_a_supported_chart`):
  older charts ignore the key, and `1.12.0` overwrites the held count on
  the next Helm upgrade. Pools declared in `n8n_worker_pools` are not
  paused. The chart's matching
  `keda.webhookProcessor.pause` is deliberately not exposed: this module
  scales webhook processors with its own HPA (`scaling.tf`), so no
  webhook `ScaledObject` exists for the annotation to land on.
  `tests/scripts/smoke-test.sh` skips the worker-floor assertion while the
  `ScaledObject` is paused, and, when paused at 0, also skips the checks
  that need a running worker (worker version, worker Redis connectivity,
  workflow execution); the load test is skipped for any pause. The new
  `detect_worker_pause()` helper is covered by the offline self-test.
- **`n8n_graceful_shutdown_timeout`** (chart `redis.worker.timeout`, renders
  `N8N_GRACEFUL_SHUTDOWN_TIMEOUT`). Seconds n8n waits for in-flight
  executions to finish after SIGTERM before it exits on its own. This is
  the only supported way to change the value: the chart renders this
  ConfigMap key on every n8n container, so `n8n_extra_env`,
  `n8n_worker_extra_env`, and worker pool `extra_env` already reject the
  name at plan time. An explicit value plus
  `n8n_prestop_sleep` must stay strictly below
  `n8n_termination_grace_period`, or validation fails, because Kubernetes
  would SIGKILL the pod before n8n finishes shutting down. Left `null`, the
  module sends no override, the chart keeps its own 30s default, and
  existing releases see no Helm values change. In that case the same rule
  applied to the 30s default is only a warning, the new
  `graceful_shutdown_fits_grace_period` check, so configurations that
  planned before still plan. Ported from `terraform-aws-n8n` PR #148,
  without its custom-chart-repository gate (this module hardcodes the
  upstream chart repository).

### Changed

- **`kubernetes` provider requirement bumped to `~> 3.0`** (was `~> 2.0`),
  across all 11 `versions.tf` files that declare it (root,
  `modules/controllers`, and all nine examples). Verified live-plan-shape-safe against `examples/small`
  under mocked providers: only the two known cosmetic "Deprecated
  Resource" warnings on unversioned resource types, no resource
  replacement.
- **`time` provider requirement bumped to `~> 0.14`** (was `~> 0.12`).
  Additive; no plan diff.
- **Default `n8n_chart_version` bumped to `1.13.0`** (was `1.11.0`;
  matches the AWS sibling). Two chart changes reach every pre-release
  deployment on the first `helm upgrade`:
  - **Worker `spec.replicas` is now KEDA-owned** (n8n-hosting #201). The
    chart omits the field once a worker `ScaledObject` renders, which this
    module's configuration always does. Helm's three-way merge removes the
    field it used to manage, so the worker Deployment drops to 1 replica
    until the KEDA-created HPA restores `minReplicas` (measured at about
    5 s on a live `examples/small` upgrade from `1.11.0` with a floor of
    2, during the same rollout that moved worker pods onto the new chart's
    pod template). The reset always targets 1, so any deployment running
    more than 1 worker at upgrade time (a higher floor, or KEDA scaled up
    on load) terminates the surplus pods, and executions still running
    after the worker's shutdown window can be interrupted; see
    `docs/upgrading-n8n.md`. No change at a floor of 1 that has not scaled
    above 1. After that, a Helm upgrade at the
    floor no longer writes a static count back over KEDA's decision.
    Webhook processors are unaffected: the module's own HPA is outside the
    chart's view, so the chart keeps rendering `webhookProcessor.replicaCount`.
  - **Main pods lose the task-runner sidecar** (n8n-hosting #179, shipped
    in chart `1.12.0`). In queue mode n8n offloads manual executions to
    workers and starts no broker on main, so the chart renders the sidecar,
    its env, and the launcher ConfigMap mount on workers only. Main pods
    roll once to drop the container; `n8n_task_runner_*` resources now
    apply to workers alone, and `check.autoscaling_maxima_fit_aks_capacity`
    stops adding the sidecar request to the main ceiling for the verified
    upstream charts `1.12.0` and `1.13.0` (`local.n8n_chart_has_worker_only_runners`,
    the same version-gated shape as `terraform-aws-n8n`; modeled peak
    demand at the defaults falls from 16600m to 15400m). Any other
    `n8n_chart_version`, including the `1.11.0`-based worker-pools preview
    chart, keeps the conservative main-sidecar allowance.
  Inert here: the chart's `image.tag` default moving from floating
  `stable` to its appVersion (this module always sets `n8n_image_tag`),
  and the `keda` block gaining a typed schema (this module's values
  already pass it; `tests/scripts/check-n8n-chart.sh` renders every
  fixture with schema validation on). `queueMode.workerGroups` is still
  unreleased, so `n8n_worker_pools` callers stay on the `1.11.0`-based
  preview chart and do not pick up either change until a new preview
  build is cut. New `docs/upgrading-n8n.md` (the counterpart of the AWS
  and GCP siblings' guide) carries the per-version upgrade notes.
- CI toolchain currency: `TF_VERSION` `1.16.2` (was `1.15.1`),
  `TFLINT_VERSION` `v0.64.0` (was `v0.53.0`), pinned `CHECKOV_VERSION`
  `3.3.17` (was unpinned via `bridgecrewio/checkov-action@v12`'s own
  floating tag), `azure/setup-helm` pinned to `v4.3.0`.
- CI toolchain further bumped: `TF_VERSION` `1.16.2` to `1.16.4` and
  `CHECKOV_VERSION` `3.3.17` to `3.3.20`, porting `terraform-aws-n8n`
  #153 (`terraform-aws-n8n` #152 does not apply: this module's
  `tests/scripts/smoke-test.sh` derives topology from rendered resources
  and has no legacy `DEPLOY_MODE` or standalone SQLite branch to remove;
  single-main queue mode is unaffected).
  The Terraform requirement remains `>= 1.9`. Checkov
  `3.3.20`'s only change is a plan-parser fix for `forget`-action
  resources, so it drew no new findings against this repo (verified
  locally: pass 1 reports the same 182 passed / 174 failed / 40 skipped
  on both `3.3.17` and `3.3.20`). These toolchain updates do not change
  infrastructure defaults.
- Contributor tooling, mirroring `terraform-aws-n8n` #82 and #115:
  `.github/CODEOWNERS`, `CONTRIBUTORS`, an optional `Taskfile.yml` wrapper
  (`task ci`) around the local validation loop, and
  `scripts/check-variable-banners.sh` (`task banners`, local-only) for the
  `# ── Section ──` banner convention in `variables.tf` and `outputs.tf`.
  No module behavior changes.
- `n8n_extra_env` and `n8n_worker_extra_env` now reject
  `N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME`, which
  `n8n_worker_pools` owns. A caller who was setting either through the
  escape hatch fails at plan on upgrade rather than silently: set through
  `n8n_extra_env` the pool name would put every main, worker, and webhook
  pod into one pool, and the flag alone would switch routing on with no
  pool to route to. Declare the pool with `n8n_worker_pools` instead.

### Security

- `redis_exporter_image`'s default is now pinned by digest as well as tag
  (`oliver006/redis_exporter:v1.90.0@sha256:a129504e...`, the multi-arch
  index). The tag alone was mutable, so the default `IfNotPresent` pull
  policy could keep running a superseded image on a node that already had
  it cached; the digest makes the reference immutable. Deployments with
  `redis_exporter_enabled = true` roll the exporter pod once on the next
  apply; nothing changes for the default `false`.

[Unreleased]: https://github.com/n8n-io/terraform-azurerm-n8n/compare/0.1.0...HEAD
[0.1.0]: https://github.com/n8n-io/terraform-azurerm-n8n/releases/tag/0.1.0
