#!/usr/bin/env bash
# Pre-apply check that the target Azure region and subscription can actually
# host this module's managed services. Catches the four region/subscription
# gaps observed in live runs before a 15-30 minute apply hits them:
#
#   AKS        AvailabilityZoneNotSupported  (zones missing for the VM SKU)
#   AKS        OperationNotAllowed quota      (vCPU quota below the node pools' ceiling;
#                                             surfaces as a helm_release.n8n timeout)
#   PostgreSQL ParameterOutOfRange 'Version'   (no Flexible Server versions offered)
#   Redis      InsufficientCapacity           (Azure Managed Redis has no room)
#
# Azure exposes no capacity API for Managed Redis; the only reliable test is a
# real create. `--probe-redis` creates a throwaway cluster in a throwaway
# resource group, reports the outcome, and deletes it (success 5-10 min, capacity
# failure usually < 1 min; billed by the minute). Without the flag the Redis
# check is skipped and the report says so.
#
# By default the script reads region and sizing from *your* configuration: it
# runs `terraform plan -refresh=false` in the current directory (any root that
# calls this module - an example or your own) and pulls location, VM size,
# node pool ceilings (max_count), zones, PostgreSQL version/SKU, and Redis SKU
# from the planned resources, so a check matches exactly what apply would
# request. Every value can be overridden with a flag; `--region` alone skips
# the plan and uses flag/root-module defaults.
#
# `PREFLIGHT_SELF_TEST=1 ./preflight-region-check.sh` runs the input validation
# and quota evaluation against synthetic fixtures and exits before any `az` or
# `terraform` call, so CI can exercise it offline (needs only `jq`).
#
# Requires `az` >= 2.75 (older releases return a different `az postgres
# flexible-server list-skus` payload and the `redisenterprise` extension
# declares that floor), logged in with the target subscription selected, `jq`,
# and - unless `--region` is given - `terraform` with `terraform init` already
# run in the root. `--probe-redis` also needs the `redisenterprise` CLI
# extension, which the script installs when missing. Read-only except for the optional
# Redis probe. Non-zero exit when any check fails. Run with `--help` for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage (from the root you will apply, e.g. examples/small):
  ../../tests/scripts/preflight-region-check.sh [options]
    --dir PATH           Terraform root to plan (default: current directory)
    --region NAME        skip the plan; use this region + flag/root defaults
    --vm-size SKU        aks_node_vm_size          (root default Standard_D4s_v4)
    --node-count-max N   aks_node_count_max        (root default 6; the system and user node
                                                     pools each scale aks_node_count_min..N
                                                     independently, so peak demand is 2 x N
                                                     nodes of --vm-size)
    --zones 1,2,3        aks_availability_zones    (root default 1,2,3; pass '' for a zone-less region)
    --pg-version N       pg_version                (root default 16)
    --pg-sku SKU         pg_sku_name               (root default GP_Standard_D2s_v3)
    --redis-sku SKU      redis_sku_name            (root default Balanced_B1)
    --probe-redis        actually create+delete a Managed Redis cluster
    -h, --help           show this help
EOF
}

# `zones_set` distinguishes an explicit `--zones ''` (zone-less region) from
# an omitted flag, which falls back to the plan or the root default.
dir=. region='' vm_size='' node_count_max='' node_count_max_set=false zones='' zones_set=false pg_version='' pg_sku='' redis_sku='' probe_redis=false
need_value() { (($# >= 2)) || { echo "Option $1 requires a value" >&2; usage >&2; exit 2; }; }
while (($#)); do
  case $1 in
    --dir) need_value "$@"; dir=$2; shift 2 ;;
    --region) need_value "$@"; region=$2; shift 2 ;;
    --vm-size) need_value "$@"; vm_size=$2; shift 2 ;;
    --node-count-max) need_value "$@"; node_count_max=$2; node_count_max_set=true; shift 2 ;;
    --zones) need_value "$@"; zones=$2; zones_set=true; shift 2 ;;
    --pg-version) need_value "$@"; pg_version=$2; shift 2 ;;
    --pg-sku) need_value "$@"; pg_sku=$2; shift 2 ;;
    --redis-sku) need_value "$@"; redis_sku=$2; shift 2 ;;
    --probe-redis) probe_redis=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

