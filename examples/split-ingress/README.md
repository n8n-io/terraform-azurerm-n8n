# Split ingress example

Two Application Gateways instead of the root module's single one: a public gateway that serves only webhook traffic, and a private gateway that serves the editor UI, REST API, and everything else. The point is blast radius: only the endpoints that must accept unauthenticated internet traffic are exposed, and the admin surface never leaves the VNet.

| Endpoint | Application Gateway | Hostname | Reachable from |
|---|---|---|---|
| Webhooks, forms, waiting webhooks, MCP | `webhook` (public, WAF_v2 by default) | `hooks.n8n.example.com` | The internet |
| Editor UI, REST API, and the same webhook prefixes | `admin` (private, Standard_v2) | `n8n.example.com` | Only the VNet, or whatever is peered/VPN-attached to it |

## How this differs from every other example

`create_ingress = false` on the root module call disables the module's own Application Gateway, AGIC addon, and Ingress entirely. AKS, PostgreSQL, Azure Managed Redis, private Azure Blob storage, and the n8n Helm release are still module-managed; only ingress moves into this example's `ingress.tf`.

AKS's built-in `ingress_application_gateway` addon binds to exactly one Application Gateway per cluster, so serving two gateways from one cluster needs two **standalone** `ingress-azure` Helm releases (not the addon), each with:

- Its own Application Gateway (`azurerm_application_gateway.webhook` / `.admin`).
- Its own AKS workload-identity user-assigned identity, federated to its own Kubernetes namespace (`agic-webhook` / `agic-admin`) and the chart's fixed `ingress-azure` service account name.
- `Contributor` on only its own gateway (never both — crossing these would let one controller reconfigure the other gateway), `Reader` on the resource group, and `Network Contributor` on the shared `appgw` subnet.
- A distinct `kubernetes.io/ingress.class` value (`azure/application-gateway-webhook` / `azure/application-gateway-admin`) so each install reconciles only the Ingress object that names it.

Both gateways issue lab-grade self-signed certificates from `modules/tls-self-signed`, one per hostname, imported into one shared Key Vault. Replace both with real certificates before production use.

## Editor and webhook URLs

The root module's `n8n_webhook_url` input (port-aws-040-enhancements section 11) lets this example advertise webhooks on the public host while the editor identity stays on the private one. This example passes `n8n_webhook_url = "https://${local.webhook_domain}"`, so:

- `N8N_WEBHOOK_URL` (what n8n hands out in generated webhook, form, and MCP links) is `https://hooks.n8n.example.com`, the public gateway's hostname.
- `N8N_EDITOR_BASE_URL` stays `https://n8n.example.com`, the private admin gateway's hostname, so the OAuth2 credential callback (`/rest/oauth2-credential/callback`) keeps returning to the admin host.

The public gateway routes every webhook prefix (that is what the mocked tests in `tests/defaults.tftest.hcl` assert), so both n8n's own generated links and a URL you construct yourself against `webhook_base_url` (this example's output, which always matches `n8n_webhook_url`) resolve correctly. This fix only changes what n8n advertises; it does not redesign routing — the public gateway already routed the same five prefixes before this change. The pinned n8n version also uses the configured webhook base for test-webhook and form-trigger URLs in the editor; verify that behavior manually against a real deployment, since it is not covered by the offline chart-rendering check.

## Apply

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace the placeholders.
2. Run `terraform init` and `terraform apply`. AGIC needs both role assignments and the RBAC propagation gates to settle before it can reconcile either gateway; the first Ingress admission can take a few minutes after `apply` reports success.
3. Point your own DNS at `webhook_appgw_fqdn` (public) and `admin_appgw_private_ip` (private, once AGIC assigns it) once you are ready to move off the self-signed certificates.

The root default writes binary data to private Azure Blob and requires the separate `feat:binaryDataAz` n8n Enterprise entitlement. Select `database` instead if that entitlement is unavailable; PostgreSQL is the durable queue-mode fallback. 0.1.0 does not support n8n's inline-memory `default` mode or a shared-filesystem mode.

