# Ingress options for n8n on AKS

This module's default ingress (`create_ingress = true`) is an **Application Gateway v2** driven by the **AGIC** (Application Gateway Ingress Controller) add-on. This doc explains why, when an alternative fits better, what changes when you switch an existing deployment, and the contract any replacement ingress (`create_ingress = false`) must reproduce.

## Why Application Gateway v2 with AGIC

- **Maturity.** AGIC on Application Gateway v2 is Microsoft's longest-supported AKS ingress path. It has GA support for private (internal) frontends, TLS offload from Key Vault, connection draining, and WAF policies. The module's `ingress.tf` uses TLS offload and connection draining in every configuration, and a private frontend when `appgw_frontend_mode = "internal"`. WAF is optional: with the default `appgw_sku_name = "WAF_v2"` the module attaches a WAF policy, and with `Standard_v2` it attaches none.
- **Private-frontend support.** The module supports `appgw_frontend_mode = "internal"` for admin-only or VPN-gated deployments. Application Gateway v2 supports a fully private frontend IP today.
- **A declarative model that fits this module.** AGIC reads a standard `kubernetes_ingress_v1` object and reconciles Application Gateway listeners and rules from it. This lets the module render ordered path rules from Terraform without an Application Gateway-specific custom resource.

## Alternatives, and where they fit

Microsoft is moving AKS ingress guidance toward two newer paths. Both are worth evaluating for a replacement ingress under `create_ingress = false`. One of them has a hard blocker for private deployments.

- **Application Gateway for Containers** ([components][agc-components]) is Microsoft's successor to AGIC. It uses a dedicated ALB Controller that watches both `Ingress` and Gateway API resources, and it supports faster reconciliation and per-backend traffic splitting that AGIC does not.
  - **Current limitation, checked 2026-10-07:** each Application Gateway for Containers frontend is an Azure-generated FQDN, and Microsoft states that private IP addresses aren't currently supported ([components][agc-components]). This rules it out as a replacement for any deployment that uses `appgw_frontend_mode = "internal"`. Re-check the components page before you rely on this limit, because it may change.
- **The application routing add-on with the Kubernetes Gateway API** ([Microsoft Learn][app-routing-gateway]) is an AKS-managed Gateway API implementation exposed through standard `Gateway` and `HTTPRoute` objects. Its Gateway API mode is different from the add-on's older NGINX-based mode: it runs a managed Istio control plane (`istiod`) that provisions Envoy as the data-plane proxy for each `Gateway`. It is not the full Istio service mesh, so there is no sidecar injection and there are no Istio CRDs for workloads. Microsoft's AKS release notes state that support for the NGINX-based application routing add-on ends after November 2026, and the Gateway API mode replaces it. This add-on suits a caller who wants an AKS-managed controller without running AGIC or Application Gateway for Containers. It supports internal (private) listeners through a private Azure Load Balancer.

Neither alternative is wired into this module. Both are valid for a caller-owned ingress under `create_ingress = false`, as long as the caller reproduces the contract below.

## Before you set `create_ingress = false`

### Switching an existing deployment destroys module-owned ingress resources

On a deployment that already ran with `create_ingress = true`, setting the flag to `false` makes Terraform plan to:

- destroy the Application Gateway (`azurerm_application_gateway.n8n`),
- destroy its static public IP when `appgw_frontend_mode = "public"` (`azurerm_public_ip.appgw`), so the public IP address changes,
- destroy the module-created WAF policy, when the module created one,
- destroy the subnet NSG and its association with `appgw_subnet_id`,
- destroy the module's Kubernetes `Ingress`, the AGIC role assignments, the Application Gateway TLS identity, and the Key Vault role assignment,
- destroy the public or private Azure DNS A-records, when a zone ID and record toggle are set,
- remove the AGIC add-on from the AKS cluster in place.

Clients that still resolve the old address lose access once the gateway is gone. Setting the flag back to `true` creates a new gateway and a new public IP. It does not restore the old address.

To switch with minimal downtime:

1. Build the replacement ingress while the module's gateway still serves traffic. Give it its own frontend and a certificate it can serve before DNS moves, and test it against its own address.
2. Move DNS to the new address. If you own DNS outside the module, update your records. If the module manages the records, transfer ownership first, because a zone cannot hold two record sets with the same name and type:
   1. In one change, add caller-owned `azurerm_dns_a_record` (or `azurerm_private_dns_a_record`) resources that match the module's records (same zone, name, TTL, and current target), and add one `moved` block per host. For example, `from = module.n8n.azurerm_dns_a_record.n8n["n8n.example.com"]` and `to = azurerm_dns_a_record.n8n["n8n.example.com"]`. In the same change, set the module's record toggle to `false` **and** set its zone ID to `null`: `create_public_dns_record = false` with `public_dns_zone_id = null`, or `create_private_dns_record = false` with `private_dns_zone_id = null`. The module's validation rejects a zone ID while its toggle is `false`, so keep the zone coordinates on the caller-owned records instead.
   2. Save the plan and review it. It must show only moves, with no record created or destroyed. Apply that saved plan.
   3. Point the caller-owned records at the new frontend, wait for the old TTL to expire, and confirm traffic on the old gateway has stopped. An A record can only target an IP address. If the replacement frontend is an FQDN, as every Application Gateway for Containers frontend is ([components][agc-components]), changing the record type (normally A to CNAME, for a name that is not the zone apex) replaces the record. Review that change as its own saved plan, and plan the zone apex separately, because a CNAME cannot sit there.
