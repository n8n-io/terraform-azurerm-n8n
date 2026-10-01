#!/usr/bin/env bash
# Render the module's actual helm_release.n8n.values against the pinned n8n Helm
# chart and assert on the manifests Helm produces. This is a regression check
# against the real module-to-chart mapping, not an independently maintained
# approximation: fixture values are exported from mocked Terraform plans.
#
# Requires `terraform init -backend=false` to have already run at the module
# root, plus `helm` and `jq` on PATH. No apply, cluster access, Azure credentials,
# or state persistence beyond a throwaway temp directory. Helm's
# built-in JSON-schema validation runs on every `helm template` call below
# (no flag needed to enable it; only `--skip-schema-validation` disables it,
# which this script never passes), so a fixture that violates the chart
# schema fails the corresponding `helm template` invocation.
#
# Local usage:
#   terraform init -backend=false   # once, from the repo root
#   tests/scripts/check-n8n-chart.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

for tool in terraform helm jq; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Fixed, non-secret plan-time inputs. These satisfy every non-nullable
# required variable this root module declares; they carry no real Azure
# resource identifiers or credentials. Additional -var flags (e.g. a
# topology override) can be passed as extra arguments — they are appended
# after these fixed values, so they take precedence.
#
# hashicorp/kubernetes ~> 3.0 (port-aws-050-enhancements) prints a
# "Deprecated value used" warning on stdout for every console invocation
# that evaluates the root's kubernetes_namespace.n8n-backed output, even
# when -no-color is set and stderr is discarded. `tail -n 1` below keeps
# only the actual expression result (always the last output line) so a
# stray warning line never breaks `jq -er .`.
console() {
  terraform console -no-color -state="$tmp/terraform.tfstate" \
    -var='location=eastus' \
    -var='resource_group_name=n8ntest-rg' \
    -var='friendly_name_prefix=n8ntest' \
    -var='vnet_id=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet' \
    -var='aks_subnet_id=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/aks' \
    -var='postgres_subnet_id=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/postgres' \
    -var='redis_subnet_id=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/redis' \
    -var='appgw_subnet_id=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/appgw' \
    -var='private_endpoint_subnet_id=/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/n8ntest-rg/providers/Microsoft.Network/virtualNetworks/n8ntest-vnet/subnets/pe' \
    -var='n8n_domain=n8n.test.example.com' \
    -var='app_gateway_tls_cert_secret_id=https://n8ntest-shared-kv.vault.azure.net/secrets/n8n-tls-cert/abc123' \
    -var='n8n_license_key=test-license-key-not-real' \
    "$@" | tail -n 1 | jq -er .
}

chart_version=$(console <<< 'var.n8n_chart_version')
echo "== Pulling n8n chart ${chart_version} =="
helm pull "oci://ghcr.io/n8n-io/n8n-helm-chart/n8n" --version "$chart_version" --untar --untardir "$tmp"

# Worker pools (early alpha) render only on a chart that carries
# queueMode.workerGroups, which no numbered release does yet; the official
# preview build is the only public chart that exercises worker-pools.tf's
# real output. Keep this in step with the version examples/worker-pools
# documents and the worker_pools runs in tests/chart-values.tftest.hcl pin.
preview_chart_version="1.11.0-preview.workerpools.1"
echo "== Pulling n8n preview chart ${preview_chart_version} (worker pools) =="
mkdir -p "$tmp/preview"
helm pull "oci://ghcr.io/n8n-io/n8n-helm-chart/n8n" --version "$preview_chart_version" --untar --untardir "$tmp/preview"

# Export each fixture's exact planned Helm values. Secret references keep the
# values known and non-sensitive; no credential payload enters the plan.
echo "== Planning module Helm values with mocked providers =="
if ! terraform test -no-color -json -verbose \
  -filter=tests/chart-values.tftest.hcl > "$tmp/terraform-test.jsonl"; then
  jq -r 'select(.type == "diagnostic") | "\(.diagnostic.severity): \(.diagnostic.summary)\n\(.diagnostic.detail // "")"' \
    "$tmp/terraform-test.jsonl" >&2
  exit 1
fi

jq -e 'select(.type == "test_summary") | .test_summary.status == "pass"' \
  "$tmp/terraform-test.jsonl" >/dev/null || {
  jq -r 'select(.type == "diagnostic") | "\(.diagnostic.severity): \(.diagnostic.summary)\n\(.diagnostic.detail // "")"' \
    "$tmp/terraform-test.jsonl" >&2
  exit 1
}

export_values() {
  local run="$1"
  local out="$2"
  jq -er --arg run "$run" '
    select(.type == "test_plan" and ."@testrun" == $run)
    | .test_plan.resource_changes[]
    | select(.address == "helm_release.n8n")
    | .change.after.values[0]
  ' "$tmp/terraform-test.jsonl" > "$out"
}

