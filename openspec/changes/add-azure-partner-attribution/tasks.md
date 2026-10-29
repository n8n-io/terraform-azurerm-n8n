## 1. Examples

- [x] 1.1 Declare `partner_id` and wire it into each example's azurerm provider (nine examples)
- [x] 1.2 Rejection, null opt-out, alternate-form and default-value tests per example; regenerate `terraform-docs`

## 2. Docs

- [x] 2.1 README section (opt-out, `disable_terraform_partner_id`, customer notice), CHANGELOG entry, AGENTS.md note

## 3. Live validation and default

- [x] 3.1 Live apply of `examples/small` (swedencentral) with the Microsoft-issued GUID: all 411 ARM requests carried `pid-f1198e81-0323-4ce9-9753-ed1a8c596b19` in the provider user agent (azurerm 5.10.0); bare GUID, `pid-<guid>`, `pid-<guid>-partnercenter` and uppercase inputs each produced the expected header
- [x] 3.2 Confirm AKS node-resource-group and VMSS tag propagation: the f462a1f live run found module tags on the node resource group's resources and the `n8nuser` VMSS, but none on the system pool VMSS
- [x] 3.5 Set `tags` on `default_node_pool` (in-place update: `tags` is not in the provider's `cycleNodePoolProperties`, checked at v5.5.0 and v5.9.0)
- [ ] 3.6 Confirm live that the system pool VMSS is tagged and the pool is updated in place, not rotated
- [x] 3.3 Examples default to n8n's GUID; opt out with `partner_id = null`
- [ ] 3.4 Microsoft confirms, through the partnerships team's channel, that the 3.1 deployment is attributed to n8n's GUID (Microsoft does not share CUA data with partners, so no Partner Center report can show it)
