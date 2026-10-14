## Why

`terraform-aws-n8n` #187 tags every resource with `aws-apn-id` so AWS Partner
Revenue Measurement credits n8n for deployment spend, and #200 extends the tag
to EKS worker instances. Azure's counterpart is **Customer Usage Attribution
(CUA)**: usage of Azure resources in a customer subscription is associated
with a partner when a tracking GUID registered in Partner Center is attached to
the deployment. It is not tag-based, so the AWS mechanism does not port
directly. Microsoft documents two Terraform-compatible routes:

1. the `azurerm` provider's `partner_id` argument (or `ARM_PARTNER_ID`), which
   adds `pid-<guid>` to the provider's user agent; and
2. an ARM deployment named `pid-<guid>` (type `Microsoft.Resources/deployments`
   with an empty template) in the target resource group.

This module configures no providers, so route 1 belongs to the caller; route 2
is the only one the module can implement itself.

n8n's tracking GUID has not been issued yet. This change implements the
mechanism with an empty default so it can be validated end to end later by
setting one input, with no code change.

## What Changes

- New input `azure_partner_attribution_id` (non-nullable string, default `""`,
  i.e. disabled until the GUID exists). Accepts `<guid>`, `pid-<guid>` or
  `pid-<guid>-partnercenter`; anything else fails validation.
- When non-empty, one `azurerm_resource_group_template_deployment` named
  `pid-<guid>` with an empty template is created in `var.resource_group_name`.
- Every example exposes the same input (default `null`, so the module's
  default applies and flipping it later needs no example edit).
- README section: what CUA reports, that it is separate from licensing and
  telemetry, how to opt out, and that provider-level `partner_id` is the
  caller's alternative.
- Documented non-goals: AWS #200's node launch-template tagging has no Azure
  equivalent to port, because AKS propagates cluster and node-pool `tags` to
  the node resource group and VMSS, which `aks.tf` already sets.

## Capabilities

### Modified Capabilities

- `single-module-deployment`: new optional attribution input and resource.
- `deployment-examples`: every example passes the input through.

## Impact

- `variables.tf`, new `attribution.tf`, `README.md`, `CHANGELOG.md`, `AGENTS.md`.
- Nine example roots (variable + module argument + README reference).
- Default behaviour is unchanged until the default is set to n8n's GUID; that
  later flip is a minor-only change and needs an upgrade note (one new
  deployment record, no resource replaced).
- Open dependency: n8n's registered GUID, from Partnerships.