render() {
  local values_file="$1"
  local out_prefix="$2"
  local template="$3"
  local chart_dir="${4:-$tmp/n8n}"
  helm template n8n "$chart_dir" -f "$values_file" \
    --show-only "templates/${template}.yaml" > "$tmp/${out_prefix}-${template}.yaml"
  console <<< "jsonencode(yamldecode(file(\"$tmp/${out_prefix}-${template}.yaml\")))" > "$tmp/${out_prefix}-${template}.json"
}

echo "== Rendering default multi-main values fixture =="
export_values multi_main "$tmp/multi-main-values.json"

echo "== Rendering single-main values fixture (minimum 1, a higher configured maximum) =="
export_values single_main "$tmp/single-main-values.json"

echo "== Rendering PostgreSQL runtime-tuning values fixture (all four timing overrides) =="
export_values pg_runtime "$tmp/pg-runtime-values.json"

echo "== Rendering PostgreSQL TLS CA values fixture (verify-full + postgres_ssl_ca_pem) =="
export_values ssl_ca "$tmp/ssl-ca-values.json"

echo "== Rendering Bull worker timing values fixture (all three timing overrides) =="
export_values worker_timing "$tmp/worker-timing-values.json"

echo "== Rendering execution save-policy values fixture (independent success/error policies, both booleans changed) =="
export_values save_policy "$tmp/save-policy-values.json"
export_values save_policy_inverse "$tmp/save-policy-inverse-values.json"

echo "== Rendering application heap ceiling values fixture =="
export_values heap "$tmp/heap-values.json"

echo "== Rendering caller-managed task-runner launcher configuration values fixture =="
export_values task_runner_config "$tmp/task-runner-config-values.json"

echo "== Rendering pod DNS configuration values fixture (nameservers, searches, and an ndots/edns0 option pair) =="
export_values dns "$tmp/dns-values.json"

echo "== Rendering split editor/webhook URL values fixture (n8n_webhook_url override) =="
export_values split_url "$tmp/split-url-values.json"

echo "== Rendering worker-only environment values fixture (n8n_worker_extra_env) =="
export_values worker_extra_env "$tmp/worker-extra-env-values.json"

echo "== Rendering worker pools values fixtures (unauthenticated and authenticated Redis) =="
export_values worker_pools "$tmp/worker-pools-values.json"
export_values worker_pools_authenticated "$tmp/worker-pools-auth-values.json"

echo "== Rendering paused worker autoscaling values fixture (pause with a zero hold count) =="
export_values worker_pause "$tmp/worker-pause-values.json"

for template in deployment-main deployment-worker deployment-webhook-processor hpa-main pdb scaledobject-worker configmap; do
  render "$tmp/multi-main-values.json" multi-main "$template"
done

for template in deployment-main hpa-main pdb; do
  render "$tmp/single-main-values.json" single-main "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/pg-runtime-values.json" pg-runtime "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor configmap; do
  render "$tmp/ssl-ca-values.json" ssl-ca "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor configmap; do
  render "$tmp/worker-timing-values.json" worker-timing "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/save-policy-values.json" save-policy "$template"
  render "$tmp/save-policy-inverse-values.json" save-policy-inverse "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/heap-values.json" heap "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/task-runner-config-values.json" task-runner-config "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/dns-values.json" dns "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/split-url-values.json" split-url "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/worker-extra-env-values.json" worker-extra-env "$template"
done

render "$tmp/worker-pause-values.json" worker-pause scaledobject-worker

# Against the preview chart: Helm's schema validation runs on every one of
# these calls, so a values shape the workerGroups schema rejects (for example
# an empty authenticationRef.name) fails here, not at apply.
for template in deployment-worker-group scaledobject-worker-group scaledobject-worker deployment-main; do
  render "$tmp/worker-pools-values.json" worker-pools "$template" "$tmp/preview/n8n"
  render "$tmp/worker-pools-auth-values.json" worker-pools-auth "$template" "$tmp/preview/n8n"
done

main_min=$(console <<< 'var.n8n_main_hpa_min_replicas')
main_max=$(console <<< 'var.n8n_main_hpa_max_replicas')
main_cpu=$(console <<< 'var.n8n_main_hpa_cpu_threshold')
worker_min=$(console <<< 'var.n8n_worker_keda_min_replicas')
worker_max=$(console <<< 'var.n8n_worker_keda_max_replicas')
worker_jobs=$(console <<< 'var.n8n_worker_keda_jobs_per_replica')
webhook_min=$(console <<< 'var.n8n_webhook_hpa_min_replicas')
domain=$(console <<< 'var.n8n_domain')

echo "== Verify topology manifests (default multi-main) =="

jq -e --argjson n "$main_min" '.spec.replicas == $n' "$tmp/multi-main-deployment-main.json" >/dev/null \
  || { echo "FAIL: deployment-main.spec.replicas != n8n_main_hpa_min_replicas" >&2; exit 1; }

