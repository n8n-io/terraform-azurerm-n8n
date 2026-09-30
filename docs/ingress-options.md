# Ingress options for n8n on AKS

This module's default ingress (`create_ingress = true`) is an **Application Gateway v2** driven by the **AGIC** (Application Gateway Ingress Controller) add-on. This doc explains why, when an alternative fits better, and the routing contract any replacement ingress (`create_ingress = false`) must reproduce.

## Why Application Gateway v2 with AGIC

- **Maturity and parity.** AGIC on Application Gateway v2 is Microsoft's longest-supported AKS ingress path with GA support for WAF policies, private (internal) frontends, TLS offload from Key Vault, and connection draining — every capability this module's `ingress.tf` depends on.
- **Private-frontend support.** The module supports `appgw_frontend_mode = "internal"` for admin-only or VPN-gated deployments. Application Gateway v2 supports a fully private frontend IP today.
- **AGIC's declarative model matches this module's shape.** AGIC reads a standard `kubernetes_ingress_v1` object and reconciles Application Gateway listeners/rules from it, which is what lets this module render ordered path rules from Terraform without an Application Gateway-specific CRD.

## Alternatives, and where they do or don't fit

Microsoft has been moving AKS ingress guidance toward two newer paths. Both are worth evaluating for a replacement (`create_ingress = false`) ingress, with one hard blocker for this module's private-frontend use case:

- **Application Gateway for Containers** ([Microsoft Learn: Application Gateway for Containers components](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview)) is Microsoft's positioned successor to AGIC: it uses a dedicated ALB Controller and Gateway API resources instead of a `kubernetes_ingress_v1` object, and it supports faster reconciliation and per-backend traffic splitting AGIC does not.
  - **Current limitation, checked 2026-09-30:** Application Gateway for Containers does not support a private (internal-only) frontend IP — every frontend is a public IP or an existing internal/external Azure Load Balancer, not a fully private Application Gateway listener. This rules it out as a drop-in replacement for any deployment using `appgw_frontend_mode = "internal"`. Re-check [Microsoft Learn: Application Gateway for Containers components](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview) before relying on this constraint — it may change.
- **The application routing add-on with the Kubernetes Gateway API** ([Microsoft Learn: Application routing add-on with the Kubernetes Gateway API](https://learn.microsoft.com/en-us/azure/aks/app-routing-add-on)) is an AKS-managed NGINX-based ingress controller, exposed through standard Gateway API `Gateway`/`HTTPRoute` objects. Microsoft's AKS release notes state the legacy **NGINX-based application routing add-on's support ends after November 2026**; the Gateway API mode is its replacement. This add-on is a reasonable choice for a caller who wants an AKS-managed controller without standing up AGIC or Application Gateway for Containers themselves, and it does support internal (private) listeners via a private Azure Load Balancer, unlike Application Gateway for Containers.

Neither alternative is wired into this module. Both are valid choices for a caller-owned ingress under `create_ingress = false`, provided the caller reproduces the routing contract below.

## The routing contract for a replacement ingress

Whatever ingress technology a caller chooses under `create_ingress = false`, three behaviors the module's own Ingress provides must be reproduced or n8n's webhook and multi-main behavior breaks silently:

### 1. Path-prefix ordering

Use the `n8n_test_webhook_path_prefixes` and `n8n_webhook_path_prefixes` module outputs, not hardcoded strings — they track whatever prefixes the pinned n8n/chart version exposes.

Route, in this order, for every host in `n8n_domain` and `n8n_additional_domains`:

1. Every prefix in `n8n_test_webhook_path_prefixes` (editor test-mode: `/webhook-test`, `/form-test`, `/mcp-test`) to `n8n_service_name` (the main Service).
2. Every prefix in `n8n_webhook_path_prefixes` (production webhooks: `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, `/mcp`) to `n8n_webhook_service_name` (the webhook-processor Service).
3. `/` (catch-all) to `n8n_service_name`.

This order matters because most Azure ingress controllers, including AGIC, render `Prefix`-typed rules as literal string-prefix matches evaluated in declared order: `/webhook*` also matches `/webhook-test`, so routing `/webhook-test` to the main Service requires that rule to be declared first. See [`examples/customer-managed-cluster/ingress.tf`](../examples/customer-managed-cluster/ingress.tf) and [`examples/customer-managed-everything/ingress.tf`](../examples/customer-managed-everything/ingress.tf) for a caller-owned AGIC Ingress that reproduces this ordering, and [`examples/split-ingress/`](../examples/split-ingress/) for a public webhook-only gateway paired with a private admin gateway.

### 2. Session affinity

The module's own Ingress sets `appgw.ingress.kubernetes.io/cookie-based-affinity = "true"` (see `locals.tf`) to pin each client to one main pod for the life of a session. In multi-main mode (more than one main replica), n8n's editor session and in-memory auth state are not shared across main pods, so a load-balanced request that lands on a different main than the one that started the session sees intermittent authentication failures.

A replacement ingress must configure the equivalent of session affinity for traffic routed to `n8n_service_name`:

- **AGIC (`kubernetes_ingress_v1`):** `appgw.ingress.kubernetes.io/cookie-based-affinity = "true"` on the Ingress, as done in `examples/customer-managed-cluster/ingress.tf` and `examples/customer-managed-everything/ingress.tf`.
- **Application Gateway for Containers / Gateway API:** configure session affinity on the corresponding `HTTPRoute`/backend policy for the main Service. The exact resource is provider-specific; consult the chosen controller's session-affinity or sticky-session documentation.

Webhook traffic routed to `n8n_webhook_service_name` does not need session affinity — webhook processors are stateless with respect to the queue.

### 3. `N8N_PROXY_HOPS`

n8n uses `N8N_PROXY_HOPS` (Express's `trust proxy` hop count) to determine which `X-Forwarded-*` header to trust for the client's real IP and protocol. The module renders this as `var.n8n_proxy_hops` (default `1`, correct for the module's own single-hop Application Gateway).

A caller-owned ingress topology with more than one hop in front of the cluster — for example an Application Gateway for Containers ALB behind an additional external load balancer, or a CDN in front of the ingress — must set `var.n8n_proxy_hops` to the caller's actual hop count. Too low a value causes n8n to trust the wrong header and misattribute client IPs and TLS termination state; too high a value lets a client spoof `X-Forwarded-For` past the trusted boundary.
