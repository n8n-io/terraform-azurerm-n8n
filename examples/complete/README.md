# Complete example

End-to-end deployment of the `terraform-azurerm-n8n` module, including the VNet and 5 subnets it depends on AND a public Azure DNS zone with the `var.n8n_domain` A-record wired automatically. Use this example as your starting point for a fresh Azure subscription.

## What it creates

- A dedicated networking resource group with a VNet (`10.0.0.0/16`) and 5 subnets:
  - `aks` — `/22`, the AKS node pool (Azure CNI)
  - `appgw` — `/24`, the Application Gateway (must be dedicated)
  - `postgres` — `/24`, delegated to `Microsoft.DBforPostgreSQL/flexibleServers` (VNet-injected Flexible Server)
  - `redis-pe` — `/24`, with `private_endpoint_network_policies = "Disabled"` (Redis Cache private endpoint)
  - `spare` — `/24`, reserved for future Phase 2 work
- A public `azurerm_dns_zone` (`var.public_dns_zone_name`) into which the n8n module writes the A-record for `var.n8n_domain` pointing at the App Gateway public IP.
- A shared `azurerm_key_vault` (`<friendly_name_prefix>-tls-kv`) holding the self-signed listener cert. The n8n module's `azurerm_role_assignment.appgw_kv_secrets_user` grants the App Gateway UAMI runtime read access on this vault.
- The self-signed listener cert via `modules/tls-self-signed/` (lab default; browsers will warn). For production-grade Let's Encrypt certs see [`../complete-letsencrypt/`](../complete-letsencrypt/); for an explicit self-signed-only deployment see [`../complete-self-signed/`](../complete-self-signed/).
- Everything the `terraform-azurerm-n8n` module creates: AKS cluster, PostgreSQL Flexible Server (private), Redis Cache (private endpoint), Storage Account + File Share, Application Gateway (WAF_v2) + AGIC addon, KEDA, and the n8n Helm release.

## Prerequisites

