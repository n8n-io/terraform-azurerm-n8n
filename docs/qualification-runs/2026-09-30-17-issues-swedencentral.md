# Qualification run: 17 issues across 15 PRs, Sweden Central, 2026-09-30

Filled-in copy of [`manual-azure-qualification.md`](../manual-azure-qualification.md)
scoped to the live validation of a batch of 17 issues across 15 draft/open
PRs in this round (issues #16 and #18 to #33). 16 of the 17 issues were
qualified; #24 (PR #51) was excluded by the maintainer and stays in draft,
pending an offline licence certificate and procedure to be supplied
separately (see the results table below). It records what was observed
across several disposable deployments. It is not a release guarantee, and
no result below transfers to other regions, SKUs, or n8n versions.

```text
Environment:     disposable subscription, swedencentral. Several
                 examples/small deploy copies across four deployment phases
                 (A: baseline on `main`, then upgraded in place to the
                 combined integration branch; A2: fresh create with the new
                 toggles enabled; B1; B2), each torn down before or shortly
                 after the next began. The in-place-on-upgrade results
                 (#18, #26) were observed during phase A.
Module version:  per-PR fix/issue-* branches, merged progressively into a
                 combined live/combined integration branch across phases.
AKS version:     1.35.7
VM SKU:          Standard_D2s_v5 (node pools and the B2 jumpbox)
Terraform:       1.13.3
Date:            2026-09-30
Operator:        buddy.rikard, with AI coding agents running the phases
```

## How to read this report

This run is organized by issue/PR, not strictly by the numbered cases in
`manual-azure-qualification.md`, since the batch's scope is a set of
independent opt-in inputs rather than a single feature. Where a case number
applies it is noted. **PASS** means the expected outcome in the linked PR's
"Live validation" section was observed; **FAIL** or **INCONCLUSIVE** mean it
was not, with the reason given.

## Results by issue

| Issue | PR | Result |
|---|---|---|
| #16 (Key Vault cert tags) | #35 | PASS |
| #20 (system-pool taint) | #36 | PASS (module's own AGIC-under-taint advisory does not reproduce against the AKS-managed add-on; recommended softening the check text) |
| #19 (AKS SKU tier) | #38 | PASS |
| #27 (PostgreSQL autogrow + drift guard) | #39 | PASS |
| #18 (Redis NoEviction) | #40 | PASS, in place on upgrade |
| #25 (PostgreSQL verify-full TLS) | #41 | PASS, after a real chart-level fix (`DB_POSTGRESDB_SSL_ENABLED`, see upstream n8n-io/n8n-hosting#175) |
| #22 (BYO private DNS zones) | #43 | PASS; caller-owned zones survived destroy |
| #28 (private cluster, Entra RBAC, egress, network policy) | #44 | PASS on Entra RBAC + local-account-disabled, BYO private DNS zone + private cluster, cilium, userDefinedRouting through a firewall. The system-DNS-zone (`"System"`) private-cluster variant was mock-tested only, not run live. |
| #26 (write-only PostgreSQL password + rotation) | #45 | PASS, in place |
| #29 (Key Vault Secrets Provider CSI + KMS) | #49 | PASS, after a role fix (`Key Vault Crypto User` instead of `Key Vault Crypto Service Encryption User`) |
| #24 (offline licence activation) | #51 | Excluded by the maintainer; its live section records a pending dependency (offline licence certificate and procedure to be supplied by the maintainer). Stays draft, not qualified in this round. |
| #21, #23, #30 to #33 | #46, #47, #48, #50 | Not independently live-validated as standalone features; carried through every combined deployment in this round without breaking any of them. |

## Findings carried into this round's PR descriptions

- **#20 / PR #36:** the module's `check.aks_tuning_requires_module_managed_aks`
  warning text describing AGIC as failing to start under
  `CriticalAddonsOnly=true:NoSchedule` does not hold for the current
  AKS-managed AGIC add-on (it carries its own toleration). The two GitHub
  issues the check's corroborating text cites describe the upstream,
  self-hosted `application-gateway-kubernetes-ingress` Helm chart, not this
  module's own code path.
- **#28 / PR #44:** `admin_group_object_ids` alone grants no cluster access
  under Azure RBAC mode (the module's default). A separate Azure role
  assignment (one of the built-in "Azure Kubernetes Service RBAC *" roles)
  scoped to the cluster is caller responsibility, not a module bug.
- **#28 / PR #44 (egress):** Microsoft's published AKS+Firewall FQDN list is
  incomplete for the default n8n image. The image's actual registry mirror
  domain (not `docker.io`) is not covered by any Microsoft or Docker Hub FQDN
  list, and Docker Hub's blob-layer CDN redirect lands on a
  `*.cloudfront.docker.com` domain, not the `*.cloudflare.docker.com` domain
  shown in Microsoft's published example. Documented on `fix/issue-28`
  (commit local to this round, pending push).
- **#29 / PR #49:** the role originally granted for AKS KMS etcd encryption
  (`Key Vault Crypto Service Encryption User`) lacks the `keys/encrypt/action`
  and `keys/decrypt/action` data actions AKS's KMS identity-permission
  validation requires, so it could never pass at any propagation delay, on a
  brand-new cluster with no identity-type switching involved. Fixed to grant
  `Key Vault Crypto User` instead, matching Microsoft's own documented role
  for this scenario.
- **Smoke-test harness gap:** `tests/scripts/smoke-test.sh` never converted
  the kubeconfig from `az aks get-credentials`'s default interactive
  devicecode `kubelogin` mode to azurecli mode, so it hung indefinitely
  non-interactively against any Entra RBAC-enabled cluster. Fixed on
  `fix/issue-28` (local commit, pending push), confirmed as a no-op against a
  plain client-certificate kubeconfig from a non-AAD cluster.

## Terraform `<1.12` `||` short-circuit evaluation note

Several of this round's new `variables.tf` validations follow the repo's
existing `var.x == null || (<expression reading var.x>)` idiom (for example
the new `aks_private_dns_zone_id`, `pg_storage_drift_guard_enabled`-adjacent,
and `*_private_dns_zone_id` validations added in this round, alongside the
many pre-existing validations of the same shape). Terraform versions before
**1.12** do not reliably short-circuit `&&`/`||` in all evaluation paths:
both operands can be evaluated even when the left-hand `== null` check would
otherwise make the right-hand expression unreachable, which can surface as a
spurious evaluation error (for example indexing into a null value) instead of
the intended validation failure message. This round's live sessions all ran
Terraform **1.13.3** (already `>= 1.12`), so this was not encountered live,
but it is not re-verified against an older Terraform binary. Any caller
pinned below Terraform 1.12 should confirm their own version's `||`
short-circuit behavior against these validation blocks before relying on the
error messages they produce; `versions.tf`'s `required_version` floor does
not currently enforce `>= 1.12` on this basis.

## Not qualified in this round

Cases 2 to 15 of `manual-azure-qualification.md` (no-op apply, Helm
update/rollback, multi-main/single-main transitions, node maintenance, OS
disk rotation, secret rotation, split-host OAuth, private DNS resolution,
Redis exporter TLS/ACL, API-unavailable recovery, AKS credential rotation,
AKS replacement, normal destroy) were not systematically re-run in this
round; it was scoped to the issue list above. Normal destroy (case 15) was
exercised informally at the end of every phase (clean teardown, `76
resources destroyed` for deployment B1 with no `az group delete` fallback
needed; B2's teardown was still in flight, App Gateway deleting, when its
session ended but completed afterward with no reported leftovers). See the
2026-09-16 and 2026-09-22 runs in this directory for the generic-case
coverage.

## Teardown

Every deployment phase (A, A2, B1, B2) was torn down via
`terraform destroy` before or shortly after the next phase began. Soft-deleted
Key Vaults left over mid-round were purged once confirmed to carry no purge
protection. Final resource-group listings across phases showed only
`NetworkWatcherRG` remaining once all phases completed.
