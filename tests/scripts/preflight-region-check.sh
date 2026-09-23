#!/usr/bin/env bash
# Pre-apply check that the target Azure region and subscription can actually
# host this module's managed services. Catches the three region/subscription
# gaps observed in live runs before a 15-30 minute apply hits them:
#
#   AKS        AvailabilityZoneNotSupported  (zones missing for the VM SKU)
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
# zones, PostgreSQL version/SKU, and Redis SKU from the planned resources, so a
# check matches exactly what apply would request. Every value can be overridden
# with a flag; `--region` alone skips the plan and uses flag/root-module defaults.
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
    --node-count-max N   aks_node_count_max        (root default 6; each of the system and
                                                     user node pools scales 0..N independently,
                                                     so peak demand is 2 x N nodes of --vm-size)
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
dir=. region='' vm_size='' node_count_max='' zones='' zones_set=false pg_version='' pg_sku='' redis_sku='' probe_redis=false
need_value() { (($# >= 2)) || { echo "Option $1 requires a value" >&2; usage >&2; exit 2; }; }
while (($#)); do
  case $1 in
    --dir) need_value "$@"; dir=$2; shift 2 ;;
    --region) need_value "$@"; region=$2; shift 2 ;;
    --vm-size) need_value "$@"; vm_size=$2; shift 2 ;;
    --node-count-max) need_value "$@"; node_count_max=$2; shift 2 ;;
    --zones) need_value "$@"; zones=$2; zones_set=true; shift 2 ;;
    --pg-version) need_value "$@"; pg_version=$2; shift 2 ;;
    --pg-sku) need_value "$@"; pg_sku=$2; shift 2 ;;
    --redis-sku) need_value "$@"; redis_sku=$2; shift 2 ;;
    --probe-redis) probe_redis=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

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
if [[ -z $region ]]; then
  command -v terraform >/dev/null || { echo "terraform missing; pass --region to skip the plan" >&2; exit 1; }
  echo "Planning $dir to read region and sizing (override any value with a flag) ..."
  terraform -chdir="$dir" plan -refresh=false -input=false -lock=false -out="$tmp/plan" >"$tmp/plan.log" 2>&1 \
    || { cat "$tmp/plan.log" >&2; echo "terraform plan failed; fix it or pass --region and sizing flags" >&2; exit 1; }
  plan=$(terraform -chdir="$dir" show -json "$tmp/plan")
  # Managed resources only: the module also declares data sources (e.g.
  # data.azurerm_kubernetes_cluster.existing) whose location may differ.
  managed='.planned_values.root_module | recurse(.child_modules[]?) | .resources[]? | select(.mode == "managed")'
  res() { jq -r --arg t "$1" --arg p "$2" \
    "[$managed | select(.type == \$t)][0].values | getpath(\$p | split(\".\") | map(tonumber? // .)) // empty" <<<"$plan"; }
  locations=$(jq -r "[$managed | select(.type == \"azurerm_kubernetes_cluster\" or .type == \"azurerm_postgresql_flexible_server\" or .type == \"azurerm_managed_redis\" or .type == \"azurerm_resource_group\") | .values.location // empty] | unique | join(\" \")" <<<"$plan")
  case $(wc -w <<<"$locations" | tr -d ' ') in
    0) echo "could not find a location in the plan; pass --region" >&2; exit 1 ;;
    1) region=$locations ;;
    *) echo "plan spans several regions ($locations); pass --region to pick one" >&2; exit 1 ;;
  esac
  [[ -n $vm_size ]] || vm_size=$(res azurerm_kubernetes_cluster default_node_pool.0.vm_size)
  [[ -n $node_count_max ]] || node_count_max=$(res azurerm_kubernetes_cluster default_node_pool.0.max_count)
  $zones_set || zones=$(res azurerm_kubernetes_cluster default_node_pool.0.zones | jq -r 'join(",")' 2>/dev/null || true)
  [[ -n $pg_version ]] || pg_version=$(res azurerm_postgresql_flexible_server version)
  [[ -n $pg_sku ]] || pg_sku=$(res azurerm_postgresql_flexible_server sku_name)
  [[ -n $redis_sku ]] || redis_sku=$(res azurerm_managed_redis sku_name)
  source="terraform plan of $dir"
