#!/usr/bin/env bash
# check-version-drift.sh: report currency of every pin in docs/versioning.md
# against public sources. Never modifies a pin; always exits 0 (this is a
# report, not a gate) unless a required tool is missing or a pin cannot be
# read from the repo at all.
#
# Covers: the six Terraform providers (GitHub releases), CI toolchain
# (TF_VERSION, TFLINT_VERSION, CHECKOV_VERSION), the n8n Helm chart default
# (OCI registry tags), and aks_kubernetes_version's default against Azure's
# published AKS supported-versions page.
#
# Deliberately does NOT use endoflife.date for the Kubernetes-version check
# (port-aws-050-enhancements): that table has no AKS-specific product entry
# and would misreport AKS's own extended-support windows, which differ from
# upstream Kubernetes EOL. The AKS learn.microsoft.com page scrape below is
# best-effort HTML parsing, not a stable API; a parse failure is reported
# as "unable to determine", not treated as a script error.
#
# Usage:
#   tests/scripts/check-version-drift.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
source tests/scripts/lib/tf-defaults.sh

for tool in curl python3; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

WORKFLOW=".github/workflows/terraform-tests.yml"

echo "== Terraform provider currency (GitHub releases) =="
declare -A PROVIDER_REPOS=(
  [azurerm]="hashicorp/terraform-provider-azurerm"
  [kubernetes]="hashicorp/terraform-provider-kubernetes"
  [helm]="hashicorp/terraform-provider-helm"
  [random]="hashicorp/terraform-provider-random"
  [time]="hashicorp/terraform-provider-time"
  [kubectl]="gavinbunney/terraform-provider-kubectl"
)
for name in "${!PROVIDER_REPOS[@]}"; do
  repo="${PROVIDER_REPOS[$name]}"
  latest=$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','?'))" 2>/dev/null || echo "unavailable")
  pinned=$(python3 -c "
import re
text = open('versions.tf').read()
m = re.search(r'${name}\s*=\s*\{[^}]*version\s*=\s*\"([^\"]+)\"', text, re.S)
print(m.group(1) if m else 'unpinned')
")
  echo "  ${name}: repo pin '${pinned}', latest release ${latest}"
done

echo
echo "== CI toolchain currency (GitHub releases) =="
TF_LATEST=$(curl -sf "https://api.github.com/repos/hashicorp/terraform/releases/latest" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','?'))" 2>/dev/null || echo "unavailable")
TFLINT_LATEST=$(curl -sf "https://api.github.com/repos/terraform-linters/tflint/releases/latest" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','?'))" 2>/dev/null || echo "unavailable")
CHECKOV_LATEST=$(curl -sf "https://pypi.org/pypi/checkov/json" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('info',{}).get('version','?'))" 2>/dev/null || echo "unavailable")

pinned_tf="$(sed -n 's/^[[:space:]]*TF_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
pinned_tflint="$(sed -n 's/^[[:space:]]*TFLINT_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
pinned_checkov="$(sed -n 's/^[[:space:]]*CHECKOV_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"

echo "  terraform: pinned v${pinned_tf}, latest ${TF_LATEST}"
echo "  tflint: pinned ${pinned_tflint}, latest ${TFLINT_LATEST}"
echo "  checkov: pinned ${pinned_checkov}, latest ${CHECKOV_LATEST}"

echo
echo "== n8n Helm chart currency (OCI registry) =="
pinned_chart=$(read_default variables.tf n8n_chart_version)
if command -v helm >/dev/null 2>&1; then
  chart_latest=$(helm show chart oci://ghcr.io/n8n-io/n8n-helm-chart/n8n 2>/dev/null \
    | sed -n 's/^version:[[:space:]]*//p' | head -1)
  echo "  n8n_chart_version: pinned ${pinned_chart}, currently-tagged latest ${chart_latest:-unavailable (helm pull without --version resolves 'latest' tag, which this chart may not publish)}"
else
  echo "  n8n_chart_version: pinned ${pinned_chart} (helm not installed locally; skipping latest-tag lookup)"
fi

echo
echo "== AKS supported Kubernetes versions (learn.microsoft.com, best effort) =="
pinned_k8s=$(read_default variables.tf aks_kubernetes_version)
aks_page=$(curl -sfL "https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions" 2>/dev/null || true)
if [[ -n "$aks_page" ]]; then
  supported=$(echo "$aks_page" | grep -oE '1\.(2[0-9]|3[0-9]|4[0-9])' | sort -Vu | tail -5 | tr '\n' ' ')
  echo "  aks_kubernetes_version: pinned ${pinned_k8s}; versions mentioned on the AKS support page (best effort, not authoritative): ${supported:-unable to determine}"
else
  echo "  aks_kubernetes_version: pinned ${pinned_k8s}; could not fetch the AKS support page (network or format change). Check manually: az aks get-versions --location <region>"
fi

echo
echo "Report complete. This script never modifies a pin; bump deliberately in a reviewed commit."