jq -e '(.spec | has("strategy")) | not' "$tmp/multi-main-deployment-main.json" >/dev/null \
  || { echo "FAIL: deployment-main unexpectedly overrides .spec.strategy in the default multi-main configuration" >&2; exit 1; }

for template in deployment-worker deployment-webhook-processor; do
  jq -e '(.spec | has("strategy")) | not' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly overrides .spec.strategy" >&2; exit 1; }
done

# Chart >= 1.13.0 (#201) leaves spec.replicas off the worker Deployment once a
# KEDA ScaledObject renders for it, which this module's configuration always
# does; the ScaledObject's minReplicaCount (asserted below) is the floor.
jq -e '(.spec | has("replicas")) | not' "$tmp/multi-main-deployment-worker.json" >/dev/null \
  || { echo "FAIL: deployment-worker must leave .spec.replicas to KEDA (chart 1.13.0 omits it once the worker ScaledObject renders)" >&2; exit 1; }

jq -e --argjson n "$webhook_min" '.spec.replicas == $n' "$tmp/multi-main-deployment-webhook-processor.json" >/dev/null \
  || { echo "FAIL: deployment-webhook-processor.spec.replicas != n8n_webhook_hpa_min_replicas" >&2; exit 1; }

jq -e --argjson mn "$main_min" --argjson mx "$main_max" --argjson cpu "$main_cpu" \
  '.spec.minReplicas == $mn and .spec.maxReplicas == $mx and (.spec.metrics[0].resource.target.averageUtilization == $cpu)' \
  "$tmp/multi-main-hpa-main.json" >/dev/null \
  || { echo "FAIL: hpa-main bounds/threshold do not match n8n_main_hpa_* variables" >&2; exit 1; }

jq -e '.spec.minAvailable == 1 and .spec.selector.matchLabels["app.kubernetes.io/component"] == "main"' \
  "$tmp/multi-main-pdb.json" >/dev/null \
  || { echo "FAIL: main PDB minAvailable/selector do not match multi-main (minAvailable = 1)" >&2; exit 1; }

jq -e --argjson mn "$worker_min" --argjson mx "$worker_max" --argjson jobs "$worker_jobs" '
  .spec.minReplicaCount == $mn
  and .spec.maxReplicaCount == $mx
  and ([.spec.triggers[].metadata.listName] | sort) == ["bull:jobs:active", "bull:jobs:wait"]
  and (.spec.triggers | all(.metadata.listLength == ($jobs | tostring)))
' "$tmp/multi-main-scaledobject-worker.json" >/dev/null \
  || { echo "FAIL: worker ScaledObject bounds/triggers do not match n8n_worker_keda_* variables" >&2; exit 1; }

# Default fixture: pause inputs at their defaults must add no annotations at
# all (the chart writes the key only when there is something to put in it),
# and pausedReplicaCount: null must pass the typed keda schema.
jq -e '(.metadata.annotations // {}) | to_entries | map(select(.key | startswith("autoscaling.keda.sh/paused"))) | length == 0' \
  "$tmp/multi-main-scaledobject-worker.json" >/dev/null \
  || { echo "FAIL: worker ScaledObject carries a KEDA pause annotation in the default fixture (n8n_worker_keda_pause false)" >&2; exit 1; }

jq -e '
  .metadata.annotations["autoscaling.keda.sh/paused"] == "true"
  and .metadata.annotations["autoscaling.keda.sh/paused-replicas"] == "0"
' "$tmp/worker-pause-scaledobject-worker.json" >/dev/null \
  || { echo "FAIL: worker ScaledObject must carry autoscaling.keda.sh/paused=true and paused-replicas=0 when n8n_worker_keda_pause is true with a zero hold count" >&2; exit 1; }

echo "PASS: deployment families, main HPA/PDB, and worker KEDA match the module's variables"

echo "== Verify topology manifests (single-main, minimum 1, configured maximum 20) =="

jq -e '.spec.replicas == 1' "$tmp/single-main-deployment-main.json" >/dev/null \
  || { echo "FAIL: single-main deployment-main.spec.replicas must be 1" >&2; exit 1; }

jq -e '.spec.strategy.type == "Recreate" and ((.spec.strategy | has("rollingUpdate")) | not)' \
  "$tmp/single-main-deployment-main.json" >/dev/null \
  || { echo "FAIL: single-main deployment-main must use Recreate without a rollingUpdate configuration" >&2; exit 1; }

jq -e '.spec.minReplicas == 1 and .spec.maxReplicas == 1' "$tmp/single-main-hpa-main.json" >/dev/null \
  || { echo "FAIL: single-main hpa-main must clamp to 1/1 regardless of the configured maximum of 20" >&2; exit 1; }

