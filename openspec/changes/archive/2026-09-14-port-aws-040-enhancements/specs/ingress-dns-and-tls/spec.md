## ADDED Requirements

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
