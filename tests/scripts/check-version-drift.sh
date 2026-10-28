#!/usr/bin/env bash
# check-version-drift.sh: report the currency of the pins in
# docs/versioning.md against public, unauthenticated sources. Never modifies
# a pin. Every finding is one line with a fixed prefix, so the weekly
# version-drift.yml workflow can tell when the set of findings changed:
#
#   DRIFT: the pin is behind upstream, or a provider constraint does not
#          admit the latest release ("outside constraint").
#   OK:    the pin is current, or its constraint already admits the latest
#          release.
#   ERROR: a lookup failed or returned something this script cannot parse.
#          Never reported as OK: a lookup that silently no-ops would look
#          identical to "up to date".
#   INFO:  context that is not actionable on its own.
#
# The report ends with a summary line ("N pin(s) behind upstream, M
# lookup(s) failed", the same format as the sibling terraform-google-n8n and
# terraform-aws-n8n modules). Exit 0 when every lookup succeeded, drift or
# not: drift is release-sized work per docs/versioning.md, not a CI failure.
# Exit 2 when any ERROR was reported, exit 1 when curl or jq is missing.
#
# Covers:
#   - Terraform providers in versions.tf, modules/controllers/versions.tf,
#     and modules/tls-*/versions.tf, against the registry.terraform.io
#     versions list (what `terraform init` resolves), prereleases dropped.
#     Each constraint is evaluated with tests/scripts/lib/constraints.sh.
#   - CI toolchain in terraform-tests.yml (TF_VERSION, TFLINT_VERSION,
#     CHECKOV_VERSION) against GitHub releases.
#   - n8n_chart_version against the chart's own OCI registry tags
#     (ghcr.io, anonymous token, plain X.Y.Z tags only).
#   - keda_chart_version (root and modules/controllers) against the kedacore
#     chart repository index, via `helm show chart`.
#   - aks_kubernetes_version against endoflife.date's azure-kubernetes-service
#     product, which tracks AKS's own standard-support calendar (not upstream
#     Kubernetes EOL). INFO while the pin is supported; DRIFT once it is EOL
#     or within AKS_EOL_WARN_DAYS (90) of EOL. Regional availability is not
#     covered: check `az aks get-versions --location <region>` or
#     tests/scripts/preflight-region-check.sh before bumping.
#
# Not covered: pins that need a credentialed Azure call (PostgreSQL major
# version support, Redis SKU availability; see preflight-region-check.sh),
# n8n_image_tag, example-only constraints, and the remaining CI tools listed
# in docs/versioning.md.
#
# Set GH_TOKEN or GITHUB_TOKEN to raise the GitHub API rate limit; the token
# is sent only to api.github.com and never printed.
#
# Usage:
#   tests/scripts/check-version-drift.sh
# Requires: bash, curl, jq; helm for the KEDA chart lookup (an ERROR line,
# not an abort, when missing).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck source=lib/tf-defaults.sh
source tests/scripts/lib/tf-defaults.sh
# shellcheck source=lib/constraints.sh
source tests/scripts/lib/constraints.sh

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

WORKFLOW=".github/workflows/terraform-tests.yml"
AKS_EOL_WARN_DAYS=90
TODAY="$(date -u +%Y-%m-%d)"

drift_count=0
error_count=0

report_drift() {
  echo "DRIFT: $1 pinned at $2, latest is $3${4:+ ($4)}"
  drift_count=$((drift_count + 1))
}

report_ok() {
  echo "OK:    $1 pinned at $2 (${3:-latest})"
}

report_error() {
  echo "ERROR: $1: $2"
  error_count=$((error_count + 1))
}

report_info() {
  echo "INFO:  $1"
}

fetch() {
  curl -sfL --max-time 30 --retry 2 "$@"
}

github_latest_release() {
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    fetch -H "Authorization: Bearer ${token}" "https://api.github.com/repos/$1/releases/latest"
  else
    fetch "https://api.github.com/repos/$1/releases/latest"
  fi | jq -r '.tag_name // empty' 2>/dev/null | latest_release
}

