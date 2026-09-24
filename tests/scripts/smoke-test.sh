#!/usr/bin/env bash
# smoke-test.sh — post-`terraform apply` smoke test for terraform-azurerm-n8n.
#
# This module deploys either the default multi-main topology (multiple
# n8n-main pods + dedicated n8n-worker pods + n8n-webhook-processor pods) or,
# when `n8n_main_hpa_min_replicas = 1`, an optional single-main topology for
# licenses without `feat:multipleMainInstances` (port-aws-040-enhancements
# section 2) — both sit behind Application Gateway with AGIC, fronted by
# Azure Managed Redis and PostgreSQL Flexible Server. The script detects
# which topology is actually rendered on the cluster and branches its main
# replica/HPA/strategy/PDB/leader-election checks accordingly; every other
# assertion (worker, webhook-processor, ingress, storage, license) applies to
# both:
#
#   ── Cluster + workload ─────────────────────────────────────────────────────
#   1.  kubectl is configured against the AKS cluster and the API server
#       responds.
#   2.  The n8n namespace exists.
#   3.  Topology detection: reads the rendered `n8n-main` HPA/Deployment/PDB
#       to determine single-main (HPA 1/1, `Recreate`, PDB minAvailable 0)
#       vs. multi-main (HPA floor > 1, rolling update, PDB minAvailable 1) —
#       never inferred from the current main pod count.
#   4.  ≥1 (single-main) or ≥2 (multi-main, or the configured floor)
#       n8n-main pods Ready, ≥1 n8n-worker pod Ready, ≥2
#       n8n-webhook-processor pods Ready. While the worker `ScaledObject`
#       is paused (`n8n_worker_keda_pause`), the worker floor check is
#       skipped; when it is paused at `paused-replicas: 0`, every check
#       that needs a running worker (application version on workers,
#       Redis connectivity, workflow execution) is skipped too, and the
#       optional load test is skipped for any pause.
#   5.  Application version: `n8n --version` agrees across main, worker,
#       and webhook-processor pods (catches a half-finished rollout).
#   6.  Leader election: multi-main expects `N8N_MULTI_MAIN_SETUP_ENABLED=true`
#       on main pods plus leadership activity in main logs; single-main
#       expects the flag unset/false and skips the log check (single-main
#       runs no Redis leader election).
#   7.  Task runner sidecar present + connected to the broker on worker
#       pods (warning when task runners are disabled).
#   8.  KEDA `TriggerAuthentication` `n8n-redis-keda-auth` present in the
#       n8n namespace — the chart's worker `ScaledObject` references it.
#   9.  Autoscaler state surface: KEDA `ScaledObject` (workers, queue-
#       depth driven against Azure Cache for Redis) + HPA
#       (`n8n-webhook-processor`, CPU-based).
#   10. Worker pods see `QUEUE_BULL_REDIS_HOST` (the Azure Cache for Redis
#       FQDN) + queue-related log activity.
#   11. PostgreSQL: main pod's `DB_POSTGRESDB_HOST` matches
#       `terraform output postgres_fqdn` and its logs show no connection
#       or authentication errors.
#   12. Azure Blob: main pod's `N8N_EXTERNAL_STORAGE_AZURE_*` environment
#       matches the storage outputs and its logs show no Blob
#       authorization errors (skipped unless the binary-data mode is
#       `azure`).
#
#   ── Ingress + reachability ─────────────────────────────────────────────────
#   13. App Gateway public IP reachable on TCP/443.
#   14. HTTPS GET on `n8n_url` returns HTTP 200 — uses regular DNS first,
#       falls back to `curl --resolve <fqdn>:443:<APPGW_PUBLIC_IP>` when
#       the parent zone hasn't been delegated to Azure DNS yet.
#   15. HTTP → HTTPS redirect on port 80 returns 30x (the chart sets
#       `appgw.ingress.kubernetes.io/ssl-redirect = "true"`).
#   16. Webhook route ownership: every prefix in
#       `n8n_webhook_path_prefixes` (`/webhook`, `/webhook-waiting`,
#       `/form`, `/form-waiting`, `/mcp`) routes to the
#       webhook-processor Service, and `/` routes to the main Service.
#
#   ── Application + license ──────────────────────────────────────────────────
#   17. API connectivity: GET `/api/v1/workflows?limit=1` returns 200
#       (skipped when N8N_API_KEY is unset).
#   18. Workflow execution: webhook → set workflow round-trip via the
#       App Gateway listener (skipped when N8N_API_KEY is unset).
#   19. n8n license is valid via `n8n license:info` exec'd inside a Ready
#       main pod (no API key needed).
#
#   ── Optional load test ─────────────────────────────────────────────────────
#   20. Worker scaling: queues CPU-burning webhook executions and verifies
#       KEDA scales `n8n-worker` up via Azure Redis queue depth (opt-in
#       via LOAD_TEST=true; requires N8N_API_KEY). Topology-agnostic — it
#       exercises worker KEDA scaling regardless of the main topology.
#
# This script is intentionally NOT wired into CI — it requires a live
# applied stack and an `az login`'d operator. See ./README.md for usage,
# ./.env.example for the configuration template.
#
# Mirrors the design of terraform-aws-n8n/tests/scripts/smoke-test.sh
# (sibling module). Same structure, same env-var contract, same `.env`
# loading priority. Azure-specific deltas:
#
#   - Topology is detected from the rendered `n8n-main` HPA/Deployment/PDB
#     (port-aws-040-enhancements section 2), not from a caller-supplied
#     DEPLOY_MODE switch like the AWS sibling's — this module derives
#     topology from one input (`n8n_main_hpa_min_replicas`), so there is
#     no separate mode flag to auto-detect from.
#   - kubectl is populated via `az aks get-credentials` (the
#     `kubectl_config_command` Terraform output) into a transient
#     kubeconfig — the operator's `~/.kube/config` is never touched.
#   - DNS-not-delegated `--resolve` fallback against the App Gateway's
#     static public IP — the example writes the A-record automatically
#     but registrar-side NS delegation to the example-owned Azure DNS
#     zone has to be in place before public DNS resolves.
#
# Priority: .env explicit values → environment variables → Terraform
# outputs → built-in defaults.

