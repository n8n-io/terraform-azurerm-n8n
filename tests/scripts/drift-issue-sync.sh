#!/usr/bin/env bash
# drift-issue-sync.sh: the offline decision half of .github/workflows/version-drift.yml's
# tracking-issue sync. Given the new check-version-drift.sh report, the
# tracking issue's current body, and its state, decide what the workflow
# does; the workflow itself makes the GitHub API calls. Split out so the
# decision is testable without GitHub (DRIFT_SYNC_SELF_TEST=1).
#
# A "finding" is a line starting with DRIFT: or ERROR:. OK: and INFO: lines,
# the generated-at header, ordering, and CRLF line endings never count as a
# change, so an unchanged set of findings replaces the body silently while a
# changed set also posts a comment (an issue body edit notifies nobody).
#
# Usage:
#   drift-issue-sync.sh action <report> <previous-body> <open|closed|none>
#     Prints one word:
#       abort    the report's last line (ignoring blank lines and code
#                fences) is not a valid summary, or the summary's counts
#                disagree with its DRIFT:/ERROR: lines (a crashed or
#                reformatted run); leave the issue alone rather than
#                closing it as clean
#       create   findings and no tracking issue yet
#       update   replace the body only: open issue with the same findings,
#                or closed issue whose findings did not come back changed
#                (a manual close with unchanged findings stays closed)
#       comment  open issue, findings changed: replace the body and comment
#       close    open issue, no findings: replace the body and close
#       reopen   closed issue, findings changed and some remain: replace
#                the body, reopen, and comment
#       noop     no findings, and no issue or a closed one without findings
#   drift-issue-sync.sh changes <previous-body> <report>
#     Prints a Markdown comment body listing new and resolved findings.
set -uo pipefail

SUMMARY_RE='^check-version-drift\.sh: ([0-9]+) pin\(s\) behind upstream, ([0-9]+) lookup\(s\) failed$'

# findings <file>: sorted, unique DRIFT:/ERROR: lines; nothing for a missing file.
findings() {
  [[ -f "$1" ]] || return 0
  tr -d '\r' <"$1" | { grep -E '^(DRIFT|ERROR):' || true; } | LC_ALL=C sort -u
}

# report_complete <file>: the last line, ignoring blank lines and code fences,
# is the summary, and its counts match the DRIFT:/ERROR: lines. Output after
# the summary means the run did not end where the script ends.
report_complete() {
  local line drift errors
  [[ -f "$1" ]] || return 1
  line="$(tr -d '\r' <"$1" | sed -e '/^[[:space:]]*$/d' -e '/^```/d' | tail -n 1)"
  [[ "$line" =~ $SUMMARY_RE ]] || return 1
  drift="$(tr -d '\r' <"$1" | grep -cE '^DRIFT:')"
  errors="$(tr -d '\r' <"$1" | grep -cE '^ERROR:')"
  [[ "${BASH_REMATCH[1]}" == "$drift" && "${BASH_REMATCH[2]}" == "$errors" ]]
}

decide_action() {
  local report="$1" previous="$2" state="$3" new old
  report_complete "$report" || { echo abort; return; }
  new="$(findings "$report")"
  old="$(findings "$previous")"
  case "$state" in
    none) [[ -z "$new" ]] && echo noop || echo create ;;
    closed)
      if [[ -z "$new" && -z "$old" ]]; then
        echo noop
      elif [[ -n "$new" && "$new" != "$old" ]]; then
        echo reopen
      else
        echo update
      fi
      ;;
    open)
      if [[ -z "$new" ]]; then
        echo close
      elif [[ "$new" == "$old" ]]; then
        echo update
      else
        echo comment
      fi
      ;;
    *)
      echo "unknown issue state: $state" >&2
      return 1
      ;;
  esac
}

# print_block <title> <lines>: a Markdown section with the lines fenced, or nothing.
print_block() {
  [[ -n "$2" ]] || return 0
  printf '%s\n\n```text\n%s\n```\n\n' "$1" "$2"
}