failed=0 warned=0
pass() { printf '  \xe2\x9c\x94  %s\n' "$1"; }
fail() { printf '  \xe2\x9c\x98  %s\n' "$1"; failed=1; }
warn() { printf '  !  %s\n' "$1"; warned=1; }
skip() { printf '  \xe2\x80\x93  %s\n' "$1"; }

# Strict, bounded integer tests. Every value that reaches bash arithmetic goes
# through one of these first: bash evaluates array subscripts inside $((...)),
# so an unchecked value such as 'a[$(cmd)]' would run cmd, an unset name trips
# `set -u` mid-report, and bash wraps on overflow instead of failing. At most
# nine digits (and 1000 nodes per pool, the AKS limit) keeps every sum and
# product below 2^63.
is_pos_int() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }
is_uint() { [[ $1 =~ ^(0|[1-9][0-9]{0,8})$ ]]; }
is_node_count() { is_pos_int "$1" && (($1 <= 1000)); }

# Plan readers (terraform show -json output in a file). Managed resources
# only: the module also declares data sources (e.g.
# data.azurerm_kubernetes_cluster.existing) whose location may differ.
managed='.planned_values.root_module | recurse(.child_modules[]?) | .resources[]? | select(.mode == "managed")'
# plan_pool_maxes PLAN VM_SIZE: max_count of the cluster default pool and of
# every separate node pool of VM_SIZE, space-separated, so the worst case is
# summed rather than assumed from the system pool (the user pool mirrors it
# in aks.tf today, but that is not a contract). null/unknown prints "null".
plan_pool_maxes() {
  jq -r --arg vm "$2" "[$managed | if .type == \"azurerm_kubernetes_cluster\" then .values.default_node_pool[0] elif .type == \"azurerm_kubernetes_cluster_node_pool\" then .values else empty end | select(.vm_size == \$vm) | .max_count | tostring] | join(\" \")" "$1"
}
# plan_quota_mode PLAN: `fail` only when every AKS cluster and node pool
# change in the plan is a pure create, so no counted node can already be
# inside currentValue. Anything else (no-op, update, replace, a mix of new
# and existing clusters, or no AKS change at all) is `warn`. Deposed objects
# are ignored.
plan_quota_mode() {
  jq -r '[.resource_changes[]? | select(.mode == "managed" and (.type == "azurerm_kubernetes_cluster" or .type == "azurerm_kubernetes_cluster_node_pool") and .deposed == null) | .change.actions] | if length > 0 and all(. == ["create"]) then "fail" else "warn" end' "$1"
}

# check_quota USAGE_JSON KEY LABEL NEEDED MODE
# Compares one `az vm list-usage` row (matched on .name.value == KEY) against
# NEEDED vCPUs. MODE is `fail` for a cluster this apply creates, or `warn` for
# an existing one, whose own nodes are already inside currentValue, so an
# over-limit result there can be a false positive.
check_quota() {
  local usage=$1 key=$2 label=$3 needed=$4 mode=$5
  local row current limit msg
  row=$(jq -c --arg n "$key" '[.[] | select(.name.value == $n)][0] // empty' "$usage")
  if [[ -z $row ]]; then
    skip "$label ('$key') not found in az vm list-usage output; vCPU quota unchecked for it"
    return
  fi
  current=$(jq -r '.currentValue' <<<"$row")
  limit=$(jq -r '.limit' <<<"$row")
  if ! is_uint "$current" || ! is_uint "$limit"; then
    skip "$label ('$key') returned non-numeric or out-of-range usage ($current/$limit); vCPU quota unchecked for it"
    return
  fi
  if ((current + needed <= limit)); then
    pass "$label: $current used + $needed needed <= $limit limit"
    return
  fi
  msg="$label: $current used + $needed needed > $limit limit -> request a quota increase (az quota update --resource-name $key --scope /subscriptions/<id>/providers/Microsoft.Compute/locations/${region:-<region>} --limit-object value=<new> --resource-type dedicated; needs 'az extension add -n quota'), pick a smaller aks_node_vm_size/aks_node_count_max, or try another region"
  if [[ $mode == warn ]]; then
    warn "$msg (existing cluster: verify before acting)"
  else
    fail "$msg"
  fi
}