# ── Terraform providers ────────────────────────────────────────────────────

echo "== Terraform providers (registry.terraform.io) =="
records=""
for file in versions.tf modules/*/versions.tf; do
  found="$(provider_records "$file")"
  if [[ -z "$found" ]]; then
    report_error "$file" "no required_providers entries found"
    continue
  fi
  where="$(dirname "$file")"
  [[ "$where" == "." ]] && where="root"
  while IFS= read -r line; do
    records+="${line}|${where}"$'\n'
  done <<<"$found"
done

# Group identical (provider, constraint) pairs so a constraint repeated in a
# submodule is one line naming every location, not one line per file.
grouped="$(printf '%s' "$records" | sort -t'|' -k1,1 -k3,3 -k4,4 | awk -F'|' '
  { key = $1 "|" $2 "|" $3 }
  key != prev { if (prev != "") print prev "|" locs; prev = key; locs = $4; next }
  { locs = locs ", " $4 }
  END { if (prev != "") print prev "|" locs }
')"

latest_cache=""
while IFS='|' read -r name source constraint locs; do
  [[ -z "$name" ]] && continue
  display="${name} provider [${locs}]"
  if [[ -z "$source" || -z "$constraint" ]]; then
    report_error "$display" "missing source or version constraint"
    continue
  fi
  latest="$(awk -F'|' -v s="$source" '$1 == s { print $2; exit }' <<<"$latest_cache")"
  if [[ -z "$latest" ]]; then
    latest="$(fetch "https://registry.terraform.io/v1/providers/${source}/versions" \
      | jq -r '.versions[].version' 2>/dev/null | latest_release)"
    if [[ -z "$latest" ]]; then
      report_error "$display" "registry.terraform.io lookup for ${source} failed"
      continue
    fi
    latest_cache+="${source}|${latest}"$'\n'
  fi
  verdict=0
  constraint_accepts "$constraint" "$latest" || verdict=$?
  case "$verdict" in
    0) report_ok "$display" "\"${constraint}\"" "accepts latest ${latest}" ;;
    1) report_drift "$display" "\"${constraint}\"" "$latest" "outside constraint" ;;
    *) report_error "$display" "cannot evaluate constraint \"${constraint}\" against ${latest}" ;;
  esac
done <<<"$grouped"

# ── CI toolchain ───────────────────────────────────────────────────────────

echo
echo "== CI toolchain (GitHub releases) =="
check_tool() {
  local display="$1" env_name="$2" repo="$3" pinned latest
  pinned="$(sed -n "s/^[[:space:]]*${env_name}:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$WORKFLOW" | head -1)"
  pinned="${pinned#v}"
  if [[ ! "$pinned" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    report_error "$display" "could not read ${env_name} from ${WORKFLOW}"
    return
  fi
  latest="$(github_latest_release "$repo")"
  if [[ -z "$latest" ]]; then
    report_error "$display" "GitHub releases lookup for ${repo} failed"
    return
  fi
  if [[ "$pinned" == "$latest" ]]; then
    report_ok "$display" "$pinned"
  else
    report_drift "$display" "$pinned" "$latest"
  fi
}
check_tool "terraform (TF_VERSION)" TF_VERSION hashicorp/terraform
check_tool "tflint (TFLINT_VERSION)" TFLINT_VERSION terraform-linters/tflint
check_tool "checkov (CHECKOV_VERSION)" CHECKOV_VERSION bridgecrewio/checkov

# ── Helm charts ────────────────────────────────────────────────────────────

echo
echo "== Helm charts =="
# check_chart <display> <latest> <file:variable>...: compares every listed
# default against one upstream latest.
check_chart() {
  local display="$1" latest="$2" spec file var pinned
  shift 2
  for spec in "$@"; do
    file="${spec%%:*}"
    var="${spec#*:}"
    pinned="$(read_default "$file" "$var")"
    if [[ -z "$pinned" ]]; then
      report_error "$display [${file}]" "could not read the ${var} default"
    elif [[ -z "$latest" ]]; then
      : # the caller already reported the failed lookup
    elif [[ "$pinned" == "$latest" ]]; then
      report_ok "$display [${file}]" "$pinned"
    else
      report_drift "$display [${file}]" "$pinned" "$latest"
    fi
  done
}

n8n_latest=""
token="$(fetch "https://ghcr.io/token?scope=repository:n8n-io/n8n-helm-chart/n8n:pull&service=ghcr.io" \
  | jq -r '.token // empty' 2>/dev/null)"
if [[ -z "$token" ]]; then
  report_error "n8n chart" "ghcr.io anonymous token request failed"
else
  n8n_latest="$(fetch -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/n8n-io/n8n-helm-chart/n8n/tags/list?n=10000" \
    | jq -r '.tags[]' 2>/dev/null | latest_release)"
  [[ -n "$n8n_latest" ]] || report_error "n8n chart" "ghcr.io tag list lookup failed"
fi
[[ -n "$n8n_latest" ]] && check_chart "n8n chart (n8n_chart_version)" "$n8n_latest" variables.tf:n8n_chart_version

keda_latest=""
if ! command -v helm >/dev/null 2>&1; then
  report_error "KEDA chart" "helm is not on PATH"
else
  # `helm show chart --repo` reads the repository's index.yaml and resolves
  # its latest stable version (prereleases need --devel), without adding a
  # repository to the local Helm configuration.
  keda_latest="$(helm show chart keda --repo https://kedacore.github.io/charts 2>/dev/null \
    | sed -n 's/^version:[[:space:]]*//p' | latest_release)"
  [[ -n "$keda_latest" ]] || report_error "KEDA chart" "kedacore chart repository lookup failed"