describe_changes() {
  local old new added resolved
  old="$(findings "$1")"
  new="$(findings "$2")"
  added="$(LC_ALL=C comm -13 <(printf '%s\n' "$old" | sed '/^$/d') <(printf '%s\n' "$new" | sed '/^$/d'))"
  resolved="$(LC_ALL=C comm -23 <(printf '%s\n' "$old" | sed '/^$/d') <(printf '%s\n' "$new" | sed '/^$/d'))"
  print_block "New:" "$added"
  print_block "Resolved:" "$resolved"
  if [[ -z "$added" && -z "$resolved" ]]; then
    printf 'No change in findings.\n'
  fi
}

# ── Offline self-test ──────────────────────────────────────────────────────
if [[ "${DRIFT_SYNC_SELF_TEST:-0}" == "1" ]]; then
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  failures=0
  cases=0

  # fixture <name> <body>: write a fixture file.
  fixture() { printf '%s\n' "$2" >"$dir/$1"; }

  expect_action() {
    local name="$1" report="$2" previous="$3" state="$4" expected="$5" actual
    cases=$((cases + 1))
    actual="$(decide_action "$dir/$report" "$dir/$previous" "$state")"
    if [[ "$actual" != "$expected" ]]; then
      echo "FAIL: $name: action $report $previous $state -> '$actual', expected '$expected'" >&2
      failures=$((failures + 1))
    fi
  }

  expect_changes() {
    local name="$1" previous="$2" report="$3" pattern="$4" mode="$5" out
    cases=$((cases + 1))
    out="$(describe_changes "$dir/$previous" "$dir/$report")"
    if [[ "$mode" == "has" ]] && ! grep -qF -- "$pattern" <<<"$out"; then
      echo "FAIL: $name: changes output lacks '$pattern':" >&2
      echo "$out" >&2
      failures=$((failures + 1))
    elif [[ "$mode" == "lacks" ]] && grep -qF -- "$pattern" <<<"$out"; then
      echo "FAIL: $name: changes output contains '$pattern':" >&2
      echo "$out" >&2
      failures=$((failures + 1))
    fi
  }

  fixture drift.md 'Generated 2026-10-12T09:00Z by [workflow run](https://example.invalid/1).

```text
== Terraform providers (registry.terraform.io) ==
DRIFT: helm provider [modules/controllers, root] pinned at "~> 2.12", latest is 3.3.0 (outside constraint)
OK:    random provider [root] pinned at "~> 3.0" (accepts latest 3.9.1)
DRIFT: terraform (TF_VERSION) pinned at 1.16.4, latest is 1.16.5
INFO:  aks_kubernetes_version pinned at 1.35, latest is 1.36 (pinned version supported until 2027-03-31)

check-version-drift.sh: 2 pin(s) behind upstream, 0 lookup(s) failed
```'
  # Same findings, reordered; new header, new OK/INFO lines; CRLF endings as
  # the GitHub API can return an edited body.
  printf '%s\r\n' 'Generated 2026-10-19T09:00Z by [workflow run](https://example.invalid/2).' '' '```text' \
    'DRIFT: terraform (TF_VERSION) pinned at 1.16.4, latest is 1.16.5' \
    'OK:    random provider [root] pinned at "~> 3.0" (accepts latest 3.9.2)' \
    'DRIFT: helm provider [modules/controllers, root] pinned at "~> 2.12", latest is 3.3.0 (outside constraint)' \
    'INFO:  aks_kubernetes_version pinned at 1.35, latest is 1.37 (pinned version supported until 2027-03-31)' \
    '' 'check-version-drift.sh: 2 pin(s) behind upstream, 0 lookup(s) failed' '```' >"$dir/same.md"
  fixture newer.md '```text
DRIFT: helm provider [modules/controllers, root] pinned at "~> 2.12", latest is 3.4.0 (outside constraint)
DRIFT: terraform (TF_VERSION) pinned at 1.16.4, latest is 1.16.5
check-version-drift.sh: 2 pin(s) behind upstream, 0 lookup(s) failed
```'
  fixture error.md '```text