if [[ "${PREFLIGHT_SELF_TEST:-0}" == "1" ]]; then
  command -v jq >/dev/null || { echo "Required tool missing: jq" >&2; exit 1; }
  st_tmp=$(mktemp -d); trap 'rm -rf "$st_tmp"' EXIT
  st_failures=0
  # Every probe is written as `rc=0; <cond> || rc=1` so a failing condition
  # is recorded instead of tripping `set -e`.
  st_expect() { # st_expect NAME RC
    if [[ $2 -eq 0 ]]; then echo "self-test ok:   $1"; else echo "self-test FAIL: $1" >&2; st_failures=$((st_failures + 1)); fi
  }
  for v in 1 6 12 999999999; do rc=0; is_pos_int "$v" || rc=1; st_expect "is_pos_int accepts '$v'" "$rc"; done
  # shellcheck disable=SC2016 # the literal '$(false)' is the injection probe
  for v in '' 0 -1 abc 2.5 06 ' 6' 'a[$(false)]' 1000000000 9223372036854775808; do
    rc=1; is_pos_int "$v" || rc=0; st_expect "is_pos_int rejects '$v'" "$rc"
  done
  for v in 1 1000; do rc=0; is_node_count "$v" || rc=1; st_expect "is_node_count accepts '$v'" "$rc"; done
  for v in 0 1001 4611686018427387904; do rc=1; is_node_count "$v" || rc=0; st_expect "is_node_count rejects '$v'" "$rc"; done
  # Plan readers: a child-module cluster plus a user pool of the same size are
  # summed; a pool of another size and a data source are ignored.
  st_plan() { # st_plan FILE CLUSTER_ACTIONS POOL_ACTIONS [USER_MAX] [EXTRA_CHANGE]
    cat >"$1" <<JSON
{"planned_values":{"root_module":{"resources":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"vm_size":"Standard_D8s_v5","max_count":9}}],
 "child_modules":[{"resources":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster","values":{"default_node_pool":[{"vm_size":"Standard_D2s_v5","max_count":2}]}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"vm_size":"Standard_D2s_v5","max_count":${4:-3}}},
  {"mode":"data","type":"azurerm_kubernetes_cluster","values":{"default_node_pool":[{"vm_size":"Standard_D2s_v5","max_count":50}]}}]}]}},
 "resource_changes":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster","change":{"actions":$2}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","change":{"actions":$3}}${5:-}]}
