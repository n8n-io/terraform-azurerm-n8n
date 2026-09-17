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
# resource group, reports the outcome, and deletes it (success ~5 min, capacity
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
# Requires `az` (logged in, target subscription selected), `jq`, and - unless
# `--region` is given - `terraform` with `terraform init` already run in the
# root. Read-only except for the optional Redis probe. Non-zero exit when any
# check fails.
#
# Usage (from the root you will apply, e.g. examples/small):
#   ../../tests/scripts/preflight-region-check.sh [options]
#     --dir PATH           Terraform root to plan (default: current directory)
#     --region NAME        skip the plan; use this region + flag/root defaults
#     --vm-size SKU        aks_node_vm_size          (root default Standard_D4s_v4)
#     --zones 1,2,3        aks_availability_zones    (root default 1,2,3)
#     --pg-version N       pg_version                (root default 16)
#     --pg-sku SKU         pg_sku_name               (root default GP_Standard_D2s_v3)
#     --redis-sku SKU      redis_sku_name            (root default Balanced_B1)
#     --probe-redis        actually create+delete a Managed Redis cluster
set -euo pipefail

dir=. region='' vm_size='' zones='' pg_version='' pg_sku='' redis_sku='' probe_redis=false
while (($#)); do
  case $1 in
    --dir) dir=$2; shift 2 ;;
    --region) region=$2; shift 2 ;;
    --vm-size) vm_size=$2; shift 2 ;;
    --zones) zones=$2; shift 2 ;;
    --pg-version) pg_version=$2; shift 2 ;;
    --pg-sku) pg_sku=$2; shift 2 ;;
    --redis-sku) redis_sku=$2; shift 2 ;;
    --probe-redis) probe_redis=true; shift ;;
    -h|--help) sed -n '28,38p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

for tool in az jq; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

# Pull whatever the caller did not override from the planned resources. Works
# for any module depth; a resource that the config does not create (e.g.
# create_redis = false) is simply absent and its check is skipped.
source=flags/defaults
if [[ -z $region ]]; then
  command -v terraform >/dev/null || { echo "terraform missing; pass --region to skip the plan" >&2; exit 1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  echo "Planning $dir to read region and sizing (override any value with a flag) ..."
  terraform -chdir="$dir" plan -refresh=false -input=false -lock=false -out="$tmp/plan" >"$tmp/plan.log" 2>&1 \
    || { cat "$tmp/plan.log" >&2; echo "terraform plan failed; fix it or pass --region and sizing flags" >&2; exit 1; }
  plan=$(terraform -chdir="$dir" show -json "$tmp/plan")
  res() { jq -r --arg t "$1" --arg p "$2" \
    '[.planned_values.root_module | recurse(.child_modules[]?) | .resources[]? | select(.type == $t)][0].values | getpath($p | split(".") | map(tonumber? // .)) // empty' <<<"$plan"; }
  for t in azurerm_kubernetes_cluster azurerm_postgresql_flexible_server azurerm_managed_redis azurerm_resource_group; do
    region=$(res "$t" location); [[ -n $region ]] && break
  done
  [[ -n $vm_size ]] || vm_size=$(res azurerm_kubernetes_cluster default_node_pool.0.vm_size)
  [[ -n $zones ]] || zones=$(res azurerm_kubernetes_cluster default_node_pool.0.zones | jq -r 'join(",")' 2>/dev/null || true)
  [[ -n $pg_version ]] || pg_version=$(res azurerm_postgresql_flexible_server version)
  [[ -n $pg_sku ]] || pg_sku=$(res azurerm_postgresql_flexible_server sku_name)
  [[ -n $redis_sku ]] || redis_sku=$(res azurerm_managed_redis sku_name)
  [[ -n $region ]] || { echo "could not find a location in the plan; pass --region" >&2; exit 1; }
  source="terraform plan of $dir"
else
  : "${vm_size:=Standard_D4s_v4}" "${zones:=1,2,3}" "${pg_version:=16}" "${pg_sku:=GP_Standard_D2s_v3}" "${redis_sku:=Balanced_B1}"
fi

failed=0
pass() { printf '  \xe2\x9c\x94  %s\n' "$1"; }
fail() { printf '  \xe2\x9c\x98  %s\n' "$1"; failed=1; }
skip() { printf '  \xe2\x80\x93  %s\n' "$1"; }

sub=$(az account show --query '{name:name,id:id}' -o tsv | tr '\t' ' ')
echo "Region: $region   Subscription: $sub"
echo "Inputs from $source: vm=${vm_size:-n/a} zones=[${zones:-none}] pg=${pg_version:-n/a}/${pg_sku:-n/a} redis=${redis_sku:-n/a}"

echo
echo "== Resource providers =="
for rp in Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Cache Microsoft.Network Microsoft.Storage Microsoft.KeyVault; do
  state=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo Unknown)
  if [[ $state == Registered ]]; then pass "$rp registered"; else fail "$rp is $state (az provider register -n $rp)"; fi
