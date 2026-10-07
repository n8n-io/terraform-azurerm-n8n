# Qualification run: 17 issues across 15 PRs, Sweden Central, 2026-09-30

Filled-in copy of [`manual-azure-qualification.md`](../manual-azure-qualification.md)
scoped to the live validation of a batch of 17 issues across 15 draft/open
PRs in this round (issues #16 and #18 to #33). 10 issues have targeted
live results. 6 issues (#21, #23, #30 to #33) were only observed in the
combined deployments, not validated live as standalone features. #24
(PR #51) was excluded by the maintainer and stays in draft, pending an
offline licence certificate and procedure to be supplied separately (see
the results table below). It records what was observed
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
Module version:  baseline main at 7ce8ba7 (phase A), then per-PR
                 fix/issue-* branches, merged progressively into a
                 combined live/combined integration branch across phases.
                 The commit SHA deployed in phases A2, B1, and B2 was not
                 recorded.
AKS version:     1.35.7
n8n image tag:   2.35.0 (module default at 7ce8ba7); per-phase overrides
                 not recorded
Chart version:   1.13.0 (module default at 7ce8ba7; the 1.14.0 bump in
                 #52 merged after this run); per-phase overrides not
                 recorded
Providers:       not fully recorded per phase (#35 reports azurerm
                 4.81.0 for its evidence carried over from #17)
Backend:         not recorded
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
was not, with the reason given. Each result records the observation made
during this round against the PR as it stood then. It does not qualify
later revisions of a PR or its merged implementation. Some PR descriptions
were updated after this round (for example #41 with chart 1.14.0 tests,
and #43 with a later retest), and those later results are not part of
this record. Notes such as "merged later in #44" were added after the run
and only identify where a change ended up.

## Results by issue

| Issue | PR | Result |
|---|---|---|
| #16 (Key Vault cert tags) | #35 | PASS |
| #20 (system-pool taint) | #36 | PASS (the module's AGIC-under-taint advisory did not hold for the AKS-managed add-on, so the check was removed in `0ede977`) |
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

- **#20 / PR #36:** the module's `check.aks_critical_addons_only_conflicts_with_managed_ingress`
  warning text describing AGIC as failing to start under
  `CriticalAddonsOnly=true:NoSchedule` does not hold for the current
  AKS-managed AGIC add-on (it carries its own toleration). The check cited
  the AzureRM `kubernetes_cluster` documentation. The two GitHub issues
  found as corroboration during an earlier session describe the upstream,
  self-hosted `application-gateway-kubernetes-ingress` Helm chart, not this
  module's own code path. The check and its test were removed outright
  (commit `0ede977`, merged in #36 as `d90e42c`) rather than reworded,
  since live evidence disproved the advisory's premise entirely.
- **#28 / PR #44:** `admin_group_object_ids` alone grants no cluster access
  under Azure RBAC mode (the default once `aks_entra_rbac` is set;
  `aks_entra_rbac` itself defaults to null). A separate Azure role
  assignment (one of the built-in "Azure Kubernetes Service RBAC *" roles)
  scoped to the cluster is caller responsibility, not a module bug.
- **#28 / PR #44 (egress):** in this run's firewall allow-list, Microsoft's
  published AKS+Firewall FQDN list was not enough to pull the default n8n
  image. The image's actual registry mirror
  domain (not `docker.io`) is not covered by any Microsoft or Docker Hub FQDN
  list, and Docker Hub's blob-layer CDN redirect lands on a
  `*.cloudfront.docker.com` domain, not the `*.cloudflare.docker.com` domain
  shown in Microsoft's published example. Documented on `fix/issue-28`
  (commit local to this round, pending push at the time of the run;
  merged later in #44 as `c4d9f7c`).
- **#29 / PR #49:** the role originally granted for AKS KMS etcd encryption
  (`Key Vault Crypto Service Encryption User`) lacks the `keys/encrypt/action`
  and `keys/decrypt/action` data actions AKS's KMS identity-permission
  validation requires, so it could never pass at any propagation delay, on a
  brand-new cluster with no identity-type switching involved. Fixed to grant
  `Key Vault Crypto User` instead, matching Microsoft's own documented role
  for this scenario.
- **Smoke-test harness gap:** `tests/scripts/smoke-test.sh` never converted
  the kubeconfig from `az aks get-credentials`'s default interactive
  devicecode `kubelogin` mode to azurecli mode. In a non-interactive run
  against the Entra RBAC-enabled cluster in this round, it waited for a
  device-code sign-in that never came and did not finish. Fixed on
  `fix/issue-28` (local commit, pending push at the time of the run;
  merged later in #44 as `c4d9f7c`), confirmed as a no-op against a
  plain client-certificate kubeconfig from a non-AAD cluster.

## Terraform `<1.12` `||` short-circuit evaluation note

Terraform only short-circuits `&&` and `||` from 1.12.0. Before that, it
always evaluates both operands. A `var.x == null || <expression reading
var.x>` guard therefore does not protect the right-hand side on Terraform
1.9 to 1.11. If that side fails on null (attribute access, arithmetic,
`length()`), the plan fails with an evaluation error, even when the caller
leaves the input at its null default.

`variables.tf` mostly uses the null-safe `var.x == null ? true : (...)`
form already (see the comment on `aks_system_node_count_min`). A few
validations still use `||` with a right-hand side that fails on null. One
example is the `n8n_dns_config` validations, where
`var.n8n_dns_config == null || var.n8n_dns_config.nameservers == null`
reads an attribute of a variable that defaults to null. On Terraform below
1.12, this can stop a default configuration from planning, not only change
an error message. Not every `||` guard is affected: a right-hand side
wrapped in `can(...)`, or one that only reads other variables, stays safe.

This round's live sessions all ran Terraform **1.13.3**, so this was not
encountered live and was not reproduced on an older binary. The conclusion
comes from the Terraform 1.12.0 changelog ("Logical binary operators can
now short-circuit"). At the time of the run, `versions.tf` declared
`required_version = ">= 1.9"`. #45, merged after the run, raised it to
`>= 1.11` for write-only arguments. That is still below 1.12, so the
problem remains. CI pins Terraform 1.16.4, so it never tests the declared
floor.

Both sibling modules provide precedents for the ternary form.
`terraform-google-n8n` requires it in its `AGENTS.md` and pins CI to its
1.9.x floor. `terraform-aws-n8n` uses it and declares `>= 1.11`, but its CI
runs a newer version, so its floor is not tested either. The follow-up for
this module is to rewrite the remaining unsafe guards as ternaries and to
add CI coverage at the declared floor, not to raise the floor to 1.12.

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