set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────
# Look for .env in (1) the script's own directory, then (2) the current
# working directory (TERRAFORM_DIR / wherever the operator launched the
# script from). Mirrors the AWS sibling's loader. Never errors when the
# file is absent — .env is optional and `.gitignore`'d.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _env_candidate in "$SCRIPT_DIR/.env" "$(pwd)/.env"; do
  if [[ -f "$_env_candidate" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$_env_candidate"
    set +a
    break
  fi
done

# ── Configuration ─────────────────────────────────────────────────────────────

TERRAFORM_DIR="${TERRAFORM_DIR:-$(pwd)}"

# Main replica floor is detected per-topology in the "Topology detection"
# section below (single-main clamps to 1; multi-main reads the rendered
# n8n-main HPA's minReplicas). Invalid topology stops the live smoke test.
MAIN_MIN=2
WORKER_MIN=1
WEBHOOK_MIN=2

# Multi-main optional load-test settings — no-ops unless LOAD_TEST=true.
# `LOAD_SEED_JOBS=40` is calibrated to clear the chart's stock
# `queueMode.workerConcurrency=10` × `n8n_worker_keda_min_replicas=2` =
# 20 in-flight slots AND push at least 10 jobs into `bull:jobs:wait` (the
# KEDA trigger threshold = `listLength=5` × 2 replicas), which together
# give KEDA something to scale on. Lower the seed only if you've also
# lowered the chart-level concurrency or the KEDA target list-length;
# otherwise the load test can complete without any queue depth ever
# accumulating and the autoscaler-scale-up assertion warns harmlessly.
LOAD_TEST="${LOAD_TEST:-false}"
LOAD_REQUESTS="${LOAD_REQUESTS:-100}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-20}"
LOAD_SEED_JOBS="${LOAD_SEED_JOBS:-40}"      # phase 1: jobs queued to trigger the autoscaler (see comment above)
LOAD_JOB_DURATION_SECS="${LOAD_JOB_DURATION_SECS:-15}"
SCALE_WAIT_SECS="${SCALE_WAIT_SECS:-240}"

# Curl timeout used by the non-load-test reachability checks.
CURL_TIMEOUT=10

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── State ─────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
WARN=0
SKIPPED=0

# ── Helpers ───────────────────────────────────────────────────────────────────

header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
pass()   { echo -e "  ${GREEN}✔${RESET}  $*"; PASS=$((PASS + 1)); }
fail()   { echo -e "  ${RED}✘${RESET}  $*"; FAIL=$((FAIL + 1)); }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $*"; WARN=$((WARN + 1)); }
skip()   { echo -e "  ${YELLOW}–${RESET}  $* ${YELLOW}(skipped)${RESET}"; SKIPPED=$((SKIPPED + 1)); }
info()   { echo -e "      ${CYAN}↳${RESET} $*"; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}ERROR: required command '$1' not found.${RESET}" >&2
    echo -e "${RED}Install it before running smoke-test.sh.${RESET}" >&2
    exit 1
  fi
}

# Resolves an FQDN via the system resolver. Echoes "yes" / "no" so callers
# can decide whether to fall back to `curl --resolve <fqdn>:443:<ip>`.
dns_resolves() {
  local host="$1"
  if command -v getent &>/dev/null; then
    getent hosts "$host" &>/dev/null && return 0
  else
    # macOS: no getent — `host` is part of bind-utils, fall back to dig
    # and finally to a Python one-liner if nothing else is available.
    if command -v host &>/dev/null && host -W 2 "$host" &>/dev/null; then
      return 0
    elif command -v dig &>/dev/null && [[ -n "$(dig +short +time=2 +tries=1 "$host" 2>/dev/null)" ]]; then
      return 0
    elif command -v python3 &>/dev/null && python3 -c "import socket,sys; sys.exit(0 if socket.gethostbyname('$host') else 1)" &>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Build the curl arg list for hitting `n8n_url`. When DNS resolves we use
# the URL verbatim; when it doesn't, we splice in `--resolve` against the
# AGW public IP so HTTPS / API / webhook tests still work end-to-end.
#
# The `${arr[@]+"${arr[@]}"}` idiom is the canonical bash-3.2 workaround
# for `set -u` tripping on empty-array expansion (macOS ships bash 3.2).
# Without it, `"${arr[@]}"` raises `unbound variable` when arr is empty
# and `set -u` is on, silently aborting the script the first time we
# reach for the curl helper.
CURL_RESOLVE_ARGS=()

curl_to_n8n() {
  curl -sk ${CURL_RESOLVE_ARGS[@]+"${CURL_RESOLVE_ARGS[@]}"} "$@"
}

# ── Topology detection ─────────────────────────────────────────────────────────
# Detect single-main vs. multi-main from the *rendered* chart resources
# rather than the current main pod count, which can transiently differ from
# the configured floor mid-rollout. The n8n-main HorizontalPodAutoscaler is
# the canonical signal: single-main always clamps minReplicas = maxReplicas
# = 1 (design.md decision 2, n8n.tf local.n8n_main_hpa_effective_max_replicas).
# Multi-main requires a floor of at least 2 and a maximum at or above it.
# Missing or inconsistent HPA/Deployment/PDB settings fail the check.
# Deployment strategy and PDB minAvailable are read as consistency
# cross-checks against that same topology, not as a second source of truth.
# Defined here (rather than inline where it's called) so the self-test block
# below can exercise it against fixtures without duplicating the logic.
detect_topology() {
  TOPOLOGY="unknown"

  local main_hpa_min main_hpa_max main_strategy main_pdb_min
  local fail_before="$FAIL"
  main_hpa_min=$(kubectl get hpa n8n-main -n "$NAMESPACE" \
    -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)
  main_hpa_max=$(kubectl get hpa n8n-main -n "$NAMESPACE" \
    -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)
  main_strategy=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
    -o jsonpath='{.spec.strategy.type}' 2>/dev/null || true)
  main_pdb_min=$(kubectl get pdb n8n-main -n "$NAMESPACE" \
    -o jsonpath='{.spec.minAvailable}' 2>/dev/null || true)

  if [[ ! "$main_hpa_min" =~ ^[1-9][0-9]*$ || ! "$main_hpa_max" =~ ^[1-9][0-9]*$ ]]; then
    fail "n8n-main HPA bounds are missing or invalid: min='${main_hpa_min:-<unset>}' max='${main_hpa_max:-<unset>}'"
    return 1
  fi

  if [[ "$main_hpa_max" -lt "$main_hpa_min" || ( "$main_hpa_min" == "1" && "$main_hpa_max" != "1" ) ]]; then
    fail "n8n-main HPA must use 1/1 for single-main or 2+ with max >= min for multi-main (got $main_hpa_min/$main_hpa_max)"
    return 1
  fi

  if [[ "$main_hpa_min" == "1" ]]; then
    TOPOLOGY="single-main"
    MAIN_MIN=1
    pass "Detected topology: single-main (n8n-main HPA minReplicas=maxReplicas=1)"

    if [[ "$main_strategy" == "Recreate" ]]; then
      pass "n8n-main deployment strategy is Recreate (matches the single-main safeguard)"
    else
      fail "n8n-main deployment strategy is '${main_strategy:-<unset>}', expected Recreate for single-main"
    fi

    if [[ "$main_pdb_min" == "0" ]]; then
      pass "n8n-main PDB minAvailable=0 (voluntary eviction permitted, matches single-main)"
    else
      fail "n8n-main PDB minAvailable='${main_pdb_min:-<unset>}', expected 0 for single-main"
    fi
  else
    TOPOLOGY="multi-main"
    MAIN_MIN="$main_hpa_min"
    pass "Detected topology: multi-main (n8n-main HPA minReplicas=$main_hpa_min, maxReplicas=${main_hpa_max:-?})"

    if [[ "$main_strategy" == "RollingUpdate" ]]; then
      pass "n8n-main deployment strategy is RollingUpdate (chart default, matches multi-main)"
    else
      fail "n8n-main deployment strategy is '${main_strategy:-<unset>}', expected RollingUpdate for multi-main"
    fi

    if [[ "$main_pdb_min" == "1" ]]; then
      pass "n8n-main PDB minAvailable=1 (protects one replica during voluntary disruption, matches multi-main)"
    else
      fail "n8n-main PDB minAvailable='${main_pdb_min:-<unset>}', expected 1 for multi-main"
    fi
  fi

  info "Topology: $TOPOLOGY (main floor: $MAIN_MIN)"
  [[ "$FAIL" -eq "$fail_before" ]]
}

# ── Pod readiness helper ─────────────────────────────────────────────────────
# Defined here (rather than inline in the "Pod readiness" section below) for
# the same self-test reason as detect_topology() above.
check_deployment() {
  local name="$1"
  local min_replicas="$2"
  local label="$3"

  if ! kubectl get deployment "$name" -n "$NAMESPACE" &>/dev/null; then
    fail "$label: deployment '$name' not found"
    return
  fi

  local ready desired
  ready=$(kubectl get deployment "$name" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready="${ready:-0}"
  desired=$(kubectl get deployment "$name" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "$ready" -ge "$min_replicas" && "$ready" -eq "$desired" ]]; then
    pass "$label: $ready/$desired pods Ready (min $min_replicas)"
  else
    fail "$label: $ready/$desired pods Ready (need ≥ $min_replicas)"
    local bad_pods
    bad_pods=$(kubectl get pods -n "$NAMESPACE" \
      -l "app.kubernetes.io/component=${name#n8n-}" \
      --no-headers 2>/dev/null \
      | awk '{print $1, $3}' \
      | grep -v "Running\|Completed" || true)
    if [[ -n "$bad_pods" ]]; then
      while IFS= read -r line; do info "$line"; done <<< "$bad_pods"
    fi
  fi
}

# ── Worker pause detection ───────────────────────────────────────────────────
# n8n_worker_keda_pause annotates the chart's worker ScaledObject with
# autoscaling.keda.sh/paused (and paused-replicas when a held count is set).
# Sets WORKER_PAUSED ("true"/"false"), WORKER_PAUSED_REPLICAS (the held count,
# empty when workers freeze at their current count), and WORKER_DRAINED
# ("true" only when paused at 0, i.e. no worker is expected to be running and
# queued jobs deliberately wait in Redis). Defined here for the same
# self-test reason as detect_topology() above.
detect_worker_pause() {
  WORKER_PAUSED="false"
  WORKER_PAUSED_REPLICAS=""
  WORKER_DRAINED="false"

  local paused
  paused=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused}' 2>/dev/null || echo "")
  [[ "$paused" == "true" ]] || return 0

  WORKER_PAUSED="true"
  WORKER_PAUSED_REPLICAS=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}' 2>/dev/null || echo "")
  if [[ "$WORKER_PAUSED_REPLICAS" == "0" ]]; then
    WORKER_DRAINED="true"
  fi
}

# Inspect captured history, not current leader uniqueness. Diagnostics take
# precedence over role messages so a later recovery cannot hide a conflict.
check_leader_logs() {
  local logs="$1" label="$2" diagnostics activity
  diagnostics=$(printf '%s\n' "$logs" | grep -iE \
    'Detected ([2-9]|[1-9][0-9]+) instances claiming leader role|Leader failed to renew leader key|Failed to (set leader key|clear leader key|get leader key|renew leader TTL|try leader key set)' || true)
  if [[ -n "$diagnostics" ]]; then
    fail "$label: leader-election conflict/failure diagnostic in captured logs (may be historical; does not establish ongoing split-brain)"
    while IFS= read -r line; do info "$line"; done <<< "$diagnostics"
    return
  fi

  if printf '%s\n' "$logs" | grep -qi 'MaxListenersExceededWarning'; then
    warn "$label: listener warnings in captured logs are not leader-election success evidence"
  fi

  activity=$(printf '%s\n' "$logs" \
    | grep -viE 'warn|error|fail' \
    | grep -E '\[Instance ID [^]]+\] (Leader is now this instance|Leader is this instance|Leader is other instance "[^"]+"|This is now a follower instance)[[:space:]]*$' \
    | tail -3 || true)
  if [[ -n "$activity" ]]; then
    info "$label: historical leader-role activity (not proof of a unique current leader)"
    while IFS= read -r line; do info "$line"; done <<< "$activity"
  else
    skip "$label: no explicit leader-role activity in captured logs; leader uniqueness is unverified"
  fi
}

check_main_leader_logs() {
  local leader_pods leader_pod leader_logs
  if ! leader_pods=$(kubectl get pods -n "$NAMESPACE" \
      -l app.kubernetes.io/component=main \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); then
    fail "Could not enumerate main pods for leader-log inspection"
    return
  fi
  if [[ -z "$leader_pods" ]]; then
    fail "No main pods available for leader-log inspection"
    return
  fi
  while IFS= read -r leader_pod; do
    [[ -z "$leader_pod" ]] && continue
    if leader_logs=$(kubectl logs "$leader_pod" -n "$NAMESPACE" -c n8n-main --tail=200); then
      check_leader_logs "$leader_logs" "$leader_pod"
    else
      fail "$leader_pod: could not read main container logs"
    fi
  done <<< "$leader_pods"
}