DRIFT: helm provider [modules/controllers, root] pinned at "~> 2.12", latest is 3.3.0 (outside constraint)
DRIFT: terraform (TF_VERSION) pinned at 1.16.4, latest is 1.16.5
ERROR: KEDA chart: kedacore chart repository lookup failed
check-version-drift.sh: 2 pin(s) behind upstream, 1 lookup(s) failed
```'
  fixture clean.md '```text
OK:    tflint (TFLINT_VERSION) pinned at 0.64.0 (latest)
INFO:  aks_kubernetes_version pinned at 1.36, latest is 1.36 (pinned version supported until 2027-06-30)

check-version-drift.sh: 0 pin(s) behind upstream, 0 lookup(s) failed
```'
  # A run that died before the summary: no findings, but not clean.
  fixture truncated.md '```text
== Terraform providers (registry.terraform.io) ==
OK:    random provider [root] pinned at "~> 3.0" (accepts latest 3.9.1)
```'
  # The summary disagrees with the lines it summarises, as if the DRIFT:
  # prefix were renamed: zero parsed findings must not read as clean.
  fixture mismatch.md '```text
STALE: helm provider pinned at "~> 2.12", latest is 3.3.0
check-version-drift.sh: 1 pin(s) behind upstream, 0 lookup(s) failed
```'
  fixture empty.md ''
  # Output continued after the summary: the run did not end where the script does.
  fixture trailing.md '```text
DRIFT: terraform (TF_VERSION) pinned at 1.16.4, latest is 1.16.5
check-version-drift.sh: 1 pin(s) behind upstream, 0 lookup(s) failed
bash: line 9: unexpected EOF
```'

  expect_action "first report with drift creates the issue" drift.md missing.md none create
  expect_action "clean with no issue does nothing" clean.md missing.md none noop
  expect_action "same findings only replace the body" same.md drift.md open update
  expect_action "same findings, reverse direction" drift.md same.md open update
  expect_action "a changed latest version comments" newer.md drift.md open comment
  expect_action "a new ERROR comments" error.md drift.md open comment
  expect_action "a resolved finding comments" drift.md error.md open comment
  expect_action "a clean report closes the open issue" clean.md drift.md open close
  expect_action "drift after a close reopens" drift.md clean.md closed reopen
  expect_action "clean while closed does nothing" clean.md clean.md closed noop
  expect_action "a manual close with unchanged findings stays closed" same.md drift.md closed update
  expect_action "changed findings while closed reopen" newer.md drift.md closed reopen
  expect_action "findings resolved while closed refresh the body" clean.md drift.md closed update
  expect_action "output after the summary aborts" trailing.md drift.md open abort
  expect_action "an empty previous body counts as no findings" drift.md empty.md open comment
  expect_action "a truncated report never closes the issue" truncated.md drift.md open abort
  expect_action "a truncated report never creates an issue" truncated.md missing.md none abort
  expect_action "summary counts must match the lines" mismatch.md drift.md open abort
  expect_action "a missing report aborts" missing.md drift.md open abort

  expect_changes "new version listed as new" drift.md newer.md 'latest is 3.4.0' has
  expect_changes "old version listed as resolved" drift.md newer.md 'Resolved:' has
  expect_changes "unchanged finding not listed" drift.md newer.md 'TF_VERSION' lacks
  expect_changes "OK lines never listed" drift.md clean.md 'tflint' lacks
  expect_changes "everything resolved" drift.md clean.md 'latest is 1.16.5' has
  expect_changes "first findings all new" empty.md error.md 'ERROR: KEDA chart' has

  echo "drift-issue-sync.sh self-test: ${cases} case(s), ${failures} failure(s)"
  ((failures == 0))
  exit
fi

case "${1:-}" in
  action)
    [[ $# -eq 4 ]] || { echo "usage: $0 action <report> <previous-body> <open|closed|none>" >&2; exit 64; }
    decide_action "$2" "$3" "$4"
    ;;
  changes)
    [[ $# -eq 3 ]] || { echo "usage: $0 changes <previous-body> <report>" >&2; exit 64; }
    describe_changes "$2" "$3"
    ;;
  *)
    sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "$0"
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] || exit 64
    ;;
esac
