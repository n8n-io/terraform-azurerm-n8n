#!/usr/bin/env bash
# check-example-parity.sh: diff the set of variable names every example's
# variables.tf declares against examples/small's, and fail on any name
# present on one side only that is not in that example's allowlist below.
# A stale allowlist entry (one that no longer explains a real diff) fails
# too. Names only: a shared variable's type or default is not compared.
#
# Mirrors terraform-aws-n8n's scripts/check-example-parity.sh. Catches the
# class of drift where one example gains or loses a passthrough variable
# without its siblings following (port-aws-050-enhancements section 5).
#
# Usage:
#   scripts/check-example-parity.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE="small"
EXAMPLES=(medium large split-ingress worker-pools customer-managed-cluster customer-managed-redis customer-managed-storage customer-managed-everything)

names() {
  python3 -c "
import re, sys
text = open(sys.argv[1]).read()
for name in sorted(set(re.findall(r'variable \"([a-zA-Z0-9_]+)\" \{', text))):
    print(name)
" "examples/$1/variables.tf"
}

base_names="$(names "$BASE")"
fail=0

# name -> space-separated list of examples where its presence/absence
# relative to small is expected and documented. Each entry names exactly
# one side of the diff: "+name" (example declares it, small does not) or
# "-name" (small declares it, example does not).
# Newline-delimited "key|examples" records rather than an associative array:
# macOS still ships bash 3.2, which has no `declare -A`, and every other
# script in this repo stays 3.2-compatible for the same reason (see
# tests/scripts/verify-custom-image.sh).
ALLOW=$(cat <<'EOF_ALLOW'
# small's own AKS-sizing/foundation inputs that other examples fix at a
# tier-specific value (no caller override needed) or never surface
# because they build their foundation differently.
-aks_availability_zones|medium large split-ingress customer-managed-cluster customer-managed-redis customer-managed-everything
-aks_node_vm_size|medium large split-ingress customer-managed-redis
-resource_group_location|medium large split-ingress customer-managed-cluster customer-managed-redis customer-managed-storage customer-managed-everything
# Only small, medium, and large issue a public Azure DNS zone; the
# customer-managed and split-ingress examples use a self-signed cert
# with no public DNS record.
-public_dns_zone_name|split-ingress customer-managed-cluster customer-managed-redis customer-managed-storage customer-managed-everything
# large owns its own PostgreSQL (create_database = false) via a
# PgBouncer-fronted Aurora-equivalent setup, so the module's
# pg_backup_retention_days passthrough does not apply.
-pg_backup_retention_days|large customer-managed-everything
# customer-managed-storage and customer-managed-everything externalize
# Blob (create_blob_storage = false), so blob_delete_retention_days
# does not apply.
-blob_delete_retention_days|customer-managed-storage customer-managed-everything
# split-ingress's own two-gateway topology inputs.
+admin_allowed_cidr_blocks|split-ingress
+create_webhook_waf_policy|split-ingress
+webhook_subdomain|split-ingress
# customer-managed-everything provisions its own PostgreSQL server and
# needs its admin password as a plain input, unlike every other example
# where the module manages it.
+postgres_admin_password|customer-managed-everything
# worker-pools is the only example that cannot run the module's default
# chart: queueMode.workerGroups ships in a preview build only, so the
# version is a required input there (no default) and the attestation
# flag goes with it. n8n_image_tag also becomes a required-in-practice
# input, pinned above the pools' n8n 2.39.0 floor rather than the
# module's own 2.35.0 default. See its README, "Getting a chart that
# renders pools".
+n8n_chart_version|worker-pools
+n8n_worker_pools_chart_verified|worker-pools
+n8n_image_tag|worker-pools
# It also sizes the chart's own unlabelled worker deployment, which runs
# beside the pools as the control group for everything not pinned to one.
+n8n_worker_keda_min_replicas|worker-pools
+n8n_worker_keda_max_replicas|worker-pools
EOF_ALLOW
)

# Examples listed for one allowlist key, or empty when the key is absent.
allow_examples() {
  printf '%s\n' "$ALLOW" | awk -F'|' -v k="$1" '$1 == k { print $2; exit }'
}

allow_keys() {
  printf '%s\n' "$ALLOW" | awk -F'|' 'NF > 1 && $1 !~ /^#/ { print $1 }'
}

is_allowed() {
  local sign="$1" name="$2" example="$3"
  local examples
  examples="$(allow_examples "${sign}${name}")"
  [[ -n "$examples" ]] || return 1
  [[ " $examples " == *" $example "* ]]
}

for example in "${EXAMPLES[@]}"; do
  ex_names="$(names "$example")"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! grep -qxF "$name" <<<"$ex_names"; then
      if ! is_allowed "-" "$name" "$example"; then
        echo "FAIL: examples/small declares \"$name\" but examples/$example does not, and this is not in the allowlist." >&2
        fail=1
      fi
    fi
  done <<<"$base_names"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! grep -qxF "$name" <<<"$base_names"; then
      if ! is_allowed "+" "$name" "$example"; then
        echo "FAIL: examples/$example declares \"$name\" but examples/small does not, and this is not in the allowlist." >&2
        fail=1
      fi
    fi
  done <<<"$ex_names"
done

# A stale allowlist entry: the named example no longer has the diff the
# entry claims to explain.
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  sign="${key:0:1}"
  name="${key:1}"
  for example in $(allow_examples "$key"); do
    ex_names="$(names "$example")"
    in_base=$(grep -qxF "$name" <<<"$base_names" && echo yes || echo no)
    in_ex=$(grep -qxF "$name" <<<"$ex_names" && echo yes || echo no)
    if [[ "$sign" == "-" && ( "$in_base" == "no" || "$in_ex" == "yes" ) ]]; then
      echo "FAIL: allowlist entry \"$key\" for $example is stale (no longer a small-only variable)." >&2
      fail=1
    fi
    if [[ "$sign" == "+" && ( "$in_ex" == "no" || "$in_base" == "yes" ) ]]; then
      echo "FAIL: allowlist entry \"$key\" for $example is stale (no longer an $example-only variable)." >&2
      fail=1
    fi
  done
done <<<"$(allow_keys)"

if [[ $fail -eq 0 ]]; then
  echo "OK: every example's variable-name diff against examples/small is allowlisted, and no allowlist entry is stale."
fi

exit "$fail"
