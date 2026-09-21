#!/usr/bin/env bash
# check-checkov.sh: run the checkov scan that gates CI.
#
# This is not a local imitation of the CI job: the `checkov` job in
# .github/workflows/terraform-tests.yml runs this exact script, so the
# flags, the config file, and the exit/reporting behavior have a single
# definition.
#
# Deliberate deviation from the AWS sibling's check-checkov.sh: AWS's repo
# is fully curated (every finding fixed or annotated with
# `checkov:skip=<ID>:<reason>`), so its script hard-fails on any finding.
# Azure's repo carries a pre-existing, uncurated backlog across every
# sizing example (subnet NSG associations, Key Vault purge protection,
# storage SAS/soft-delete, etc.) that a full curation pass has not
# reached yet (see AGENTS.md's "Static analysis" quality-bar section).
# Hard-failing on that backlog here would be a scope-widening no one
# asked for, so pass 1 below reports but never fails the script. The one
# thing this script does hard-fail on is pass 2's coverage guarantee: an
# opt-in resource that stops being reached is a real regression (a
# rename or a broken toggle), not a backlog item, and that must never go
# quiet again the way the original checkov-action gap did.
#
# Two passes: the configuration as written (reported, not gating), then
# the same scan with every opt-in toggle in tests/checkov/opt-in.tfvars
# turned on (gating on coverage only), because checkov never evaluates a
# count-0 resource (details at pass 2 below).
#
# Usage:
#   tests/scripts/check-checkov.sh
#
# Requires checkov at the version CI pins (CHECKOV_VERSION in the
# workflow):
#   uv tool install checkov==<version>
#   # or: pipx install --force checkov==<version>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/terraform-tests.yml"

if ! command -v checkov >/dev/null 2>&1; then
  echo "checkov not found on PATH. Install it: uv tool install checkov" >&2
  exit 1
fi

# checkov results depend on the checkov version, not only on the code being
# scanned (a resource reached only through a local module source can draw
# zero findings on one checkov release and a full check family on the
# next), so a clean run on an arbitrary version says nothing about whether
# the gate passes. The pin lives in the workflow, making that file the
# single source of truth for CI and for here; CHECKOV_VERSION_CHECK=off
# bypasses this, which is what you want when trying a newer release before
# pinning it.
PINNED="$(sed -n 's/^[[:space:]]*CHECKOV_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
INSTALLED="$(checkov --version 2>/dev/null | tr -d '[:space:]')"

if [[ "${CHECKOV_VERSION_CHECK:-on}" != "off" && -n "$PINNED" && "$INSTALLED" != "$PINNED" ]]; then
  cat >&2 <<EOF
checkov version mismatch: installed $INSTALLED, CI pins $PINNED.

Results are not comparable across versions, so this run would not tell you
whether CI passes. Install the pinned version:

  uv tool install checkov==$PINNED
  # or: pipx install --force checkov==$PINNED

The pin lives in $WORKFLOW (CHECKOV_VERSION).
Set CHECKOV_VERSION_CHECK=off to run anyway.
EOF
  exit 1
fi

cd "$REPO_ROOT"

SCAN=(checkov -d . --framework terraform --config-file .checkov.yaml --compact)

# Pass 1: the module and every example exactly as written. --quiet prints
# failures only, so a clean pass is silent apart from the summary line.
# Report only: see the header note on the pre-existing, uncurated backlog.
echo "checkov pass 1/2: defaults (reported, not gating)"
set +e
"${SCAN[@]}" --quiet
set -e

# Pass 2: the same scan with every opt-in toggle turned on. checkov
# evaluates `count` from variable defaults and answers each check on a
# count-0 resource with UNKNOWN, which it drops from the report, so a
# resource that is off in the module defaults and in every example is
# never evaluated by pass 1 at all: kubernetes_deployment_v1.redis_exporter
# and its Service draw zero results with defaults and the full set of
# CKV_K8S_* checks with the toggle on. tests/checkov/opt-in.tfvars lists
# the toggles; OPT_IN_RESOURCES lists the addresses the pass must reach,
# so a rename or a toggle that stops resolving fails here instead of
# silently shrinking coverage back to zero. Add to both when adding an
# opt-in Kubernetes resource.
OPT_IN_TFVARS="tests/checkov/opt-in.tfvars"
OPT_IN_RESOURCES=(
  "kubernetes_deployment_v1.redis_exporter[0]"
  "kubernetes_service_v1.redis_exporter[0]"
)

echo "checkov pass 2/2: opt-in resources (--var-file $OPT_IN_TFVARS)"
# Not --quiet: PASSED lines are what prove the scan reached each resource.
# The full listing is kept in a temp file and only the summary is echoed.
OPT_IN_REPORT="$(mktemp)"
trap 'rm -f "$OPT_IN_REPORT"' EXIT
set +e
"${SCAN[@]}" --var-file "$OPT_IN_TFVARS" > "$OPT_IN_REPORT"
rc=$?
set -e

# On findings, show only the failed blocks, the way --quiet would have. A
# block is one "Check:" line and its indented detail lines.
if [[ $rc -ne 0 ]]; then
  awk '
    /^Check:/ { if (block ~ /FAILED for resource/) printf "%s", block; block = $0 "\n"; next }
    /^[[:space:]]/ { block = block $0 "\n"; next }
    { if (block ~ /FAILED for resource/) printf "%s", block; block = "" }
    END { if (block ~ /FAILED for resource/) printf "%s", block }
  ' "$OPT_IN_REPORT"
fi
grep -E "^(Passed checks|terraform scan results)" "$OPT_IN_REPORT" || true

for address in "${OPT_IN_RESOURCES[@]}"; do
  if ! grep -qF "$address" "$OPT_IN_REPORT"; then
    echo "checkov pass 2 did not reach $address: no check was evaluated against it." >&2
    echo "Either its toggle is missing from $OPT_IN_TFVARS or the resource was renamed." >&2
    exit 1
  fi
done

echo "checkov: coverage confirmed for every opt-in resource (findings above are reported, not gating; see AGENTS.md)."
