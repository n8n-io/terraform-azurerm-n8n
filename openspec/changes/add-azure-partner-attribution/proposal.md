## Why

`terraform-aws-n8n` #187 tags every resource with `aws-apn-id` so AWS Partner
Revenue Measurement credits n8n for deployment spend, and #200 extends the tag
to EKS worker instances. Azure's counterpart is **Customer Usage Attribution
(CUA)**: usage in a customer subscription is associated with a partner through
a tracking GUID registered in Partner Center. It is not tag-based.

Microsoft documents the Terraform route as the `azurerm` provider's
`partner_id` argument (or `ARM_PARTNER_ID`), which adds `pid-<guid>` to the
provider's user agent. The module configures no providers, so only the
caller's provider block can set it. n8n's tracking GUID
(`f1198e81-0323-4ce9-9753-ed1a8c596b19`) is issued by Microsoft.

## What Changes

- Every example declares `partner_id` (default n8n's GUID; `null` opts out) and passes it to its
  `provider "azurerm"` block, so an example's provider sends n8n's partner
  ID for every resource it creates, including the module's, unless the
  operator sets `partner_id = null`. Whether Microsoft then attributes the
  usage to n8n is confirmed only on Microsoft's side (task 3.4).
- README section documenting the route for root-module callers, the opt-out
  (including `disable_terraform_partner_id`), and the customer notice
  Microsoft asks partners to publish.
- No root input, resource or output for attribution. An earlier draft added an empty
  `pid-<guid>` ARM deployment; review showed attribution follows the
  deployment that creates the resources, so it would not attribute AKS,
  PostgreSQL or Redis. It was removed (see design.md).
- Root fix in `aks.tf`: `default_node_pool` now sets `tags`
  (`common_tags` plus `Name = "<cluster>-system"`). The live run found the
  system pool's VM scale set untagged, because the cluster's `tags` do not
  reach it. This is the Azure equivalent of AWS #200's goal (tagged nodes).
  The fix is not yet confirmed live (task 3.6).
- Non-goal: AWS #200's node launch-template tagging itself has no Azure
  equivalent to port; AKS applies node-pool `tags` to each pool's VM scale
  set.

## Capabilities

### Modified Capabilities

- `deployment-examples`: every example exposes `partner_id` and wires it into
  its azurerm provider.
- AKS node pools: the system (default) pool carries the module's tags, like
  the `n8nuser` pool.

## Impact

- Nine example roots (variable, provider block, tests, README reference).
- Root module: one change in `aks.tf`, `tags` on `default_node_pool`, plus
  a test assertion. Existing clusters see an in-place update of the system
  pool's tags; `tags` is not a node pool rotation property in the azurerm
  provider, so the pool should not be recreated (not yet confirmed live,
  task 3.6).
- Example users send n8n's partner ID by default; `partner_id = null` opts
  out. The live run confirmed the user agent; Microsoft-side attribution is
  unverified (task 3.4). `partner_id` causes no resource or plan change
  either way: it only changes the provider's user agent.