# ── Self-test (offline, no Azure credentials) ─────────────────────────────────
# `SMOKE_TEST_SELF_TEST=1 ./smoke-test.sh` exercises detect_topology() and
# check_deployment() against recorded/synthetic kubectl fixtures for
# single-main, healthy multi-main, degraded multi-main (one ready pod of
# two desired), and invalid HPA/strategy/PDB combinations, proving the logic offline,
# without az login, terraform state, or a live cluster. Runs and exits before
# Preflight's require_cmd/az-login checks, so `bash -n` plus this mode is the
# full offline verification surface for this script.
if [[ "${SMOKE_TEST_SELF_TEST:-0}" == "1" ]]; then
  NAMESPACE="n8n"
  self_test_failures=0

  assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
      pass "$desc (got '$actual')"
    else
      fail "$desc (expected '$expected', got '$actual')"
      self_test_failures=$((self_test_failures + 1))
    fi
  }

  # Fixture-driven stub replacing the real kubectl for the duration of the
  # self-test. FIXTURE_HPA_MIN/MAX, FIXTURE_STRATEGY, FIXTURE_PDB_MIN, and
  # FIXTURE_MAIN_READY/FIXTURE_MAIN_DESIRED drive every call detect_topology()
  # and check_deployment() make; anything else (e.g. the bad-pods listing)
  # returns an empty, successful result.
  kubectl() {
    if [[ "$1" == "get" && "$2" == "hpa" && "$3" == "n8n-main" ]]; then
      case "$*" in
        *minReplicas*) echo "$FIXTURE_HPA_MIN" ;;
        *maxReplicas*) echo "$FIXTURE_HPA_MAX" ;;
      esac
      return 0
    elif [[ "$1" == "get" && "$2" == "deployment" && "$3" == "n8n-main" ]]; then
      case "$*" in
        *strategy.type*)   echo "$FIXTURE_STRATEGY" ;;
        *readyReplicas*)   echo "$FIXTURE_MAIN_READY" ;;
        *spec.replicas*)   echo "$FIXTURE_MAIN_DESIRED" ;;
      esac
      return 0
    elif [[ "$1" == "get" && "$2" == "pdb" && "$3" == "n8n-main" ]]; then
      echo "$FIXTURE_PDB_MIN"
      return 0
    fi
    return 0
  }

  echo "== Self-test: single-main =="
  FIXTURE_HPA_MIN=1 FIXTURE_HPA_MAX=1 FIXTURE_STRATEGY="Recreate" FIXTURE_PDB_MIN=0 \
    FIXTURE_MAIN_READY=1 FIXTURE_MAIN_DESIRED=1
  detect_topology
  assert_eq "single-main topology" "single-main" "$TOPOLOGY"
  assert_eq "single-main floor" "1" "$MAIN_MIN"
  check_deployment "n8n-main" "$MAIN_MIN" "n8n-main"

  echo "== Self-test: healthy multi-main =="
  before_fail="$FAIL"
  FIXTURE_HPA_MIN=2 FIXTURE_HPA_MAX=6 FIXTURE_STRATEGY="RollingUpdate" FIXTURE_PDB_MIN=1 \
    FIXTURE_MAIN_READY=2 FIXTURE_MAIN_DESIRED=2
  detect_topology
  assert_eq "multi-main topology" "multi-main" "$TOPOLOGY"
  assert_eq "multi-main floor" "2" "$MAIN_MIN"
  check_deployment "n8n-main" "$MAIN_MIN" "n8n-main"
  if [[ "$FAIL" -eq "$before_fail" ]]; then
    pass "healthy multi-main pod-readiness check raised no failures"
  else
    fail "healthy multi-main fixture unexpectedly raised a pod-readiness failure"
    self_test_failures=$((self_test_failures + 1))
  fi

  echo "== Self-test: degraded multi-main (one ready pod of two desired) =="
  before_fail="$FAIL"
  FIXTURE_HPA_MIN=2 FIXTURE_HPA_MAX=6 FIXTURE_STRATEGY="RollingUpdate" FIXTURE_PDB_MIN=1 \
    FIXTURE_MAIN_READY=1 FIXTURE_MAIN_DESIRED=2
  detect_topology
  assert_eq "degraded multi-main topology" "multi-main" "$TOPOLOGY"
  check_deployment "n8n-main" "$MAIN_MIN" "n8n-main"
  if [[ "$FAIL" -gt "$before_fail" ]]; then
    pass "degraded multi-main correctly reported as failing (1/2 ready < floor 2)"
  else
    fail "degraded multi-main fixture did not trip a failed pod-readiness check"
    self_test_failures=$((self_test_failures + 1))
  fi

  echo "== Self-test: invalid topology safeguards =="
  while IFS='|' read -r fixture_name FIXTURE_HPA_MIN FIXTURE_HPA_MAX FIXTURE_STRATEGY FIXTURE_PDB_MIN; do
    before_fail="$FAIL"
    if detect_topology; then
      fail "$fixture_name unexpectedly passed topology detection"
      self_test_failures=$((self_test_failures + 1))
    elif [[ "$FAIL" -gt "$before_fail" ]]; then
      pass "$fixture_name correctly failed topology detection"
    else
      fail "$fixture_name returned failure without recording a failed check"
      self_test_failures=$((self_test_failures + 1))
    fi
  done <<'FIXTURES'
missing HPA||||
missing minimum||6|RollingUpdate|1
missing maximum|2||RollingUpdate|1
nonnumeric minimum|invalid|6|RollingUpdate|1
nonnumeric maximum|2|invalid|RollingUpdate|1
zero minimum|0|6|RollingUpdate|1
zero maximum|2|0|RollingUpdate|1
negative minimum|-1|6|RollingUpdate|1
fractional minimum|1.5|6|RollingUpdate|1
fractional maximum|2|6.5|RollingUpdate|1
inverted bounds|3|2|RollingUpdate|1
unclamped single-main|1|6|RollingUpdate|1
single-main rolling update|1|1|RollingUpdate|0
single-main missing strategy|1|1||0
single-main wrong PDB|1|1|Recreate|1
single-main missing PDB|1|1|Recreate|
multi-main recreate|2|6|Recreate|1
multi-main missing strategy|2|6||1
multi-main wrong PDB|2|6|RollingUpdate|0
multi-main missing PDB|2|6|RollingUpdate|
FIXTURES

  echo ""
  echo "== Self-test: leader-log evidence =="
  while IFS='|' read -r fixture_name expected_fail expected_warn expected_skip fixture_logs; do
    before_pass="$PASS" before_fail="$FAIL" before_warn="$WARN" before_skip="$SKIPPED"
    check_leader_logs "$(printf '%b' "$fixture_logs")" "$fixture_name"
    delta_pass=$((PASS - before_pass)) delta_fail=$((FAIL - before_fail))
    delta_warn=$((WARN - before_warn)) delta_skip=$((SKIPPED - before_skip))
    assert_eq "$fixture_name counters (pass/fail/warn/skip)" \
      "0/$expected_fail/$expected_warn/$expected_skip" "$delta_pass/$delta_fail/$delta_warn/$delta_skip"
  done <<'LEADER_FIXTURES'
multiple leaders|1|0|0|Cluster check warning Detected 2 instances claiming leader role: a, b
many leaders|1|0|0|Cluster check warning Detected 12 instances claiming leader role: a, b
listener warning|0|1|1|MaxListenersExceededWarning: 11 leader-takeover listeners added to [MultiMainSetup]
positive|0|0|0|[Instance ID a] Leader is now this instance
follower|0|0|0|[Instance ID b] This is now a follower instance
mixed conflict and recovery|1|0|0|Detected 2 instances claiming leader role: a, b\n[Instance ID a] Leader is now this instance\n[Instance ID a] Leader is this instance\n[Instance ID a] Leader is this instance\n[Instance ID a] Leader is this instance
listener and positive|0|1|0|MaxListenersExceededWarning: 11 leader-stepdown listeners\n[Instance ID a] Leader is now this instance
warning with positive text|0|0|1|Warning: [Instance ID a] Leader is now this instance
renewal failure|1|0|0|[Multi-main setup] Leader failed to renew leader key
Redis leader failure|1|0|0|Failed to set leader key in Redis during init: connection refused
resolved audit event|0|0|1|n8n.audit.cluster.split-brain.resolved
unrelated|0|0|1|Initializing n8n process
empty|0|0|1|
LEADER_FIXTURES

  # Exercise real failure handling, including continuing after a failed read.
  kubectl() {
    if [[ "$1" == "get" ]]; then
      [[ "$LEADER_READ_FIXTURE" == "enumeration failure" ]] && return 1
      [[ "$LEADER_READ_FIXTURE" == "no pods" ]] && return 0
      printf 'main-a\nmain-b\n'
    elif [[ "$1" == "logs" ]]; then
      if [[ "$LEADER_READ_FIXTURE" == "first read failure" && "$2" == "main-a" ]]; then
        return 1
      elif [[ "$2" == "main-b" ]]; then
        echo 'Detected 2 instances claiming leader role: a, b'
      else
        echo '[Instance ID a] Leader is now this instance'
      fi
    else
      return 1
    fi
  }
  while IFS='|' read -r LEADER_READ_FIXTURE expected_fail; do
    before_pass="$PASS" before_fail="$FAIL"
    check_main_leader_logs
    delta_pass=$((PASS - before_pass)) delta_fail=$((FAIL - before_fail))
    assert_eq "$LEADER_READ_FIXTURE counters (pass/fail)" "0/$expected_fail" "$delta_pass/$delta_fail"
  done <<'LEADER_READ_FIXTURES'
enumeration failure|1
no pods|1
second pod conflict|1
first read failure|2
LEADER_READ_FIXTURES

  echo ""
  echo "== Self-test: worker pause detection =="
  kubectl() {
    if [[ "$1" == "get" && "$2" == "scaledobject" && "$3" == "n8n-worker" ]]; then
      case "$*" in
        *paused-replicas*) echo "$FIXTURE_PAUSED_REPLICAS" ;;
        *paused*)          echo "$FIXTURE_PAUSED" ;;
      esac
      return 0
    fi
    return 1
  }
  while IFS='|' read -r fixture_name FIXTURE_PAUSED FIXTURE_PAUSED_REPLICAS expected; do
    detect_worker_pause
    assert_eq "$fixture_name (paused/held/drained)" "$expected" \
      "$WORKER_PAUSED/$WORKER_PAUSED_REPLICAS/$WORKER_DRAINED"
  done <<'PAUSE_FIXTURES'