fi
[[ -n "$keda_latest" ]] && check_chart "KEDA chart (keda_chart_version)" "$keda_latest" \
  variables.tf:keda_chart_version modules/controllers/variables.tf:keda_chart_version

# ── AKS Kubernetes version ─────────────────────────────────────────────────

echo
echo "== AKS Kubernetes version (endoflife.date) =="
check_aks() {
  local display="aks_kubernetes_version" pinned status latest listed is_eol eol_from days
  pinned="$(read_default variables.tf aks_kubernetes_version)"
  if [[ ! "$pinned" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    report_error "$display" "could not read the aks_kubernetes_version default"
    return
  fi
  status="$(fetch "https://endoflife.date/api/v1/products/azure-kubernetes-service" \
    | aks_release_status "$pinned" "$TODAY")"
  if [[ -z "$status" ]]; then
    report_error "$display" "endoflife.date azure-kubernetes-service lookup failed"
    return
  fi
  IFS=$'\t' read -r latest listed is_eol eol_from days <<<"$status"
  case "$(aks_classify "$listed" "$is_eol" "$days" "$AKS_EOL_WARN_DAYS")" in
    unlisted)
      report_error "$display" "pinned ${pinned} is not listed by endoflife.date (newest GA is ${latest})" ;;
    eol)
      report_drift "$display" "$pinned" "$latest" "pinned version is past AKS end of life${eol_from:+ (${eol_from})}" ;;
    no-eol-date)
      report_info "${display} pinned at ${pinned}, latest is ${latest} (no published end-of-life date)" ;;
    near-eol)
      report_drift "$display" "$pinned" "$latest" "pinned version reaches AKS end of life on ${eol_from}" ;;
    supported)
      # No day count: the line must not change from week to week by itself.
      report_info "${display} pinned at ${pinned}, latest is ${latest} (pinned version supported until ${eol_from})" ;;
    *)
      report_error "$display" "cannot classify the endoflife.date answer for ${pinned}" ;;
  esac
}
check_aks

# ── Summary ────────────────────────────────────────────────────────────────

echo
echo "check-version-drift.sh: ${drift_count} pin(s) behind upstream, ${error_count} lookup(s) failed"
((error_count == 0)) || exit 2
exit 0
