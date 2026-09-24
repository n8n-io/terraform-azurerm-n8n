#!/usr/bin/env bash
# Ralph init: bring the repo to a runnable state and run a basic smoke check.
# Safe to run repeatedly. No Azure credentials required — all checks are
# offline (fmt / validate / mocked terraform test).
set -euo pipefail

# This script lives in openspec/; run everything from the repo root.
cd "$(dirname "$0")/.."

echo "== Tool check =="
for tool in terraform tflint checkov terraform-docs helm jq markdownlint; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ok: $tool ($("$tool" --version 2>/dev/null | head -1))"
  else
    echo "  MISSING: $tool (install via: brew install $tool)"
    [ "$tool" = "terraform" ] && exit 1
  fi
done

echo
echo "== terraform fmt =="
terraform fmt -check -recursive

# Every directory that carries resources and/or a test suite. `.` (the root)
# is the single resource-bearing module since align-azure-with-aws-capabilities
# section 15.5 deleted modules/infra and modules/workload. modules/controllers
# is the directly callable KEDA submodule added by
# add-customer-managed-modularity section 3. The split-ingress topology
# example, the worker-pools topology example (early alpha, added by
# port-aws-050-enhancements), and the four customer-managed-*
# examples (added by add-customer-managed-modularity section 7) match the
# CI matrices in .github/workflows/terraform-tests.yml. The cloudflare and
# godaddy DNS-provider examples were removed in slim-first-release-surface
# section 1; see modules/tls-letsencrypt/README.md for the DNS-01 provider
# snippets they used to demonstrate.
DIRS=(
  .
  modules/controllers
  modules/tls-self-signed
  modules/tls-letsencrypt
  examples/small
  examples/medium
  examples/large
  examples/split-ingress
  examples/worker-pools
  examples/customer-managed-cluster
  examples/customer-managed-redis
  examples/customer-managed-storage
  examples/customer-managed-everything
)

for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || { echo "skip: $dir (not present)"; continue; }
  echo
  echo "== $dir =="
  (
    cd "$dir"
    terraform init -backend=false -input=false >/dev/null
    terraform validate
    if compgen -G "tests/*.tftest.hcl" >/dev/null; then
      terraform test
    else
      echo "  (no tests)"
    fi
  )
done

echo
echo "== n8n chart rendering check =="
# Renders the pinned n8n Helm chart against the root module's actual
# variables/locals and asserts on the manifests Helm produces. Offline: no
# cluster, no Azure credentials, no apply. Needs helm + jq (checked above)
# and the root's own "terraform init -backend=false", already run in the
# loop above. See tests/scripts/README.md#chart-rendering-check.
tests/scripts/check-n8n-chart.sh

echo
echo "== smoke-test.sh offline self-test =="
# Exercises detect_topology() and check_deployment() against synthetic
# kubectl fixtures. Exits before the script's Preflight/az-login section, so
# it needs no live cluster or Azure credentials. This is not a live smoke
# test against a real deployment; that stays manual, per
# tests/scripts/README.md#smoke-test.
bash -n tests/scripts/smoke-test.sh
SMOKE_TEST_SELF_TEST=1 tests/scripts/smoke-test.sh

echo
echo "== preflight-region-check.sh syntax check and self-test =="
# Every real check in this script needs live Azure credentials, so only its
# syntax, shellcheck (when installed), --help path, and offline self-test
# (input validation + quota evaluation against synthetic fixtures) run here.
# See tests/scripts/README.md#region-preflight.
bash -n tests/scripts/preflight-region-check.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning tests/scripts/preflight-region-check.sh
fi
tests/scripts/preflight-region-check.sh --help >/dev/null
PREFLIGHT_SELF_TEST=1 tests/scripts/preflight-region-check.sh

echo
echo "== new-script syntax checks (port-aws-050-enhancements) =="
# Same treatment for the scripts this change added: chart-values-diff.sh
# and verify-worker-pools.sh need network or a live cluster for their real
# work, so only syntax, shellcheck (when installed), and --help run here.
for script in tests/scripts/chart-values-diff.sh tests/scripts/verify-worker-pools.sh \
  tests/scripts/check-version-drift.sh tests/scripts/check-checkov.sh scripts/check-example-parity.sh; do
  bash -n "$script"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$script"
  fi
done
tests/scripts/chart-values-diff.sh --help >/dev/null

echo
echo "== markdownlint =="
# Optional locally, like shellcheck above: CI installs the pinned
# MARKDOWNLINT_VERSION and runs it there regardless.
if command -v markdownlint >/dev/null 2>&1; then
  markdownlint --config .markdownlint.yml README.md AGENTS.md 'docs/**/*.md' 'examples/**/README.md' 'modules/**/README.md'
else
  echo "  skipped: markdownlint not installed (npm install -g markdownlint-cli)"
fi

echo
echo "== scripts/check-example-parity.sh =="
scripts/check-example-parity.sh

# Report-only and network-dependent; everything above runs offline. Set
# SKIP_VERSION_DRIFT=1 to keep this script fully offline.
if [[ "${SKIP_VERSION_DRIFT:-0}" != "1" ]]; then
  echo
  echo "== tests/scripts/check-version-drift.sh (report only, needs network) =="
  tests/scripts/check-version-drift.sh
fi

echo
echo "== Smoke check passed =="
