# PostgreSQL TLS modes and certificate verification

Both the module-managed and external PostgreSQL paths connect over TLS by
default, but `require` (the default on both paths) only encrypts the
connection: it does not check that the certificate the server presents
belongs to the host n8n dialed. `verify-ca` and `verify-full` close that gap
by validating the certificate against a trusted CA.

n8n's Postgres driver (`pg`/node-postgres) does not expose libpq's
distinction between `verify-ca` (trust the certificate chain, skip the
hostname check) and `verify-full` (trust the chain and check the hostname).
Setting `ssl.rejectUnauthorized` on the underlying Node TLS socket always
performs both the chain and the hostname check. The module renders
`postgres_managed_ssl_mode` / `postgres_external_ssl_mode` into that single
`rejectUnauthorized` flag (`true` for both `verify-ca` and `verify-full`,
`false` otherwise — see `n8n.tf`'s `database.ssl.rejectUnauthorized`), so
selecting `verify-ca` here does not get you a weaker, hostname-check-skipping
mode: it renders identical settings to `verify-full` and n8n always checks
the hostname once either mode is selected. Pick either name for
documentation/audit purposes; the connection's actual behavior does not
differ between them.

## Selecting a mode

- `postgres_managed_ssl_mode` controls the module-managed Flexible Server
  path (`create_database = true`, the default). Azure Database for
  PostgreSQL Flexible Server enforces TLS on every connection, so this input
  only accepts `require`, `verify-ca`, or `verify-full` — `disable`,
  `allow`, and `prefer` would never apply and are rejected at plan time.
- `postgres_external_ssl_mode` controls the external path
  (`create_database = false`) and accepts the full PostgreSQL set
  (`disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`),
  since an external server's TLS posture is the caller's choice. `allow` and
  `prefer` are accepted for compatibility with PostgreSQL's `sslmode` naming,
  but the module has no plaintext-fallback path: both render
  `database.ssl.enabled = true` on the Helm chart (any mode other than
  `disable` does), so the connection is always encrypted the same as
  `require`. There is no way to request "encrypt if the server supports it,
  otherwise connect in plaintext" through this module; use `disable` for an
  unencrypted connection or `require`/`verify-ca`/`verify-full` for an
  encrypted one.

Both inputs feed `local.postgres_connection.ssl_mode` (`database.tf`), which
the n8n Helm chart's `database.ssl.enabled` / `database.ssl.rejectUnauthorized`
values derive from. The pinned n8n Helm chart (`1.13.0`) renders
`database.ssl.enabled` into a ConfigMap key named `DB_POSTGRESDB_SSL`, but
n8n only reads `DB_POSTGRESDB_SSL_ENABLED`
([n8n-io/n8n-hosting#175](https://github.com/n8n-io/n8n-hosting/pull/175)
upstream) — the chart's own value alone leaves the connection plaintext
regardless of the selected mode. The module works around this by also
setting `DB_POSTGRESDB_SSL_ENABLED` directly through `config.extraEnv`
(`locals.tf`'s `n8n_postgres_ssl_enabled_env`) whenever the effective
`ssl_mode` is not `disable`, independent of chart version.

## Supplying a CA bundle for `verify-ca` / `verify-full`

`verify-ca` and `verify-full` both require n8n to trust the certificate
authority that signed the server's certificate. Set `postgres_ssl_ca_pem` to
a PEM-encoded CA bundle to pass it straight through to the chart's native
`database.ssl.ca` value, which the chart renders into its own ConfigMap and
injects as `DB_POSTGRESDB_SSL_CA` on every main, worker, and
webhook-processor pod. This applies to both the managed and external paths —
a caller pointing at an external server behind the same CA hierarchy can use
it too.

```hcl
postgres_managed_ssl_mode = "verify-full"
postgres_ssl_ca_pem       = file("${path.module}/azure-postgres-root-cas.pem")
```

If `postgres_ssl_ca_pem` is left null, `verify-ca` / `verify-full` still work
as long as the pod image's own default trust store (Node's bundled CA list)
already trusts the server's issuing CA. Azure Database for PostgreSQL
Flexible Server's certificates chain to
[DigiCert Global Root G2](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-networking-ssl-tls#tls-and-ssl-versions-and-supported-ciphers)
and, on servers not yet migrated, the retiring
[Microsoft RSA Root Certificate Authority 2017](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-networking-ssl-tls). Both are
widely trusted roots, so many Node-based images already carry them — verify
against your actual pod image rather than assuming either way. Setting
`postgres_ssl_ca_pem` with the exact bundle Microsoft publishes removes that
uncertainty and survives a future CA rotation without depending on the image's
bundled trust store being current.

An advisory (non-blocking) `check` in `database.tf`
(`postgres_ssl_ca_requires_verify_mode`) warns if `postgres_ssl_ca_pem` is
set while the effective `ssl_mode` is `disable`, `allow`, or `prefer`: the
chart still receives the value, but n8n never reads it in those modes.

## Azure's CA rotation

Microsoft periodically rotates the root and intermediate CAs Azure Database
for PostgreSQL Flexible Server uses; see
[Azure's TLS/SSL certificate rotation guidance](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-networking-ssl-tls)
for the current schedule and the combined bundle Microsoft publishes. If you
pin `postgres_ssl_ca_pem` to a specific bundle, track that page and refresh
the input before the old CA's validity window closes, or `verify-ca` /
`verify-full` connections will start failing closed once the server rolls to
a certificate signed by a CA your bundle does not include. `require` mode
(the default) is unaffected by CA rotation since it never validates the
certificate chain.

## Upgrading an existing deployment

Changing `postgres_managed_ssl_mode` or `postgres_external_ssl_mode` only
changes what n8n's application containers send as connection parameters —
it does not recreate the PostgreSQL server itself, and a Helm-only rollout
applies the new value on the next pod restart. There is no queue-draining or
downtime requirement for this change specifically. If you add
`postgres_ssl_ca_pem` at the same time, the new chart-rendered ConfigMap
entry also lands as a rolling pod update.

The one failure mode to check before switching to `verify-full`: confirm the
CA bundle you supply (or the pod image's default trust store) actually
covers the certificate chain your server currently presents. Test in a
non-production environment first, or the main, worker, and webhook-processor
pods will fail every database connection after the rollout completes.