not paused|||false//false
paused annotation false|false||false//false
paused at current count|true||true//false
paused at zero|true|0|true/0/true
paused at two|true|2|true/2/false
stray held count without pause|false|0|false//false
PAUSE_FIXTURES

  echo "Self-test summary: $PASS passed, $FAIL failed (includes expected failures), $WARN warned"
  if [[ "$self_test_failures" -gt 0 ]]; then
    echo "SELF-TEST RESULT: FAIL"
    exit 1
  fi
  echo "SELF-TEST RESULT: PASS"
  exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────

header "Preflight"

require_cmd terraform
require_cmd az
require_cmd kubectl
require_cmd curl
require_cmd python3

if ! az account show &>/dev/null; then
  echo -e "${RED}ERROR: not logged in to Azure. Run 'az login' first.${RESET}" >&2
  exit 1
fi
pass "az CLI logged in"

# ── Read Terraform outputs ────────────────────────────────────────────────────
# Each output is read individually so the script falls back gracefully
# (skip / warn) when a caller is running against a remote deployment with
# only environment-variable inputs and no local state.

header "Reading Terraform outputs from: $TERRAFORM_DIR"

read_output() {
  local name="$1"
  terraform -chdir="$TERRAFORM_DIR" output -raw "$name" 2>/dev/null || true
}

if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]] && command -v terraform &>/dev/null; then
  AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-$(read_output aks_cluster_name)}"
  AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-$(read_output aks_resource_group)}"
  # The example-level output is named `namespace` (examples/small|medium|large's
  # outputs.tf), not `n8n_namespace` (that name is the *root module's* output).
  # Fall back to n8n_namespace for callers running the script straight against
  # a root module directory that re-exports the module output verbatim.
  NAMESPACE="${NAMESPACE:-$(read_output namespace)}"
  NAMESPACE="${NAMESPACE:-$(read_output n8n_namespace)}"
  N8N_URL="${N8N_URL:-$(read_output n8n_url)}"
  APPGW_PUBLIC_IP="${APPGW_PUBLIC_IP:-$(read_output appgw_public_ip)}"
  KUBECTL_CMD="$(read_output kubectl_config_command)"
  POSTGRES_FQDN="${POSTGRES_FQDN:-$(read_output postgres_fqdn)}"
  STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-$(read_output storage_account_name)}"
  BLOB_CONTAINER_NAME="${BLOB_CONTAINER_NAME:-$(read_output azure_blob_container_name)}"

  info "aks_cluster_name      = ${AKS_CLUSTER_NAME:-<not found>}"
  info "aks_resource_group    = ${AKS_RESOURCE_GROUP:-<not found>}"
  info "n8n_namespace         = ${NAMESPACE:-<not found>}"
  info "n8n_url               = ${N8N_URL:-<not found>}"
  info "appgw_public_ip       = ${APPGW_PUBLIC_IP:-<not found>}"
  info "postgres_fqdn         = ${POSTGRES_FQDN:-<not found>}"
  info "storage_account_name  = ${STORAGE_ACCOUNT_NAME:-<not found>}"
  info "blob_container_name   = ${BLOB_CONTAINER_NAME:-<not found>}"
else
  info "No terraform.tfstate in $TERRAFORM_DIR — relying on environment variables."
  KUBECTL_CMD=""
fi

NAMESPACE="${NAMESPACE:-n8n}"
N8N_API_KEY="${N8N_API_KEY:-}"
POSTGRES_FQDN="${POSTGRES_FQDN:-}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"
BLOB_CONTAINER_NAME="${BLOB_CONTAINER_NAME:-}"

# Final required-input check.
for var in AKS_CLUSTER_NAME AKS_RESOURCE_GROUP N8N_URL APPGW_PUBLIC_IP; do
  if [[ -z "${!var:-}" ]]; then
    echo -e "${RED}ERROR: $var is unset and not present in terraform output.${RESET}" >&2
    echo -e "${RED}Set it in .env, export it, or run from a directory with terraform.tfstate.${RESET}" >&2
    exit 1
  fi
done

# ── Configure kubectl ─────────────────────────────────────────────────────────
# Use a transient kubeconfig so the operator's ~/.kube/config stays clean
# when running the smoke test against multiple environments. When we have
# the `kubectl_config_command` output, use that verbatim (matches the AWS
# sibling); otherwise fall back to building the command from
# AKS_CLUSTER_NAME + AKS_RESOURCE_GROUP.

header "Configure kubectl for AKS cluster"

KUBECONFIG_TMP=$(mktemp)
trap 'rm -f "$KUBECONFIG_TMP"' EXIT
export KUBECONFIG="$KUBECONFIG_TMP"

if [[ -n "$KUBECTL_CMD" ]]; then
  info "Running: $KUBECTL_CMD --file \$KUBECONFIG"
  if ! eval "$KUBECTL_CMD --file \"$KUBECONFIG_TMP\"" &>/dev/null; then
    fail "kubectl_config_command failed"
    exit 1
  fi
else
  info "Running: az aks get-credentials --name $AKS_CLUSTER_NAME --resource-group $AKS_RESOURCE_GROUP"
  if ! az aks get-credentials \
      --name "$AKS_CLUSTER_NAME" \
      --resource-group "$AKS_RESOURCE_GROUP" \
      --overwrite-existing \
      --file "$KUBECONFIG_TMP" \
      &>/dev/null; then
    fail "az aks get-credentials failed for $AKS_CLUSTER_NAME / $AKS_RESOURCE_GROUP"
    exit 1
  fi
fi
pass "kubeconfig populated for $AKS_CLUSTER_NAME"

if ! kubectl cluster-info &>/dev/null; then
  fail "kubectl cannot reach the cluster — check your kubeconfig / credentials"
  exit 1
fi
pass "kubectl cluster connectivity"

# ── DNS-not-delegated fallback wiring ─────────────────────────────────────────
# The Azure DNS zone the example creates needs upstream NS delegation at
# the registrar before var.n8n_domain resolves publicly. The example
# writes the A-record automatically, but the operator-side delegation is
# out of band — until it's done, every HTTPS / API / webhook test in the
# script needs `curl --resolve <fqdn>:443:<APPGW_PUBLIC_IP>` to land on
# the App Gateway listener.

header "DNS resolution"

n8n_host="${N8N_URL#https://}"
n8n_host="${n8n_host#http://}"
n8n_host="${n8n_host%%/*}"

if dns_resolves "$n8n_host"; then
  pass "Public DNS resolves $n8n_host (registrar delegation in place)"
  CURL_RESOLVE_ARGS=()
else
  warn "Public DNS does not resolve $n8n_host — falling back to --resolve $n8n_host:443:$APPGW_PUBLIC_IP"
  info "Set NS records for the parent zone at the registrar to remove this fallback:"
  info "  terraform output public_dns_zone_name_servers"
  CURL_RESOLVE_ARGS=(--resolve "${n8n_host}:443:${APPGW_PUBLIC_IP}" --resolve "${n8n_host}:80:${APPGW_PUBLIC_IP}")
fi

# ── Namespace ─────────────────────────────────────────────────────────────────

header "n8n namespace"

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  fail "namespace '$NAMESPACE' does not exist"
  exit 1
fi
pass "namespace '$NAMESPACE' exists"

# ── Topology detection ─────────────────────────────────────────────────────────
# detect_topology() is defined earlier (alongside the self-test block) so it
# can be exercised offline against fixtures without duplicating the logic.

header "Topology detection"

detect_topology

# ── Pod readiness (main / worker / webhook-processor) ─────────────────────────
# check_deployment() is defined earlier for the same self-test reason.

header "Pod readiness"

check_deployment "n8n-main"              "$MAIN_MIN"    "n8n-main"
# n8n_worker_keda_pause annotates the ScaledObject; while paused the worker
# count is whatever was held (possibly 0), so the floor assertion is moot.
# WORKER_DRAINED also gates the later worker-dependent checks.
detect_worker_pause
if [[ "$WORKER_PAUSED" == "true" ]]; then
  skip "n8n-worker floor check: KEDA autoscaling is paused (n8n_worker_keda_pause = true, held count: ${WORKER_PAUSED_REPLICAS:-current})"
else
  check_deployment "n8n-worker"          "$WORKER_MIN"  "n8n-worker"
fi
check_deployment "n8n-webhook-processor" "$WEBHOOK_MIN" "n8n-webhook-processor"

# ── Application version ───────────────────────────────────────────────────────
# Confirms every pod family runs the same n8n application version — a
# half-finished rollout is exactly the state in which "works on main, fails
# on workers" surfaces, so ruling out version drift belongs before any
# functional check runs. `n8n --version` is authoritative; the image tag on
# the pod spec is printed alongside it for cross-reference.

header "Application version"

version_report=""
for component in main worker webhook-processor; do
  pod=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=${component}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$pod" && "$component" == "worker" && "$WORKER_DRAINED" == "true" ]]; then
    skip "n8n-worker application version: workers are paused at 0 replicas (n8n_worker_keda_paused_replica_count = 0)"
    continue
  elif [[ -z "$pod" ]]; then
    warn "No Ready n8n-${component} pod available to check application version"
    continue
  fi

  container="n8n-${component}"
  image=$(kubectl get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath="{.spec.containers[?(@.name=='${container}')].image}" 2>/dev/null || true)
  version=$(kubectl exec "$pod" -n "$NAMESPACE" -c "$container" \
    -- n8n --version 2>/dev/null || echo "<unreadable>")

  info "$(printf '%-20s version=%-14s image=%s' "$component" "$version" "${image:-<unreadable>}")"
  version_report="${version_report}${component}|${version}