JSON
  }
  st_plan "$st_tmp/p.json" '["create"]' '["create"]'
  out=$(plan_pool_maxes "$st_tmp/p.json" Standard_D2s_v5); rc=0; [[ $out == "2 3" ]] || rc=1
  st_expect "plan_pool_maxes sums matching pools across modules, ignores other sizes and data sources (got '$out')" "$rc"
  st_plan "$st_tmp/p.json" '["create"]' '["create"]' null
  out=$(plan_pool_maxes "$st_tmp/p.json" Standard_D2s_v5); rc=0; [[ $out == "2 null" ]] || rc=1
  st_expect "plan_pool_maxes surfaces an unknown max_count as 'null' (got '$out')" "$rc"
  st_mode() { # st_mode NAME EXPECTED CLUSTER_ACTIONS POOL_ACTIONS [EXTRA_CHANGE]
    st_plan "$st_tmp/p.json" "$3" "$4" 3 "${5:-}"
    out=$(plan_quota_mode "$st_tmp/p.json"); rc=0; [[ $out == "$2" ]] || rc=1
    st_expect "plan_quota_mode: $1 -> $2 (got '$out')" "$rc"
  }
  st_mode "new cluster and pool" fail '["create"]' '["create"]'
  st_mode "existing cluster, no-op" warn '["no-op"]' '["no-op"]'
  st_mode "existing cluster, update" warn '["update"]' '["no-op"]'
  st_mode "replace (delete, create)" warn '["delete","create"]' '["delete","create"]'
  st_mode "new pool on existing cluster" warn '["no-op"]' '["create"]'
  st_mode "second, existing cluster in the plan" warn '["create"]' '["create"]' ',{"mode":"managed","type":"azurerm_kubernetes_cluster","change":{"actions":["no-op"]}}'
  st_mode "deposed object ignored" fail '["create"]' '["create"]' ',{"mode":"managed","type":"azurerm_kubernetes_cluster","deposed":"abc123","change":{"actions":["delete"]}}'
  printf '{"resource_changes":[]}' >"$st_tmp/p.json"
  out=$(plan_quota_mode "$st_tmp/p.json"); rc=0; [[ $out == warn ]] || rc=1
  st_expect "plan_quota_mode: no AKS change -> warn (got '$out')" "$rc"
  cat >"$st_tmp/usage.json" <<'JSON'
[{"name":{"value":"standardDSv5Family"},"currentValue":8,"limit":20},
 {"name":{"value":"cores"},"currentValue":8,"limit":10},
 {"name":{"value":"weirdFamily"},"currentValue":"x","limit":10}]
JSON
  st_quota() { # st_quota KEY NEEDED MODE -> check_quota output plus final failed=N
    failed=0; check_quota "$st_tmp/usage.json" "$1" "$1" "$2" "$3"; echo "failed=$failed"
  }
  # Fits under the family cap, exceeds the aggregate cap.
  out=$(st_quota standardDSv5Family 8 fail); rc=0
  [[ $out == *"8 used + 8 needed <= 20 limit"* && $out == *failed=0 ]] || rc=1
  st_expect "family quota passes within limit" "$rc"
  out=$(st_quota cores 8 fail); rc=0
  [[ $out == *"8 used + 8 needed > 10 limit"* && $out == *"az extension add -n quota"* && $out == *failed=1 ]] || rc=1
  st_expect "cores quota fails for a new cluster" "$rc"
  out=$(st_quota cores 8 warn); rc=0
  [[ $out == *"existing cluster"* && $out == *failed=0 ]] || rc=1
  st_expect "cores quota only warns for an existing cluster" "$rc"
  out=$(st_quota cores 2 fail); rc=0
  [[ $out == *"8 used + 2 needed <= 10 limit"* && $out == *failed=0 ]] || rc=1
  st_expect "quota exactly at the limit passes" "$rc"
  out=$(st_quota missingFamily 8 fail); rc=0
  [[ $out == *"not found"* && $out == *failed=0 ]] || rc=1
  st_expect "missing usage row is skipped" "$rc"
  out=$(st_quota weirdFamily 8 fail); rc=0
  [[ $out == *"non-numeric or out-of-range"* && $out == *failed=0 ]] || rc=1
  st_expect "non-numeric usage row is skipped" "$rc"
  if ((st_failures)); then echo "self-test: $st_failures failure(s)" >&2; exit 1; fi
  echo "self-test: all checks passed"
  exit 0
fi

