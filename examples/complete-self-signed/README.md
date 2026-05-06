# Complete example — self-signed TLS

End-to-end deployment of the `terraform-azurerm-n8n` module wired against the [`modules/tls-self-signed/`](../../modules/tls-self-signed/) submodule (registry-hardening Phase 4 R4.2). The submodule's `app_gateway_tls_cert_secret_id` output is fed straight into the root module's `var.app_gateway_tls_cert_secret_id` input — the registry-hardening US-012 contract that retired the legacy `var.tls_mode` (self_signed / letsencrypt / custom_pfx) variable surface.

## When to use self-signed mode

Self-signed mode is intended for **lab / internal-only** deployments. Browsers will warn on the cert, and clients have to trust it manually. For production deployments use the sibling [`examples/complete-letsencrypt/`](../complete-letsencrypt/) example or pass a pre-imported Key Vault Secret URI (e.g. from your existing PKI / DigiCert / Sectigo cert) directly to `module.n8n` as `app_gateway_tls_cert_secret_id`.

## What it creates

- A dedicated networking resource group with a VNet (`10.0.0.0/16`) and 5 subnets — same shape as `examples/complete/`.
- A public `azurerm_dns_zone` (`var.public_dns_zone_name`) into which the n8n module's A-record is written.
- A shared Key Vault (`${var.friendly_name_prefix}-tls-kv`) in the example's network RG. The submodule imports its generated PEM into this vault; the root module's `azurerm_role_assignment.appgw_kv_secrets_user` grants the App Gateway UAMI runtime read access.
- The submodule [`modules/tls-self-signed/`](../../modules/tls-self-signed/) — generates a 2048-bit RSA key + an X.509 self-signed cert valid for `var.tls_validity_period_hours`.
- Everything the root [`terraform-azurerm-n8n`](../../README.md) module creates: AKS cluster, PostgreSQL Flexible Server (private), Redis Cache (private endpoint), Storage Account + File Share, Application Gateway (WAF_v2) + AGIC addon, KEDA, and the n8n Helm release.

## Prerequisites

