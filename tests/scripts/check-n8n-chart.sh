#!/usr/bin/env bash
# Render the module's actual locals/variables against the pinned n8n Helm
# chart and assert on the manifests Helm produces. This is a regression check
# against the real module-to-chart mapping, not an independently maintained
# approximation: every value asserted below is pulled from `terraform console`
# against this root module rather than retyped by hand.
#
# Requires `terraform init -backend=false` to have already run at the module
# root, plus `helm` and `jq` on PATH. No plan/apply, cluster access, Azure
# credentials, or state persistence beyond a throwaway temp directory. Helm's
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
    "$@" | jq -er .
}

# helm template requires exactly these fields to be known for queue mode's
# chart-native validation (`n8n.validate` in _helpers.tpl); they are dummy
# strings, not the module's real managed/external connection locals, which
# can be unknown at plan time when the managed database/Redis resources are
# in play. Structural assertions below never depend on these values.
helm_set_common=(
  --set secretRefs.existingSecret=test-core
  --set license.enabled=true
  --set license.existingSecret.name=test-license
  --set database.useExternal=true
  --set database.host=test-db.example.invalid
  --set redis.enabled=true
  --set redis.host=test-redis.example.invalid
)

chart_version=$(console <<< 'var.n8n_chart_version')
echo "== Pulling n8n chart ${chart_version} =="
helm pull "oci://ghcr.io/n8n-io/n8n-helm-chart/n8n" --version "$chart_version" --untar --untardir "$tmp"

# Renders the module's real multiMain/replicaCount/strategy/pdb/hpa mapping
# (locals.tf's n8n_main_multi_enabled / n8n_main_hpa_effective_max_replicas
# selectors, wired in n8n.tf) for one topology, plus the other module fields
# unaffected by topology. Every value is read directly from this module's own
# console rather than retyped, so a future n8n.tf change that touches these
# paths is caught here. terraform console evaluates one line at a time when
# fed from a pipe (no interactive REPL continuation), so the whole expression
# must be a single line despite its length.
render_topology_values() {
  local out="$1"
  shift
  console "$@" <<'HCL' > "$out"
jsonencode({multiMain={enabled=local.n8n_main_multi_enabled,replicas=var.n8n_main_hpa_min_replicas},replicaCount=var.n8n_main_hpa_min_replicas,strategy=local.n8n_main_multi_enabled?{}:{type="Recreate"},hpa={main={enabled=true,minReplicas=var.n8n_main_hpa_min_replicas,maxReplicas=local.n8n_main_hpa_effective_max_replicas,targetCPUUtilizationPercentage=var.n8n_main_hpa_cpu_threshold}},pdb={enabled=true,minAvailable=local.n8n_main_multi_enabled?1:0},queueMode={enabled=true,workerReplicaCount=var.n8n_worker_keda_min_replicas,workerConcurrency=var.n8n_worker_concurrency},webhookProcessor={enabled=true,replicaCount=var.n8n_webhook_hpa_min_replicas,disableProductionWebhooksOnMainProcess=true},executions={data={saveOnError=var.n8n_executions_data_save_on_error,saveOnSuccess=var.n8n_executions_data_save_on_success,saveOnProgress=var.n8n_executions_data_save_on_progress,saveManualExecutions=var.n8n_executions_data_save_manual_executions}},redis=length(local.n8n_queue_worker_settings)==0?{}:{worker=local.n8n_queue_worker_settings},keda={enabled=true,worker={pollingInterval=15,cooldownPeriod=300,minReplicaCount=var.n8n_worker_keda_min_replicas,maxReplicaCount=var.n8n_worker_keda_max_replicas,triggers=[for list_name in ["bull:jobs:wait","bull:jobs:active"] : {type="redis",metadata={listName=list_name,listLength=tostring(var.n8n_worker_keda_jobs_per_replica),enableTLS="false"}}]}},config={extraEnv=concat([{name="N8N_WEBHOOK_URL",value="https://${var.n8n_domain}"}],local.n8n_postgres_runtime_env,local.n8n_node_heap_env)}})
HCL
}

render() {
  local values_file="$1"
  local out_prefix="$2"
  local template="$3"
  helm template n8n "$tmp/n8n" -f "$values_file" "${helm_set_common[@]}" \
    --show-only "templates/${template}.yaml" > "$tmp/${out_prefix}-${template}.yaml"
  console <<< "jsonencode(yamldecode(file(\"$tmp/${out_prefix}-${template}.yaml\")))" > "$tmp/${out_prefix}-${template}.json"
}

echo "== Rendering default multi-main values fixture =="
render_topology_values "$tmp/multi-main-values.json"

echo "== Rendering single-main values fixture (minimum 1, a higher configured maximum) =="
render_topology_values "$tmp/single-main-values.json" \
  -var='n8n_main_hpa_min_replicas=1' \
  -var='n8n_main_hpa_max_replicas=20'

echo "== Rendering PostgreSQL runtime-tuning values fixture (all four timing overrides) =="
render_topology_values "$tmp/pg-runtime-values.json" \
  -var='postgres_connection_timeout_ms=45000' \
  -var='postgres_ping_timeout_ms=15000' \
  -var='postgres_ping_interval_seconds=5' \
  -var='postgres_ping_max_failures_before_recovery=6'

