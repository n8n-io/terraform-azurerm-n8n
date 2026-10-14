## ADDED Requirements

### Requirement: Examples expose Customer Usage Attribution

Every example root SHALL declare `partner_id` (default `null`) and set it as
the `partner_id` of its `provider "azurerm"` block. The variable SHALL accept
null, a GUID, `pid-<guid>` or `pid-<guid>-partnercenter` (case-insensitive),
and SHALL reject any other value.

#### Scenario: Reject a malformed tracking ID

- **WHEN** an example plans with `partner_id = "not-a-guid"`
- **THEN** plan fails on `var.partner_id`

#### Scenario: Default sends no partner ID

- **WHEN** an example plans with no value for `partner_id`
- **THEN** the provider receives null and `ARM_PARTNER_ID` still applies
