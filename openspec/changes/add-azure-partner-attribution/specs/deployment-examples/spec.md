## ADDED Requirements

### Requirement: Examples expose the attribution input

Every example root SHALL declare `azure_partner_attribution_id` with default
`null` and pass it to `module "n8n"`, so the module's default applies unless
the operator overrides it and an empty string disables attribution.

#### Scenario: Example inherits the module default

- **WHEN** an example plans with no value for the input
- **THEN** the module receives the input as null and uses its own default
