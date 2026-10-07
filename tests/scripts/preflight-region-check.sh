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
# node pool ceilings (max_count, or node_count for a fixed-size pool), zones, PostgreSQL version/SKU, and Redis SKU
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
    --vm-size SKU        aks_node_vm_size          (root default Standard_D4s_v4; sizes the
                                                     user "n8nuser" pool, and the system pool
                                                     too unless --system-vm-size overrides it)
    --node-count-max N   aks_node_count_max        (root default 6; ceiling for the user pool,
                                                     and for the system pool too unless
                                                     --system-node-count-max overrides it)
    --system-vm-size SKU        aks_system_node_vm_size   (root default null: falls back to --vm-size)
    --system-node-count-max N   aks_system_node_count_max (root default null: falls back to --node-count-max)
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
# Empty sizing values mean "not overridden": the plan (or, with --region, the
# root default) supplies them, see apply_overrides below.
dir=. region='' vm_size='' node_count_max='' system_vm_size='' system_node_count_max='' zones='' zones_set=false pg_version='' pg_sku='' redis_sku='' probe_redis=false
need_value() { (($# >= 2)) || { echo "Option $1 requires a value" >&2; usage >&2; exit 2; }; }
# Sizing flags treat an empty value as "not overridden", so an explicit empty
# value is rejected instead of being silently ignored.
need_nonempty() { [[ -n $2 ]] || { echo "Option $1 requires a non-empty value" >&2; exit 2; }; }
while (($#)); do
  case $1 in
    --dir) need_value "$@"; dir=$2; shift 2 ;;
    --region) need_value "$@"; region=$2; shift 2 ;;
    --vm-size) need_value "$@"; need_nonempty "$@"; vm_size=$2; shift 2 ;;
    --node-count-max) need_value "$@"; need_nonempty "$@"; node_count_max=$2; shift 2 ;;
    --system-vm-size) need_value "$@"; need_nonempty "$@"; system_vm_size=$2; shift 2 ;;
    --system-node-count-max) need_value "$@"; need_nonempty "$@"; system_node_count_max=$2; shift 2 ;;
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
# Node pools are handled as "ROLE VM_SIZE MAX ZONES" records, one per line.
# ROLE is `system` for a cluster's default pool, `user` for the module's
# "n8nuser" pool, and `extra` for any other node pool. MAX is the pool's
# worst-case node count: max_count for an autoscaled pool, node_count for a
# fixed-size one. ZONES is the pool's comma-separated zone list, or `-` for
# none. Plain records instead of associative arrays: macOS still ships bash
# 3.2, which has no `declare -A` (the same reason smoke-test.sh and
# verify-custom-image.sh avoid it).
#
# plan_pool_records PLAN: one record for every managed AKS node pool in the
# plan, across every module instance, so a root that calls the module twice
# is counted twice. An unknown count prints "null".
plan_pool_records() {
  local prog
  prog='def cap: if .auto_scaling_enabled == false then .node_count else .max_count end;
    def z: (.zones // []) | if length == 0 then "-" else join(",") end;
    ['"$managed"' | if .type == "azurerm_kubernetes_cluster" then (.values.default_node_pool[0] // empty | {r: "system", v: .vm_size, m: cap, z: z})
      elif .type == "azurerm_kubernetes_cluster_node_pool" then (.values | {r: (if .name == "n8nuser" then "user" else "extra" end), v: .vm_size, m: cap, z: z})
      else empty end] | .[] | "\(.r) \(.v // "null") \(.m | tostring) \(.z)"'
  jq -r "$prog" "$1"
}
# apply_overrides: reads records on stdin and applies the sizing flags, using
# the same fallback the module uses (locals.tf): the system pool takes
# --system-vm-size, else --vm-size, else its planned value, and likewise
# --system-node-count-max, else --node-count-max. The user pool takes
# --vm-size/--node-count-max. Other pools keep their planned size and count.
# An explicit --zones replaces every pool's zones. Empty flag variables mean
# "not overridden".
apply_overrides() {
  local role vm max z
  # `|| [[ -n $role ]]` keeps a last record that has no trailing newline.
  while read -r role vm max z || [[ -n $role ]]; do
    [[ -n $role ]] || continue
    case $role in
      system) vm=${system_vm_size:-${vm_size:-$vm}}; max=${system_node_count_max:-${node_count_max:-$max}} ;;
      user) vm=${vm_size:-$vm}; max=${node_count_max:-$max} ;;
    esac
    if $zones_set; then z=${zones:--}; fi
    echo "$role $vm $max ${z:--}"
  done
}
# size_peaks: reads records on stdin and prints one "VM_SIZE PEAK ROLES ZONES"
# line per distinct VM size: PEAK is the sum of MAX across every pool of that
# size, ROLES the comma-separated roles involved, and ZONES the union of their
# zones (`-` for none), since the SKU must be offered in every zone any of its
# pools uses. On a count that is not an integer from 0 to 1000, prints the
# reason to stderr and returns 2.
size_peaks() {
  local role vm max z records='' peak roles zl
  while read -r role vm max z || [[ -n $role ]]; do
    [[ -n $role ]] || continue
    is_uint "$max" && ((max <= 1000)) \
      || { echo "$role node pool count for $vm must be an integer from 0 to 1000 (got '${max:-<empty>}'); pass --node-count-max N or --system-node-count-max N" >&2; return 2; }
    records+="$role $vm $max ${z:--}"$'\n'
  done
  [[ -n $records ]] || return 0
  printf '%s' "$records" | awk '
    function add(list, item) { return index("," list ",", "," item ",") ? list : (list == "" ? item : list "," item) }
    { n[$2] += $3; r[$2] = add(r[$2], $1); c = split($4, a, ","); for (i = 1; i <= c; i++) if (a[i] != "-") zs[$2] = add(zs[$2], a[i]); seen[$2] = 1 }
    END { for (v in seen) print v, n[v], r[v], (zs[v] == "" ? "-" : zs[v]) }' | sort |
    while read -r vm peak roles zl; do
      [[ $zl == - ]] || zl=$(tr ',' '\n' <<<"$zl" | sort | paste -sd, -)
      echo "$vm $peak $roles $zl"
    done
}
# family_totals: reads "FAMILY NEEDED ROLES" lines on stdin and prints one
# line per family with NEEDED summed and ROLES merged, so two VM sizes of the
# same family are checked against that family's quota together.
family_totals() {
  awk 'NF { n[$1] += $2; split($3, a, ","); for (i in a) if (index("," r[$1] ",", "," a[i] ",") == 0) r[$1] = (r[$1] == "" ? a[i] : r[$1] "," a[i]) } END { for (f in n) print f, n[f], r[f] }' | sort
}
# quota_hint ROLES: the inputs that size the pools in ROLES, for the advice
# printed when a quota check fails.
quota_hint() {
  local hint='' part
  case ",$1," in *,user,*) hint="aks_node_vm_size/aks_node_count_max" ;; esac
  case ",$1," in *,system,*)
    part="aks_system_node_vm_size/aks_system_node_count_max (or the shared aks_node_vm_size/aks_node_count_max they fall back to)"
    hint=${hint:+$hint, }$part ;;
  esac
  case ",$1," in *,extra,*) hint=${hint:+$hint, }"the other node pools of this size" ;; esac
  echo "${hint:-aks_node_vm_size/aks_node_count_max}"
}
# plan_quota_mode PLAN: `fail` only when every AKS cluster and node pool
# change in the plan is a pure create, so no counted node can already be
# inside currentValue. Anything else (no-op, update, replace, a mix of new
# and existing clusters, or no AKS change at all) is `warn`. Deposed objects
# are ignored.
plan_quota_mode() {
  jq -r '[.resource_changes[]? | select(.mode == "managed" and (.type == "azurerm_kubernetes_cluster" or .type == "azurerm_kubernetes_cluster_node_pool") and .deposed == null) | .change.actions] | if length > 0 and all(. == ["create"]) then "fail" else "warn" end' "$1"
}