3. Set `create_ingress = false`. Save the plan (`terraform plan -out=ingress-cutover.tfplan`), review every resource it destroys, and apply that saved plan.

If you cannot transfer DNS ownership, treat the switch as planned downtime: the module deletes its records in step 3, and the outage lasts until you recreate them and resolver caches expire.

Once `create_ingress = false`, the `appgw_*` inputs, `ingress_annotations`, and `app_gateway_keyvault_role_assignment_enabled` configure nothing. Restore their defaults, or Terraform warns through the `ingress_tuning_requires_module_managed_ingress` and `keyvault_role_assignment_requires_module_managed_ingress` checks. Set both DNS record toggles to `false` and their zone IDs (`public_dns_zone_id`, `private_dns_zone_id`) to `null`: a toggle left on creates no records and raises the `dns_requires_module_managed_ingress` warning, and the variable validation rejects a zone ID while its toggle is `false`.

### Settings to review when replacing ingress

The module's gateway and Ingress carry settings that the routing contract below does not cover. A replacement ingress does not get them automatically. Decide for each one whether you need it and how your controller expresses it:

| Setting | Module value | Where the module sets it |
| --- | --- | --- |
| Session affinity to the main Service | `cookie-based-affinity = "true"` | Ingress annotation, `local.appgw_ingress_default_annotations` in `locals.tf` |
| Request timeout | 300 s (AGIC default: 30 s) | Ingress annotation `request-timeout` |
| Connection draining | On, 30 s (AGIC default: off) | Ingress annotations `connection-draining`, `connection-draining-timeout` |
| HTTP to HTTPS redirect | On | Ingress annotation `ssl-redirect` |
| TLS certificate and policy | Key Vault secret from `app_gateway_tls_cert_secret_id`, `appgw_ssl_policy` (TLS 1.2 or later) | `azurerm_application_gateway.n8n`, `ingress.tf` |
| HTTP/2 | Off, because it intermittently resets the editor's initial asset burst | `azurerm_application_gateway.n8n`, `ingress.tf` |
| WAF | Optional. With `appgw_sku_name = "WAF_v2"` (the default), the module creates an OWASP 3.2 policy whose mode is `appgw_waf_mode`, or attaches `appgw_waf_policy_id`. With `Standard_v2`, no WAF policy | `ingress.tf` |
| Source restriction | `appgw_allowed_inbound_cidrs` on the gateway subnet NSG, covering editor and webhook paths | `azurerm_network_security_group.appgw`, `ingress.tf` |
| Frontend exposure | Public static IP or private-only frontend (`appgw_frontend_mode`) | `ingress.tf` |
| DNS | Optional public or private A-records | `dns.tf` |
| Proxy hop count | `n8n_proxy_hops`, default `1` | `N8N_PROXY_HOPS` in `n8n.tf` |

The caller-owned AGIC Ingress in [`examples/customer-managed-cluster/ingress.tf`](../examples/customer-managed-cluster/ingress.tf) and [`examples/customer-managed-everything/ingress.tf`](../examples/customer-managed-everything/ingress.tf) reproduces the annotation rows. For Application Gateway for Containers, session affinity and timeouts live in a `RoutePolicy` (Gateway API) or an `IngressExtension` (Ingress API) ([session affinity][agc-session-affinity]). Its default request timeout is 60 seconds and applies even while data is streaming. Gateway API `HTTPRoute` timeouts take precedence over a `RoutePolicy` timeout ([components][agc-components]).

## The routing contract for a replacement ingress

Whatever ingress technology you choose under `create_ingress = false`, reproduce three behaviors of the module's own Ingress. If you get any of them wrong, webhooks, multi-main editor sessions, or client-IP attribution break without an error.

### 1. Path-prefix ordering

Use the `n8n_test_webhook_path_prefixes` and `n8n_webhook_path_prefixes` module outputs, not hardcoded strings. These outputs list the prefixes this module version supports. They are static locals in `locals.tf`, fixed at the module's pinned chart version, not derived from the chart at plan time. If a future chart version adds or renames webhook or test-mode paths, the outputs and this doc must change with it.

Route, in this order, for every host in `n8n_domain` and `n8n_additional_domains`:

1. Every prefix in `n8n_test_webhook_path_prefixes` (editor test mode: `/webhook-test`, `/form-test`, `/mcp-test`) to `n8n_service_name` (the main Service).
2. Every prefix in `n8n_webhook_path_prefixes` (production webhooks: `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, `/mcp`) to `n8n_webhook_service_name` (the webhook-processor Service).
3. `/` (catch-all) to `n8n_service_name`.

The order matters for AGIC. AGIC renders `Prefix`-typed rules as string-prefix patterns that Application Gateway evaluates in declared order, so `/webhook*` also matches `/webhook-test`. Declaring the test-mode rules first keeps `/webhook-test` on the main Service. Controllers that implement Kubernetes `Prefix` or Gateway API `PathPrefix` matching by whole path segment, and prefer the longest match, do not have this problem, but the declared order above is correct for them too. See [`examples/customer-managed-cluster/ingress.tf`](../examples/customer-managed-cluster/ingress.tf) and [`examples/customer-managed-everything/ingress.tf`](../examples/customer-managed-everything/ingress.tf) for a caller-owned AGIC Ingress that reproduces this ordering, and [`examples/split-ingress/`](../examples/split-ingress/) for a public webhook-only gateway paired with a private admin gateway.

In a split topology like `examples/split-ingress`, the public gateway routes only the production webhook prefixes for its own webhook host and has no catch-all, so the editor stays on the private gateway.

### 2. Session affinity

n8n's [queue mode docs](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/enable-queue-mode#configuring-multi-main-setup) require every main process in a multi-main setup to run behind a load balancer with session persistence. The module's own Ingress sets `appgw.ingress.kubernetes.io/cookie-based-affinity = "true"` (see `locals.tf`) so each browser stays on one main pod for its editor requests and push connection.

A replacement ingress must configure the equivalent for traffic routed to `n8n_service_name`:

- **AGIC (`kubernetes_ingress_v1`):** `appgw.ingress.kubernetes.io/cookie-based-affinity = "true"` on the Ingress, as the caller-owned examples do.
- **Application Gateway for Containers:** a `sessionAffinity` block in a `RoutePolicy` for Gateway API, or in an `IngressExtension` for the Ingress API ([session affinity][agc-session-affinity]).
- **Other Gateway API controllers:** the controller's own session-persistence or sticky-session setting for the main Service.

Webhook traffic routed to `n8n_webhook_service_name` does not need session affinity. AGIC applies the annotation to every backend of the Ingress it is set on, so an Ingress that also routes webhook prefixes pins those too. That is harmless.

### 3. `N8N_PROXY_HOPS`

n8n passes `N8N_PROXY_HOPS` to Express's [`trust proxy`](https://expressjs.com/en/guide/behind-proxies.html) setting. The number decides which `X-Forwarded-For` entry n8n takes as the client IP. Any value of `1` or more also makes n8n honor `X-Forwarded-Proto`; the hop count does not change which protocol value n8n reads. The module renders `n8n_proxy_hops` (default `1`) on every n8n pod: main, worker, and webhook processor.

Count every proxy on the client's path that adds an `X-Forwarded-For` entry, whatever `create_ingress` is set to. HTTP proxies such as Application Gateway, Application Gateway for Containers ([components][agc-components]), Azure Front Door, or an in-cluster ingress controller add one. A layer 4 Azure Load Balancer adds none and does not count.

| Path to n8n | `n8n_proxy_hops` |
| --- | --- |
| Module or caller-owned Application Gateway only | `1` |
| Application Gateway for Containers only | `1` |
| Azure Front Door, then Application Gateway | `2` |
| Internal Azure Load Balancer, then an in-cluster ingress controller | `1` |
| Internal Azure Load Balancer straight to the n8n Services, no HTTP proxy | `0` |

Too low a value attributes every request to the nearest extra proxy's IP. Too high a value lets a client forge its IP: n8n trusts the hops you declare, so a client that reaches an inner proxy directly can put any address in `X-Forwarded-For` and n8n accepts it. A value above `1` is only safe when the inner proxy accepts traffic from the outer one alone, for example an Application Gateway that only accepts traffic from Front Door. At any value of `1` or more, the same applies to anything that bypasses the declared proxy chain. For example, a caller inside the cluster that reaches the n8n Services directly can set its own `X-Forwarded-For`. The value is one setting for every path, so every route to n8n (editor and webhook alike) must cross the same number of proxies.

**Known issue: Application Gateway v2 adds the client port.** Application Gateway v2 writes each `X-Forwarded-For` entry as `IP:port` ([Microsoft Learn][appgw-xff-port]), so n8n sees the client IP with the source port appended, for example `203.0.113.7:59936`. n8n logs an `ERR_ERL_INVALID_IP_ADDRESS` validation error from its rate limiter, and the per-IP login limit most likely keys on each source port instead of each client. The per-email login limit is not affected. This applies to the module's own gateway and to caller-owned AGIC gateways. A rewrite rule that sets `X-Forwarded-For` to `{var_add_x_forwarded_for_proxy}` removes the port and keeps any upstream entries. The module does not add one yet; see [#60](https://github.com/n8n-io/terraform-azurerm-n8n/issues/60).

[agc-components]: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/application-gateway-for-containers-components "Application Gateway for Containers components"
[agc-session-affinity]: https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/session-affinity "Session affinity overview for Application Gateway for Containers"
[app-routing-gateway]: https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api "Application routing add-on with the Kubernetes Gateway API"
[appgw-xff-port]: https://learn.microsoft.com/en-us/azure/application-gateway/rewrite-http-headers-url#remove-port-information-from-the-x-forwarded-for-header "Remove port information from the X-Forwarded-For header"
