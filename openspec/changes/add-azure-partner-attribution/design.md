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
3. **Example variable `partner_id`, default `null`.** Null sends nothing and
   lets `ARM_PARTNER_ID` apply. No placeholder GUID is shipped: a fake one
   would report junk to Microsoft. The validation mirrors the provider's
   accepted forms, case-insensitively, with `-partnercenter` valid only after
   `pid-<guid>`. The variable-parity script requires all nine examples to match.
4. **No node tagging work.** AWS #200 exists because EKS does not propagate
   node-group tags to EC2. AKS applies cluster tags to the node resource
   group's resources and node-pool tags to the VMSS; verify on the live run.

## Risks

- Provider `partner_id` is not assertable in `terraform test`; examples only
  test input validation. The live run must confirm the user agent carries
  `pid-<guid>` and that usage appears in Partner Center.
- Callers of the root module must set `partner_id` themselves; nothing in the
  module enforces it.

## Open Questions

- n8n's GUID and registration format (partner-generated vs `-partnercenter`).
- Whether examples should default to n8n's GUID once issued (AWS did) or stay
  opt-in.