done

echo
echo "== AKS: ${vm_size:-n/a} zones [${zones:-none}] =="
if [[ -z $vm_size ]]; then
  skip "no module-managed AKS cluster in the plan (create_aks = false); nothing to check"
elif ! sku_json=$(az vm list-skus -l "$region" --size "$vm_size" --resource-type virtualMachines -o json 2>/dev/null \
    | jq -ce --arg n "$vm_size" '[.[] | select(.name == $n)][0] // empty'); then
  fail "$vm_size is not offered in $region (aks_node_vm_size)"
else
  restrictions=$(jq -r '[.restrictions[]? | .reasonCode] | unique | join(",")' <<<"$sku_json")
  [[ -z $restrictions ]] && pass "$vm_size offered with no subscription restrictions" \
    || fail "$vm_size restricted for this subscription: $restrictions (request quota or pick another aks_node_vm_size)"
  offered=$(jq -r '[.locationInfo[0].zones[]?] | sort | join(",")' <<<"$sku_json")
  missing=$(comm -23 <(tr ',' '\n' <<<"$zones" | sort) <(tr ',' '\n' <<<"$offered" | sort) | paste -sd, -)
  if [[ -z $missing ]]; then
    pass "zones [$zones] supported (region offers [${offered:-none}])"
  else
    fail "zones [$missing] not offered for $vm_size in $region; region offers [${offered:-none}] -> set aks_availability_zones = [$(sed 's/[^,]*/"&"/g' <<<"$offered")]"
  fi
fi

echo
echo "== PostgreSQL Flexible Server: version ${pg_version:-n/a}, SKU ${pg_sku:-n/a} =="
pg_json=$(az postgres flexible-server list-skus -l "$region" -o json 2>/dev/null || echo '[]')
versions=$(jq -r '[.[0].supportedServerVersions[]?.name] | join(" ")' <<<"$pg_json")
if [[ -z $pg_version ]]; then
  skip "no module-managed PostgreSQL server in the plan (create_database = false); nothing to check"
elif [[ -z $versions ]]; then
  fail "no Flexible Server versions offered in $region for this subscription (apply fails with ParameterOutOfRange 'Version'); pick another region"
elif grep -qw "$pg_version" <<<"$versions"; then
  pass "version $pg_version offered (region offers: $versions)"
else
  fail "version $pg_version not offered (region offers: $versions) -> change pg_version"
fi
# GP_Standard_D2s_v3 -> edition GeneralPurpose, sku Standard_D2s_v3
case ${pg_sku%%_*} in B) edition=Burstable ;; GP) edition=GeneralPurpose ;; MO) edition=MemoryOptimized ;; *) edition= ;; esac
vm=${pg_sku#*_}
if [[ -z $pg_sku ]]; then
  :
elif [[ -n $edition ]] && jq -e --arg e "$edition" --arg s "$vm" \
  '.[0].supportedServerEditions[]? | select(.name == $e) | .supportedServerSkus[]? | select(.name == $s)' <<<"$pg_json" >/dev/null; then
  pass "$pg_sku offered"
else
  fail "$pg_sku not offered in $region -> change pg_sku_name"
fi

echo
echo "== Azure Managed Redis: ${redis_sku:-n/a} =="
if [[ -z $redis_sku ]]; then
  skip "no module-managed Redis in the plan (create_redis = false); nothing to check"
elif ! $probe_redis; then
  skip "capacity probe skipped (Azure has no capacity API; re-run with --probe-redis to create+delete a $redis_sku cluster)"
else
  rg="n8n-preflight-$(date +%s)"
  trap 'rm -rf "${tmp:-}"; az group delete -n "$rg" --yes --no-wait >/dev/null 2>&1 || true' EXIT
  az group create -n "$rg" -l "$region" --tags Purpose=n8n-preflight -o none
  # Synchronous create: a capacity rejection surfaces in well under a minute,
  # success takes ~5 min. --no-database keeps the probe to the cluster itself.
  if out=$(az redisenterprise create -g "$rg" -n "${rg}-redis" -l "$region" --sku "$redis_sku" \
      --public-network-access Disabled --no-database -o none 2>&1); then
    pass "$redis_sku created in $region (capacity available right now); deleting probe"
  elif grep -q InsufficientCapacity <<<"$out"; then
    fail "$redis_sku has no capacity in $region right now -> try another allowed redis_sku_name, another region, or create_redis = false (see docs/redis.md)"
  else
    fail "$redis_sku probe failed for another reason: $(grep -m1 -E 'ERROR|Code:' <<<"$out")"
  fi
fi

echo
if ((failed)); then echo "RESULT: FAIL - fix the items above before terraform apply"; exit 1; fi
echo "RESULT: PASS - $region looks deployable for the checked SKUs (capacity is point-in-time)"