for tool in az jq; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
# The PostgreSQL capability payload this script parses (top-level
# supportedServerVersions, supportedServerEditions[].supportedServerSkus) is
# what az >= 2.75 returns; older releases nest it differently and would report
# every version and SKU as missing.
az_version=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 0.0.0)
if [[ $(printf '%s\n' 2.75.0 "$az_version" | sort -V | head -1) != 2.75.0 ]]; then
  echo "Azure CLI >= 2.75 required (found $az_version); run az upgrade" >&2; exit 1
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Pull whatever the caller did not override from the planned resources. Works
# for any module depth; a resource that the config does not create (e.g.
# create_redis = false) is simply absent and its check is skipped.
source=flags/defaults
# peak_nodes: worst-case node count of --vm-size across every module node pool
# at max_count. quota_mode: fail when the plan only creates AKS clusters and
# pools, warn otherwise (see plan_quota_mode). Without a plan we cannot tell,
# so fail.
peak_nodes='' quota_mode=fail
if [[ -z $region ]]; then
  command -v terraform >/dev/null || { echo "terraform missing; pass --region to skip the plan" >&2; exit 1; }
  echo "Planning $dir to read region and sizing (override any value with a flag) ..."
  terraform -chdir="$dir" plan -refresh=false -input=false -lock=false -out="$tmp/plan" >"$tmp/plan.log" 2>&1 \
    || { cat "$tmp/plan.log" >&2; echo "terraform plan failed; fix it or pass --region and sizing flags" >&2; exit 1; }
  terraform -chdir="$dir" show -json "$tmp/plan" >"$tmp/plan.json"
  plan=$(<"$tmp/plan.json")
  res() { jq -r --arg t "$1" --arg p "$2" \
    "[$managed | select(.type == \$t)][0].values | getpath(\$p | split(\".\") | map(tonumber? // .)) // empty" <<<"$plan"; }
  locations=$(jq -r "[$managed | select(.type == \"azurerm_kubernetes_cluster\" or .type == \"azurerm_postgresql_flexible_server\" or .type == \"azurerm_managed_redis\" or .type == \"azurerm_resource_group\") | .values.location // empty] | unique | join(\" \")" <<<"$plan")
  case $(wc -w <<<"$locations" | tr -d ' ') in
    0) echo "could not find a location in the plan; pass --region" >&2; exit 1 ;;
    1) region=$locations ;;
    *) echo "plan spans several regions ($locations); pass --region to pick one" >&2; exit 1 ;;
  esac
  [[ -n $vm_size ]] || vm_size=$(res azurerm_kubernetes_cluster default_node_pool.0.vm_size)
  if ! $node_count_max_set && [[ -n $vm_size ]]; then
    node_count_max=$(res azurerm_kubernetes_cluster default_node_pool.0.max_count)
    pool_maxes=$(plan_pool_maxes "$tmp/plan.json" "$vm_size")
    peak_nodes=0
    for m in $pool_maxes; do
      is_node_count "$m" || { echo "planned node pool max_count '$m' is not an integer from 1 to 1000; pass --node-count-max N" >&2; exit 2; }
      peak_nodes=$((peak_nodes + m))
    done
    ((peak_nodes > 0)) || peak_nodes=''
  fi
  quota_mode=$(plan_quota_mode "$tmp/plan.json")
  $zones_set || zones=$(res azurerm_kubernetes_cluster default_node_pool.0.zones | jq -r 'join(",")' 2>/dev/null || true)
  [[ -n $pg_version ]] || pg_version=$(res azurerm_postgresql_flexible_server version)
  [[ -n $pg_sku ]] || pg_sku=$(res azurerm_postgresql_flexible_server sku_name)
  [[ -n $redis_sku ]] || redis_sku=$(res azurerm_managed_redis sku_name)
  source="terraform plan of $dir"
else
  : "${vm_size:=Standard_D4s_v4}" "${pg_version:=16}" "${pg_sku:=GP_Standard_D2s_v3}" "${redis_sku:=Balanced_B1}"
  $node_count_max_set || node_count_max=6
  $zones_set || zones=1,2,3
  echo "NOTE: --region given; checking root-module defaults and flags, not the terraform.tfvars of $dir." >&2
fi