# check_quota USAGE_JSON KEY LABEL NEEDED MODE [HINT]
# Compares one `az vm list-usage` row (matched on .name.value == KEY) against
# NEEDED vCPUs. MODE is `fail` for a cluster this apply creates, or `warn` for
# an existing one, whose own nodes are already inside currentValue, so an
# over-limit result there can be a false positive. HINT names the inputs to
# shrink (see quota_hint).
check_quota() {
  local usage=$1 key=$2 label=$3 needed=$4 mode=$5 hint=${6:-aks_node_vm_size/aks_node_count_max}
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
  msg="$label: $current used + $needed needed > $limit limit -> request a quota increase (az quota update --resource-name $key --scope /subscriptions/<id>/providers/Microsoft.Compute/locations/${region:-<region>} --limit-object value=<new> --resource-type dedicated; needs 'az extension add -n quota'), pick a smaller $hint, or try another region"
  if [[ $mode == warn ]]; then
    warn "$msg (existing cluster: verify before acting)"
  else
    fail "$msg"
  fi
}

for flag in "--node-count-max=$node_count_max" "--system-node-count-max=$system_node_count_max"; do
  [[ -z ${flag#*=} ]] || is_node_count "${flag#*=}" \
    || { echo "${flag%%=*} must be an integer from 1 to 1000 (got '${flag#*=}')" >&2; exit 2; }
done

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
  # Plan readers: every managed pool is a record, in every module, with its
  # role and zones; a fixed-size pool counts node_count; data sources are
  # ignored.
  st_plan() { # st_plan FILE CLUSTER_ACTIONS POOL_ACTIONS [USER_MAX] [EXTRA_CHANGE]
    cat >"$1" <<JSON
{"planned_values":{"root_module":{"resources":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"name":"other","vm_size":"Standard_D8s_v5","max_count":9,"zones":["1"]}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"name":"fixed","vm_size":"Standard_E4s_v5","auto_scaling_enabled":false,"node_count":3,"max_count":null}}],
 "child_modules":[{"resources":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster","values":{"default_node_pool":[{"vm_size":"Standard_D2s_v5","auto_scaling_enabled":true,"max_count":2,"zones":["1","2","3"]}]}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"name":"n8nuser","vm_size":"Standard_D2s_v5","auto_scaling_enabled":true,"max_count":${4:-3},"zones":["1","2","3"]}},
  {"mode":"data","type":"azurerm_kubernetes_cluster","values":{"default_node_pool":[{"vm_size":"Standard_D2s_v5","max_count":50}]}}]}]}},
 "resource_changes":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster","change":{"actions":$2}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","change":{"actions":$3}}${5:-}]}