jq -e '.spec.minAvailable == 0' "$tmp/single-main-pdb.json" >/dev/null \
  || { echo "FAIL: single-main PDB must allow voluntary eviction with minAvailable = 0" >&2; exit 1; }

echo "PASS: single-main passes chart schema validation with one main, HPA 1/1, Recreate, and PDB minimum 0"

echo "== Verify runtime manifests (execution save policy, URL naming) =="

# Check all roles: webhook processors decide final retention for production
# webhooks even though the chart omits its native save-policy env on that role.
for fixture in multi-main save-policy save-policy-inverse; do
  case "$fixture" in
    multi-main)          success=all  error=all  progress=false manual=true ;;
    save-policy)         success=none error=all  progress=true  manual=false ;;
    save-policy-inverse) success=all  error=none progress=false manual=true ;;
  esac
  for template in deployment-main deployment-worker deployment-webhook-processor; do
    jq -e --arg success "$success" --arg error "$error" --arg progress "$progress" --arg manual "$manual" '
      [.spec.template.spec.containers[0].env[] | select(.name | startswith("EXECUTIONS_DATA_SAVE_"))] as $entries
      | ($entries | length) == 4
      and ([$entries[] | {key: .name, value: .value}] | from_entries) == {
        "EXECUTIONS_DATA_SAVE_ON_SUCCESS": $success,
        "EXECUTIONS_DATA_SAVE_ON_ERROR": $error,
        "EXECUTIONS_DATA_SAVE_ON_PROGRESS": $progress,
        "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS": $manual
      }
    ' "$tmp/${fixture}-${template}.json" >/dev/null \
      || { echo "FAIL: ${fixture} ${template} must render each execution save-policy entry exactly once with the expected value" >&2; exit 1; }
  done
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e --arg url "https://${domain}" '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WEBHOOK_URL")][0].value == $url
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing the current N8N_WEBHOOK_URL environment entry" >&2; exit 1; }

  jq -e --arg url "https://${domain}" '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_EDITOR_BASE_URL")][0].value == $url
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing the current N8N_EDITOR_BASE_URL environment entry" >&2; exit 1; }

  jq -e '
    ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_WEBHOOK_URL")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_EDITOR_BASE_URL")] | length == 1)
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must render exactly one N8N_WEBHOOK_URL and one N8N_EDITOR_BASE_URL entry" >&2; exit 1; }

  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "WEBHOOK_URL")] | length == 0
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders the deprecated WEBHOOK_URL alias" >&2; exit 1; }
done

# Chart 1.14.0 (#184) renamed this ConfigMap key from WEBHOOK_URL to
# N8N_WEBHOOK_URL; either one here would duplicate the module's own env entry.
jq -e '(.data | has("WEBHOOK_URL") or has("N8N_WEBHOOK_URL")) | not' "$tmp/multi-main-configmap.json" >/dev/null \
  || { echo "FAIL: the chart ConfigMap unexpectedly carries a WEBHOOK_URL or N8N_WEBHOOK_URL key (webhook.url or ingress must remain unset)" >&2; exit 1; }

echo "PASS: execution save-policy values and current URL naming are correct on every applicable container"

echo "== Verify split editor/webhook URL manifests (n8n_webhook_url override) =="

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e --arg url "https://${domain}" '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_EDITOR_BASE_URL")][0].value == $url
  ' "$tmp/split-url-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} N8N_EDITOR_BASE_URL must stay on n8n_domain when n8n_webhook_url is overridden" >&2; exit 1; }

  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WEBHOOK_URL")][0].value == "https://hooks.test.example.com:8443/n8n/"
  ' "$tmp/split-url-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} N8N_WEBHOOK_URL must equal the caller-supplied override, preserved as-is" >&2; exit 1; }

  jq -e '
    ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_WEBHOOK_URL")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_EDITOR_BASE_URL")] | length == 1)
  ' "$tmp/split-url-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must render exactly one N8N_WEBHOOK_URL and one N8N_EDITOR_BASE_URL entry in the split fixture" >&2; exit 1; }
done

echo "PASS: split editor/webhook URL override renders on every application pod family without a duplicate chart URL"

echo "== Verify PostgreSQL runtime-tuning manifests (connection/ping timing) =="

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    (.spec.template.spec.containers[0].env | map(select(.name == "DB_POSTGRESDB_CONNECTION_TIMEOUT"))[0].value) == "45000"
    and (.spec.template.spec.containers[0].env | map(select(.name == "DB_PING_TIMEOUT_MS"))[0].value) == "15000"
    and (.spec.template.spec.containers[0].env | map(select(.name == "DB_PING_INTERVAL_SECONDS"))[0].value) == "5"
    and (.spec.template.spec.containers[0].env | map(select(.name == "DB_PING_MAX_FAILURES_BEFORE_RECOVERY"))[0].value) == "6"
  ' "$tmp/pg-runtime-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing one or more PostgreSQL runtime-tuning environment values" >&2; exit 1; }
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    ([.spec.template.spec.containers[0].env[] | select(.name == "DB_POSTGRESDB_CONNECTION_TIMEOUT")] | length == 0)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "DB_PING_TIMEOUT_MS")] | length == 0)
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders PostgreSQL runtime-tuning values in the default fixture (all four inputs null)" >&2; exit 1; }
done