if [[ -n $vm_size && -z $peak_nodes ]]; then
  is_node_count "$node_count_max" \
    || { echo "aks_node_count_max must be an integer from 1 to 1000 (got '${node_count_max:-<empty>}'); pass --node-count-max N" >&2; exit 2; }
  peak_nodes=$((2 * node_count_max))
fi
# Run an az command, keeping stdout in $1 (a file) and reporting the first
# stderr line on failure, so an expired login or a typo is never mistaken for
# "SKU not offered".
az_json() { local out=$1; shift; az "$@" -o json >"$out" 2>"$tmp/az.err"; }
az_err() { head -1 "$tmp/az.err" 2>/dev/null || true; }

sub=$(az account show --query '{name:name,id:id}' -o tsv 2>"$tmp/az.err" | tr '\t' ' ') \
  || { echo "az account show failed ($(az_err)); run az login and select the target subscription" >&2; exit 1; }
if ! az_json "$tmp/loc.json" account list-locations --query "[?name=='$region']"; then
  echo "az account list-locations failed: $(az_err)" >&2; exit 1
fi
[[ $(jq 'length' "$tmp/loc.json") -eq 1 ]] \
  || { echo "Unknown region '$region' for this subscription (az account list-locations -o table lists the valid names)" >&2; exit 1; }
echo "Region: $region   Subscription: $sub"
echo "Inputs from $source: vm=${vm_size:-n/a} node_count_max=${node_count_max:-n/a} zones=[${zones:-none}] pg=${pg_version:-n/a}/${pg_sku:-n/a} redis=${redis_sku:-n/a}"

echo
echo "== Resource providers =="
for rp in Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Cache Microsoft.Network Microsoft.Storage Microsoft.KeyVault Microsoft.ManagedIdentity; do
  state=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo Unknown)
  if [[ $state == Registered ]]; then pass "$rp registered"; else fail "$rp is $state (az provider register -n $rp)"; fi
done

echo
echo "== AKS: ${vm_size:-n/a} zones [${zones:-none}] =="
if [[ -z $vm_size ]]; then
  skip "no module-managed AKS cluster in the plan (create_aks = false); nothing to check"
# --all keeps SKUs the subscription is restricted from, so the restriction
# reason is reported instead of a bare "not offered".
elif ! az_json "$tmp/skus.json" vm list-skus -l "$region" --size "$vm_size" --resource-type virtualMachines --all; then
  fail "az vm list-skus failed: $(az_err)"
elif ! sku_json=$(jq -ce --arg n "$vm_size" '[.[] | select(.name == $n)][0] // empty' "$tmp/skus.json"); then
  fail "$vm_size is not offered in $region (aks_node_vm_size)"
else
  # A Location restriction blocks the SKU outright; a Zone restriction only
  # removes the listed zones, so subtract those from the offered set instead.
  loc_restr=$(jq -r '[.restrictions[]? | select(.type == "Location") | .reasonCode] | unique | join(",")' <<<"$sku_json")
  offered=$(jq -r '([.locationInfo[0].zones[]?]) - ([.restrictions[]? | select(.type == "Zone") | .restrictionInfo.zones[]?]) | sort | join(",")' <<<"$sku_json")
  missing=$(comm -23 <(tr ',' '\n' <<<"$zones" | sort) <(tr ',' '\n' <<<"$offered" | sort) | paste -sd, -)
  if [[ -n $loc_restr ]]; then
    fail "$vm_size restricted for this subscription in $region: $loc_restr (request quota or pick another aks_node_vm_size); zone check skipped"
  elif [[ -z $missing ]]; then
    pass "$vm_size offered with no location-level subscription restrictions"
    pass "zones [${zones:-none}] supported (region offers [${offered:-none}])"
  else
    pass "$vm_size offered with no location-level subscription restrictions"
    hcl=$([[ -n $offered ]] && sed 's/[^,]*/"&"/g' <<<"$offered" || true)
    fail "zones [$missing] not offered for $vm_size in $region; region offers [${offered:-none}] -> set aks_availability_zones = [$hcl]"
  fi
fi