JSON
  }
  st_plan "$st_tmp/p.json" '["create"]' '["create"]'
  out=$(plan_pool_records "$st_tmp/p.json" | sort | paste -sd'|' -); rc=0
  [[ $out == "extra Standard_D8s_v5 9 1|extra Standard_E4s_v5 3 -|system Standard_D2s_v5 2 1,2,3|user Standard_D2s_v5 3 1,2,3" ]] || rc=1
  st_expect "plan_pool_records lists every managed pool with role, count, and zones, uses node_count for a fixed-size pool, and ignores data sources (got '$out')" "$rc"
  st_plan "$st_tmp/p.json" '["create"]' '["create"]' null
  out=$(plan_pool_records "$st_tmp/p.json" | grep '^user'); rc=0; [[ $out == "user Standard_D2s_v5 null 1,2,3" ]] || rc=1
  st_expect "plan_pool_records surfaces an unknown max_count as 'null' (got '$out')" "$rc"
  # Two module instances in one root, each 4 system + 6 user nodes of the
  # same size, need 20 nodes, not 10.
  cat >"$st_tmp/two.json" <<'JSON'
{"planned_values":{"root_module":{"child_modules":[
 {"resources":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster","values":{"default_node_pool":[{"vm_size":"Standard_D4s_v4","max_count":4,"zones":["1","2","3"]}]}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"name":"n8nuser","vm_size":"Standard_D4s_v4","max_count":6,"zones":["1","2","3"]}}]},
 {"resources":[
  {"mode":"managed","type":"azurerm_kubernetes_cluster","values":{"default_node_pool":[{"vm_size":"Standard_D4s_v4","max_count":4,"zones":["1","2","3"]}]}},
  {"mode":"managed","type":"azurerm_kubernetes_cluster_node_pool","values":{"name":"n8nuser","vm_size":"Standard_D4s_v4","max_count":6,"zones":["1","2","3"]}}]}]}}}
JSON
  out=$(plan_pool_records "$st_tmp/two.json" | apply_overrides | size_peaks); rc=0
  [[ $out == "Standard_D4s_v4 20 system,user 1,2,3" ]] || rc=1
  st_expect "size_peaks counts every module instance in the plan (got '$out', want 'Standard_D4s_v4 20 system,user 1,2,3')" "$rc"
  # Override resolution mirrors locals.tf: --node-count-max also sizes the
  # system pool unless --system-node-count-max is set, and --vm-size also
  # sizes it unless --system-vm-size is set. --zones replaces every pool's
  # zones.
  st_resolve() { # st_resolve NAME WANT VM NCM SVM SNCM [ZONES_SET ZONES]
    out=$(vm_size=$3 node_count_max=$4 system_vm_size=$5 system_node_count_max=$6 zones_set=${7:-false} zones=${8:-} \
      apply_overrides <<<"system Standard_D4s_v4 6 1,2,3
user Standard_D4s_v4 6 1,2,3
extra Standard_D8s_v5 3 1" | paste -sd'|' -)
    rc=0; [[ $out == "$2" ]] || rc=1
    st_expect "apply_overrides: $1 (got '$out')" "$rc"
  }
  st_resolve "no flags keeps the planned values" "system Standard_D4s_v4 6 1,2,3|user Standard_D4s_v4 6 1,2,3|extra Standard_D8s_v5 3 1" '' '' '' ''
  st_resolve "--node-count-max sizes both pools" "system Standard_D4s_v4 10 1,2,3|user Standard_D4s_v4 10 1,2,3|extra Standard_D8s_v5 3 1" '' 10 '' ''
  st_resolve "--system-node-count-max wins for the system pool" "system Standard_D4s_v4 2 1,2,3|user Standard_D4s_v4 10 1,2,3|extra Standard_D8s_v5 3 1" '' 10 '' 2
  st_resolve "--vm-size sizes both pools" "system Standard_D8s_v5 6 1,2,3|user Standard_D8s_v5 6 1,2,3|extra Standard_D8s_v5 3 1" Standard_D8s_v5 '' '' ''
  st_resolve "--system-vm-size wins for the system pool" "system Standard_D2s_v5 6 1,2,3|user Standard_D8s_v5 6 1,2,3|extra Standard_D8s_v5 3 1" Standard_D8s_v5 '' Standard_D2s_v5 ''
  st_resolve "--zones '' clears every pool's zones" "system Standard_D4s_v4 6 -|user Standard_D4s_v4 6 -|extra Standard_D8s_v5 3 -" '' '' '' '' true ''
  out=$(printf '%s\n' "system Standard_D2s_v5 2 1,2,3" "user Standard_D8s_v5 6 3,1" "extra Standard_D8s_v5 3 2" "extra Standard_E4s_v5 0 -" | size_peaks | paste -sd'|' -); rc=0
  [[ $out == "Standard_D2s_v5 2 system 1,2,3|Standard_D8s_v5 9 user,extra 1,2,3|Standard_E4s_v5 0 extra -" ]] || rc=1
  st_expect "size_peaks sums pools per VM size, keeps roles, unions zones per size, and accepts a zero-node pool (got '$out')" "$rc"
  # $(...) strips the trailing newline, so the last record of a captured
  # list arrives without one and must still count, in each reader.
  out=$(printf 'system Standard_D2s_v5 2 1\nuser Standard_D8s_v5 6 1' | apply_overrides | paste -sd'|' -); rc=0
  [[ $out == "system Standard_D2s_v5 2 1|user Standard_D8s_v5 6 1" ]] || rc=1
  st_expect "apply_overrides keeps a last record with no trailing newline (got '$out')" "$rc"
  out=$(printf 'system Standard_D2s_v5 2 1\nuser Standard_D8s_v5 6 1' | size_peaks | paste -sd'|' -); rc=0
  [[ $out == "Standard_D2s_v5 2 system 1|Standard_D8s_v5 6 user 1" ]] || rc=1
  st_expect "size_peaks keeps a last record with no trailing newline (got '$out')" "$rc"
  out=$(printf '%s\n' "user Standard_D4s_v4 null 1" | size_peaks 2>&1) && ec=0 || ec=$?
  rc=$([[ $ec -eq 2 && $out == *"must be an integer"* ]] && echo 0 || echo 1)
  st_expect "size_peaks rejects a non-integer count (got '$out')" "$rc"
  out=$(printf '%s\n' "standardDSv5Family 16 system" "standardDSv5Family 48 user" "standardDDSv5Family 8 extra" | family_totals | paste -sd'|' -); rc=0
  [[ $out == "standardDDSv5Family 8 extra|standardDSv5Family 64 system,user" ]] || rc=1
  st_expect "family_totals sums vCPU need per family and merges roles (got '$out')" "$rc"
  out=$(quota_hint system); rc=0; [[ $out == aks_system_node_vm_size/aks_system_node_count_max* ]] || rc=1
  st_expect "quota_hint names the system-pool inputs for a system-only family (got '$out')" "$rc"
  out=$(quota_hint user); rc=0; [[ $out == "aks_node_vm_size/aks_node_count_max" ]] || rc=1
  st_expect "quota_hint names the shared inputs for a user-only family (got '$out')" "$rc"
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
# quota_mode: fail when the plan only creates AKS clusters and pools, warn
# otherwise (see plan_quota_mode). Without a plan we cannot tell, so fail.
quota_mode=fail
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
  # Every node pool of every cluster in the plan, with the sizing flags
  # applied on top (apply_overrides).
  pools=$(plan_pool_records "$tmp/plan.json" | apply_overrides)
  quota_mode=$(plan_quota_mode "$tmp/plan.json")
  [[ -n $pg_version ]] || pg_version=$(res azurerm_postgresql_flexible_server version)
  [[ -n $pg_sku ]] || pg_sku=$(res azurerm_postgresql_flexible_server sku_name)
  [[ -n $redis_sku ]] || redis_sku=$(res azurerm_managed_redis sku_name)
  source="terraform plan of $dir"
else
  : "${pg_version:=16}" "${pg_sku:=GP_Standard_D2s_v3}" "${redis_sku:=Balanced_B1}"
  # The root defaults (aks_node_vm_size = Standard_D4s_v4, aks_node_count_max
  # = 6, system overrides null) for one cluster, with the flags on top.
  pools=$(printf '%s\n' "system Standard_D4s_v4 6 1,2,3" "user Standard_D4s_v4 6 1,2,3" | apply_overrides)
  echo "NOTE: --region given; checking root-module defaults and flags, not the terraform.tfvars of $dir." >&2
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
echo "Inputs from $source: node pools [$(printf '%s\n' "$pools" | awk 'NF { printf "%s%s %s x %s zones %s", (n++ ? ", " : ""), $1, $2, $3, $4 }')] pg=${pg_version:-n/a}/${pg_sku:-n/a} redis=${redis_sku:-n/a}"

echo
echo "== Resource providers =="
for rp in Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Cache Microsoft.Network Microsoft.Storage Microsoft.KeyVault Microsoft.ManagedIdentity; do
  state=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo Unknown)
  if [[ $state == Registered ]]; then pass "$rp registered"; else fail "$rp is $state (az provider register -n $rp)"; fi
done

echo
echo "== AKS: node pools =="
# One "FAMILY NEEDED ROLES" line per VM size whose SKU was read, summed per
# family by family_totals below.
family_lines='' grand_needed=0
peaks=$(printf '%s\n' "$pools" | size_peaks) || exit 2
if [[ -z $peaks ]]; then
  skip "no module-managed AKS cluster in the plan (create_aks = false); nothing to check"
else
  # fd 3, not stdin, so az cannot consume the remaining lines.
  while read -r size peak roles size_zones <&3; do
    [[ $size_zones != - ]] || size_zones=''
    echo
    echo "-- $size ($roles pool(s), up to $peak nodes), zones [${size_zones:-none}] --"
    # --all keeps SKUs the subscription is restricted from, so the restriction
    # reason is reported instead of a bare "not offered".
    if ! az_json "$tmp/skus-$size.json" vm list-skus -l "$region" --size "$size" --resource-type virtualMachines --all; then
      fail "az vm list-skus failed for $size: $(az_err)"
      continue
    elif ! sku_json=$(jq -ce --arg n "$size" '[.[] | select(.name == $n)][0] // empty' "$tmp/skus-$size.json"); then
      fail "$size is not offered in $region"
      continue
    fi
    # A Location restriction blocks the SKU outright; a Zone restriction only
    # removes the listed zones, so subtract those from the offered set instead.
    loc_restr=$(jq -r '[.restrictions[]? | select(.type == "Location") | .reasonCode] | unique | join(",")' <<<"$sku_json")
    offered=$(jq -r '([.locationInfo[0].zones[]?]) - ([.restrictions[]? | select(.type == "Zone") | .restrictionInfo.zones[]?]) | sort | join(",")' <<<"$sku_json")
    missing=$(comm -23 <(tr ',' '\n' <<<"$size_zones" | sort) <(tr ',' '\n' <<<"$offered" | sort) | paste -sd, -)
    if [[ -n $loc_restr ]]; then
      fail "$size restricted for this subscription in $region: $loc_restr (request quota or pick another VM size); zone check skipped"
    elif [[ -z $missing ]]; then
      pass "$size offered with no location-level subscription restrictions"
      pass "zones [${size_zones:-none}] supported (region offers [${offered:-none}])"
    else
      pass "$size offered with no location-level subscription restrictions"
      hcl=$([[ -n $offered ]] && sed 's/[^,]*/"&"/g' <<<"$offered" || true)
      fail "zones [$missing] not offered for $size in $region; region offers [${offered:-none}] -> set aks_availability_zones = [$hcl]"
    fi
    vcpus=$(jq -r '.capabilities[]? | select(.name == "vCPUs") | .value' <<<"$sku_json")
    family=$(jq -r '.family // empty' <<<"$sku_json")
    if ! is_pos_int "$vcpus" || [[ -z $family ]]; then
      skip "could not read vCPU count/family for $size; vCPU quota unchecked for it"
      continue
    fi
    needed=$((peak * vcpus))
    family_lines+="$family $needed $roles"$'\n'
    grand_needed=$((grand_needed + needed))
  done 3<<<"$peaks"
fi

echo
echo "== vCPU quota headroom (every node pool at its ceiling) =="
# AKS SKU/zone availability (checked above) says nothing about whether the
# subscription's regional vCPU quota can actually hold the autoscaler's
# ceiling; a quota wall surfaces only ~10-20 min into apply, as
# helm_release.n8n's 600s timeout expires waiting for a node the autoscaler
# could not add (Error: OperationNotAllowed, "Operation results in exceeding
# quota limits"). The user (n8nuser) pool scales aks_node_count_min..max of
# aks_node_vm_size; the system pool scales the same range of the same size
# unless aks_system_node_vm_size/_count_min/_count_max override it (aks.tf).
# Worst-case demand sums every planned pool's vCPU need at its ceiling (every
# module instance, both pools, and any other pool) per VM family, plus the
# aggregate regional cap. Upgrade surge (aks_node_upgrade_max_surge) and
# temporary rotation pools add nodes on top of that later; they are not part
# of this check.
if [[ -z $peaks ]]; then
  skip "no module-managed AKS cluster in the plan (create_aks = false); nothing to check"
elif [[ -z $family_lines ]]; then
  skip "vCPU count/family for the planned VM size(s) could not be read above; vCPU quota unchecked"
elif ! az_json "$tmp/usage.json" vm list-usage -l "$region"; then
  fail "az vm list-usage failed: $(az_err)"
else
  # "cores" is the subscription's aggregate regional vCPU cap across every
  # VM family; each family entry (e.g. standardDSv5Family) is a separate,
  # usually tighter, per-family cap. Every family in play, plus cores, must
  # clear the ceiling.
  all_roles=''
  while read -r family needed roles <&3; do
    check_quota "$tmp/usage.json" "$family" "$family family quota" "$needed" "$quota_mode" "$(quota_hint "$roles")"
    all_roles+=",$roles"
  done 3< <(printf '%s' "$family_lines" | family_totals)
  check_quota "$tmp/usage.json" cores "Regional aggregate vCPU quota" "$grand_needed" "$quota_mode" "$(quota_hint "${all_roles#,}")"
  if [[ $quota_mode == warn ]]; then
    echo "  (this plan keeps an existing AKS cluster: currentValue already counts its nodes, so an over-limit result is a warning, not a failure.)"
  elif [[ $source != "terraform plan of $dir" ]]; then
    echo "  (no plan read: if this cluster already exists, currentValue already counts its nodes and a failure above can be a false positive.)"
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