echo "PASS: PostgreSQL connection/ping timing renders on all three application pod families and is omitted by default"

echo "== Verify PostgreSQL TLS CA manifests (DB_POSTGRESDB_SSL_ENABLED / DB_POSTGRESDB_SSL_CA_FILE) =="

# Regression check for the bug this fixture exists to catch: the pinned
# chart renders database.ssl.enabled into a ConfigMap key named
# DB_POSTGRESDB_SSL, which n8n does not read (n8n-io/n8n-hosting#175
# upstream). The module works around this with its own
# DB_POSTGRESDB_SSL_ENABLED entry in config.extraEnv; assert on the
# container env directly so a future chart bump that fixes the upstream
# name does not silently mask a regression in the module's own workaround.
for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "DB_POSTGRESDB_SSL_ENABLED")] | length == 1
    and .[0].value == "true"
  ' "$tmp/ssl-ca-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must carry exactly one DB_POSTGRESDB_SSL_ENABLED=true entry when the effective ssl_mode is not disable" >&2; exit 1; }
done

# n8n reads DB_POSTGRESDB_SSL_CA as a filesystem path (readFileSync), not
# inline PEM content, so the module must not pass the PEM through the
# chart's native database.ssl.ca value (which would land it verbatim in the
# ConfigMap under that same key). It instead mounts a dedicated Secret and
# points DB_POSTGRESDB_SSL_CA_FILE at the mounted file.
jq -e '.data | has("DB_POSTGRESDB_SSL_CA") | not' \
  "$tmp/ssl-ca-configmap.json" >/dev/null \
  || { echo "FAIL: the chart ConfigMap must not carry DB_POSTGRESDB_SSL_CA; n8n reads that setting as a file path, not inline PEM content" >&2; exit 1; }

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "DB_POSTGRESDB_SSL_CA_FILE")] | length == 1
    and .[0].value == "/etc/n8n/postgres-ssl-ca/ca.pem"
  ' "$tmp/ssl-ca-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must carry exactly one DB_POSTGRESDB_SSL_CA_FILE entry pointing at the mounted CA file" >&2; exit 1; }

  jq -e '
    [.spec.template.spec.volumes[] | select(.name == "postgres-ssl-ca" and .secret.secretName == "n8n-postgres-ssl-ca")] | length == 1
  ' "$tmp/ssl-ca-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must mount the postgres-ssl-ca Secret volume" >&2; exit 1; }

  jq -e '
    [.spec.template.spec.containers[0].volumeMounts[] | select(.name == "postgres-ssl-ca" and .mountPath == "/etc/n8n/postgres-ssl-ca" and .readOnly == true)] | length == 1
  ' "$tmp/ssl-ca-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must mount the postgres-ssl-ca volume read-only at /etc/n8n/postgres-ssl-ca" >&2; exit 1; }
done

echo "PASS: DB_POSTGRESDB_SSL_ENABLED renders on every application pod family and postgres_ssl_ca_pem reaches n8n through a mounted file, not the chart's ConfigMap"

echo "== Verify Bull worker timing manifests (lock duration/renewal/stalled interval/graceful shutdown timeout) =="

jq -e '
  .data.QUEUE_WORKER_LOCK_DURATION == "90000"
  and .data.QUEUE_WORKER_LOCK_RENEW_TIME == "15000"
  and .data.QUEUE_WORKER_STALLED_INTERVAL == "45000"
  and .data.N8N_GRACEFUL_SHUTDOWN_TIMEOUT == "45"
' "$tmp/worker-timing-configmap.json" >/dev/null \
  || { echo "FAIL: the chart ConfigMap is missing one or more Bull worker timing overrides" >&2; exit 1; }

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    ([.spec.template.spec.containers[0].env[] | select(.name == "QUEUE_WORKER_LOCK_DURATION")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "QUEUE_WORKER_LOCK_RENEW_TIME")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "QUEUE_WORKER_STALLED_INTERVAL")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_GRACEFUL_SHUTDOWN_TIMEOUT")] | length == 1)
  ' "$tmp/worker-timing-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing one or more Bull worker timing ConfigMap references" >&2; exit 1; }
done

jq -e '
  .data.QUEUE_WORKER_LOCK_DURATION == "60000"
  and .data.QUEUE_WORKER_LOCK_RENEW_TIME == "10000"
  and .data.QUEUE_WORKER_STALLED_INTERVAL == "30000"
