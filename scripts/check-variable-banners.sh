#!/usr/bin/env bash
# check-variable-banners.sh — every variable/output block in variables.tf and
# outputs.tf must sit under a "# ── Section ──" banner comment (see AGENTS.md,
# "Clear documentation"). Catches two drift patterns:
#
#   1. A block that precedes every recognized banner in the file (there is
#      no banner anywhere above it yet). Once at least one banner has been
#      seen, every later block reads as "covered" by whichever banner came
#      last, even one appended at true end-of-file with no new banner of
#      its own: distinguishing "correctly filed under this banner" from
#      "just happened to land after it" needs the semantic judgment call
#      the next paragraph already disclaims, not something this positional
#      check can soundly infer. This still guarantees the one thing it
#      claims: the file can never rot to having no sections at all.
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
# shells and containers) makes every real banner fail the strict-format
# check. Don't trust the *name* of LC_ALL/LC_CTYPE/LANG: an env var can read
# "en_US.UTF-8" while the underlying locale was never generated on this
# machine (common in minimal containers), in which case glibc silently
# stays in "C" despite the variable's name, and a name-only check would
# wrongly "preserve" a locale that never actually activated. Probe real
# multibyte matching behavior instead: if the current environment can't
# match "─" as a single character, try C.UTF-8 (the most widely available
# generated UTF-8 locale); if neither works, fall through and let the
# strict-format check fail loudly with a clear cause below, rather than
# silently misreporting every banner as malformed.
utf8_locale_usable() {
  "$BASH" -c '[[ "─" =~ ^.$ ]]' 2>/dev/null
}
if ! utf8_locale_usable; then
  if LC_ALL=C.UTF-8 utf8_locale_usable; then
    export LC_ALL=C.UTF-8
  else
    echo "check-variable-banners: no usable UTF-8 locale found (current environment and C.UTF-8 both fail to match a multibyte character); banner matching may report false failures below" >&2
  fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FILES=(variables.tf outputs.tf)
# Keep in lockstep with the banner order in variables.tf/outputs.tf. Update
# this list in the same PR that adds, renames, or reorders a banner, or this
# check fails on an otherwise-correct checkout.
VARIABLE_BANNERS=("Root contract skeleton (align-azure-with-aws-capabilities, section 1)" "Core inputs" "BYO networking" "AKS sizing, version, and hardening" "PostgreSQL topologies (align-azure-with-aws-capabilities section 3)" "External PostgreSQL endpoint (create_database = false)" "Redis topologies (align-azure-with-aws-capabilities section 4)" "Private Azure Blob storage" "Application Gateway ingress" "Application DNS" "Binary and execution-data storage modes" "Controllers and base n8n release" "n8n runtime and resource controls" "Metrics, tracing, and Enterprise log streaming" "Optional Redis queue metrics exporter (observability.tf)" "Workload autoscaling" "Custom images, extensions, volumes, and environment" "Credential overwrites" "n8n domain, certificate, and license" "AKS Key Vault Secrets Provider (Secrets Store CSI driver)" "AKS KMS etcd encryption" "Customer-managed infrastructure ownership (add-customer-managed-modularity section 1)")
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
    line="${line%$'\r'}"

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
    # Guard the empty case: "${banners[@]}" on an empty array trips set -u
    # on bash < 4.4 (including macOS /bin/bash 3.2).
    if [[ "${#banners[@]}" -eq 0 ]]; then
      echo "  found    (0): (none)" >&2
    else
      echo "  found    (${#banners[@]}): $(printf '%s | ' "${banners[@]}")" >&2
    fi
    echo "  expected (${#expected[@]}): $(printf '%s | ' "${expected[@]}")" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo >&2
  echo "See AGENTS.md, 'Clear documentation' > variable/output banners, for the convention; see this script's VARIABLE_BANNERS/OUTPUT_BANNERS arrays for the current section list." >&2
  exit 1
fi

echo "check-variable-banners: OK (${FILES[*]})"
