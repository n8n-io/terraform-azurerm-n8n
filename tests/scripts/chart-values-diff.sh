#!/usr/bin/env bash
# chart-values-diff.sh:
# Diff the pinned n8n chart's values.yaml against a candidate version via
# `helm show values`. One command instead of two remembered `helm show
# values` invocations plus a manual diff. Never writes or bumps a pin.
#
# Exits 0 once both `helm show values` calls succeed and `diff` ran,
# regardless of whether a diff was found. Exits 1 on bad usage, a missing
# tool, or a failed `helm show values` call (network/registry issue, or a
# candidate version that does not exist).
#
# <candidate-version> is normally a published chart version (resolved via the
# OCI registry, same as the pinned chart). It may instead be a local chart
# directory (one containing a Chart.yaml), which `helm show values` reads
# directly: this is how a not-yet-released chart (e.g. a chart 2.0 candidate
# checked out from an open n8n-hosting PR) gets diffed against the pinned
# version before it is published.
#
# Usage:
#   tests/scripts/chart-values-diff.sh <candidate-version>
#   tests/scripts/chart-values-diff.sh <path-to-local-chart-dir>
#   tests/scripts/chart-values-diff.sh --help
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source tests/scripts/lib/tf-defaults.sh

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 <candidate-version>|<path-to-local-chart-dir>"
  echo "Diffs the pinned n8n_chart_version's values.yaml against <candidate-version>."
  echo "<candidate-version> may be a local chart directory (containing Chart.yaml)"
  echo "instead of a published version, for a chart not yet released."
  exit 0
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <candidate-version>|<path-to-local-chart-dir>" >&2
  exit 1
fi

candidate="$1"

command -v helm >/dev/null || { echo "Required tool missing: helm" >&2; exit 1; }

pinned=$(read_default variables.tf n8n_chart_version)
if [[ -z "$pinned" ]]; then
  echo "Could not read n8n_chart_version's default from variables.tf" >&2
  exit 1
fi

repo="oci://ghcr.io/n8n-io/n8n-helm-chart/n8n"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== Pinned: ${pinned} =="
helm show values "$repo" --version "$pinned" > "$tmp/pinned.yaml"

if [[ -f "${candidate}/Chart.yaml" ]]; then
  echo "== Candidate: local chart at ${candidate} =="
  helm show values "$candidate" > "$tmp/candidate.yaml"
else
  echo "== Candidate: ${candidate} =="
  helm show values "$repo" --version "$candidate" > "$tmp/candidate.yaml"
fi

echo "== Diff (pinned -> candidate) =="
diff -u "$tmp/pinned.yaml" "$tmp/candidate.yaml" || true
