#!/usr/bin/env bash
# Ralph init: bring the repo to a runnable state and run a basic smoke check.
# Safe to run repeatedly. No Azure credentials required — all checks are
# offline (fmt / validate / mocked terraform test).
set -euo pipefail

cd "$(dirname "$0")"

echo "== Tool check =="
for tool in terraform tflint checkov terraform-docs; do
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
# section 15.5 deleted modules/infra and modules/workload. The
# split-ingress topology example matches the CI matrices in
# .github/workflows/terraform-tests.yml. The cloudflare and godaddy
# DNS-provider examples were removed in slim-first-release-surface section 1;
# see modules/tls-letsencrypt/README.md for the DNS-01 provider snippets they
# used to demonstrate.
DIRS=(
  .
  modules/tls-self-signed
  modules/tls-letsencrypt
  examples/small
  examples/medium
  examples/large
  examples/split-ingress
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
echo "== Smoke check passed =="
