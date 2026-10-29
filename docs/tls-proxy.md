# TLS-inspecting and TLS-terminating proxies

A customer proxy can sit on either side of n8n, or both. The two sides are
independent inputs.

| Proxy position | What breaks without configuration | Module inputs | You still own |
| --- | --- | --- | --- |
| **Outbound** (n8n to the internet, TLS-inspecting) | Node rejects the proxy's re-signed certificates (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`) | `n8n_extra_ca_pem` for the proxy CA, plus `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` in `n8n_extra_env` | The proxy, its allow-list, and which hosts bypass it |
| **Inbound** (client to the ingress, TLS-terminating, WAF or CDN) | n8n attributes the client to the wrong proxy when the hop count is too low | `n8n_proxy_hops`; `app_gateway_tls_cert_secret_id` for a private-CA origin certificate; `n8n_webhook_url` if the public host differs | The proxy's certificate, its trust of the origin certificate, forwarding `X-Forwarded-For` / `X-Forwarded-Proto` |
| **Both** | Both rows | Set both groups | Both |

## Outbound: trust the proxy's CA

```hcl
n8n_extra_ca_pem = file("${path.module}/proxy-ca.pem") # certificates only

n8n_extra_env = [
  { name = "HTTPS_PROXY", value = "http://proxy.corp.example:3128" },
  { name = "HTTP_PROXY", value = "http://proxy.corp.example:3128" },
  # Keep cluster-internal and Azure private-endpoint traffic off the proxy.
  { name = "NO_PROXY", value = "localhost,127.0.0.1,.svc,.cluster.local,.privatelink.postgres.database.azure.com,.blob.core.windows.net" },
]
```

- The PEM is stored in a module-managed Secret (`n8n-ca-bundle-secret`) and mounted
  read-only at `/etc/n8n-certs/ca-bundle.crt` on the main, worker, and
  webhook-processor pods. `NODE_EXTRA_CA_CERTS` points at it. While the input
  is set, `NODE_EXTRA_CA_CERTS` is rejected in `n8n_extra_env`,
  `n8n_worker_extra_env`, and pool `extra_env`; the volume name `ca-bundle`
  and that mount path are reserved.
- Node reads one file. Azure Managed Redis chains to a public root, so the
  module has no CA of its own to merge.
- Changing the PEM rolls every n8n pod, worker pools included, through a
  `checksum/extra-ca` pod annotation, because Node reads the file only at
  start.
- Setting the input back to `null` deletes the Secret before the Helm update
  that drops the mount. Old pods keep serving but can log `FailedMount`
  events until the rollout replaces them, and an old pod rescheduled in that
  window stays in `ContainerCreating`. Plan the removal for a quiet period. The module does not use
  `create_before_destroy` on this Secret: Terraform would propagate it to the
  namespace, the AKS cluster, and the node pools, and a later forced
  replacement of any of them would then fail on the fixed name.
- A Helm rollback after a failed upgrade does not restore the previous PEM:
  the Secret is managed by Terraform, not Helm. To go back, set the previous
  PEM in Terraform and apply.
- Private keys are rejected at plan time.
- An authenticated proxy takes credentials in the URL
  (`http://user:password@proxy.corp.example:3128`). `n8n_extra_env` values are
  plain text in Terraform state and Helm values.

### Task-runner sidecar

The module does not deliver the CA to the task-runner sidecar: the chart
mounts only the launcher config into it, and its `extraVolumeMounts` apply to
the n8n container only. Requests from a Code node through
`this.helpers.httpRequest` are made by the n8n process, which trusts the
bundle. A runner workload that needs the CA itself needs a custom runner image
(`n8n_task_runner_image_repository` / `n8n_task_runner_image_tag`) with the CA
baked in and a matching `n8n_task_runner_custom_config` launcher configuration
that allows `NODE_EXTRA_CA_CERTS`. This path is not tested against this module.

## Inbound: a proxy in front of the ingress

```hcl
n8n_proxy_hops = 2 # customer proxy + Application Gateway
```

- `n8n_proxy_hops` (default `1`) sets `N8N_PROXY_HOPS` on every role. Count
  every proxy that adds an `X-Forwarded-For` entry; see
  [`ingress-options.md`](./ingress-options.md#3-n8n_proxy_hops).
- For a proxy that verifies the origin certificate against a private CA,
  supply a certificate from that CA through `app_gateway_tls_cert_secret_id`
  (the `modules/tls-self-signed` and `modules/tls-letsencrypt` helpers produce
  this value).
- The module cannot configure the proxy. It must send `X-Forwarded-For` and
  `X-Forwarded-Proto`, and its `Host` header must match the hostname the
  gateway serves.
- The editor's live updates use a WebSocket on `/rest/push`. The proxy must
  forward `Upgrade` / `Connection` (nginx needs `proxy_http_version 1.1` and
  `proxy_set_header Upgrade $http_upgrade`), and the browser `Origin` must
  match the `Host` the proxy forwards, or n8n closes it with code 1008.
  n8n pings every 60 seconds; keep the proxy idle timeout above that.