"
done

unique_versions=$(printf '%s' "$version_report" | awk -F'|' 'NF>1 {print $2}' | sort -u | grep -c . || true)
if [[ "${unique_versions:-0}" -eq 0 ]]; then
  fail "Could not read the application version from any pod family"
elif [[ "$unique_versions" -eq 1 ]]; then
  pass "All pod families report the same n8n application version"
else
  fail "Pod families report $unique_versions different n8n application versions — rollout is not converged"
fi

# ── Leader election ───────────────────────────────────────────────────────────
# Multi-main elects a single leader pod via Redis to run DB migrations + the
# schedule trigger; followers wait for the leader's signal. Single-main runs
# no leader election at all (there is only ever one main pod), so this
# section branches on $TOPOLOGY (detected above) instead of unconditionally
# expecting N8N_MULTI_MAIN_SETUP_ENABLED=true.

header "Leader election"

main_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=main" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$main_pod" ]]; then
  warn "No Ready n8n-main pod available to check leader election"
elif [[ "$TOPOLOGY" == "single-main" ]]; then
  multi_main=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_MULTI_MAIN_SETUP_ENABLED 2>/dev/null || echo "")
  if [[ "$multi_main" != "true" ]]; then
    pass "N8N_MULTI_MAIN_SETUP_ENABLED is not 'true' on the single main pod (got: '${multi_main:-<unset>}')"
  else
    warn "N8N_MULTI_MAIN_SETUP_ENABLED=true on a single-main deployment (unexpected for n8n_main_hpa_min_replicas = 1)"
  fi
  skip "Leader-election log check (single-main runs no Redis leader election)"
else
  multi_main=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_MULTI_MAIN_SETUP_ENABLED 2>/dev/null || echo "")
  if [[ "$multi_main" == "true" ]]; then
    pass "N8N_MULTI_MAIN_SETUP_ENABLED=true on selected main pod (configuration check only)"
  else
    warn "N8N_MULTI_MAIN_SETUP_ENABLED is not 'true' (got: '${multi_main:-<unset>}')"
    info "Expected when n8n_main_hpa_min_replicas > 1"
  fi

  check_main_leader_logs
fi

# ── Task runner sidecar (workers) ─────────────────────────────────────────────
# In queue mode Code nodes execute on worker pods, so the task runner
# sidecar belongs on n8n-worker (not n8n-main / n8n-webhook-processor).
# The sidecar is opt-in via the chart — when disabled, this is a warn,
# not a fail.

header "Task runner sidecar"

worker_containers=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

if echo "$worker_containers" | grep -qiE "runner"; then
  runner_container=$(echo "$worker_containers" | tr ' ' '\n' | grep -iE "runner" | head -1)
  pass "Task runner sidecar present on n8n-worker pods: $runner_container"

  worker_pod=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=worker" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$worker_pod" ]]; then
    runner_logs=$(kubectl logs "$worker_pod" -n "$NAMESPACE" -c "$runner_container" \
      --tail=100 2>/dev/null || true)
    if echo "$runner_logs" | grep -qiE "connected|ready|broker|listening"; then
      connected_line=$(echo "$runner_logs" | grep -iE "connected|ready|broker|listening" | tail -1)
      pass "Worker runner sidecar connected to broker"
      info "$connected_line"
    else
      warn "No broker-connection line in worker runner logs (last 100 lines)"
      info "Verify: kubectl logs $worker_pod -n $NAMESPACE -c $runner_container"
    fi
  fi
else
  warn "Task runner sidecar not present on n8n-worker — task runners are likely disabled in the chart values"
  info "Set n8n_task_runners_enabled = true (or the equivalent chart override) and re-apply if you want them"
fi

# ── KEDA TriggerAuthentication present ────────────────────────────────────────
# Asserts the `kubectl_manifest.keda_trigger_authentication` resource
# from `modules/workload/keda.tf` (registry-hardening US-007 R3.2)
# actually landed the CR on the cluster. The n8n chart's worker
# `ScaledObject` resolves the auth ref by GVK + namespace + name; without
# the CR present, KEDA logs `error fetching trigger authentication` and
# the worker pool sits at the floor regardless of queue depth.

header "KEDA TriggerAuthentication"

if ! kubectl get crd triggerauthentications.keda.sh &>/dev/null; then
  fail "TriggerAuthentication CRD missing — KEDA helm release likely failed"
  info "Check: kubectl -n keda get pods (expect keda-operator + keda-metrics-apiserver Ready)"
elif ! kubectl get triggerauthentication n8n-redis-keda-auth -n "$NAMESPACE" &>/dev/null; then
  fail "TriggerAuthentication 'n8n-redis-keda-auth' missing in namespace '$NAMESPACE'"
  info "Check: kubectl -n $NAMESPACE describe scaledobject (KEDA reports the missing auth ref)"
else
  pass "TriggerAuthentication 'n8n-redis-keda-auth' present in namespace '$NAMESPACE'"
fi

# ── Autoscaler configuration ──────────────────────────────────────────────────

header "Autoscaler configuration"

# Webhook-processor: chart-rendered HPA, CPU-based.
if kubectl get hpa n8n-webhook-processor -n "$NAMESPACE" &>/dev/null; then
  hpa_min=$(kubectl get hpa n8n-webhook-processor -n "$NAMESPACE" \
    -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "?")
  hpa_max=$(kubectl get hpa n8n-webhook-processor -n "$NAMESPACE" \
    -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "?")
  hpa_current=$(kubectl get hpa n8n-webhook-processor -n "$NAMESPACE" \
    -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "?")
  hpa_target=$(kubectl get hpa n8n-webhook-processor -n "$NAMESPACE" \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "<unknown>")
  pass "Webhook-processor HPA: min=$hpa_min max=$hpa_max current=$hpa_current CPU=${hpa_target}%"
else
  warn "Webhook-processor HPA not found — expected 'kubernetes_horizontal_pod_autoscaler_v2.webhook_processor' from modules/workload/scaling.tf"
fi

# Workers: KEDA ScaledObject (queue-depth driven, the canonical worker
# autoscaler in this module). HPA fallback warning if the chart was
# overridden to use CPU-based scaling instead.
if kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null; then
  so_min=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null || echo "?")
  so_max=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null || echo "?")
  so_ready=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  pass "Worker KEDA ScaledObject: min=$so_min max=$so_max ready=$so_ready (Azure Redis queue depth)"
elif kubectl get hpa n8n-worker -n "$NAMESPACE" &>/dev/null; then
  warn "Worker autoscaler is HPA, not KEDA ScaledObject — chart override or KEDA outage?"
else
  fail "No autoscaler found for n8n-worker (expected KEDA ScaledObject from the n8n chart)"
  info "The n8n chart's worker ScaledObject is opt-in: set"
  info "  keda.enabled = true"
  info "  keda.worker.triggers[*].authenticationRef.name = n8n-redis-keda-auth"
  info "in the helm_release.n8n values block (modules/workload/n8n.tf). The"
  info "matching TriggerAuthentication CR is already installed; only the"
  info "chart-side switch is missing."
fi

# ── Redis connectivity ────────────────────────────────────────────────────────
# Confirms the worker pods see the Azure Cache for Redis FQDN via
# QUEUE_BULL_REDIS_HOST and that the BullMQ client has emitted log lines
# touching the queue subsystem (good proxy for a healthy connection).

header "Queue mode — Redis connectivity"

worker_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=worker" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$worker_pod" && "$WORKER_DRAINED" == "true" ]]; then
  skip "Worker Redis connectivity: workers are paused at 0 replicas (n8n_worker_keda_paused_replica_count = 0)"
elif [[ -z "$worker_pod" ]]; then
  fail "No Ready n8n-worker pod available to probe Redis connectivity"
else
  info "Using worker pod: $worker_pod"

  redis_host=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv QUEUE_BULL_REDIS_HOST 2>/dev/null || true)
  redis_port=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv QUEUE_BULL_REDIS_PORT 2>/dev/null || true)
  redis_tls=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv QUEUE_BULL_REDIS_TLS 2>/dev/null || true)

  if [[ -n "$redis_host" ]]; then
    pass "Worker env: QUEUE_BULL_REDIS_HOST=$redis_host port=${redis_port:-?} tls=${redis_tls:-?}"
    if [[ "$redis_host" != *.redis.azure.net && "$redis_host" != *.redis.cache.windows.net ]]; then
      warn "Redis host doesn't look like an Azure Managed Redis or Azure Cache for Redis FQDN — chart override?"
    fi
  else
    warn "Could not read QUEUE_BULL_REDIS_HOST from worker — chart-side env wiring may have drifted"
  fi

  queue_logs=$(kubectl logs "$worker_pod" -n "$NAMESPACE" -c n8n-worker --tail=200 2>/dev/null \
    | grep -iE "queue|bull|redis|worker.*started" | tail -3 || true)
  if [[ -n "$queue_logs" ]]; then
    pass "Worker logs show queue activity"
    while IFS= read -r line; do info "$line"; done <<< "$queue_logs"
  else
    warn "No queue-related log lines in worker logs (last 200) — pod may have just started"
  fi
fi

# ── PostgreSQL connectivity ───────────────────────────────────────────────────
# PostgreSQL Flexible Server sits on a delegated subnet with no public data
# plane, so this machine cannot open a direct TCP connection to it the way it
# can to the App Gateway's public IP. Verify instead from inside the
# workload: the main pod's DB_POSTGRESDB_* environment matches the Terraform
# output, and recent main pod logs show no connection or auth failures
# (n8n fails fast and loudly on migration/connection errors, so their
# absence in a Ready pod's logs is a reliable proxy for a healthy link).

header "PostgreSQL connectivity"