' "$tmp/multi-main-configmap.json" >/dev/null \
  || { echo "FAIL: the default fixture (all worker timing inputs null) must retain the chart's own pinned defaults (60000/10000/30000 ms) unchanged" >&2; exit 1; }

# check.graceful_shutdown_fits_grace_period compares against
# local.n8n_chart_default_graceful_shutdown_timeout when the input is null, so
# the rendered chart default must equal that local. A chart bump that moves
# the default fails here until the local is updated.
expected_shutdown_default=$(console <<< 'local.n8n_chart_default_graceful_shutdown_timeout')
jq -e --arg expected "$expected_shutdown_default" '.data.N8N_GRACEFUL_SHUTDOWN_TIMEOUT == $expected' \
  "$tmp/multi-main-configmap.json" >/dev/null \
  || { echo "FAIL: chart ${chart_version} renders N8N_GRACEFUL_SHUTDOWN_TIMEOUT=$(jq -r '.data.N8N_GRACEFUL_SHUTDOWN_TIMEOUT' "$tmp/multi-main-configmap.json") by default, but local.n8n_chart_default_graceful_shutdown_timeout is ${expected_shutdown_default}; update the local" >&2; exit 1; }

jq -e '.data.QUEUE_WORKER_MAX_STALLED_COUNT == "1"' "$tmp/worker-timing-configmap.json" >/dev/null \
  || { echo "FAIL: the chart's own QUEUE_WORKER_MAX_STALLED_COUNT default must remain untouched (this module exposes no such input)" >&2; exit 1; }

echo "PASS: Bull worker timing overrides render exactly once per name on every application pod family, and the default fixture keeps the chart's own pinned defaults"

echo "== Verify application heap ceiling manifests (NODE_OPTIONS) =="

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "NODE_OPTIONS")] | length == 1
    and .[0].value == "--max-old-space-size=768"
  ' "$tmp/heap-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must render exactly one NODE_OPTIONS=--max-old-space-size=768 entry when n8n_node_max_old_space_size_mb is set" >&2; exit 1; }

  jq -e '.spec.template.spec.containers[0].resources == '"$(jq -c '.spec.template.spec.containers[0].resources' "$tmp/multi-main-${template}.json")"'' \
    "$tmp/heap-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} container resource limits/requests must stay unchanged when the heap ceiling is set" >&2; exit 1; }
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "NODE_OPTIONS")] | length == 0
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders NODE_OPTIONS in the default fixture (n8n_node_max_old_space_size_mb null)" >&2; exit 1; }
done

echo "PASS: the application heap ceiling renders exactly one NODE_OPTIONS entry on every application pod family without changing container resources, and is omitted by default"

echo "== Verify caller-managed task-runner launcher configuration manifests (customConfig mount) =="

# Chart 1.12.0 and later (n8n-hosting #179) render the task-runner sidecar on
# main only in standalone mode; this module always runs queue mode, so only
# the worker carries the sidecar and the launcher mount.
jq -e '
  (.spec.template.spec.containers | map(select(.name == "task-runner"))[0].volumeMounts | map(select(.name == "task-runner-config"))[0])
  == {"name": "task-runner-config", "mountPath": "/etc/n8n-task-runners.json", "subPath": "n8n-task-runners.json", "readOnly": true}
' "$tmp/task-runner-config-deployment-worker.json" >/dev/null \
  || { echo "FAIL: deployment-worker task-runner sidecar must mount the caller-managed ConfigMap key at /etc/n8n-task-runners.json using subPath" >&2; exit 1; }

jq -e '
  [.spec.template.spec.volumes[] | select(.name == "task-runner-config")][0].configMap.name == "n8n-task-runner-launcher"
' "$tmp/task-runner-config-deployment-worker.json" >/dev/null \
  || { echo "FAIL: deployment-worker pod volumes must reference the caller-supplied ConfigMap name for task-runner-config" >&2; exit 1; }

