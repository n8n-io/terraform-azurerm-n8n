#!/usr/bin/env bash
# test-version-drift-workflow.sh: offline test of .github/workflows/version-drift.yml's
# own shell steps. Each step's `run:` body is read straight out of the
# workflow and executed the way `shell: bash` runs it (bash -eo pipefail),
# against a stub check-version-drift.sh and a fake `gh` that answers from a
# JSON fixture of issues and logs every write. No network, no GitHub.
#
# Usage: tests/scripts/test-version-drift-workflow.sh
# Requires: bash, awk, jq.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"
WORKFLOW="$REPO/.github/workflows/version-drift.yml"

command -v jq >/dev/null || { echo "Required tool missing: jq" >&2; exit 1; }

failures=0
cases=0

check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    echo "FAIL: $1 ($2)" >&2
    failures=$((failures + 1))
  fi
}

# step_field <step name> <run|if>: the step's `if:` value or its `run: |` body
# with the block indentation removed. Assumes this workflow's layout: steps
# at six spaces, keys at eight, block lines at ten.
step_field() {
  awk -v name="$1" -v field="$2" '
    /^      - / { in_step = ($0 == "      - name: " name); in_run = 0; if (in_step) next }
    in_step && field == "if" && /^        if: / { sub(/^        if: /, ""); print; exit }
    in_step && field == "run" && /^        run: \|$/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^          /) print substr($0, 11)
      else if ($0 ~ /^[[:space:]]*$/) print ""
      else exit
    }
  ' "$WORKFLOW"
}

RUN_STEP="run tests/scripts/check-version-drift.sh"
SYNC_STEP="sync tracking issue"
FAIL_STEP="fail on lookup errors"

for step in "$RUN_STEP" "$SYNC_STEP" "$FAIL_STEP"; do
  # shellcheck disable=SC2034 # read by the eval in check()
  body="$(step_field "$step" run)"
  check "step '$step' has a run body" '[[ -n "$body" ]]'
  # Expressions are expanded by GitHub, not bash; keep them in env: blocks.
  check "step '$step' run body has no \${{ }} expressions" '[[ "$body" != *"\${{"* ]]'
done
check "the sync step runs after a failed lookup" '[[ "$(step_field "$SYNC_STEP" if)" == "always()" ]]'
check "the fail step runs after a failed lookup" '[[ "$(step_field "$FAIL_STEP" if)" == "always()" ]]'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake gh: `issue list` filters the fixture by --state and --label (search
# is ignored, so it returns a superset, as GitHub's fuzzy search can) and
# applies --jq; `issue view` prints a body; every other call is a write and
# is logged with any --body-file contents.
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
state=open label="" jqf="" body_file="" num=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --state) state="${args[i + 1]}" ;;
    --label) label="${args[i + 1]}" ;;
    --jq) jqf="${args[i + 1]}" ;;
    --body-file) body_file="${args[i + 1]}" ;;
  esac
done
apply_jq() { if [[ -n "$jqf" ]]; then jq -r "$jqf"; else cat; fi; }
case "$1 $2" in
  "issue list")
    jq --arg s "$state" --arg l "$label" '
      map(select(($s == "all" or (.state | ascii_downcase) == $s)
        and ($l == "" or (.labels | index($l)))))
      | sort_by(-.number)
      | map(. + {labels: (.labels | map({name: .}))})' "$GH_FIXTURE" | apply_jq
    ;;
  "issue view")
    num="$3"
    jq --argjson n "$num" 'map(select(.number == $n)) | .[0] | {body}' "$GH_FIXTURE" | apply_jq
    ;;
  *)
    echo "WRITE: $*" >>"$GH_LOG"
    [[ -n "$body_file" ]] && sed 's/^/  | /' "$body_file" >>"$GH_LOG"
    ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"

# run_step <workdir> <step name> [VAR=value...]: run a step body; prints its exit code.
run_step() {
  local dir="$1" step="$2" rc=0
  shift 2
  step_field "$step" run >"$dir/.step.sh"
  (
    cd "$dir" || exit 1
    env PATH="$TMP/bin:$PATH" GITHUB_OUTPUT="$dir/.output" GITHUB_STEP_SUMMARY="$dir/.summary" \
      GH_LOG="$dir/.gh.log" RUN_URL="https://example.invalid/run" "$@" \
      bash --noprofile --norc -eo pipefail .step.sh >"$dir/.stdout" 2>&1
  ) || rc=$?
  echo "$rc"
}

