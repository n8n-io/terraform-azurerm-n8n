## 1. Module

- [x] 1.1 Add `azure_partner_attribution_id` to `variables.tf` with validation
- [x] 1.2 Add `attribution.tf` with the `pid-<guid>` empty-template deployment
- [x] 1.3 Plan-time tests: default off, bare GUID, pid prefix, partnercenter suffix, malformed rejected

## 2. Examples

- [x] 2.1 Declare and pass the input in all nine examples; add tests per example
- [x] 2.2 Regenerate every `terraform-docs` block

## 3. Docs

- [x] 3.1 README section, CHANGELOG entry, AGENTS.md note
- [x] 3.2 Request to Partnerships for the GUID (in the PR description)

## 4. Deferred until a GUID exists

- [ ] 4.1 Live apply on Azure; confirm deployment record and Partner Center usage report
- [ ] 4.2 Confirm AKS node-resource-group and VMSS tag propagation
- [ ] 4.3 Flip the default to n8n's GUID
