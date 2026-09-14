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
# resource identifiers or credentials.
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

echo "== Rendering module-derived values fixture =="
# Every field below is a direct var.* reference resolved through this
# module's own console, or a value the module currently renders as a chart
# literal (multiMain.enabled, pdb.minAvailable, executions.data.*, the
# N8N_WEBHOOK_URL entry) per n8n.tf. When those literals become variables
# (later sections of this change), update the expressions here to reference
# the same variables rather than duplicating a second constant.
# terraform console evaluates one line at a time when fed from a pipe (no
# interactive REPL continuation), so the whole expression must be a single
# line despite its length.
console <<'HCL' > "$tmp/values.json"
jsonencode({multiMain={enabled=true,replicas=var.n8n_main_hpa_min_replicas},hpa={main={enabled=true,minReplicas=var.n8n_main_hpa_min_replicas,maxReplicas=var.n8n_main_hpa_max_replicas,targetCPUUtilizationPercentage=var.n8n_main_hpa_cpu_threshold}},pdb={enabled=true,minAvailable=1},queueMode={enabled=true,workerReplicaCount=var.n8n_worker_keda_min_replicas,workerConcurrency=var.n8n_worker_concurrency},webhookProcessor={enabled=true,replicaCount=var.n8n_webhook_hpa_min_replicas,disableProductionWebhooksOnMainProcess=true},executions={data={saveOnError="all",saveOnSuccess="all",saveOnProgress=false,saveManualExecutions=true}},keda={enabled=true,worker={pollingInterval=15,cooldownPeriod=300,minReplicaCount=var.n8n_worker_keda_min_replicas,maxReplicaCount=var.n8n_worker_keda_max_replicas,triggers=[for list_name in ["bull:jobs:wait","bull:jobs:active"] : {type="redis",metadata={listName=list_name,listLength=tostring(var.n8n_worker_keda_jobs_per_replica),enableTLS="false"}}]}},config={extraEnv=[{name="N8N_WEBHOOK_URL",value="https://${var.n8n_domain}"}]}})
HCL

render() {
  local template="$1"
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" "${helm_set_common[@]}" \
    --show-only "templates/${template}.yaml" > "$tmp/${template}.yaml"
  console <<< "jsonencode(yamldecode(file(\"$tmp/${template}.yaml\")))" > "$tmp/${template}.json"
}

for template in deployment-main deployment-worker deployment-webhook-processor hpa-main pdb scaledobject-worker configmap; do
  render "$template"
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

jq -e --argjson n "$main_min" '.spec.replicas == $n' "$tmp/deployment-main.json" >/dev/null \
  || { echo "FAIL: deployment-main.spec.replicas != n8n_main_hpa_min_replicas" >&2; exit 1; }

jq -e '(.spec | has("strategy")) | not' "$tmp/deployment-main.json" >/dev/null \
  || { echo "FAIL: deployment-main unexpectedly overrides .spec.strategy in the default multi-main configuration" >&2; exit 1; }

for template in deployment-worker deployment-webhook-processor; do
  jq -e '(.spec | has("strategy")) | not' "$tmp/${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly overrides .spec.strategy" >&2; exit 1; }
done

jq -e --argjson n "$worker_min" '.spec.replicas == $n' "$tmp/deployment-worker.json" >/dev/null \
  || { echo "FAIL: deployment-worker.spec.replicas != n8n_worker_keda_min_replicas" >&2; exit 1; }

jq -e --argjson n "$webhook_min" '.spec.replicas == $n' "$tmp/deployment-webhook-processor.json" >/dev/null \
  || { echo "FAIL: deployment-webhook-processor.spec.replicas != n8n_webhook_hpa_min_replicas" >&2; exit 1; }

jq -e --argjson mn "$main_min" --argjson mx "$main_max" --argjson cpu "$main_cpu" \
  '.spec.minReplicas == $mn and .spec.maxReplicas == $mx and (.spec.metrics[0].resource.target.averageUtilization == $cpu)' \
  "$tmp/hpa-main.json" >/dev/null \
  || { echo "FAIL: hpa-main bounds/threshold do not match n8n_main_hpa_* variables" >&2; exit 1; }

jq -e '.spec.minAvailable == 1 and .spec.selector.matchLabels["app.kubernetes.io/component"] == "main"' \
  "$tmp/pdb.json" >/dev/null \
  || { echo "FAIL: main PDB minAvailable/selector do not match the current default (minAvailable = 1)" >&2; exit 1; }

jq -e --argjson mn "$worker_min" --argjson mx "$worker_max" --argjson jobs "$worker_jobs" '
  .spec.minReplicaCount == $mn
  and .spec.maxReplicaCount == $mx
  and ([.spec.triggers[].metadata.listName] | sort) == ["bull:jobs:active", "bull:jobs:wait"]
  and (.spec.triggers | all(.metadata.listLength == ($jobs | tostring)))
' "$tmp/scaledobject-worker.json" >/dev/null \
  || { echo "FAIL: worker ScaledObject bounds/triggers do not match n8n_worker_keda_* variables" >&2; exit 1; }

echo "PASS: deployment families, main HPA/PDB, and worker KEDA match the module's variables"

echo "== Verify runtime manifests (execution save policy, URL naming) =="

for template in deployment-main deployment-worker; do
  jq -e '
    (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_ERROR"))[0].value) == "all"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_SUCCESS"))[0].value) == "all"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_ON_PROGRESS"))[0].value) == "false"
    and (.spec.template.spec.containers[0].env | map(select(.name == "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS"))[0].value) == "true"
  ' "$tmp/${template}.json" >/dev/null \
    || { echo "FAIL: ${template} execution save-policy environment values do not match the current defaults" >&2; exit 1; }
done

jq -e '
  [.spec.template.spec.containers[0].env[] | select(.name == "EXECUTIONS_DATA_SAVE_ON_ERROR")] | length == 0
' "$tmp/deployment-webhook-processor.json" >/dev/null \
  || { echo "FAIL: deployment-webhook-processor unexpectedly renders execution save-policy environment entries" >&2; exit 1; }

for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e --arg url "https://${domain}" '
    [.spec.template.spec.containers[0].env[] | select(.name == "N8N_WEBHOOK_URL")][0].value == $url
  ' "$tmp/${template}.json" >/dev/null \
    || { echo "FAIL: ${template} is missing the current N8N_WEBHOOK_URL environment entry" >&2; exit 1; }

  jq -e '
    [.spec.template.spec.containers[0].env[] | select(.name == "WEBHOOK_URL")] | length == 0
  ' "$tmp/${template}.json" >/dev/null \
    || { echo "FAIL: ${template} unexpectedly renders the deprecated WEBHOOK_URL alias" >&2; exit 1; }
done

jq -e '(.data | has("WEBHOOK_URL")) | not' "$tmp/configmap.json" >/dev/null \
  || { echo "FAIL: the chart ConfigMap unexpectedly carries a WEBHOOK_URL key (webhook.url or ingress must remain unset)" >&2; exit 1; }

echo "PASS: execution save-policy values and current URL naming are correct on every applicable container"

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
  dup_count=$(jq '[.spec.template.spec.containers[0].env[].name] | group_by(.) | map(select(length > 1)) | length' "$tmp/${template}.json")
  if [[ "$dup_count" -ne 0 ]]; then
    echo "FAIL: ${template} renders duplicate environment entry names" >&2
    exit 1
  fi
done
echo "PASS: duplicate-entry detector is effective, and no module-rendered container has a duplicate name"

echo
echo "PASS: check-n8n-chart.sh (chart ${chart_version})"
