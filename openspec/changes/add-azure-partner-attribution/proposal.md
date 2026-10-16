## Why

`terraform-aws-n8n` #187 tags every resource with `aws-apn-id` so AWS Partner
Revenue Measurement credits n8n for deployment spend, and #200 extends the tag
to EKS worker instances. Azure's counterpart is **Customer Usage Attribution
(CUA)**: usage in a customer subscription is associated with a partner through
a tracking GUID registered in Partner Center. It is not tag-based.

Microsoft documents the Terraform route as the `azurerm` provider's
`partner_id` argument (or `ARM_PARTNER_ID`), which adds `pid-<guid>` to the
provider's user agent. The module configures no providers, so only the
caller's provider block can set it. n8n's tracking GUID is issued by Microsoft.

## What Changes

- Every example declares `partner_id` (default n8n's GUID; `null` opts out) and passes it to its
  `provider "azurerm"` block, so an operator sets one variable (or
  `ARM_PARTNER_ID`) and the example's resources, including the module's, are
  attributed.
- README section documenting the route for root-module callers.
- No root input, resource or output. An earlier draft added an empty
  `pid-<guid>` ARM deployment; review showed attribution follows the
  deployment that creates the resources, so it would not attribute AKS,
  PostgreSQL or Redis. It was removed (see design.md).
- Non-goal: AWS #200's node launch-template tagging has no Azure equivalent
  to port; AKS propagates cluster and node-pool `tags`, which `aks.tf` sets.

## Capabilities

### Modified Capabilities

- `deployment-examples`: every example exposes `partner_id` and wires it into
  its azurerm provider.

## Impact

- Nine example roots (variable, provider block, test, README reference).
- Root module unchanged. No behaviour change unless a caller sets a value.
- Open dependency: n8n's registered GUID, from Partnerships.
