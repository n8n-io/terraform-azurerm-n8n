## ADDED Requirements

### Requirement: Examples expose Customer Usage Attribution

Every example root SHALL declare `partner_id` (default n8n's Microsoft-issued GUID, `f1198e81-0323-4ce9-9753-ed1a8c596b19`; `null` opts out) and set it as
the `partner_id` of its `provider "azurerm"` block. The variable SHALL accept
null, a GUID, `pid-<guid>` or `pid-<guid>-partnercenter` (case-insensitive),
and SHALL reject any other value.

#### Scenario: Reject a malformed tracking ID

- **WHEN** an example plans with `partner_id = "not-a-guid"`
- **THEN** plan fails on `var.partner_id`

#### Scenario: Default attributes usage to n8n

- **WHEN** an example applies with no value for `partner_id`
- **THEN** the provider sends `pid-f1198e81-0323-4ce9-9753-ed1a8c596b19` in its user agent

#### Scenario: Explicit null opts out

- **WHEN** an example applies with `partner_id = null`
- **THEN** the provider receives null and `ARM_PARTNER_ID` still applies