- **Terraform** >= 1.9
- **Azure CLI** >= 2.50, signed in to the target subscription (`az login`)
- **kubectl** >= 1.30 (for post-apply operational access)
- **Helm** >= 3.14 (only required if you tail Helm release status; not needed for apply itself)
- An n8n Enterprise license key (https://n8n.io/pricing)
- A registered domain whose NS records you can edit at your registrar — the example creates a public Azure DNS zone for it, but the upstream NS delegation must be set at the registrar by hand (Terraform can't do this — it lives outside Azure)
- The principal running `terraform apply` needs Key Vault Certificates Officer (or equivalent access policy) on the shared Key Vault the example creates — the inline access_policy in main.tf grants the running operator the necessary cert/secret control

## Apply

The example is single-apply: one `terraform apply` provisions the VNet, AKS cluster, Postgres, Redis, Application Gateway, KEDA, the n8n Helm release, the public DNS zone, the shared Key Vault, the self-signed cert (imported into the vault), AND the A-record for `var.n8n_domain`. No manual DNS step in the middle.

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set public_dns_zone_name, n8n_domain, n8n_license_key

terraform init
terraform apply
```

Allow ~3 minutes after apply for the App Gateway listener to converge once AGIC publishes the Ingress.

### Delegate the zone at your registrar

The example creates a fresh Azure DNS zone, but Azure can't tell your domain registrar that it's authoritative — that delegation lives upstream. After the first apply, copy the zone's NS records into your registrar's DNS settings for `var.public_dns_zone_name`:

```bash
terraform output -json public_dns_zone_name_servers
```

Paste the four NS hostnames (one per line, without trailing dot) into your registrar's NS records for the zone. Propagation typically completes in 5–60 minutes — track it with `dig NS <var.public_dns_zone_name>`.

For zones whose NS records are already delegated to Azure DNS at the registrar (e.g. you've previously hosted this zone in Azure), set `var.public_dns_zone_name` to that zone — the example will create a NEW zone with the same name in the example's network RG, which lives alongside any pre-existing zone but is the one Terraform manages here. (To re-use a pre-existing Azure DNS zone instead, drop the `azurerm_dns_zone.public` resource from `main.tf` and pass the existing zone's name + RG directly to the module.)

## Retrieve outputs

```bash
# All non-sensitive outputs at a glance
terraform output

# Specific outputs
terraform output -raw n8n_url                            # https://<n8n_domain>
terraform output -raw appgw_public_ip                    # public IP the A-record points at
terraform output -raw aks_cluster_name                   # for `az aks get-credentials`
terraform output -raw public_dns_zone_name               # the zone the example created
terraform output -json public_dns_zone_name_servers      # NS records to set at the registrar

# Sensitive outputs (must use -raw, accessed through the module)
terraform output -raw -module=n8n kube_config_raw > kubeconfig
terraform output -raw -module=n8n encryption_key         # back this up in a password manager
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

The module's `cleanup.tf` runs a destroy-time `time_sleep.wait_for_aks_drain` gate (default 120 s) between the Helm uninstall and the namespace delete, absorbing the Azure Files CIFS detach window. The shared Key Vault, the DNS zone, and the network RG are destroyed too — remember to remove the corresponding NS records at your registrar afterwards. If `destroy` hangs on the App Gateway, the private endpoints, or the file-share detach, see [`../../docs/troubleshooting.md`](../../docs/troubleshooting.md) and [`../../docs/destroy-cleanup.md`](../../docs/destroy-cleanup.md).

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
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.13 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.13 |

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
| [azurerm_role_assignment.kv_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_subnet.aks](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.redis_pe](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.spare](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_virtual_network.n8n](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [time_sleep.kv_operator_rbac_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_common_tags"></a> [common\_tags](#input\_common\_tags) | Additional Azure tags applied to the example's resource groups, VNet, DNS zone, shared Key Vault, AND merged into `local.common_tags` inside both `module.infra` and `module.workload`. | `map(string)` | `{}` | no |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Lowercase prefix used in every resource name. 2–12 alnum-lowercase chars (Azure storage-account naming is the binding constraint). Flowed verbatim into `module.infra` and `module.workload` so the same prefix appears across both tiers. | `string` | `"n8nlab"` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region to deploy into (e.g. eastus, westeurope, australiaeast). Flowed into both `module.infra` and the example-owned resource groups, VNet, DNS zone, and shared Key Vault. | `string` | `"eastus"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name n8n is served on (e.g. n8n.example.com). Must be a subdomain of (or equal to) var.public\_dns\_zone\_name — the example creates an Azure DNS zone with that name and the example's `azurerm_dns_a_record.n8n` writes the A-record for n8n\_domain into it pointing at `module.infra.appgw_public_ip_address`. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Flowed into `module.workload` as the chart's `n8n.encryption.licenseActivationKey` value. | `string` | n/a | yes |
| <a name="input_public_dns_zone_name"></a> [public\_dns\_zone\_name](#input\_public\_dns\_zone\_name) | Name of the public Azure DNS zone the example creates (e.g. example.com). var.n8n\_domain must resolve inside this zone. After the first apply, copy the zone's name-server records (terraform output -json public\_dns\_zone\_name\_servers) into your registrar so the world can resolve n8n\_domain to the App Gateway public IP — Terraform alone cannot delegate NS upstream. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_cluster_name"></a> [aks\_cluster\_name](#output\_aks\_cluster\_name) | Name of the AKS cluster — pass to `az aks get-credentials --name <this> --resource-group <aks_resource_group>` (sourced from `module.infra.aks_cluster_name`). |
| <a name="output_aks_resource_group"></a> [aks\_resource\_group](#output\_aks\_resource\_group) | Name of the workload resource group the AKS cluster (and every other module.infra-owned resource) lives in. Distinct from the example's network resource group, which holds the VNet / DNS zone / shared KV. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Static public IP address of the Application Gateway (sourced from `module.infra.appgw_public_ip_address`). The example also writes the A-record automatically — surfaced here for sanity-checking and for operators who want to set NS at the registrar before DNS converges. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Ready-to-eval shell command that points kubectl at this AKS cluster (e.g. `az aks get-credentials --name <cluster> --resource-group <rg> --overwrite-existing`). The smoke-test harness in `tests/scripts/smoke-test.sh` reads this output to switch contexts automatically when the operator is juggling several clusters in `~/.kube/config`. Mirrors the `kubectl_config_command` output exposed by the AWS sibling's `examples/complete/`. |
| <a name="output_n8n_namespace"></a> [n8n\_namespace](#output\_n8n\_namespace) | Kubernetes namespace n8n is deployed into (sourced from `module.workload.n8n_namespace`). Use `kubectl -n <this>` for operational queries. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL n8n is reachable at once DNS delegation is in place (sourced from `module.workload.n8n_url`). |
| <a name="output_public_dns_zone_name"></a> [public\_dns\_zone\_name](#output\_public\_dns\_zone\_name) | Name of the public Azure DNS zone the example created. Identical to var.public\_dns\_zone\_name — exposed so callers can pipe `terraform output` straight into automation. |
| <a name="output_public_dns_zone_name_servers"></a> [public\_dns\_zone\_name\_servers](#output\_public\_dns\_zone\_name\_servers) | Authoritative name servers Azure assigned to the public DNS zone. Configure these at your registrar as the NS records for var.public\_dns\_zone\_name to complete the upstream delegation. Run `terraform output -json public_dns_zone_name_servers` after apply. |
| <a name="output_tls_cert_secret_id"></a> [tls\_cert\_secret\_id](#output\_tls\_cert\_secret\_id) | Versioned Key Vault Secret URI of the App Gateway listener cert that `module.tls_self_signed` issued and `azurerm_key_vault.shared` holds. Identical to the value passed into `module.infra` and `module.workload` as `app_gateway_tls_cert_secret_id`. Marked sensitive — possession of the URI plus vault-read rights is enough to fetch the private key. |
<!-- END_TF_DOCS -->