- **Terraform** >= 1.9
- **Azure CLI** >= 2.50, signed in to the target subscription (`az login`)
- **kubectl** >= 1.30 (for post-apply operational access)
- **Helm** >= 3.14 (only required if you tail Helm release status; not needed for apply itself)
- An n8n Enterprise license key (https://n8n.io/pricing)
- A registered domain whose NS records you can edit at your registrar — the example creates a public Azure DNS zone for it, but the upstream NS delegation must be set at the registrar by hand.
- Cert-import rights on the shared Key Vault the example creates — handled inline by the example's `access_policy` block, which grants the running principal full cert/secret control automatically.

Self-signed mode does NOT require ACME / Let's Encrypt env vars or DNS Zone Contributor on the public zone — the cert is generated locally by the `hashicorp/tls` provider.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set public_dns_zone_name, n8n_domain, n8n_license_key

terraform init
terraform apply
```

The example is single-apply: one `terraform apply` provisions the VNet, AKS cluster, Postgres, Redis, Application Gateway, KEDA, the n8n Helm release, the public DNS zone, the A-record for `var.n8n_domain`, the shared Key Vault, AND the self-signed cert (imported into the vault by the submodule). Allow ~3 minutes after apply for the App Gateway listener to converge once AGIC publishes the Ingress.

### Delegate the zone at your registrar

```bash
terraform output -json public_dns_zone_name_servers
```

Paste the four NS hostnames into your registrar's NS records for `var.public_dns_zone_name`. Propagation typically completes in 5–60 minutes — track it with `dig NS <var.public_dns_zone_name>`.

### Renewal

The `hashicorp/tls` provider auto-renews the self-signed cert when within 30 days of expiry — re-running `terraform apply` inside that window regenerates the key + cert and re-imports them into the Key Vault. The Application Gateway picks up the new versioned secret URI on its next `azurerm_application_gateway` apply.

## Retrieve outputs

```bash
# All non-sensitive outputs at a glance
terraform output

# Specific outputs
terraform output -raw n8n_url
terraform output -raw appgw_public_ip
terraform output -raw aks_cluster_name
terraform output -raw public_dns_zone_name
terraform output -json public_dns_zone_name_servers

# Sensitive outputs
terraform output -raw tls_self_signed_cert_secret_id  # Submodule cert URI (consumed by App Gateway listener)
terraform output -raw -module=n8n encryption_key
```

To wire kubectl after retrieving the cluster name:

```bash
az aks get-credentials \
  --name "$(terraform output -raw aks_cluster_name)" \
  --resource-group "$(terraform output -raw aks_resource_group)"

kubectl -n n8n get pods
```

## Teardown

```bash
terraform destroy
```

`terraform destroy` removes the self-signed certs, the shared Key Vault (with soft-delete retention 7 days), and tears down the workload + network. The DNS zone the example created is destroyed too — remember to remove the corresponding NS records at your registrar afterwards.

## See also

- [`../../modules/tls-self-signed/README.md`](../../modules/tls-self-signed/) — the submodule reference.
- [`../../README.md`](../../README.md) — root-module reference.
- [`../complete-letsencrypt/`](../complete-letsencrypt/) — sibling example for Let's Encrypt mode.
- [`../complete/`](../complete/) — the recommended single-apply default example (also self-signed via the same submodule).

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_infra"></a> [infra](#module\_infra) | ../../modules/infra | n/a |
| <a name="module_tls_self_signed"></a> [tls\_self\_signed](#module\_tls\_self\_signed) | ../../modules/tls-self-signed | n/a |
| <a name="module_workload"></a> [workload](#module\_workload) | ../../modules/workload | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_dns_a_record.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dns_a_record) | resource |
| [azurerm_dns_zone.public](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dns_zone) | resource |
| [azurerm_key_vault.shared](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_resource_group.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.redis_pe](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.spare](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_virtual_network.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags to apply to the example's resource group, VNet, and shared Key Vault. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase prefix used in every resource name. 2–12 alnum-lowercase chars (Azure storage-account naming is the binding constraint). | `string` | `"n8nlab"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region to deploy into (e.g. eastus, westeurope, australiaeast). | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must be a subdomain of (or equal to) var.public\_dns\_zone\_name — the example creates an Azure DNS zone with that name and the n8n module writes the A-record for n8n\_domain into it. The self-signed cert's CN is set to this same value. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing. | `string` | n/a | yes |
| <a name="input_public_dns_zone_name"></a> [public\_dns\_zone\_name](#input\_public\_dns\_zone\_name) | Name of the public Azure DNS zone the example creates (e.g. example.com). var.n8n\_domain must resolve inside this zone. After the first apply, copy the zone's name-server records (terraform output -json public\_dns\_zone\_name\_servers) into your registrar so the world can resolve n8n\_domain to the App Gateway public IP — Terraform alone cannot delegate NS upstream. | `string` | n/a | yes |
| <a name="input_tls_validity_period_hours"></a> [tls\_validity\_period\_hours](#input\_tls\_validity\_period\_hours) | Lifetime of the self-signed certificate the submodule issues, in hours. Defaults to 8760 (1 year). The cert auto-renews via Terraform when within `early_renewal_hours` (30 days) of expiry — re-running terraform apply within that window regenerates the key + cert and re-imports them into the shared Key Vault. Self-signed mode is intended for lab / internal-only use; production deployments should use the sibling `examples/complete-letsencrypt/` example or the BYO `custom_pfx` path on the root module. | `number` | `8760` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster — pass to `az aks get-credentials --name <this> --resource-group <aks_resource_group>` (sourced from `module.infra.aks_cluster_name`). |
| <a name="output_aks_resource_group"></a> [aks\_resource\_group](#output\_aks\_resource\_group) | Name of the workload resource group the AKS cluster (and every other module.infra-owned resource) lives in. Distinct from the example's network resource group, which holds the VNet / DNS zone / shared KV. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Static public IP address of the Application Gateway (sourced from `module.infra.appgw_public_ip_address`). The example also writes the A-record automatically — surfaced here for sanity-checking. |
| <a name="output_n8n_namespace"></a> [n8n\_namespace](#output\_n8n\_namespace) | Kubernetes namespace n8n is deployed into (sourced from `module.workload.n8n_namespace`). Use `kubectl -n <this>` for operational queries. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL n8n is reachable at once DNS delegation is in place (sourced from `module.workload.n8n_url`). |
| <a name="output_public_dns_zone_name"></a> [public\_dns\_zone\_name](#output\_public\_dns\_zone\_name) | Name of the public Azure DNS zone the example created. Identical to var.public\_dns\_zone\_name — exposed so callers can pipe `terraform output` straight into automation. |
| <a name="output_public_dns_zone_name_servers"></a> [public\_dns\_zone\_name\_servers](#output\_public\_dns\_zone\_name\_servers) | Authoritative name servers Azure assigned to the public DNS zone. Configure these at your registrar as the NS records for var.public\_dns\_zone\_name to complete the upstream delegation. Run `terraform output -json public_dns_zone_name_servers` after apply. |
| <a name="output_tls_self_signed_cert_secret_id"></a> [tls\_self\_signed\_cert\_secret\_id](#output\_tls\_self\_signed\_cert\_secret\_id) | Versioned Key Vault Secret URI for the submodule-issued self-signed cert. Sensitive because it embeds the certificate's secret-version segment, which a holder of read access to the vault can use to fetch the private key. |
<!-- END_TF_DOCS -->