if [[ -z "$main_pod" ]]; then
  warn "No Ready n8n-main pod available to probe PostgreSQL connectivity"
else
  pg_host=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv DB_POSTGRESDB_HOST 2>/dev/null || true)
  pg_database=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv DB_POSTGRESDB_DATABASE 2>/dev/null || true)
  pg_ssl=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv DB_POSTGRESDB_SSL_ENABLED 2>/dev/null || true)

  if [[ -n "$pg_host" ]]; then
    pass "Main env: DB_POSTGRESDB_HOST=$pg_host database=${pg_database:-?} ssl=${pg_ssl:-?}"
    if [[ -n "${POSTGRES_FQDN:-}" && "$pg_host" != "$POSTGRES_FQDN" ]]; then
      warn "DB_POSTGRESDB_HOST ($pg_host) does not match terraform output postgres_fqdn ($POSTGRES_FQDN)"
    fi
  else
    warn "Could not read DB_POSTGRESDB_HOST from main — chart-side env wiring may have drifted"
  fi

  pg_errors=$(kubectl logs "$main_pod" -n "$NAMESPACE" -c n8n-main --tail=300 2>/dev/null \
    | grep -iE "ECONNREFUSED|password authentication failed|could not connect to server|SASL|connection terminated unexpectedly" \
    | tail -5 || true)
  if [[ -z "$pg_errors" ]]; then
    pass "No PostgreSQL connection or auth errors in main pod logs (last 300 lines)"
  else
    fail "PostgreSQL connection or auth errors found in main pod logs"
    while IFS= read -r line; do info "$line"; done <<< "$pg_errors"
  fi

  migration_log=$(kubectl logs "$main_pod" -n "$NAMESPACE" -c n8n-main --tail=300 2>/dev/null \
    | grep -iE "migrations? (finished|completed|ran successfully)" | tail -1 || true)
  if [[ -n "$migration_log" ]]; then
    pass "PostgreSQL migrations completed"
    info "$migration_log"
  else
    info "No migration-completion log line in last 300 lines — normal if the pod has been up a while"
  fi
fi

# ── Azure Blob storage ────────────────────────────────────────────────────────
# Confirms the workload identity path is wired end-to-end on the main pod:
# the container/account env matches the Terraform output, and
# N8N_DEFAULT_BINARY_DATA_MODE reflects the configured storage mode. This is
# infrastructure-level proof only — the module-verification spec's
# n8n-level write/read/download/delete acceptance criteria belong to the
# live procedure in section 17.3 (docs/data-storage.md), which needs a real
# workflow execution, not just an environment check.

header "Azure Blob storage"

if [[ -z "$main_pod" ]]; then
  warn "No Ready n8n-main pod available to probe Azure Blob configuration"
else
  binary_mode=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_DEFAULT_BINARY_DATA_MODE 2>/dev/null || true)
  blob_container=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME 2>/dev/null || true)
  blob_account=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME 2>/dev/null || true)
  blob_auto_detect=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT 2>/dev/null || true)

  info "N8N_DEFAULT_BINARY_DATA_MODE=${binary_mode:-<unset>}"

  if [[ "$binary_mode" != "azure" ]]; then
    skip "Azure Blob checks (N8N_DEFAULT_BINARY_DATA_MODE is '${binary_mode:-<unset>}', not 'azure')"
  else
    if [[ -n "$blob_container" && -n "$BLOB_CONTAINER_NAME" && "$blob_container" == "$BLOB_CONTAINER_NAME" ]]; then
      pass "N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME matches terraform output ($blob_container)"
    elif [[ -n "$blob_container" ]]; then
      warn "N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME=$blob_container does not match terraform output azure_blob_container_name (${BLOB_CONTAINER_NAME:-<unset>})"
    else
      fail "N8N_EXTERNAL_STORAGE_AZURE_CONTAINER_NAME not set on main pod despite azure binary mode"
    fi

    if [[ -n "$blob_account" ]]; then
      pass "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME=$blob_account (workload-identity auth path)"
      if [[ -n "$STORAGE_ACCOUNT_NAME" && "$blob_account" != "$STORAGE_ACCOUNT_NAME" ]]; then
        warn "Account name does not match terraform output storage_account_name ($STORAGE_ACCOUNT_NAME)"
      fi
    else
      info "N8N_EXTERNAL_STORAGE_AZURE_ACCOUNT_NAME not set — connection-string or account-key auth may be in use"
    fi

    if [[ "$blob_auto_detect" == "true" ]]; then
      pass "N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT=true (workload identity, DefaultAzureCredential)"
    fi

    blob_errors=$(kubectl logs "$main_pod" -n "$NAMESPACE" -c n8n-main --tail=300 2>/dev/null \
      | grep -iE "AuthorizationFailure|ContainerNotFound|blob.*(forbidden|denied)" | tail -5 || true)
    if [[ -z "$blob_errors" ]]; then
      pass "No Azure Blob authorization or access errors in main pod logs (last 300 lines)"
    else
      fail "Azure Blob authorization or access errors found in main pod logs"
      while IFS= read -r line; do info "$line"; done <<< "$blob_errors"
    fi
  fi
fi

# ── App Gateway public IP reachability ────────────────────────────────────────

header "App Gateway public IP reachability"

# Use `curl --connect-timeout` rather than `nc -z` because `nc`'s flag
# set differs across BSD (macOS) and GNU netcat. Any HTTP code (including
# 4xx) proves the listener is up — only `000` (connection failure) fails.
http_code=$(curl -sk --connect-timeout "$CURL_TIMEOUT" -o /dev/null \
  -w "%{http_code}" "https://${APPGW_PUBLIC_IP}/" 2>/dev/null || echo "000")
if [[ "$http_code" != "000" ]]; then
  pass "App Gateway public IP $APPGW_PUBLIC_IP reachable on TCP/443 (HTTP $http_code)"
else
  fail "App Gateway public IP $APPGW_PUBLIC_IP not reachable on TCP/443"
  info "Check: az network public-ip show -g <rg> -n <pip> --query 'ipAddress'"
fi

# ── HTTPS GET on n8n_url returns 200 ──────────────────────────────────────────
# Tries /healthz/readiness first (n8n ≥ 1.0; checks DB + license) then
# falls back to /healthz on older images. Uses CURL_RESOLVE_ARGS so the
# probe works even when public DNS hasn't propagated.

header "HTTPS GET on n8n_url"

healthz_url="${N8N_URL%/}/healthz/readiness"
healthz_status=$(curl_to_n8n -o /dev/null -w "%{http_code}" \
  --max-time "$CURL_TIMEOUT" "$healthz_url" 2>/dev/null || echo "000")

if [[ "$healthz_status" == "200" ]]; then
  pass "GET $healthz_url returned HTTP 200"
elif [[ "$healthz_status" == "404" ]]; then
  healthz_url="${N8N_URL%/}/healthz"
  healthz_status=$(curl_to_n8n -o /dev/null -w "%{http_code}" \
    --max-time "$CURL_TIMEOUT" "$healthz_url" 2>/dev/null || echo "000")
  if [[ "$healthz_status" == "200" ]]; then
    pass "GET $healthz_url returned HTTP 200 (readiness endpoint not present on this n8n image)"
  else
    fail "GET $healthz_url returned HTTP $healthz_status (expected 200)"
  fi
elif [[ "$healthz_status" == "000" ]]; then
  fail "GET $healthz_url — connection failed"
  info "If you just applied, the DNS A-record may not have propagated and the"
  info "AGW listener may still be settling — re-run the smoke test in 60 s."
else
  fail "GET $healthz_url returned HTTP $healthz_status (expected 200)"
fi

# ── HTTP → HTTPS redirect ─────────────────────────────────────────────────────
# The chart sets `appgw.ingress.kubernetes.io/ssl-redirect = "true"` on
# the n8n Ingress, which AGIC translates into an AGW redirect-config
# from port 80 to 443. Verify the redirect lives.

header "HTTP → HTTPS redirect"

http_url="${N8N_URL/https:/http:}"
if [[ "$http_url" == "$N8N_URL" ]]; then
  skip "n8n_url is not https — redirect check not applicable"
else
  redirect_status=$(curl -sk --connect-timeout "$CURL_TIMEOUT" \
    ${CURL_RESOLVE_ARGS[@]+"${CURL_RESOLVE_ARGS[@]}"} -o /dev/null -w "%{http_code}" \
    --max-time "$CURL_TIMEOUT" "$http_url" 2>/dev/null || echo "000")
  if [[ "$redirect_status" =~ ^30[1-8]$ ]]; then
    pass "HTTP → HTTPS redirect: $redirect_status"
  elif [[ "$redirect_status" == "000" ]]; then
    warn "HTTP → HTTPS redirect: connection failed (port-80 listener may not be configured)"
  else
    warn "HTTP → HTTPS redirect returned $redirect_status (expected 301/302/307/308)"
    info "Inspect: kubectl -n $NAMESPACE get ingress -o yaml | grep ssl-redirect"
  fi
fi

# ── Webhook route ownership ───────────────────────────────────────────────────
# n8n runs here with dedicated webhook-processor pods, so every one of
# local.n8n_webhook_path_prefixes (root locals.tf, module output
# n8n_webhook_path_prefixes) MUST route to the webhook-processor Service
# ahead of the main-service catch-all, or requests fall through to main and
# 404: waiting webhooks never resume, Form Trigger nodes break, MCP server
# triggers are unreachable. Checking the Ingress object directly is
# deterministic — it needs no registered workflow, and it distinguishes
# "wrong backend" from "no workflow with that path".

header "Webhook route ownership"

WEBHOOK_SVC="n8n-webhook-processor"
MAIN_SVC="n8n-main"