for template in deployment-main deployment-webhook-processor; do
  jq -e '
    ([.spec.template.spec.containers[] | select(.name == "task-runner")] | length == 0)
    and ([.spec.template.spec.volumes[]? | select(.name == "task-runner-config")] | length == 0)
  ' "$tmp/task-runner-config-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must gain no task-runner sidecar or launcher mount (chart >= 1.12.0 renders the main sidecar only in standalone mode)" >&2; exit 1; }
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    (.spec.template.spec.containers | map(select(.name == "task-runner"))[0].volumeMounts // []) | map(select(.name == "task-runner-config")) | length == 0
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly mounts a task-runner-config volume in the default fixture (n8n_task_runner_custom_config null)" >&2; exit 1; }
done

echo "PASS: caller-managed task-runner launcher configuration mounts on the worker sidecar only, with an exact file path and subPath, and is omitted by default"

echo "== Verify pod DNS configuration manifests (dnsConfig) =="

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    .spec.template.spec.dnsConfig == {
      "nameservers": ["10.0.0.10"],
      "searches": ["svc.cluster.local"],
      "options": [{"name": "ndots", "value": "1"}, {"name": "edns0"}]
    }
  ' "$tmp/dns-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} dnsConfig does not match the caller-supplied nameservers/searches/options, or carries a null field" >&2; exit 1; }
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '(.spec.template.spec | has("dnsConfig")) | not' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders a dnsConfig block in the default fixture (n8n_dns_config null)" >&2; exit 1; }
done

echo "PASS: pod DNS configuration is identical on all three pod families with no null fields, and is omitted by default"

echo "== Verify worker-only environment manifests (queueMode.workerExtraEnv) =="

jq -e '
  [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_ONLY_SETTING")] | length == 1
  and .[0].value == "worker-only"
' "$tmp/worker-extra-env-deployment-worker.json" >/dev/null \
  || { echo "FAIL: deployment-worker must render exactly one N8N_WORKER_ONLY_SETTING entry from n8n_worker_extra_env" >&2; exit 1; }

for template in deployment-main deployment-webhook-processor; do
  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_ONLY_SETTING")] | length == 0
  ' "$tmp/worker-extra-env-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} must not receive n8n_worker_extra_env entries (worker-only)" >&2; exit 1; }
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_ONLY_SETTING")] | length == 0
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders a worker-only entry in the default fixture (n8n_worker_extra_env empty)" >&2; exit 1; }
done

echo "PASS: n8n_worker_extra_env renders on the worker container only, and is omitted by default"

echo "== Verify worker pools manifests against the preview chart (${preview_chart_version}) =="

# One pool Deployment, labelled and carrying N8N_WORKER_POOL_NAME, and the
# mains carrying N8N_WORKER_POOLS_ENABLED.
jq -e '
  .metadata.name == "n8n-worker-gpu"
  and .metadata.labels["n8n.io/worker-pool"] == "gpu"
  and .metadata.labels["app.kubernetes.io/component"] == "worker-group"
  and ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_POOL_NAME")] | length == 1 and .[0].value == "gpu")
  and ([.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_POOLS_ENABLED")] | length == 1 and .[0].value == "true")
' "$tmp/worker-pools-deployment-worker-group.json" >/dev/null \
  || { echo "FAIL: the preview chart must render one n8n-worker-gpu Deployment labelled worker-group/n8n.io/worker-pool=gpu with N8N_WORKER_POOL_NAME=gpu and N8N_WORKER_POOLS_ENABLED=true" >&2; exit 1; }

jq -e '
  [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_POOLS_ENABLED")] | length == 1 and .[0].value == "true"
' "$tmp/worker-pools-deployment-main.json" >/dev/null \
  || { echo "FAIL: main pods must carry N8N_WORKER_POOLS_ENABLED=true while pools are declared" >&2; exit 1; }

# Pool ScaledObject on the unauthenticated external Redis path: the pool's
# own queue, the module's threshold, enableTLS equal to what the default
# worker's own triggers render (the fixture's external Redis keeps the
# module default redis_external_tls_enabled = true, so "true" here), and no
# authenticationRef on either scaler. The pool key must be omitted, not "":
# the chart schema puts minLength 1 on it, and the helm template call above
# would already have failed on an empty name.
default_tls=$(jq -r '.spec.triggers[0].metadata.enableTLS' "$tmp/worker-pools-scaledobject-worker.json")
[[ "$default_tls" == "true" || "$default_tls" == "false" ]] \
  || { echo "FAIL: default worker ScaledObject baseline must render enableTLS as \"true\" or \"false\", got '${default_tls}'" >&2; exit 1; }

jq -e --argjson jobs "$worker_jobs" --arg tls "$default_tls" '
  .metadata.name == "n8n-worker-gpu"
  and .spec.scaleTargetRef.name == "n8n-worker-gpu"
  and .spec.minReplicaCount == 0 and .spec.maxReplicaCount == 3
  and ([.spec.triggers[].metadata.listName] | sort) == ["bull:jobs-gpu:active", "bull:jobs-gpu:wait"]
  and (.spec.triggers | all(.metadata.listLength == ($jobs | tostring)))
  and (.spec.triggers | all(.metadata.enableTLS == $tls))
  and (.spec.triggers | all(has("authenticationRef") | not))
  and (.spec.triggers | all(.metadata | has("passwordFromEnv") or has("username") | not))
' "$tmp/worker-pools-scaledobject-worker-group.json" >/dev/null \
  || { echo "FAIL: pool ScaledObject (unauthenticated Redis) must watch bull:jobs-gpu:{wait,active} with the module threshold, the default worker's enableTLS (${default_tls}), no authenticationRef, and no credential metadata" >&2; exit 1; }

jq -e '.spec.triggers | all(.authenticationRef.name == "" or (has("authenticationRef") | not))' \
  "$tmp/worker-pools-scaledobject-worker.json" >/dev/null \
  || { echo "FAIL: default worker ScaledObject baseline (unauthenticated Redis) must render no effective authenticationRef" >&2; exit 1; }

# Authenticated path: both scalers reference the module's TriggerAuthentication.
jq -e '
  .spec.triggers | length == 2
  and all(.authenticationRef.name == "n8n-redis-keda-auth")
  and all(.metadata | has("passwordFromEnv") or has("username") | not)
' "$tmp/worker-pools-auth-scaledobject-worker-group.json" >/dev/null \
  || { echo "FAIL: pool ScaledObject (authenticated Redis) must reference TriggerAuthentication n8n-redis-keda-auth on every trigger and carry no credential metadata" >&2; exit 1; }

jq -e '.spec.triggers | length == 2 and all(.authenticationRef.name == "n8n-redis-keda-auth")' \
  "$tmp/worker-pools-auth-scaledobject-worker.json" >/dev/null \
  || { echo "FAIL: default worker ScaledObject (authenticated Redis) must reference TriggerAuthentication n8n-redis-keda-auth" >&2; exit 1; }

# Default fixture on the pinned numbered chart: no pool objects and no flag.
for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '[.spec.template.spec.containers[0].env[] | select(.name == "N8N_WORKER_POOLS_ENABLED")] | length == 0' \
    "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders N8N_WORKER_POOLS_ENABLED in the default fixture (no pools)" >&2; exit 1; }
done

echo "PASS: worker pools render one labelled Deployment and one ScaledObject per pool on the preview chart, with the pool's queue, the module threshold, enableTLS, and the shared TriggerAuthentication matching the default worker's scaler; omitted by default"

echo "== Verify no deprecated n8n environment variable renders =="
# n8n deprecated N8N_AVAILABLE_BINARY_DATA_MODES and warns on every start.
# Scans every rendered manifest from every fixture: env entries on any
# container, and ConfigMap data keys. The *-values.json fixtures hold the
# Helm values YAML string, not JSON, so they are skipped; every other file
# must parse, because jq -e exits 1 for "not found" and >1 for an error, and
# treating an unparseable manifest as "not found" would pass silently.
scanned=0
for f in "$tmp"/*.json "$tmp"/preview/*.json; do
  [[ -e "$f" ]] || continue
  [[ "$f" == *-values.json ]] && continue
  rc=0
  jq -e '[.. | objects | select((.name? == "N8N_AVAILABLE_BINARY_DATA_MODES") or has("N8N_AVAILABLE_BINARY_DATA_MODES"))] | length > 0' "$f" >/dev/null || rc=$?
  if (( rc == 0 )); then
    echo "FAIL: N8N_AVAILABLE_BINARY_DATA_MODES is rendered in $(basename "$f"); n8n deprecated it and warns on every start" >&2
    exit 1
  elif (( rc > 1 )); then
    echo "FAIL: could not parse rendered manifest $(basename "$f") (jq exit ${rc}), so the deprecated-env scan cannot vouch for it" >&2
    exit 1
  fi
  scanned=$((scanned + 1))
done
(( scanned > 0 )) || { echo "FAIL: the deprecated-env scan found no rendered manifests to check" >&2; exit 1; }
echo "PASS: N8N_AVAILABLE_BINARY_DATA_MODES absent from all ${scanned} rendered manifests"

echo "== Self-test: duplicate managed environment-entry detector =="
# This does not scan module output; it proves the jq expression the checks
# above rely on actually flags a duplicate name, rather than being a
# vacuously true no-op.
duplicate_fixture='[{"name":"N8N_WEBHOOK_URL","value":"a"},{"name":"N8N_WEBHOOK_URL","value":"b"}]'
dup_count=$(echo "$duplicate_fixture" | jq '[.[].name] | group_by(.) | map(select(length > 1)) | length')
if [[ "$dup_count" -eq 0 ]]; then
  echo "FAIL: the duplicate-entry detector did not flag an intentionally duplicated fixture" >&2
  exit 1
fi

for template in deployment-main deployment-worker deployment-webhook-processor; do
  dup_count=$(jq '[.spec.template.spec.containers[0].env[].name] | group_by(.) | map(select(length > 1)) | length' "$tmp/multi-main-${template}.json")
  if [[ "$dup_count" -ne 0 ]]; then
    echo "FAIL: ${template} renders duplicate environment entry names" >&2
    exit 1
  fi
done
echo "PASS: duplicate-entry detector is effective, and no module-rendered container has a duplicate name"

echo
echo "PASS: check-n8n-chart.sh (chart ${chart_version})"