echo
echo "== vCPU quota headroom: ${vm_size:-n/a} x ${peak_nodes:-n/a} nodes (every node pool at max_count) =="
# AKS SKU/zone availability (checked above) says nothing about whether the
# subscription's regional vCPU quota can actually hold the autoscaler's
# ceiling; a quota wall surfaces only ~10-20 min into apply, as
# helm_release.n8n's 600s timeout expires waiting for a node the autoscaler
# could not add (Error: OperationNotAllowed, "Operation results in exceeding
# quota limits"). Both node pools share var.aks_node_vm_size and each scales
# aks_node_count_min..aks_node_count_max independently (aks.tf), so worst-case
# demand is both pools simultaneously at the ceiling: 2 x aks_node_count_max
# nodes. Upgrade surge (aks_node_upgrade_max_surge) and temporary rotation
# pools add nodes on top of that later; they are not part of this check.
if [[ -z $vm_size ]]; then
  skip "no module-managed AKS cluster in the plan (create_aks = false); nothing to check"
elif [[ ! -s "$tmp/skus.json" ]]; then
  skip "SKU lookup for $vm_size did not run or failed above; vCPU quota unchecked"
else
  vcpus=$(jq -r --arg n "$vm_size" '[.[] | select(.name == $n)][0].capabilities[]? | select(.name == "vCPUs") | .value' "$tmp/skus.json")
  family=$(jq -r --arg n "$vm_size" '[.[] | select(.name == $n)][0].family // empty' "$tmp/skus.json")
  if ! is_pos_int "$vcpus" || [[ -z $family ]]; then
    skip "could not read vCPU count/family for $vm_size from the SKU lookup above; vCPU quota unchecked"
  elif ! az_json "$tmp/usage.json" vm list-usage -l "$region"; then
    fail "az vm list-usage failed: $(az_err)"
  else
    needed=$((peak_nodes * vcpus))
    # "cores" is the subscription's aggregate regional vCPU cap across every
    # VM family; the family entry (e.g. standardDSv5Family) is a separate,
    # usually tighter, per-family cap. Both must clear the ceiling.
    check_quota "$tmp/usage.json" "$family" "$vm_size family quota" "$needed" "$quota_mode"
    check_quota "$tmp/usage.json" cores "Regional aggregate vCPU quota" "$needed" "$quota_mode"
    if [[ $quota_mode == warn ]]; then
      echo "  (this plan keeps an existing AKS cluster: currentValue already counts its nodes, so an over-limit result is a warning, not a failure.)"
    elif [[ $source != "terraform plan of $dir" ]]; then
      echo "  (no plan read: if this cluster already exists, currentValue already counts its nodes and a failure above can be a false positive.)"
    fi
  fi
fi

echo
echo "== PostgreSQL Flexible Server: version ${pg_version:-n/a}, SKU ${pg_sku:-n/a} =="
if [[ -z $pg_version && -z $pg_sku ]]; then
  skip "no module-managed PostgreSQL server in the plan (create_database = false); nothing to check"
elif ! az_json "$tmp/pg.json" postgres flexible-server list-skus -l "$region"; then
  fail "az postgres flexible-server list-skus failed: $(az_err)"
