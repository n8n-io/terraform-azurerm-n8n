# PostgreSQL TLS modes and certificate verification

Both the module-managed and external PostgreSQL paths connect over TLS by
default. `require` (the default on both paths) only encrypts the connection.
It does not check that the certificate the server presents belongs to the
host n8n dialed. `verify-ca` and `verify-full` close that gap by validating
the certificate against a trusted CA.

n8n's Postgres driver (`pg`/node-postgres) does not expose libpq's
distinction between `verify-ca` (trust the certificate chain, skip the
hostname check) and `verify-full` (trust the chain and check the hostname).
With certificate verification on, the underlying Node TLS socket always
checks both the chain and the hostname. The module renders
`postgres_managed_ssl_mode` / `postgres_external_ssl_mode` into a single
`rejectUnauthorized` flag (`true` for both `verify-ca` and `verify-full`,
`false` otherwise; see `n8n.tf`'s `database.ssl.rejectUnauthorized`). So
`verify-ca` is not a weaker mode that skips the hostname check here. It
renders the same settings as `verify-full`. Pick either name for
documentation or audit purposes; the connection behaves the same.

## Selecting a mode

- `postgres_managed_ssl_mode` controls the module-managed Flexible Server
  path (`create_database = true`, the default). Azure Database for
  PostgreSQL Flexible Server enforces TLS on every connection, so this input
  only accepts `require`, `verify-ca`, or `verify-full`. `disable`, `allow`,
  and `prefer` would never apply and are rejected at plan time.
- `postgres_external_ssl_mode` controls the external path
  (`create_database = false`) and accepts the full PostgreSQL set
  (`disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`),
  since an external server's TLS posture is the caller's choice. `allow` and
  `prefer` are accepted for compatibility with PostgreSQL's `sslmode` naming,
  but the module has no plaintext-fallback path: both behave the same as
  `require`. There is no way to request "encrypt if the server supports it,
  otherwise connect in plaintext" through this module. Use `disable` for an
  unencrypted connection, or `require`, `verify-ca`, or `verify-full` for an
  encrypted one.

Both inputs feed `local.postgres_connection.ssl_mode` (`database.tf`), which
the n8n Helm chart's `database.ssl.enabled` / `database.ssl.rejectUnauthorized`
values derive from.

### Chart workaround for `DB_POSTGRESDB_SSL_ENABLED`

The pinned n8n Helm chart (`1.14.0`, and `1.13.0` before it) renders
`database.ssl.enabled` into an environment variable named
`DB_POSTGRESDB_SSL`, but n8n only reads `DB_POSTGRESDB_SSL_ENABLED`
([n8n-io/n8n-hosting#175](https://github.com/n8n-io/n8n-hosting/pull/175),
open upstream). The module works around this by setting
`DB_POSTGRESDB_SSL_ENABLED=true` directly through `config.extraEnv`
(`locals.tf`'s `n8n_postgres_ssl_enabled_env`) whenever the effective
`ssl_mode` is not `disable`, independent of chart version.

How the chart bug affected each mode before this workaround:

| Mode | Before the workaround | With the workaround |
| --- | --- | --- |
| `require`, `allow`, `prefer` | TLS without certificate verification | Unchanged |
| `verify-ca`, `verify-full` (external path, no CA) | Plaintext | TLS with certificate verification |
| `disable` | Plaintext | Unchanged |

`require`, `allow`, and `prefer` were already encrypted because the chart
also renders `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false` for them, and n8n
builds a TLS options object whenever that flag is `false`. Only the
verifying modes lost TLS entirely, because they leave that flag at its
default.

## Supplying a CA bundle for `verify-ca` / `verify-full`

`verify-ca` and `verify-full` both require n8n to trust the certificate
authority that signed the server's certificate. Set `postgres_ssl_ca_pem` to
a PEM-encoded CA bundle. The module trims surrounding whitespace and passes
it to the n8n Helm chart's `database.ssl.ca` value. The chart renders it into
its own ConfigMap as `DB_POSTGRESDB_SSL_CA`, which every main, worker, and
webhook-processor pod reads, and n8n passes that value to the TLS connection
as PEM content. This works for both the managed and external paths.

Because the CA is part of the Helm release:

- Changing the CA rolls the pods through the chart's own `checksum/config`
  pod annotation.
- A failed upgrade's atomic rollback restores the previous CA together with
  the previous pods (see [When a CA change fails](#when-a-ca-change-fails)).
- Removing the CA removes it in the same Helm upgrade, with no separate
  Kubernetes object to delete first.

```hcl
postgres_managed_ssl_mode = "verify-full"
postgres_ssl_ca_pem       = file("${path.module}/azure-postgres-root-cas.pem")
```

If `postgres_ssl_ca_pem` is left null, `verify-ca` / `verify-full` still work
as long as the pod image's own default trust store (Node's bundled CA list)
already trusts the server's issuing CA. Azure Database for PostgreSQL
Flexible Server uses dual-signed certificates anchored by two current root
CAs, DigiCert Global Root G2 and Microsoft RSA Root CA 2017, and Microsoft
recommends keeping both in the trusted root store
([Azure's TLS guidance](https://learn.microsoft.com/en-us/azure/postgresql/security/security-tls)).
Both are widely trusted roots, so many Node-based images already carry them.
Verify against your actual pod image rather than assuming either way.
Setting `postgres_ssl_ca_pem` to a bundle with both roots removes that
uncertainty and does not depend on the image's bundled trust store being
current. Do not put intermediate or server certificates in the bundle:
Microsoft does not support pinning them.

### The CA is ignored outside `verify-ca` / `verify-full`

In any other mode (`disable`, `allow`, `prefer`, `require`), the module
ignores `postgres_ssl_ca_pem`: it does not pass it to the chart, and an
advisory `check` in `database.tf`
(`postgres_ssl_ca_requires_verify_mode`) warns. This matters most for
`disable`: n8n turns on TLS with certificate verification whenever it sees a
CA, so delivering one would break a connection to a server you declared
plaintext. You can stage the CA before switching the mode; it takes effect
on the apply that selects `verify-ca` or `verify-full`.

### When a CA change fails

If a new bundle does not cover the certificate chain the server presents, the
new pods cannot connect and the Helm upgrade fails when it reaches
`n8n_helm_timeout` (600 seconds by default). `atomic = true` then rolls the
release back. The rollback restores the previous CA and the previous
Deployment specification, so the pods Kubernetes creates afterwards use the
working CA and connect without another apply. Set `postgres_ssl_ca_pem` back
to the working bundle before the next apply.

What stays available while the failing upgrade runs depends on the topology:

- **Multi-main (default):** main and webhook-processor pods keep serving,
  because their HTTP readiness probes keep the failing new pods out of
  rotation while the old pods stay up. Workers do not: the chart's worker
  readiness probe only checks that the `n8n worker` process exists
  (`pgrep`), so a new worker that cannot reach the database still counts as
  ready, and the rollout removes the healthy old worker. Queued executions
  wait in Redis until the rollback finishes.
- **Single-main (`n8n_main_hpa_min_replicas = 1`):** the chart's `Recreate`
  strategy applies to the main, worker, and webhook-processor Deployments, so
  all old pods stop before the new ones start. The editor, REST API,
  webhooks, scheduled triggers, and queue processing are unavailable until
  the rollback finishes and the restored pods are Ready.

Test a new bundle in a non-production environment first.

## Azure's CA rotation

Microsoft periodically rotates the root and intermediate CAs Azure Database
for PostgreSQL Flexible Server uses. See
[Azure's TLS/SSL certificate rotation guidance](https://learn.microsoft.com/en-us/azure/postgresql/security/security-tls)
for the current schedule and the combined bundle Microsoft publishes. If you
pin `postgres_ssl_ca_pem` to a specific bundle, track that page and refresh
the input before the old CA's validity window closes. Otherwise `verify-ca` /
`verify-full` connections start failing closed once the server rolls to a
certificate signed by a CA your bundle does not include. `require` mode
(the default) is unaffected by CA rotation since it never validates the
certificate chain.

## Upgrading an existing deployment

The `DB_POSTGRESDB_SSL_ENABLED` workaround adds an environment entry to every
deployment whose mode is not `disable`, so the first apply after upgrading
shows a Helm values diff and rolls the pods even if you change no input.

- **Default `require` (managed or external):** connection behavior does not
  change. The connection was already encrypted and stays unverified.
- **External `verify-ca` / `verify-full`:** the connection goes from
  plaintext to TLS with certificate verification. If the server does not
  accept TLS, uses a private CA that the pod image does not trust, or
  presents a certificate whose name does not match `postgres_external_host`,
  the pods fail every database connection after the rollout, and Helm's
  atomic rollback fails the apply. Before upgrading, confirm the server
  accepts TLS and supply its CA with `postgres_ssl_ca_pem` if needed. Test in
  a non-production environment first.

Changing `postgres_managed_ssl_mode`, `postgres_external_ssl_mode`, or
`postgres_ssl_ca_pem` only changes what n8n's application containers send as
connection parameters. None of these recreate the PostgreSQL server. Adding
or changing the CA in a verifying mode changes the rendered Helm values (the
chart's `database.ssl.ca`), so expect a plan diff and a rolling pod update.
On the default multi-main topology, that rollout is a standard rolling
update: n8n keeps serving requests while each pod cycles in turn. On the
single-main topology (`n8n_main_hpa_min_replicas = 1`), the chart's
`Recreate` strategy stops the old main, worker, and webhook-processor pods
before their replacements start, so the editor, REST API, webhooks,
scheduled triggers, and queue processing are briefly unavailable until the
new pods are Ready. This is the same interruption any single-main rollout
causes (see [`docs/upgrading-n8n.md`](./upgrading-n8n.md)). Plan a
maintenance window for that case.

Before switching to `verify-ca` or `verify-full`, confirm the CA bundle you
supply (or the pod image's default trust store) covers the certificate chain
your server currently presents. Test in a non-production environment first,
or the main, worker, and webhook-processor pods will fail every database
connection after the rollout completes.
