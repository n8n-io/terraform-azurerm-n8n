#!/usr/bin/env bash
# test-version-drift-constraints.sh: offline, table-driven test for the
# helpers check-version-drift.sh sources from tests/scripts/lib/constraints.sh:
# constraint_accepts (is a provider's latest release inside the repo's
# constraint?), latest_release (which upstream version or tag is the latest
# release?), and aks_release_status (what does endoflife.date say about the
# pinned AKS minor?). No network, no Terraform. Needs bash and jq.
#
# Usage: tests/scripts/test-version-drift-constraints.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck source=lib/constraints.sh
source tests/scripts/lib/constraints.sh

command -v jq >/dev/null || { echo "Required tool missing: jq" >&2; exit 1; }

failures=0
cases=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# check_constraint <constraint> <version> <expected exit: 0 accepts, 1 rejects, 2 unparseable>
check_constraint() {
  local actual=0
  cases=$((cases + 1))
  constraint_accepts "$1" "$2" || actual=$?
  [[ "$actual" == "$3" ]] || fail "constraint_accepts '$1' '$2' -> $actual, expected $3"
}

# check_latest <name> <expected output, empty for exit 1> <input lines...>
check_latest() {
  local name="$1" expected="$2" actual rc=0
  shift 2
  cases=$((cases + 1))
  actual="$(printf '%s\n' "$@" | latest_release)" || rc=$?
  if [[ -z "$expected" ]]; then
    [[ "$rc" != 0 && -z "$actual" ]] || fail "latest_release ($name) -> '$actual' rc=$rc, expected no output and nonzero exit"
  else
    [[ "$rc" == 0 && "$actual" == "$expected" ]] || fail "latest_release ($name) -> '$actual' rc=$rc, expected '$expected'"
  fi
}

# ── constraint_accepts: this repo's own pins against current releases ─────
check_constraint "~> 3.0" "3.3.0" 0               # kubernetes, random
check_constraint "~> 2.12" "3.3.0" 1              # helm: a major bump is outside
check_constraint "~> 2.12" "2.17.0" 0
check_constraint ">= 4.39.0, < 5.0.0" "5.9.0" 1   # azurerm root
check_constraint ">= 4.39.0, < 5.0.0" "4.81.0" 0
check_constraint ">= 4.39.0, < 5.0.0" "4.38.9" 1
check_constraint ">= 4.39.0, < 5.0.0" "5.0.0" 1   # upper bound is exclusive
check_constraint "~> 4.0" "5.9.0" 1               # azurerm in modules/tls-*
check_constraint ">= 1.14" "1.19.0" 0             # kubectl
check_constraint ">= 1.14" "1.13.9" 1
check_constraint "~> 0.14" "0.14.0" 0             # time
check_constraint "~> 0.14" "0.22.0" 0             # pre-1.0: the minor is free
check_constraint "~> 0.14" "1.0.0" 1
check_constraint "~> 0.14" "0.13.9" 1

# ── ~> precision ──────────────────────────────────────────────────────────
check_constraint "~> 1.2.3" "1.2.9" 0
check_constraint "~> 1.2.3" "1.3.0" 1
check_constraint "~> 1.2.3" "1.2.2" 1
check_constraint "~> 1" "1.99.0" 0
check_constraint "~> 1" "2.0.0" 1
check_constraint "~> 2.12" "2.11.9" 1
check_constraint "~>2.12" "2.12.0" 0              # no space after the operator
check_constraint "  ~>   3.0  " "3.1.0" 0

# ── numeric, not lexical, comparison ──────────────────────────────────────
check_constraint ">= 1.9" "1.10.0" 0
check_constraint "< 1.10" "1.9.0" 0
check_constraint "> 1.0.9" "1.0.10" 0

# ── remaining operators ───────────────────────────────────────────────────
check_constraint "1.2.3" "1.2.3" 0
check_constraint "1.2.3" "1.2.4" 1
check_constraint "= 1.2" "1.2.0" 0                # missing parts count as 0
check_constraint "!= 1.2.3" "1.2.3" 1
check_constraint "!= 1.2.3" "1.2.4" 0
check_constraint "> 1.0.0" "1.0.0" 1
check_constraint "<= 1.0.0" "1.0.0" 0
check_constraint "< 1.0.0" "1.0.0" 1
check_constraint ">= 1.0, != 1.5.0, < 2.0" "1.5.0" 1
check_constraint ">= 1.0, != 1.5.0, < 2.0" "1.6.0" 0

