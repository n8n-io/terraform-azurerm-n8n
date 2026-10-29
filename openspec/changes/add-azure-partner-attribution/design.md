## Context

Source: Microsoft Learn, "Azure customer usage attribution". Tracking IDs are
partner-generated and registered (`pid-<guid>`) or created by Partner Center for
Marketplace apps (`pid-<guid>-partnercenter`). The provider's `partner_id`
accepts `<guid>`, `pid-<guid>` and `pid-<guid>-partnercenter`, and can also be
sourced from `ARM_PARTNER_ID`.

## Decisions

1. **Provider `partner_id`, set by the caller.** It is Microsoft's documented
   Terraform route and attributes everything the provider session creates. The
   module declares no providers, so it cannot set it; examples (which own their
   provider blocks) and root-module callers do.
2. **No module-side resource.** A standalone empty `pid-<guid>` ARM deployment
   was implemented first and dropped after review: Microsoft ties template
   attribution to the `pid-` deployment inside the deployment that creates the
   resources, so an empty deployment would not attribute AKS, PostgreSQL or
   Redis, which other Terraform resources create. A resource that probably does
   not do its job is worse than documentation.
3. **Example variable `partner_id`, default n8n's Microsoft-issued GUID.**
   Examples send n8n's partner ID by default; a caller opts out with
   `partner_id = null`, which sends no CUA ID and lets `ARM_PARTNER_ID` apply.
   With neither set, the provider still sends HashiCorp's Terraform partner
   ID unless `disable_terraform_partner_id` is true.
   A non-null default overrides `ARM_PARTNER_ID`, because provider
   configuration wins over the environment. The bare GUID form is the default:
   the provider emits `pid-<guid>` itself. The validation mirrors the
   provider's accepted forms, case-insensitively, with `-partnercenter` valid
   only after `pid-<guid>`. The variable-parity script requires all nine
   examples to match.
4. **No node tagging work.** AWS #200 exists because EKS does not propagate
   node-group tags to EC2. AKS applies cluster tags to the node resource
   group's resources and node-pool tags to each pool's VMSS. The live run
   confirmed this and found the system pool's VMSS untagged, because the
   cluster's tags do not reach it; `default_node_pool` now sets its own.

## Risks

- Provider `partner_id` is not assertable in `terraform test`; examples only
  test input validation. The live run confirmed the user agent carries
  `pid-<guid>`. Microsoft-side attribution itself cannot be checked from a
  partner report: Microsoft states that CUA consumption data is not shared
  externally with partners. Only Microsoft, through the partnerships team's
  channel, can confirm it.
- Microsoft documents known issues that cause AKS and VM scale set usage to
  be under-reported through CUA. Most of this module's compute runs on AKS
  node pools (VM scale sets), so attributed usage can understate the real
  footprint.
- Callers of the root module must set `partner_id` themselves; nothing in the
  module enforces it.

## Open Questions

- Format: the bare GUID is what ships; whether Partner Center also wants the
  `pid-<guid>-partnercenter` form is for the partnerships team to confirm.
