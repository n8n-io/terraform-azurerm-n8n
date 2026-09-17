#!/usr/bin/env bash
# Ralph init: bring the repo to a runnable state and run a basic smoke check.
# Safe to run repeatedly. No Azure credentials required — all checks are
# offline (fmt / validate / mocked terraform test).
set -euo pipefail

# This script lives in openspec/; run everything from the repo root.
cd "$(dirname "$0")/.."

echo "== Tool check =="
for tool in terraform tflint checkov terraform-docs helm jq; do
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
# example and the four customer-managed-* examples (added by
# add-customer-managed-modularity section 7) match the CI matrices in
# .github/workflows/terraform-tests.yml. The cloudflare and godaddy
# DNS-provider examples were removed in slim-first-release-surface section 1;
# see modules/tls-letsencrypt/README.md for the DNS-01 provider snippets they
# used to demonstrate.
DIRS=(
  .
  modules/controllers
  modules/tls-self-signed
  modules/tls-letsencrypt
  examples/small
  examples/medium
  examples/large
  examples/split-ingress
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
echo "== Smoke check passed =="