# terraform output -json — n8n_webhook_path_prefixes is a list, not a scalar.
# Falls back to the module's hard-coded default prefix set (locals.tf,
# n8n_webhook_path_prefixes) when the output can't be read, so the check
# still runs something meaningful against a remote deployment with no local
# state.
webhook_prefixes_json=$(terraform -chdir="$TERRAFORM_DIR" output -json n8n_webhook_path_prefixes 2>/dev/null || echo "")
WEBHOOK_PREFIXES=()
if [[ -n "$webhook_prefixes_json" ]]; then
  while IFS= read -r prefix; do
    WEBHOOK_PREFIXES+=("$prefix")
  done < <(echo "$webhook_prefixes_json" \
    | python3 -c 'import sys, json; [print(p) for p in json.load(sys.stdin)]' 2>/dev/null)
fi
if [[ ${#WEBHOOK_PREFIXES[@]} -eq 0 ]]; then
  WEBHOOK_PREFIXES=(/webhook /webhook-waiting /form /form-waiting /mcp)
  info "n8n_webhook_path_prefixes output not found — using the module's default prefix set"
fi

ingress_paths=$(kubectl get ingress n8n-ingress -n "$NAMESPACE" \
  -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path}{"="}{.backend.service.name}{"\n"}{end}' \
  2>/dev/null || true)

if [[ -z "$ingress_paths" ]]; then
  skip "Webhook route ownership (no 'n8n-ingress' in namespace '$NAMESPACE')"
  info "Expected when create_ingress = false: you own the Ingress routes."
  info "Verify your own route all of: ${WEBHOOK_PREFIXES[*]} → $WEBHOOK_SVC"
else
  for prefix in "${WEBHOOK_PREFIXES[@]}"; do
    backend=$(echo "$ingress_paths" | grep -E "^${prefix}/?=" | head -1 | cut -d= -f2)

    if [[ -z "$backend" ]]; then
      fail "$prefix is not routed, so requests fall through to the main pods and 404"
    elif [[ "$backend" == "$WEBHOOK_SVC" ]]; then
      pass "$prefix → $backend"
    else
      fail "$prefix → $backend (expected $WEBHOOK_SVC)"
    fi
  done

  root_backend=$(echo "$ingress_paths" | grep -E '^/=' | head -1 | cut -d= -f2)
  if [[ "$root_backend" == "$MAIN_SVC" ]]; then
    pass "/ → $root_backend"
  elif [[ -n "$root_backend" ]]; then
    fail "/ → $root_backend (expected $MAIN_SVC)"
  else
    warn "No catch-all '/' rule on the Ingress, so the editor UI may be unreachable"
  fi
fi

header "API connectivity"

if [[ -z "$N8N_API_KEY" ]]; then
  skip "API connectivity test (set N8N_API_KEY to enable)"
else
  api_status=$(curl_to_n8n -o /dev/null -w "%{http_code}" \
    --max-time "$CURL_TIMEOUT" \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "${N8N_URL%/}/api/v1/workflows?limit=1" 2>/dev/null || echo "000")

  case "$api_status" in
    200) pass "GET /api/v1/workflows responded HTTP $api_status" ;;
    401) fail "GET /api/v1/workflows returned 401 Unauthorized — check N8N_API_KEY" ;;
    000) fail "GET /api/v1/workflows — connection failed" ;;
    *)   fail "GET /api/v1/workflows returned HTTP $api_status" ;;
  esac
fi

# ── Workflow execution (webhook → set, end-to-end) ────────────────────────────
# Mirrors the AWS sibling's multi-main "lightweight queue-mode test" —
# we don't need to exercise the task runner here (the runner-sidecar
# check above already covers it), so we use a Set node instead of Code.
# Proves: webhook-processor receives the call, queues it through Redis,
# a worker picks it up, the result lands in /api/v1/executions.

header "Workflow execution via queue"

if [[ -z "$N8N_API_KEY" ]]; then
  skip "Workflow execution test (set N8N_API_KEY to enable)"
elif [[ "$WORKER_DRAINED" == "true" ]]; then
  # No worker would consume the job: it would wait in Redis until autoscaling
  # resumes and then run against the already-deleted test workflow.
  skip "Workflow execution test: workers are paused at 0 replicas, so queued jobs wait in Redis by design (n8n_worker_keda_paused_replica_count = 0)"
else
  webhook_path="smoke-test-$$"

  workflow_payload="{
    \"name\": \"__smoke-test__\",
    \"nodes\": [
      {
        \"id\": \"a1b2c3d4-0001-0001-0001-000000000001\",
        \"name\": \"Webhook\",
        \"type\": \"n8n-nodes-base.webhook\",
        \"typeVersion\": 1,
        \"position\": [250, 300],
        \"webhookId\": \"${webhook_path}\",
        \"parameters\": {
          \"httpMethod\": \"POST\",
          \"path\": \"${webhook_path}\",
          \"responseMode\": \"onReceived\"
        }
      },
      {
        \"id\": \"a1b2c3d4-0002-0002-0002-000000000002\",
        \"name\": \"Set\",
        \"type\": \"n8n-nodes-base.set\",
        \"typeVersion\": 3.4,
        \"position\": [450, 300],
        \"parameters\": {
          \"assignments\": {
            \"assignments\": [
              { \"id\": \"1\", \"name\": \"smoke_test\", \"value\": \"passed\", \"type\": \"string\" }
            ]
          }
        }
      }
    ],
    \"connections\": {
      \"Webhook\": {
        \"main\": [[{ \"node\": \"Set\", \"type\": \"main\", \"index\": 0 }]]
      }
    },
    \"settings\": {}
  }"

  create_response=$(curl_to_n8n -w "\n%{http_code}" \
    --max-time 15 \
    -X POST \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$workflow_payload" \
    "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

  create_status=$(echo "$create_response" | tail -1)
  create_body=$(echo "$create_response" | sed '$d')

  if [[ "$create_status" != "200" ]]; then
    fail "Failed to create test workflow (HTTP $create_status)"
    info "Response: $create_body"
  else
    workflow_id=$(echo "$create_body" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
    pass "Test workflow created (id: $workflow_id)"

    activate_status=$(curl_to_n8n -o /dev/null -w "%{http_code}" \
      --max-time "$CURL_TIMEOUT" \
      -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}/activate" 2>/dev/null || echo "000")

    if [[ "$activate_status" != "200" ]]; then
      fail "Failed to activate test workflow (HTTP $activate_status)"
    else
      pass "Test workflow activated"
      info "Waiting 5 s for the webhook-processor to register the new webhook…"
      sleep 5

      info "Triggering execution via webhook (will be queued to a worker)"
      trigger_response=$(curl_to_n8n -w "\n%{http_code}" \
        --max-time 15 \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"smoke_test": true}' \
        "${N8N_URL%/}/webhook/${webhook_path}" 2>/dev/null || echo -e "\n000")
      trigger_status=$(echo "$trigger_response" | tail -1)
      trigger_body=$(echo "$trigger_response" | sed '$d')

      if [[ "$trigger_status" =~ ^2 ]]; then
        pass "Webhook triggered (HTTP $trigger_status)"

        info "Waiting for execution to complete…"
        exec_state="unknown"
        for i in $(seq 1 15); do
          sleep 2
          exec_state=$(curl_to_n8n \
            --max-time "$CURL_TIMEOUT" \
            -H "X-N8N-API-KEY: $N8N_API_KEY" \
            "${N8N_URL%/}/api/v1/executions?workflowId=${workflow_id}&limit=1" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); execs=d.get('data',[]); print(execs[0]['status'] if execs else 'pending')" 2>/dev/null \
            || echo "unknown")

          if [[ "$exec_state" == "success" ]]; then
            pass "Execution completed successfully — queue mode is working end-to-end"
            break
          elif [[ "$exec_state" == "error" || "$exec_state" == "crashed" ]]; then
            fail "Execution ended with status: $exec_state"
            info "Worker logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=worker --tail=80"
            break
          elif [[ "$i" -eq 15 ]]; then
            warn "Execution still in state '$exec_state' after 30 s"
            info "Diagnose: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=worker --tail=80"
          fi
        done
      else
        fail "Webhook trigger failed (HTTP $trigger_status)"
        info "Webhook URL: ${N8N_URL%/}/webhook/${webhook_path}"
        [[ -n "$trigger_body" ]] && info "Response: $trigger_body"
      fi
    fi

    # Cleanup runs even on failure.
    curl_to_n8n -o /dev/null --max-time "$CURL_TIMEOUT" -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}/deactivate" 2>/dev/null || true
    curl_to_n8n -o /dev/null --max-time "$CURL_TIMEOUT" -X DELETE \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}" 2>/dev/null || true
    info "Test workflow deleted"
  fi
fi

# ── n8n license validity ──────────────────────────────────────────────────────

header "n8n license validity"

if [[ -z "$main_pod" ]]; then
  fail "no Ready n8n-main pod available to check license"
else
  info "Probing license via pod: $main_pod"

  license_output=""
  license_rc=0
  license_output=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- n8n license:info 2>&1) || license_rc=$?

  # Accept both legacy (`Active main plan` / `Active features`, n8n < 1.95)
  # and modern (`isValid: true`, `planName: Enterprise`, n8n 2.x) formats.
  if [[ "$license_rc" -eq 0 ]] \
      && echo "$license_output" | grep -qiE "active main plan|active features|isValid:[[:space:]]*true|planName\"?:[[:space:]]*\"?(Enterprise|Pro|Community-registered)"; then
    plan_line=$(echo "$license_output" | grep -iE "active main plan|isValid:|planName" | head -2 \
      || echo "$license_output" | head -3)
    pass "n8n license valid"
    while IFS= read -r line; do
      [[ -n "$line" ]] && info "$line"
    done <<< "$plan_line"
  else
    license_log=$(kubectl logs "$main_pod" -n "$NAMESPACE" -c n8n-main \
      --tail=500 2>/dev/null \
      | grep -iE "license activated|license loaded|license is valid|license renewed" \
      | tail -3 || true)
    if [[ -n "$license_log" ]]; then
      pass "n8n license valid (verified via main pod logs)"
      while IFS= read -r line; do info "$line"; done <<< "$license_log"
    else
      fail "n8n license check failed"
      info "n8n license:info exit code: $license_rc"
      [[ -n "$license_output" ]] && info "Output: $(echo "$license_output" | head -3)"
      info "Verify manually: kubectl exec -n $NAMESPACE $main_pod -c n8n-main -- n8n license:info"
      info "Common causes: invalid var.n8n_license_key, license server unreachable from VNet"
    fi
  fi