else
  versions=$(jq -r '[.[0].supportedServerVersions[]?.name] | join(" ")' "$tmp/pg.json")
  if [[ -z $versions ]]; then
    fail "no Flexible Server versions offered in $region for this subscription (apply fails with ParameterOutOfRange 'Version'); pick another region"
  elif [[ -z $pg_version ]]; then
    :
  elif grep -qw "$pg_version" <<<"$versions"; then
    pass "version $pg_version offered (region offers: $versions)"
  else
    fail "version $pg_version not offered (region offers: $versions) -> change pg_version"
  fi
  # GP_Standard_D2s_v3 -> edition GeneralPurpose, sku Standard_D2s_v3. Azure has
  # returned lowercase SKU names in parts of this payload before, so compare
  # case-insensitively.
  case ${pg_sku%%_*} in B) edition=Burstable ;; GP) edition=GeneralPurpose ;; MO) edition=MemoryOptimized ;; *) edition= ;; esac
  vm=${pg_sku#*_}
  if [[ -z $pg_sku ]]; then
    :
  elif [[ -n $edition ]] && jq -e --arg e "$edition" --arg s "$vm" \
    '.[0].supportedServerEditions[]? | select(.name == $e) | .supportedServerSkus[]? | select((.name | ascii_downcase) == ($s | ascii_downcase))' "$tmp/pg.json" >/dev/null; then
    pass "$pg_sku offered"
  else
    fail "$pg_sku not offered in $region -> change pg_sku_name"
  fi
fi

echo
echo "== Azure Managed Redis: ${redis_sku:-n/a} =="
if [[ -z $redis_sku ]]; then
  skip "no module-managed Redis in the plan (create_redis = false); nothing to check"
elif ! $probe_redis; then
  skip "capacity probe skipped (Azure has no capacity API; re-run with --probe-redis to create+delete a $redis_sku cluster)"
else
  # `az redisenterprise` lives in an extension that otherwise prompts for
  # installation on first use; with output captured below that prompt would
  # be invisible and the script would appear to hang.
  az extension show -n redisenterprise -o none 2>/dev/null \
    || az extension add -n redisenterprise -o none 2>"$tmp/az.err" \
    || { fail "could not install the redisenterprise CLI extension: $(az_err)"; probe_redis=false; }
fi
# Deletion is only *submitted* (--no-wait); Azure finishes it in the
# background. A failed submission is reported loudly because the probe
# cluster is billable. The EXIT trap is a safety net for an abort mid-probe
# (Ctrl-C, az timeout); the normal path reports the outcome explicitly.
cleanup_rg() {
  if az group delete -n "$rg" --yes --no-wait -o none 2>"$tmp/rgdel.err"; then
    echo "Probe resource group $rg: deletion submitted (completes in the background)."
  else
    echo "WARNING: could not delete probe resource group $rg ($(head -1 "$tmp/rgdel.err" 2>/dev/null)). Remove it manually: az group delete -n $rg --yes" >&2
    failed=1
  fi
}
probe_redis_capacity() {
  # Synchronous create: a capacity rejection surfaces in well under a minute,
  # success takes 5-10 min. --no-database keeps the probe to the cluster itself.
  local out
  if out=$(az redisenterprise create -g "$rg" -n "${rg}-redis" -l "$region" --sku "$redis_sku" \
      --public-network-access Disabled --no-database -o none 2>&1); then
    pass "$redis_sku created in $region (capacity available right now); deleting probe"
  elif grep -q InsufficientCapacity <<<"$out"; then
    fail "$redis_sku has no capacity in $region right now -> try another allowed redis_sku_name, another region, or create_redis = false (see docs/redis.md)"
  else
    fail "$redis_sku probe failed for another reason: $(grep -m1 -E 'ERROR|Code:' <<<"$out")"
  fi
}
if [[ -n $redis_sku ]] && $probe_redis; then
  rg="n8n-preflight-$(date +%s)"
  trap 'az group delete -n "$rg" --yes --no-wait >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
  if az group create -n "$rg" -l "$region" --tags Purpose=n8n-preflight -o none 2>"$tmp/az.err"; then
    probe_redis_capacity
    cleanup_rg
  else
    fail "could not create probe resource group $rg: $(az_err)"
  fi
  trap 'rm -rf "$tmp"' EXIT
fi

echo
if ((failed)); then echo "RESULT: FAIL - fix the items above before terraform apply"; exit 1; fi
if ((warned)); then echo "RESULT: PASS with warnings - review the ! items above; $region otherwise looks deployable for the checked SKUs (capacity is point-in-time)"; exit 0; fi
echo "RESULT: PASS - $region looks deployable for the checked SKUs (capacity is point-in-time)"