# ── malformed input is exit 2, never a guess ──────────────────────────────
check_constraint "" "1.0.0" 2
check_constraint "   " "1.0.0" 2
check_constraint "~>" "1.0.0" 2
check_constraint ">= 1.x" "1.0.0" 2
check_constraint "1.2.3.4" "1.0.0" 2
check_constraint "latest" "1.0.0" 2
check_constraint ">= 1.0," "1.0.0" 2
check_constraint ">= 1.0,, < 2.0" "1.0.0" 2
check_constraint ">= 1.0, junk" "1.0.0" 2         # a bad part after a good one
check_constraint "=> 1.0" "1.0.0" 2
check_constraint ">= 1.2.0-beta" "1.2.0" 2
check_constraint "~> 6.0" "6.69.0-beta1" 2        # prerelease candidate
check_constraint "~> 6.0" "" 2
check_constraint "~> 6.0" "unknown" 2
check_constraint "~> 6.0" "v6.1.0" 2

# ── latest_release ────────────────────────────────────────────────────────
check_latest "numeric sort" "1.10.0" 1.9.0 1.10.0 1.2.0
check_latest "prerelease above the latest release is ignored" "5.9.0" 5.9.0 5.10.0-beta1 5.8.1 5.10.0-rc.1
check_latest "OCI non-version tags are ignored" "1.15.0" \
  1.14.0 1.11.0-preview.workerpools.1 artifacthub.io 1.15.0 sha256-768f9142e4f7.sig latest
check_latest "GitHub v prefix is stripped" "1.16.5" v1.16.4 v1.16.5 v1.17.0-alpha20261001
check_latest "CRLF line endings" "0.64.0" $'v0.63.0\r' $'v0.64.0\r'
check_latest "two-part versions are not releases" "2.0.0" 2.0.0 2.1
check_latest "nothing qualifies" "" artifacthub.io 1.0.0-rc1 ""

# ── aks_release_status ────────────────────────────────────────────────────
# A trimmed copy of https://endoflife.date/api/v1/products/azure-kubernetes-service
# plus one release listed before its GA date.
AKS_FIXTURE='{"result":{"releases":[
  {"name":"1.37","releaseDate":"2026-11-15","isEol":false,"eolFrom":"2027-11-30"},
  {"name":"1.36","releaseDate":"2026-06-30","isEol":false,"eolFrom":"2027-06-30"},
  {"name":"1.35","releaseDate":"2026-03-15","isEol":false,"eolFrom":"2027-03-31"},
  {"name":"1.34","releaseDate":"2025-11-30","isEol":false,"eolFrom":"2026-11-30"},
  {"name":"1.33","releaseDate":"2025-07-31","isEol":true,"eolFrom":"2026-07-31"},
  {"name":"1.9","releaseDate":"2018-01-01","isEol":true,"eolFrom":"2019-01-01"}
]}}'

# check_aks <name> <pinned> <today> <expected tab-separated line, empty for exit 1> [json]
check_aks() {
  local name="$1" pinned="$2" today="$3" expected="$4" json="${5:-$AKS_FIXTURE}" actual rc=0
  cases=$((cases + 1))
  actual="$(printf '%s' "$json" | aks_release_status "$pinned" "$today")" || rc=$?
  if [[ -z "$expected" ]]; then
    [[ "$rc" != 0 && -z "$actual" ]] || fail "aks_release_status ($name) -> '$actual' rc=$rc, expected no output and nonzero exit"
  else
    [[ "$rc" == 0 && "$actual" == "$expected" ]] || fail "aks_release_status ($name) -> '$actual' rc=$rc, expected '$expected'"
  fi
}

TAB=$'\t'
check_aks "supported pin; a pre-GA release is not the latest" 1.35 2026-10-14 \
  "1.36${TAB}true${TAB}false${TAB}2027-03-31${TAB}168"
check_aks "patch pin resolves to its minor" 1.35.6 2026-10-14 \
  "1.36${TAB}true${TAB}false${TAB}2027-03-31${TAB}168"
check_aks "the latest after its GA date" 1.36 2026-11-15 \
  "1.37${TAB}true${TAB}false${TAB}2027-06-30${TAB}227"
check_aks "pin close to EOL" 1.34 2026-10-14 \
  "1.36${TAB}true${TAB}false${TAB}2026-11-30${TAB}47"
check_aks "EOL pin" 1.33 2026-10-14 \
  "1.36${TAB}true${TAB}true${TAB}2026-07-31${TAB}-75"
check_aks "pin not listed" 1.20 2026-10-14 \
  "1.36${TAB}false${TAB}false${TAB}${TAB}"
check_aks "1.3 is not 1.33" 1.3 2026-10-14 \
  "1.36${TAB}false${TAB}false${TAB}${TAB}"
check_aks "HTML instead of JSON" 1.35 2026-10-14 "" "<html>1.29 1.30 1.31</html>"
check_aks "unexpected JSON shape" 1.35 2026-10-14 "" '{"releases":[]}'

echo "test-version-drift-constraints.sh: ${cases} case(s), ${failures} failure(s)"
((failures == 0))