fi

# ── Worker scaling test (opt-in) ──────────────────────────────────────────────
# Creates a temporary CPU-burning workflow, queues LOAD_REQUESTS
# concurrent webhook calls, and verifies that KEDA scales `n8n-worker`
# up via Azure Redis queue depth. Why not /healthz? Those requests never
# touch worker pods — they hit the main pods' HTTP listener. Workers
# only get CPU when executing workflows.

header "Worker scaling test"

if [[ "$LOAD_TEST" != "true" ]]; then
  skip "Load scaling test (set LOAD_TEST=true to enable)"
elif [[ -z "$N8N_API_KEY" ]]; then
  skip "Load scaling test (requires N8N_API_KEY)"
elif [[ "$WORKER_PAUSED" == "true" ]]; then
  skip "Load scaling test: KEDA worker autoscaling is paused (n8n_worker_keda_pause = true), so it cannot scale"
else
  SCALER_MODE=""
  if kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null; then
    info "Worker autoscaler: KEDA ScaledObject (queue-depth driven against Azure Redis)"
    SCALER_MODE="keda"
  elif kubectl get hpa n8n-worker -n "$NAMESPACE" &>/dev/null; then
    worker_hpa_targets=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
      --no-headers 2>/dev/null | awk '{print $3}' || echo "<unknown>")
    if [[ "$worker_hpa_targets" == *"<unknown>"* ]]; then
      warn "Worker HPA CPU metrics are <unknown> — metrics-server is not ready"
      info "Verify: kubectl top pods -n $NAMESPACE — wait ~2 min for metrics-server to populate"
      info "Skipping load test — it cannot demonstrate scaling in this state."
    else
      info "Worker autoscaler: HPA (CPU-based, fallback)"
      SCALER_MODE="hpa"
    fi
  else
    skip "Load scaling test — no KEDA ScaledObject or HPA found for n8n-worker"
  fi

  if [[ -n "$SCALER_MODE" ]]; then
    load_webhook_path="smoke-load-$$"
    load_duration_ms=$((LOAD_JOB_DURATION_SECS * 1000))
    load_js="const end = Date.now() + ${load_duration_ms}; let x = 0; while (Date.now() < end) { for (let i = 0; i < 100000; i++) x += Math.sqrt(i); } return [{json: {done: true, elapsed: Date.now() - (end - ${load_duration_ms})}}];"

    load_workflow_payload=$(cat <<EOF
{
  "name": "__smoke-load-test__",
  "nodes": [
    {
      "id": "a1b2c3d4-0011-0011-0011-000000000011",
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [250, 300],
      "webhookId": "${load_webhook_path}",
      "parameters": {
        "httpMethod": "POST",
        "path": "${load_webhook_path}",
        "responseMode": "onReceived"
      }
    },
    {
      "id": "a1b2c3d4-0012-0012-0012-000000000012",
      "name": "CPU Burn",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [450, 300],
      "parameters": {
        "jsCode": "${load_js}"
      }
    }
  ],
  "connections": {
    "Webhook": {
      "main": [[{"node": "CPU Burn", "type": "main", "index": 0}]]
    }
  },
  "settings": {}
}
EOF
    )

    load_workflow_id=""

    load_create_response=$(curl_to_n8n -w "\n%{http_code}" \
      --max-time 15 \
      -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$load_workflow_payload" \
      "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

    load_create_status=$(echo "$load_create_response" | tail -1)
    load_create_body=$(echo "$load_create_response" | sed '$d')

    if [[ "$load_create_status" != "200" ]]; then
      warn "Could not create load test workflow (HTTP $load_create_status) — skipping scaling test"
      info "Response: $load_create_body"
    else
      load_workflow_id=$(echo "$load_create_body" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
      info "Load test workflow created (id: $load_workflow_id, CPU burn: ${LOAD_JOB_DURATION_SECS} s/job)"

      load_activate_status=$(curl_to_n8n -o /dev/null -w "%{http_code}" \
        --max-time "$CURL_TIMEOUT" \
        -X POST \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}/activate" 2>/dev/null || echo "000")

      if [[ "$load_activate_status" != "200" ]]; then
        warn "Could not activate load test workflow (HTTP $load_activate_status) — skipping scaling test"
      else
        if [[ "$SCALER_MODE" == "hpa" ]]; then
          worker_before=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
            -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
        else
          worker_before=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        fi
        worker_before="${worker_before:-0}"
        info "Baseline — worker: $worker_before replica(s)"

        load_seed=$LOAD_SEED_JOBS
        [[ $load_seed -gt $LOAD_REQUESTS ]] && load_seed=$LOAD_REQUESTS
        load_remaining=$((LOAD_REQUESTS - load_seed))

        if [[ "$SCALER_MODE" == "keda" ]]; then
          info "Phase 1: queuing $load_seed seed jobs to build queue depth (KEDA trigger)…"
        else
          info "Phase 1: queuing $load_seed seed jobs — each burns ~${LOAD_JOB_DURATION_SECS} s CPU (HPA trigger)…"
        fi

        for i in $(seq 1 "$load_seed"); do
          curl_to_n8n -o /dev/null --max-time "$CURL_TIMEOUT" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"job\": $i}" \
            "${N8N_URL%/}/webhook/${load_webhook_path}" &
          if (( i % LOAD_CONCURRENCY == 0 )); then wait || true; fi
        done
        wait || true
        info "$load_seed seed jobs queued. Polling for scale-up (max ${SCALE_WAIT_SECS} s)…"

        worker_scaled=false
        worker_after="$worker_before"
        elapsed=0
        poll_interval=15
        while [[ $elapsed -lt $SCALE_WAIT_SECS ]]; do
          sleep $poll_interval
          elapsed=$((elapsed + poll_interval))
          if [[ "$SCALER_MODE" == "hpa" ]]; then
            worker_now=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
              -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
          else
            worker_now=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
              -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
          fi
          worker_now="${worker_now:-0}"
          if [[ "$worker_now" -gt "$worker_before" ]]; then
            worker_scaled=true
            worker_after="$worker_now"
            break
          fi
          info "  ${elapsed} s / ${SCALE_WAIT_SECS} s — worker replicas: ${worker_now} (waiting for > $worker_before)"
        done

        if [[ "$worker_scaled" == "true" ]]; then
          pass "Worker pods scaled: $worker_before → $worker_after (detected after ${elapsed} s)"

          if [[ $load_remaining -gt 0 ]]; then
            info "Phase 2: queuing $load_remaining remaining jobs across $worker_after worker(s)…"
            info "Watch new workers pick up jobs: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=worker -w"
            for i in $(seq $((load_seed + 1)) "$LOAD_REQUESTS"); do
              curl_to_n8n -o /dev/null --max-time "$CURL_TIMEOUT" \
                -X POST \
                -H "Content-Type: application/json" \
                -d "{\"job\": $i}" \
                "${N8N_URL%/}/webhook/${load_webhook_path}" &
              if (( (i - load_seed) % LOAD_CONCURRENCY == 0 )); then wait || true; fi
            done
            wait || true
            info "All $LOAD_REQUESTS jobs queued total ($load_seed seed + $load_remaining follow-on)"
          fi
        else
          warn "Worker pods did not scale ($worker_before → $worker_after) within ${SCALE_WAIT_SECS} s"
          if [[ "$SCALER_MODE" == "keda" ]]; then
            info "Diagnose: kubectl describe scaledobject n8n-worker -n $NAMESPACE"
            info "Inspect KEDA logs: kubectl logs -n keda -l app.kubernetes.io/name=keda-operator --tail=200"
          else
            info "Diagnose: kubectl describe hpa n8n-worker -n $NAMESPACE"
          fi
          info "Try: LOAD_REQUESTS=200 LOAD_JOB_DURATION_SECS=30 LOAD_TEST=true ./smoke-test.sh"
        fi

        if [[ "$SCALER_MODE" == "hpa" ]]; then
          info "Current HPA state:"
          kubectl get hpa -n "$NAMESPACE" 2>/dev/null | while IFS= read -r line; do info "$line"; done
        else
          info "Current KEDA ScaledObject state:"
          kubectl get scaledobject -n "$NAMESPACE" 2>/dev/null | while IFS= read -r line; do info "$line"; done
        fi
      fi

      if [[ -n "$load_workflow_id" ]]; then
        curl_to_n8n -o /dev/null --max-time "$CURL_TIMEOUT" -X POST \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}/deactivate" 2>/dev/null || true
        curl_to_n8n -o /dev/null --max-time "$CURL_TIMEOUT" -X DELETE \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}" 2>/dev/null || true
        info "Load test workflow deleted"
      fi
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}══════════════════════════════════════${RESET}"
echo -e "${BOLD}  Smoke Test Summary${RESET}"
echo -e "${BOLD}══════════════════════════════════════${RESET}"
echo -e "  ${GREEN}Passed:${RESET}   $PASS"
echo -e "  ${RED}Failed:${RESET}   $FAIL"
echo -e "  ${YELLOW}Warnings:${RESET} $WARN"
echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}${BOLD}RESULT: FAIL — $FAIL check(s) did not pass.${RESET}"
  exit 1
fi

echo -e "${GREEN}${BOLD}RESULT: PASS${RESET}"
exit 0