else
  : "${vm_size:=Standard_D4s_v4}" "${node_count_max:=6}" "${pg_version:=16}" "${pg_sku:=GP_Standard_D2s_v3}" "${redis_sku:=Balanced_B1}"
  $zones_set || zones=1,2,3
  echo "NOTE: --region given; checking root-module defaults and flags, not the terraform.tfvars of $dir." >&2
fi

failed=0
pass() { printf '  \xe2\x9c\x94  %s\n' "$1"; }
fail() { printf '  \xe2\x9c\x98  %s\n' "$1"; failed=1; }
skip() { printf '  \xe2\x80\x93  %s\n' "$1"; }
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
echo "== vCPU quota headroom: ${vm_size:-n/a} x $((2 * ${node_count_max:-0})) nodes (system + user pool, each 0..${node_count_max:-n/a}) =="
# AKS SKU/zone availability (checked above) says nothing about whether the
# subscription's regional vCPU quota can actually hold the autoscaler's
# ceiling; a quota wall surfaces only ~10-20 min into apply, as
# helm_release.n8n's 600s timeout expires waiting for a node the autoscaler
# could not add (Error: OperationNotAllowed, "Operation results in exceeding
# quota limits"). Both node pools share var.aks_node_vm_size and each scales
# 0..aks_node_count_max independently (aks.tf), so worst-case demand is both
# pools simultaneously at the ceiling: 2 x aks_node_count_max nodes.
if [[ -z $vm_size ]]; then
  skip "no module-managed AKS cluster in the plan (create_aks = false); nothing to check"
elif [[ ! -s "$tmp/skus.json" ]]; then
  skip "SKU lookup for $vm_size did not run or failed above; vCPU quota unchecked"
else
  vcpus=$(jq -r --arg n "$vm_size" '[.[] | select(.name == $n)][0].capabilities[]? | select(.name == "vCPUs") | .value' "$tmp/skus.json")
  family=$(jq -r --arg n "$vm_size" '[.[] | select(.name == $n)][0].family // empty' "$tmp/skus.json")
  if [[ -z $vcpus || -z $family ]]; then
    skip "could not read vCPU count/family for $vm_size from the SKU lookup above; vCPU quota unchecked"
  elif ! az_json "$tmp/usage.json" vm list-usage -l "$region"; then
    fail "az vm list-usage failed: $(az_err)"
  else
    needed=$((2 * node_count_max * vcpus))
    # "cores" is the subscription's aggregate regional vCPU cap across every
    # VM family; the family entry (e.g. standardDSv5Family) is a separate,
    # usually tighter, per-family cap. Both must clear the ceiling.
    check_quota() {
      local key=$1 label=$2
      local row current limit
      row=$(jq -c --arg n "$key" '[.[] | select(.name.value == $n)][0] // empty' "$tmp/usage.json")
      if [[ -z $row ]]; then
        skip "$label ('$key') not found in az vm list-usage output for $region; vCPU quota unchecked for it"
        return
      fi
      current=$(jq -r '.currentValue' <<<"$row")
      limit=$(jq -r '.limit' <<<"$row")
      if ((current + needed <= limit)); then
        pass "$label: $current used + $needed needed <= $limit limit"
      else
        fail "$label: $current used + $needed needed > $limit limit -> request a quota increase (az quota update --resource-name $key --scope /subscriptions/<id>/providers/Microsoft.Compute/locations/$region --limit-object value=<new> --resource-type dedicated), pick a smaller aks_node_vm_size/aks_node_count_max, or try another region"
      fi
    }
    check_quota "$family" "$vm_size family quota"
    check_quota cores "Regional aggregate vCPU quota"
    echo "  (advisory: currentValue already includes any existing nodes of this SKU, e.g. a cluster this apply will resize rather than create; a false failure there is safe to verify with az vm list-usage directly.)"
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
echo "RESULT: PASS - $region looks deployable for the checked SKUs (capacity is point-in-time)"