echo "== Rendering Bull worker timing values fixture (all three timing overrides) =="
render_topology_values "$tmp/worker-timing-values.json" \
  -var='n8n_queue_worker_lock_duration=90000' \
  -var='n8n_queue_worker_lock_renew_time=15000' \
  -var='n8n_queue_worker_stalled_interval=45000'

echo "== Rendering execution save-policy values fixture (independent success/error policies, both booleans changed) =="
render_topology_values "$tmp/save-policy-values.json" \
  -var='n8n_executions_data_save_on_success=none' \
  -var='n8n_executions_data_save_on_error=all' \
  -var='n8n_executions_data_save_on_progress=true' \
  -var='n8n_executions_data_save_manual_executions=false'

echo "== Rendering application heap ceiling values fixture =="
render_topology_values "$tmp/heap-values.json" \
  -var='n8n_node_max_old_space_size_mb=768'

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
  render "$tmp/worker-timing-values.json" worker-timing "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/save-policy-values.json" save-policy "$template"
done

for template in deployment-main deployment-worker deployment-webhook-processor; do
  render "$tmp/heap-values.json" heap "$template"
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

jq -e --argjson n "$worker_min" '.spec.replicas == $n' "$tmp/multi-main-deployment-worker.json" >/dev/null \
  || { echo "FAIL: deployment-worker.spec.replicas != n8n_worker_keda_min_replicas" >&2; exit 1; }

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

for template in deployment-main deployment-worker; do
  jq -e '
    (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_ERROR"))[0].value) == "all"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_SUCCESS"))[0].value) == "all"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_PROGRESS"))[0].value) == "false"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS"))[0].value) == "true"
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} execution save-policy environment values do not match the current defaults" >&2; exit 1; }
done

jq -e '
  [.spec.template.spec.containers[0].env[] | select(.name == "EXECUTIONS_DATA_SAVE_ON_ERROR")] | length == 0
' "$tmp/multi-main-deployment-webhook-processor.json" >/dev/null \
  || { echo "FAIL: deployment-webhook-processor unexpectedly renders execution save-policy environment entries" >&2; exit 1; }

for template in deployment-main deployment-worker; do
  jq -e '
    (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_ERROR"))[0].value) == "all"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_SUCCESS"))[0].value) == "none"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_PROGRESS"))[0].value) == "true"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS"))[0].value) == "false"
  ' "$tmp/save-policy-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} execution save-policy environment values do not match the independently overridden fixture" >&2; exit 1; }
done

jq -e '
  [.spec.template.spec.containers[0].env[] | select(.name == "EXECUTIONS_DATA_SAVE_ON_ERROR")] | length == 0
' "$tmp/save-policy-deployment-webhook-processor.json" >/dev/null \
  || { echo "FAIL: deployment-webhook-processor unexpectedly renders execution save-policy environment entries in the overridden fixture" >&2; exit 1; }

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e --arg url "https://${domain}" '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WEBHOOK_URL")][0].value == $url
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing the current N8N_WEBHOOK_URL environment entry" >&2; exit 1; }

  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "WEBHOOK_URL")] | length == 0
  ' "$tmp/multi-main-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders the deprecated WEBHOOK_URL alias" >&2; exit 1; }
done

jq -e '(.data | has("WEBHOOK_URL")) | not' "$tmp/multi-main-configmap.json" >/dev/null \
  || { echo "FAIL: the chart ConfigMap unexpectedly carries a WEBHOOK_URL key (webhook.url or ingress must remain unset)" >&2; exit 1; }

echo "PASS: execution save-policy values and current URL naming are correct on every applicable container"

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

echo "== Verify Bull worker timing manifests (lock duration/renewal/stalled interval) =="

jq -e '
  .data.QUEUE_WORKER_LOCK_DURATION == "90000"
  and .data.QUEUE_WORKER_LOCK_RENEW_TIME == "15000"
  and .data.QUEUE_WORKER_STALLED_INTERVAL == "45000"
' "$tmp/worker-timing-configmap.json" >/dev/null \
  || { echo "FAIL: the chart ConfigMap is missing one or more Bull worker timing overrides" >&2; exit 1; }

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e '
    ([.spec.template.spec.containers[0].env[] | select(.name == "QUEUE_WORKER_LOCK_DURATION")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "QUEUE_WORKER_LOCK_RENEW_TIME")] | length == 1)
    and ([.spec.template.spec.containers[0].env[] | select(.name == "QUEUE_WORKER_STALLED_INTERVAL")] | length == 1)
  ' "$tmp/worker-timing-${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing one or more Bull worker timing ConfigMap references" >&2; exit 1; }
done

jq -e '
  .data.QUEUE_WORKER_LOCK_DURATION == "60000"
  and .data.QUEUE_WORKER_LOCK_RENEW_TIME == "10000"
  and .data.QUEUE_WORKER_STALLED_INTERVAL == "30000"
' "$tmp/multi-main-configmap.json" >/dev/null \
  || { echo "FAIL: the default fixture (all three worker timing inputs null) must retain the chart's own pinned defaults (60000/10000/30000 ms) unchanged" >&2; exit 1; }

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
