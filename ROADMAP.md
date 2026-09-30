# Roadmap

This roadmap captures intent, not commitments. Items here are not on a
fixed timeline. See [`CHANGELOG.md`](./CHANGELOG.md) for what has
actually shipped.

## Phases

### Phase 1: Internal baseline

A minimal, lean Terraform module that is ready for publishing and
validated through n8n-internal testing.

### Phase 2: Lighthouse rollout

Publish the module and evaluate it through lighthouse customer
engagements, iterating early on real-world feedback.

### Phase 3: Multi-cloud parity

Keep this Azure module in step with the sibling AWS and GCP n8n modules,
reusing shared patterns for the Kubernetes workload layer.

## Candidate features

Features we may want to address along the way:

- Custom ENV variables via templates (SSO, Owner, etc.)

## Already shipped

Previously listed as candidates, now covered by the module or by n8n itself:

- **Install community packages via API.** `n8n_reinstall_missing_packages`,
  `n8n_community_packages_registry` and
  `n8n_community_packages_prevent_loading` expose the relevant n8n settings,
  and the API surface itself is n8n's, documented in the n8n docs.
- **Bring your own certificates.** `app_gateway_tls_cert_secret_id` takes a
  versioned Key Vault Secret URI for any certificate the caller already
  holds; `modules/tls-letsencrypt` and `modules/tls-self-signed` produce the
  same value when you want the module family to issue one.
- **Bring your own networking.** `vnet_id` and the per-service subnet IDs
  (`aks_subnet_id`, `postgres_subnet_id`, `redis_subnet_id`,
  `appgw_subnet_id`, `private_endpoint_subnet_id`) are required inputs, and
  the module creates no VNet or subnet.