# new_workdir <name> <stub exit code> <stub output>: a checkout-like directory
# whose check-version-drift.sh prints <stub output> and exits <code>.
new_workdir() {
  local dir="$TMP/$1"
  mkdir -p "$dir/tests/scripts"
  cp "$REPO"/tests/scripts/*.sh "$dir/tests/scripts/"
  printf '#!/usr/bin/env bash\ncat <<'"'"'OUT'"'"'\n%s\nOUT\nexit %s\n' "$3" "$2" >"$dir/tests/scripts/check-version-drift.sh"
  chmod +x "$dir/tests/scripts/check-version-drift.sh"
  : >"$dir/.output" && : >"$dir/.summary" && : >"$dir/.gh.log"
  echo '[]' >"$dir/.issues.json"
  echo "$dir"
}

# writes <dir>: how many writes the fake gh logged.
writes() { grep -c '^WRITE:' "$1/.gh.log"; }
# wrote <text>: some logged write in $w contains <text> (fixed string).
wrote() { grep -qF "WRITE: $1" "$w/.gh.log"; }

TITLE="Version drift report (automated)"
ERROR_REPORT='== Helm charts ==
DRIFT: n8n chart (n8n_chart_version) [variables.tf] pinned at 1.14.0, latest is 1.15.0
ERROR: KEDA chart: kedacore chart repository lookup failed

check-version-drift.sh: 1 pin(s) behind upstream, 1 lookup(s) failed'
CLEAN_REPORT='OK:    tflint (TFLINT_VERSION) pinned at 0.64.0 (latest)

check-version-drift.sh: 0 pin(s) behind upstream, 0 lookup(s) failed'

# ── A failed lookup (exit 2) is still reported and synced ─────────────────
w="$(new_workdir errors 2 "$ERROR_REPORT")"
rc="$(run_step "$w" "$RUN_STEP")"
check "exit 2: the run step itself succeeds" '[[ "$rc" == 0 ]]'
check "exit 2: status=2 is recorded" 'grep -qx "status=2" "$w/.output"'
check "exit 2: the report keeps the ERROR line" 'grep -q "^ERROR: KEDA chart" "$w/report.md"'
check "exit 2: the report keeps the summary line" 'grep -q "^check-version-drift.sh: 1 pin(s) behind upstream, 1 lookup(s) failed$" "$w/report.md"'
check "exit 2: the code fence is closed" '[[ "$(tail -n 1 "$w/report.md")" == "\`\`\`" ]]'
check "exit 2: the step summary has the report" 'grep -q "^ERROR: KEDA chart" "$w/.summary"'
echo "[{\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[],\"body\":\"old\"}]" >"$w/.issues.json"
rc="$(run_step "$w" "$SYNC_STEP" GH_FIXTURE="$w/.issues.json")"
check "exit 2: the sync step succeeds" '[[ "$rc" == 0 ]]'
check "existing tracker: exactly one write" '[[ "$(writes "$w")" == 1 ]]'
check "existing tracker: it is the body edit of issue 57" 'wrote "issue edit 57 --body-file report.md"'
check "existing tracker: no duplicate issue is created" '! wrote "issue create"'
check "exit 2: the ERROR line reaches the tracking issue" 'grep -q "^  | ERROR: KEDA chart" "$w/.gh.log"'
rc="$(run_step "$w" "$FAIL_STEP" STATUS=2)"
check "exit 2: the job fails after the sync" '[[ "$rc" != 0 ]]'

# ── No tracker yet: one is created ────────────────────────────────────────
w="$(new_workdir create 2 "$ERROR_REPORT")"
run_step "$w" "$RUN_STEP" >/dev/null
rc="$(run_step "$w" "$SYNC_STEP" GH_FIXTURE="$w/.issues.json")"
check "no tracker: the sync step succeeds" '[[ "$rc" == 0 ]]'
check "no tracker: exactly one write" '[[ "$(writes "$w")" == 1 ]]'
check "no tracker: it creates the tracker" 'wrote "issue create --title $TITLE --body-file report.md"'
check "no tracker: no existing issue is edited" '! wrote "issue edit"'
check "no tracker: the new issue carries the ERROR line" 'grep -q "^  | ERROR: KEDA chart" "$w/.gh.log"'

# ── A clean run passes ────────────────────────────────────────────────────
w="$(new_workdir clean 0 "$CLEAN_REPORT")"
rc="$(run_step "$w" "$RUN_STEP")"
check "exit 0: the run step succeeds" '[[ "$rc" == 0 ]]'
check "exit 0: status=0 is recorded" 'grep -qx "status=0" "$w/.output"'
rc="$(run_step "$w" "$FAIL_STEP" STATUS=0)"
check "exit 0: the fail step passes" '[[ "$rc" == 0 ]]'
rc="$(run_step "$w" "$FAIL_STEP" STATUS=)"
check "the fail step fails when the run step never recorded a status" '[[ "$rc" != 0 ]]'

# ── No report at all leaves the issue alone ───────────────────────────────
w="$(new_workdir noreport 0 "$CLEAN_REPORT")"
rc="$(run_step "$w" "$SYNC_STEP" GH_FIXTURE="$w/.issues.json")"
check "no report.md: the sync step fails" '[[ "$rc" != 0 ]]'
check "no report.md: nothing is written to GitHub" '[[ ! -s "$w/.gh.log" ]]'

# ── Tracking-issue lifecycle ──────────────────────────────────────────────
TITLE="Version drift report (automated)"
TRUNCATED_REPORT='== Terraform providers (registry.terraform.io) ==
OK:    random provider [root] pinned at "~> 3.0" (accepts latest 3.9.1)'

# sync_case <name> <stub exit> <stub output> <issues JSON>: runs the report
# step, then the sync step; leaves $w and $rc set for the checks.
sync_case() {
  w="$(new_workdir "$1" "$2" "$3")"
  printf '%s\n' "$4" >"$w/.issues.json"
  run_step "$w" "$RUN_STEP" >/dev/null
  rc="$(run_step "$w" "$SYNC_STEP" GH_FIXTURE="$w/.issues.json")"
}
# wrote <text>: some logged write contains <text> (fixed string).
wrote() { grep -qF "WRITE: $1" "$w/.gh.log"; }
# touched <number>: some logged write targets that issue.
touched() { grep -qE "^WRITE: issue [a-z]+ $1( |$)" "$w/.gh.log"; }

sync_case other-labelled 2 "$ERROR_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[\"version-drift\"],\"body\":\"old\"},
  {\"number\":90,\"title\":\"Bump the KEDA chart to 2.21.0\",\"state\":\"OPEN\",\"labels\":[\"version-drift\"],\"body\":\"human\"}]"
check "another open labelled issue: the tracker is updated" 'wrote "issue edit 57 --body-file"'
check "another open labelled issue: it is left alone" '! touched 90'

sync_case other-closed 2 "$ERROR_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"CLOSED\",\"labels\":[\"version-drift\"],\"body\":\"old\"},
  {\"number\":91,\"title\":\"Bump the helm provider to 3.x\",\"state\":\"CLOSED\",\"labels\":[\"version-drift\"],\"body\":\"human\"}]"
check "another closed labelled issue: the tracker is reopened" 'wrote "issue reopen 57"'
check "another closed labelled issue: it is left alone" '! touched 91'

sync_case fuzzy-title 2 "$ERROR_REPORT" "[
  {\"number\":92,\"title\":\"Re: $TITLE is noisy\",\"state\":\"OPEN\",\"labels\":[],\"body\":\"human\"}]"
check "a title search hit that is not the exact title is not adopted" '! touched 92'
check "a title search hit that is not the exact title: a tracker is created" 'wrote "issue create --title $TITLE --label version-drift"'

sync_case adopt 2 "$ERROR_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[],\"body\":\"old\"}]"
check "an unlabelled tracker is adopted and labelled" 'wrote "issue edit 57 --add-label version-drift"'

sync_case truncated-unlabelled 0 "$TRUNCATED_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[],\"body\":\"old\"}]"
check "incomplete report: the sync step fails" '[[ "$rc" != 0 ]]'
check "incomplete report: nothing is written, not even the label" '[[ ! -s "$w/.gh.log" ]]'

sync_case truncated-labelled 0 "$TRUNCATED_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[\"version-drift\"],\"body\":\"old\"}]"
check "incomplete report, labelled tracker: nothing is written" '[[ ! -s "$w/.gh.log" ]]'

sync_case clean-closed 0 "$CLEAN_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"CLOSED\",\"labels\":[\"version-drift\"],\"body\":\"old\"}]"
check "clean report, closed tracker: the step succeeds" '[[ "$rc" == 0 ]]'
check "clean report, closed tracker: nothing is written" '[[ ! -s "$w/.gh.log" ]]'

sync_case clean-open 0 "$CLEAN_REPORT" "[
  {\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[\"version-drift\"],\"body\":\"old\"}]"
check "clean report, open tracker: it is closed" 'wrote "issue close 57"'

# An action word the sync step does not know must not get as far as a write.
w="$(new_workdir unexpected 0 "$CLEAN_REPORT")"
printf '#!/usr/bin/env bash\necho frobnicate\n' >"$w/tests/scripts/drift-issue-sync.sh"
echo "[{\"number\":57,\"title\":\"$TITLE\",\"state\":\"OPEN\",\"labels\":[],\"body\":\"old\"}]" >"$w/.issues.json"
run_step "$w" "$RUN_STEP" >/dev/null
rc="$(run_step "$w" "$SYNC_STEP" GH_FIXTURE="$w/.issues.json")"
check "unexpected action: the sync step fails" '[[ "$rc" != 0 ]]'
check "unexpected action: nothing is written" '[[ ! -s "$w/.gh.log" ]]'

echo "test-version-drift-workflow.sh: ${cases} case(s), ${failures} failure(s)"
((failures == 0))
