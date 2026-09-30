# Security Policy

## Scope

This policy covers `terraform-azurerm-n8n`, the Terraform module published
at https://registry.terraform.io/modules/n8n-io/n8n/azurerm.

It does **not** cover:

- The n8n product itself.
- Workflows users build inside n8n.
- Azure services, Kubernetes, or other upstream components this module
  provisions or installs.

If you've found something that affects the n8n product rather than
this Terraform module, please report it through n8n's product security
channel instead.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:

1. https://github.com/n8n-io/terraform-azurerm-n8n/security/advisories/new
2. Fill in the report. We see it; the public does not.

If you cannot use GitHub Advisories, email `security@n8n.io` with
`terraform-azurerm-n8n` in the subject so the report routes correctly.

Please **do not** open public GitHub issues for security findings.

## Response expectations

This module is maintained by the n8n Solutions team on a best-effort
basis. There is no contractual SLA. We aim to:

- Acknowledge new reports within 5 business days.
- Provide an initial assessment (severity, scope, planned action)
  within 10 business days.
- Coordinate a fix and disclosure timeline with the reporter.

For critical issues with active exploitation, we move faster.

## Supported versions

Only the most recent minor version receives security fixes. Older
minor lines do not receive backports. See
[README.md, Stability & versioning](./README.md#stability--versioning)
for the versioning policy.

| Version | Security fixes |
| ------- | -------------- |
| 0.1.x   | ✅ (current)   |

## Out of scope for this policy

- Findings that require an attacker already inside the Azure
  subscription or Kubernetes cluster. Hardening within an
  already-compromised environment is best-effort and not in scope.
- Findings against the third-party Helm charts this module or its
  examples install (KEDA, the n8n chart, and the Application Gateway
  Ingress Controller in the customer-managed and split-ingress
  examples). Report those upstream; we bump our chart pins once a fix
  is available.
- Findings against Azure service defaults exposed as optional inputs.
  These are documented configuration choices, not vulnerabilities.
