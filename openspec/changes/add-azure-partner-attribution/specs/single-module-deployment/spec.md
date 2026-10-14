## ADDED Requirements

### Requirement: Azure customer usage attribution

The module SHALL accept `azure_partner_attribution_id`, a non-nullable string
defaulting to `""`. When empty, the module SHALL create no attribution
resource. When set, the module SHALL create exactly one empty-template resource
group deployment in `var.resource_group_name` named `pid-<guid>`, preserving a
supplied `pid-` prefix and `-partnercenter` suffix. Values other than a GUID,
`pid-<guid>` or `pid-<guid>-partnercenter` SHALL fail validation.

#### Scenario: Attribution disabled by default

- **WHEN** the module plans with the default input
- **THEN** no `azurerm_resource_group_template_deployment` exists

#### Scenario: Bare GUID normalised

- **WHEN** the input is a bare GUID
- **THEN** one deployment named `pid-<guid>` is planned with an empty
  `resources` array in `var.resource_group_name`

#### Scenario: Marketplace format preserved

- **WHEN** the input is `pid-<guid>-partnercenter`
- **THEN** the deployment name equals the input

#### Scenario: Malformed value rejected

- **WHEN** the input is not one of the accepted formats
- **THEN** plan fails on `var.azure_partner_attribution_id`