## Cost and operational caveats

Two Application Gateways cost roughly twice one, and this example runs two additional AGIC pods. `create_webhook_waf_policy = false` drops the public gateway to Standard_v2 if you terminate WAF elsewhere (for example, Azure Front Door in front of it). The admin gateway never carries a WAF policy: it is already private, so a WAF adds cost without adding protection here.

## Production considerations

| Module input | Default | Purpose |
| --- | --- | --- |
| `pg_backup_retention_days` | `7` | Days to retain automated PostgreSQL Flexible Server backups. Azure enforces 7-35 days for Flexible Server. |
| `blob_delete_retention_days` | `null` | Soft-delete retention window, in days, for the module-managed Blob storage account. `null` leaves soft delete disabled; set 1-365 to enable it. |

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.14 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 2.12 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 3.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.14 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_tls_self_signed_admin"></a> [tls\_self\_signed\_admin](#module\_tls\_self\_signed\_admin) | ../../modules/tls-self-signed | n/a |
| <a name="module_tls_self_signed_webhook"></a> [tls\_self\_signed\_webhook](#module\_tls\_self\_signed\_webhook) | ../../modules/tls-self-signed | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_application_gateway.admin](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_application_gateway.webhook](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_federated_identity_credential.agic_admin](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_federated_identity_credential.agic_webhook](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_key_vault.tls](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_network_security_group.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_public_ip.webhook](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.admin_tls_cert_kv_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_admin_appgw_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_admin_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_admin_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_webhook_appgw_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_webhook_rg_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.agic_webhook_subnet_network_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.key_vault_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.terraform_blob_data_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.webhook_tls_cert_kv_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.private_endpoints](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.redis](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_network_security_group_association.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [azurerm_user_assigned_identity.admin_tls_cert](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.agic_admin](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.agic_webhook](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_user_assigned_identity.webhook_tls_cert](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [azurerm_virtual_network.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [azurerm_web_application_firewall_policy.webhook](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/web_application_firewall_policy) | resource |
| [helm_release.agic_admin](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.agic_webhook](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_ingress_v1.admin_internal](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_ingress_v1.webhook_public](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace.agic_admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_namespace.agic_webhook](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [random_string.key_vault_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [time_sleep.admin_tls_cert_kv_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.key_vault_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.storage_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.webhook_tls_cert_kv_rbac](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_admin_allowed_cidr_blocks"></a> [admin\_allowed\_cidr\_blocks](#input\_admin\_allowed\_cidr\_blocks) | IPv4 CIDR blocks allowed to reach the internal admin Application Gateway, in addition to it already being private (no public IP, private-subnet frontend only). Empty (the default) allows any source that can already route to the VNet. Narrow this to your VPN pool or peered ranges for defense in depth. | `list(string)` | `[]` | no |
| <a name="input_aks_api_authorized_ip_ranges"></a> [aks\_api\_authorized\_ip\_ranges](#input\_aks\_api\_authorized\_ip\_ranges) | Operator and CI IPv4 CIDRs allowed to reach the public AKS API. Empty leaves it unrestricted and is not recommended for production. | `list(string)` | `[]` | no |
| <a name="input_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#input\_blob\_delete\_retention\_days) | Optional soft-delete retention window, in days, for the module-managed Blob storage account. Passed through to the root module's blob\_delete\_retention\_days. Null (the default) leaves soft delete disabled. | `number` | `null` | no |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags applied to example and module resources. | `map(string)` | `{}` | no |
| <a name="input_create_webhook_waf_policy"></a> [create\_webhook\_waf\_policy](#input\_create\_webhook\_waf\_policy) | Attach a module-managed OWASP 3.2 WAF policy (Detection mode) to the public webhook Application Gateway (WAF\_v2 SKU). Set to false to use the cheaper Standard\_v2 SKU with no WAF. The admin gateway is private-only and never gets a WAF policy regardless of this setting: rate limiting and managed rule groups only make sense on the endpoint that accepts untrusted internet traffic. | `bool` | `true` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase alphanumeric prefix used for Azure resource names. Change it to avoid globally unique name collisions. | `string` | `"n8nsplit"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the example. Confirm that the selected AKS, PostgreSQL, Redis, zone, and storage SKUs are available there. | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for the n8n editor UI and REST API (e.g. n8n.example.com). Served by the internal (admin) Application Gateway, so it resolves to a private address and is reachable only from inside the VNet or over a VPN/peering. This example issues its own lab-grade self-signed certificate for it (main.tf), so replace that with a real certificate before production use. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum main replicas passed through to the root module's n8n\_main\_hpa\_min\_replicas, the sole topology selector. The default of 2 keeps this example on multi-main. Set to 1 to select single-main queue mode for a license without feat:multipleMainInstances (including Business licenses); other selected features, such as Azure Blob binary/execution-data entitlements, still require their own license grants and are not affected by this setting. | `number` | `2` | no |
| <a name="input_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#input\_pg\_backup\_retention\_days) | Number of days to retain automated PostgreSQL Flexible Server backups. Passed through to the root module's pg\_backup\_retention\_days. Azure enforces a range of 7–35 days for Flexible Server (unlike RDS, Azure does not allow disabling backups). | `number` | `7` | no |
| <a name="input_webhook_subdomain"></a> [webhook\_subdomain](#input\_webhook\_subdomain) | Label prepended to n8n\_domain to form the public webhook hostname. With the default and n8n\_domain = n8n.example.com, webhooks are served from hooks.n8n.example.com by the internet-facing (webhook) Application Gateway. A separate hostname is required because a DNS name resolves to one gateway's frontend. | `string` | `"hooks"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_admin_appgw_private_ip"></a> [admin\_appgw\_private\_ip](#output\_admin\_appgw\_private\_ip) | Private IPv4 address of the internal admin Application Gateway's frontend, once AGIC provisions it. Null until then. |
| <a name="output_blob_delete_retention_days"></a> [blob\_delete\_retention\_days](#output\_blob\_delete\_retention\_days) | Effective Blob soft-delete retention window, in days, passed to the root module's blob\_delete\_retention\_days. Null leaves soft delete disabled. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command that writes the AKS context into the local kubeconfig. |
| <a name="output_main_hpa_min_replicas"></a> [main\_hpa\_min\_replicas](#output\_main\_hpa\_min\_replicas) | Effective main-topology floor passed to the root module's n8n\_main\_hpa\_min\_replicas. See module.n8n.n8n\_url for confirmation the module accepted it. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL for the n8n editor UI. Resolves to the internal (admin) Application Gateway, so it is reachable only from inside the VNet or over VPN/peering. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
| <a name="output_pg_backup_retention_days"></a> [pg\_backup\_retention\_days](#output\_pg\_backup\_retention\_days) | Effective PostgreSQL Flexible Server backup retention window, in days, passed to the root module's pg\_backup\_retention\_days. |
| <a name="output_postgres_password"></a> [postgres\_password](#output\_postgres\_password) | Generated PostgreSQL administrator password. Back it up in a secret manager. |
| <a name="output_webhook_appgw_fqdn"></a> [webhook\_appgw\_fqdn](#output\_webhook\_appgw\_fqdn) | FQDN of the public webhook Application Gateway. |
| <a name="output_webhook_base_url"></a> [webhook\_base\_url](#output\_webhook\_base\_url) | Public base URL for webhooks, forms, and MCP. Passed to the root module as n8n\_webhook\_url, so n8n's own N8N\_WEBHOOK\_URL matches this value — see module.n8n.n8n\_webhook\_url for the module's own confirmation of the effective value. |
| <a name="output_webhook_path_prefixes"></a> [webhook\_path\_prefixes](#output\_webhook\_path\_prefixes) | Path prefixes routed to the webhook processors on the public gateway. Sourced from the module so this example cannot drift from what n8n actually serves. |
<!-- END_TF_DOCS -->
