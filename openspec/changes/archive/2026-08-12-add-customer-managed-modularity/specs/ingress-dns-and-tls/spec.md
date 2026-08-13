## MODIFIED Requirements

### Requirement: Caller-owned ingress
The module SHALL support disabling module-managed Application Gateway, AGIC integration, Ingress, Key Vault access grants, and DNS resources while retaining the n8n services and exposing their names, port, namespace, webhook path prefixes, and webhook URL control. Customer-managed AKS SHALL require this caller-owned ingress path.

#### Scenario: Bring two caller-owned gateways
- **WHEN** `create_ingress` is false
- **THEN** the module SHALL create no Application Gateway, AGIC addon configuration, public IP, Ingress, Key Vault role grant, or application DNS record and SHALL expose enough service metadata for caller-owned routing

#### Scenario: Deploy onto existing AKS
- **WHEN** AKS creation is disabled
- **THEN** module-managed ingress SHALL also be disabled and the caller SHALL route the exported main and webhook service coordinates through an existing ingress controller
