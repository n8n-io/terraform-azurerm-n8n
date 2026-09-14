## Purpose

Provide secure Azure ingress, DNS, and certificate behavior for public, private, multi-domain, and caller-owned routing topologies.

## Requirements

### Requirement: Module-managed Application Gateway ingress
The module SHALL create a WAF_v2 Application Gateway and AGIC-managed Ingress by default, with explicit public or internal frontend selection, TLS policy, WAF mode, capacity or autoscaling, and additional ingress annotations.

#### Scenario: Deploy an internal editor endpoint
- **WHEN** ingress mode is internal
- **THEN** the Application Gateway SHALL use a private frontend address and the module SHALL not require a public IP address

### Requirement: Complete n8n routing
Every module-managed host SHALL route `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp` to webhook processors before routing `/` to main pods.

#### Scenario: Route a waiting webhook
- **WHEN** a request for `/webhook-waiting/...` reaches any configured host
- **THEN** Application Gateway SHALL send the request to the webhook service and not the main service

### Requirement: Source restrictions and ingress escape hatch
The module SHALL expose IPv4 source CIDR restrictions and an annotation map while warning when caller overrides make dedicated ingress controls ineffective.

#### Scenario: Restrict a public gateway
- **WHEN** allowed inbound CIDRs are configured
- **THEN** port 80 and 443 traffic outside those CIDRs SHALL be denied while required Azure gateway-management traffic remains permitted

### Requirement: Caller-owned ingress
The module SHALL support disabling module-managed Application Gateway, AGIC integration, Ingress, Key Vault access grants, and DNS resources while retaining the n8n services and exposing their names, port, namespace, webhook path prefixes, and webhook URL control. Customer-managed AKS SHALL require this caller-owned ingress path.

#### Scenario: Bring two caller-owned gateways
- **WHEN** `create_ingress` is false
- **THEN** the module SHALL create no Application Gateway, AGIC addon configuration, public IP, Ingress, Key Vault role grant, or application DNS record and SHALL expose enough service metadata for caller-owned routing

#### Scenario: Deploy onto existing AKS
- **WHEN** AKS creation is disabled
- **THEN** module-managed ingress SHALL also be disabled and the caller SHALL route the exported main and webhook service coordinates through an existing ingress controller

### Requirement: Multi-domain TLS and routing
The module SHALL support a canonical n8n domain plus validated additional domains, attach a Key Vault certificate that covers them, and create a listener and route set for every host on the managed path.

#### Scenario: Serve an additional hostname
- **WHEN** a caller supplies an additional hostname covered by the Key Vault certificate
- **THEN** the module SHALL route the hostname and, on the Azure DNS path, create the matching record

### Requirement: Azure DNS paths
The managed ingress path SHALL optionally create public or private Azure DNS records in caller-supplied zones and SHALL validate that required zone and target inputs are supplied together.

#### Scenario: Create private DNS
- **WHEN** an internal ingress uses a supplied private Azure DNS zone
- **THEN** the module SHALL create an A record that resolves the n8n host to the private Application Gateway frontend

### Requirement: Key Vault certificate access
The module SHALL consume a caller-supplied Key Vault certificate secret URI and SHALL optionally grant the Application Gateway identity the minimum Key Vault secret-read role.

#### Scenario: Read a listener certificate
- **WHEN** Key Vault role assignment is enabled with a valid vault ID and certificate secret URI
- **THEN** the Application Gateway identity SHALL receive `Key Vault Secrets User` on that vault before the listener reads the certificate

### Requirement: Independent editor and webhook base URLs

The module SHALL advertise `N8N_EDITOR_BASE_URL` as `https://<n8n_domain>` and SHALL expose nullable `n8n_webhook_url` for the advertised webhook base URL. Null SHALL retain `https://<n8n_domain>` as the webhook URL. A supplied override SHALL be an absolute HTTPS base URL with a host and no embedded credentials, whitespace, query, or fragment; an optional port SHALL be valid. Valid supplied paths and trailing slashes SHALL be preserved.

All main, worker, and webhook application containers SHALL receive exactly one current `N8N_WEBHOOK_URL` and one `N8N_EDITOR_BASE_URL` with the selected values. The module SHALL retain its current-name convention without emitting deprecated `WEBHOOK_URL`. Editor identity, internal service protocol/port, and `N8N_HOST` SHALL remain independent of the webhook override. All three URL environment names SHALL remain reserved from `n8n_extra_env`.

#### Scenario: Keep a common public base URL
- **WHEN** `n8n_domain = "n8n.example.com"` and the webhook override is null
- **THEN** the editor and webhook base URLs SHALL both be `https://n8n.example.com`
- **AND** all application pod families SHALL receive those values without duplicate URL environment entries

#### Scenario: Advertise public webhooks and a private editor
- **WHEN** `n8n_domain = "admin.example.com"` and `n8n_webhook_url = "https://hooks.example.com"`
- **THEN** the webhook base SHALL be `https://hooks.example.com`
- **AND** the editor base SHALL remain `https://admin.example.com`, keeping the OAuth2 credential callback under `/rest/oauth2-credential/callback` on the admin host

#### Scenario: Preserve a valid caller base path
- **WHEN** a caller supplies `https://hooks.example.com:8443/n8n/`
- **THEN** the module SHALL preserve that value as the advertised webhook base
- **AND** the caller SHALL remain responsible for routing that base path

#### Scenario: Keep URL advertisement separate from ingress ownership
- **WHEN** a webhook override is supplied on either ingress ownership path
- **THEN** the override SHALL NOT by itself create a DNS record, listener, certificate, or additional route
- **AND** existing managed-host routing and caller-managed ingress boundaries SHALL remain unchanged

#### Scenario: Reject invalid webhook URLs and direct overrides
- **WHEN** the override is blank, lacks an HTTPS scheme/host, includes credentials, whitespace, a query, a fragment, or an invalid port, or `n8n_extra_env` contains a reserved URL environment name
- **THEN** Terraform planning SHALL fail with guidance to use a valid dedicated input
