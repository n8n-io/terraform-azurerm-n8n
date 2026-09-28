#!/usr/bin/env bash
# check-variable-banners.sh — every variable/output block in variables.tf and
# outputs.tf must sit under a "# ── Section ──" banner comment (see AGENTS.md,
# "Clear documentation"). Catches two drift patterns:
#
#   1. A block appended with no banner above it at all.
#   2. A banner-like comment that doesn't match the established format
#      (wrong dashes, missing padding, typo'd style).
#
# What this script deliberately does NOT check: whether a variable was filed
# under the *correct* banner for its meaning (e.g. a new toggle landing in
# "Controllers and base n8n release" vs "n8n runtime and resource controls").
# That judgment call still needs a human/CODEOWNERS review — this only
# guarantees the convention itself can't silently rot to "no sections at
# all". Mirrors terraform-aws-n8n's scripts/check-variable-banners.sh.
#
# Usage:
#   scripts/check-variable-banners.sh

set -euo pipefail

# The banner regexes below match the multibyte "─" (U+2500) used in
# variables.tf/outputs.tf. Bash's [[ =~ ]] only resolves that against file
# content under a UTF-8 locale; a C/POSIX locale (the default in minimal
# shells and containers, and whatever LC_ALL/LANG a CI image sets) makes
# every real banner fail the strict-format check. Leave an already-UTF-8
# locale alone; otherwise force C.UTF-8, the most widely available UTF-8
# locale, via LC_ALL since it -- not a scoped LC_CTYPE -- is what a
# non-UTF-8 LC_ALL in the environment would otherwise override.
effective_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case "$effective_locale" in
  *.[Uu][Tt][Ff]-8 | *.[Uu][Tt][Ff]8) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FILES=(variables.tf outputs.tf)
# Keep in lockstep with the banner order in variables.tf/outputs.tf. Update
# this list in the same PR that adds, renames, or reorders a banner, or this
# check fails on an otherwise-correct checkout.
VARIABLE_BANNERS=("Root contract skeleton (align-azure-with-aws-capabilities, section 1)" "Core inputs" "BYO networking" "AKS sizing, version, and hardening" "PostgreSQL topologies (align-azure-with-aws-capabilities section 3)" "External PostgreSQL endpoint (create_database = false)" "Redis topologies (align-azure-with-aws-capabilities section 4)" "Private Azure Blob storage" "Application Gateway ingress" "Application DNS" "Binary and execution-data storage modes" "Controllers and base n8n release" "n8n runtime and resource controls" "Metrics, tracing, and Enterprise log streaming" "Optional Redis queue metrics exporter (observability.tf)" "Workload autoscaling" "Custom images, extensions, volumes, and environment" "Credential overwrites" "n8n domain, certificate, and license" "Customer-managed infrastructure ownership (add-customer-managed-modularity section 1)")
OUTPUT_BANNERS=("Outputs" "AKS" "PostgreSQL" "Redis" "Storage" "n8n workload and service discovery" "Application Gateway ingress")
BANNER_LOOSE_RE='^#[[:space:]]+[─—-]{2,}'
BANNER_STRICT_RE='^# ── (.+) ─{2,}$'
BLOCK_RE='^(variable|output) "'

fail=0

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "check-variable-banners: $file not found" >&2
    fail=1
    continue
  fi

  banner=""
  banners=()
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ $BANNER_LOOSE_RE ]]; then
      if [[ ! "$line" =~ $BANNER_STRICT_RE ]]; then
        echo "$file:$lineno: malformed banner (expected '# ── Section Name ──...──'): $line" >&2
        fail=1
      else
        banner="${BASH_REMATCH[1]}"
        banners+=("$banner")
      fi
    elif [[ "$line" =~ $BLOCK_RE ]]; then
      if [[ -z "$banner" ]]; then
        echo "$file:$lineno: no preceding '# ── Section ──' banner for: $line" >&2
        fail=1
      fi
    fi
  done < "$file"

  if [[ "$file" == "variables.tf" ]]; then
    expected=("${VARIABLE_BANNERS[@]}")
  else
    expected=("${OUTPUT_BANNERS[@]}")
  fi
  banners_match=true
  if [[ "${#banners[@]}" -ne "${#expected[@]}" ]]; then
    banners_match=false
  else
    for ((i = 0; i < ${#expected[@]}; i++)); do
      if [[ "${banners[$i]}" != "${expected[$i]}" ]]; then
        banners_match=false
        break
      fi
    done
  fi
  if [[ "$banners_match" != true ]]; then
    echo "$file: section banners are missing, renamed, or out of order" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo >&2
  echo "See AGENTS.md, 'Clear documentation' > variable/output banners, for the convention and current section list." >&2
  exit 1
fi

echo "check-variable-banners: OK (${FILES[*]})"
