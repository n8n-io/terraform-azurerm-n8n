## Context

Source behaviour: Microsoft Learn, "Azure customer usage attribution". Tracking
IDs are either partner-generated and registered (`pid-<guid>`) or created by
Partner Center for Marketplace apps (`pid-<guid>-partnercenter`). The provider's
`partner_id` validates a GUID and prefixes `pid-`.

## Decisions

1. **ARM deployment, not provider `partner_id`.** The module declares no
   providers, so it cannot set `partner_id`. An empty-template
   `azurerm_resource_group_template_deployment` named `pid-<guid>` is the
   documented template route and needs only `Microsoft.Resources/deployments/write`,
   which Contributor already grants. No new provider (no `azapi`) is required.
2. **Default `""` for now, not a placeholder GUID.** A fake GUID would
   report junk to Microsoft. The default flips to n8n's GUID once issued; until
   then `""` means no resource, so nothing changes for existing users.
3. **`""` disables.** Mirrors AWS `aws_partner_attribution_tag = ""`.
4. **Accepted formats.** Bare GUID, `pid-<guid>`, `pid-<guid>-partnercenter`;
   the whole value is matched case-insensitively (`(?i)`), and
   `-partnercenter` is valid only after `pid-<guid>`. The bare form is
   normalised to `pid-<guid>`. Longest name is 54 characters, inside the
   64-character deployment-name limit.
5. **Resource group.** `var.resource_group_name`, the group the module already
   requires; it exists for every topology including `create_aks = false`.
6. **Single deployment per module call, best-effort.** One record per call,
   not gated on `create_*` switches. It is not established that a standalone
   empty deployment attributes resources created by other deployments
   (see Risks); do not claim it does.
7. **Examples pass `null` by default.** `nullable = false` on the module input
   turns a `null` module-call argument into the module default, so an example
   needs no edit when the default flips. The variable-parity script requires
   all examples to declare the same variables.
8. **No node tagging work.** AWS #200 exists because EKS does not propagate
   node-group tags to EC2. AKS applies cluster tags to the node resource group
   and node-pool tags to the VMSS; verify on the live run.

## Risks

- **Attribution scope is unproven (review P1).** Microsoft documents template
  attribution as the `pid-` deployment inside the main deployment that creates
  the resources, and Terraform attribution as the provider's `partner_id`
  (user agent). A standalone empty deployment in the same resource group may
  not associate the AKS, PostgreSQL and Redis resources, which other
  Terraform resources create. Confirm in the Partner Center usage report;
  if it does not attribute, replace this with documentation plus
  `partner_id` in the examples' provider blocks (the caller's route).
- `terraform destroy` deletes the deployment record only; attribution history
  is kept by Microsoft.

## Open Questions

- n8n's GUID and registration format (partner-generated vs `-partnercenter`).
- Whether the default should be on for every deployment (AWS did) or opt-in.
