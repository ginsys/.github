#!/usr/bin/env bash
# tracker-audit-test.sh — fixture tests for scripts/tracker-audit.sh.
#
# Each negative fixture carries exactly one defect, so a check that silently stopped firing fails
# its own test instead of hiding behind another check's finding. A positive fixture guards the
# other direction (a script that rejects everything passes every negative test), and each
# switchable check also runs with its switch off, proving the switch is real.
#
# Usage: tracker-audit-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
SCRIPT="$ROOT/scripts/tracker-audit.sh"
NOW=1800000000   # 2027-01-15, after every past due_on below and before every future one

failures=0
pass_count=0

# Writes $1 to a temp fixture, runs the script on it with the remaining args, echoes "rc<TAB>output".
run_fixture() {
  local content="$1"; shift
  local f out rc
  f="$(mktemp)"
  printf '%s\n' "$content" > "$f"
  out=$(bash "$SCRIPT" --fixture "$f" --now "$NOW" "$@" 2>&1); rc=$?
  rm -f "$f"
  printf '%s\t%s' "$rc" "$out"
}

# assert_result DESC EXPECTED_RC EXPECTED_CHECK RESULT — EXPECTED_CHECK is the one check that must
# be the single finding, or "" for a clean run.
assert_result() {
  local desc="$1" want_rc="$2" want_check="$3" result="$4"
  local rc="${result%%$'\t'*}" out="${result#*$'\t'}" ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  if [ -n "$want_check" ]; then
    grep -q "^tracker-audit: 1 finding" <<<"$out" || ok=0
    grep -q "^  \[$want_check\]" <<<"$out" || ok=0
  else
    grep -q "^tracker-audit: OK" <<<"$out" || ok=0
  fi
  if [ "$ok" = 1 ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$want_rc check='$want_check', got rc=$rc:" >&2
    echo "    ${out//$'\n'/$'\n'    }" >&2
    failures=$((failures + 1))
  fi
}

MS_OPEN='{"number": 1, "title": "01 - Open", "state": "open", "due_on": null}'
MS_CLOSED='{"number": 2, "title": "00 - Closed", "state": "closed", "due_on": null}'
MS_LIST='[{"number": 1, "title": "01 - Open", "state": "open", "due_on": null, "open_issues": 1},
          {"number": 2, "title": "00 - Closed", "state": "closed", "due_on": null, "open_issues": 0}]'

issue() { # number labels-json milestone-json blocked_by-json
  printf '{"number": %s, "title": "t", "labels": %s, "milestone": %s, "blocked_by": %s}' "$1" "$2" "$3" "$4"
}
snap() { printf '{"issues": [%s], "milestones": %s}' "$1" "$2"; }

ALL_FLAGS=(--require-milestone --single-select type --exclusive status/in-progress:status/needs-review --blocked-in-progress)

# One type/, one status/, a milestone, only a closed blocker: nothing to report.
assert_result "conforming tracker passes with every check on" 0 "" \
  "$(run_fixture "$(snap "$(issue 10 '["type/bug","status/in-progress"]' "$MS_OPEN" '[{"number": 3, "state": "closed"}]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"

assert_result "missing milestone fails" 1 milestone \
  "$(run_fixture "$(snap "$(issue 11 '["type/bug"]' null '[]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"
assert_result "missing milestone passes without --require-milestone" 0 "" \
  "$(run_fixture "$(snap "$(issue 11 '["type/bug"]' null '[]')" "$MS_LIST")" --single-select type)"

assert_result "no type/ label fails single-select" 1 single-select \
  "$(run_fixture "$(snap "$(issue 12 '["status/needs-review"]' "$MS_OPEN" '[]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"
assert_result "two type/ labels fail single-select" 1 single-select \
  "$(run_fixture "$(snap "$(issue 13 '["type/bug","type/feature"]' "$MS_OPEN" '[]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"
assert_result "two type/ labels pass without --single-select" 0 "" \
  "$(run_fixture "$(snap "$(issue 13 '["type/bug","type/feature"]' "$MS_OPEN" '[]')" "$MS_LIST")" --require-milestone)"

assert_result "in-progress and needs-review together fail exclusive" 1 exclusive \
  "$(run_fixture "$(snap "$(issue 14 '["type/bug","status/in-progress","status/needs-review"]' "$MS_OPEN" '[]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"
assert_result "needs-refinement beside in-progress is allowed" 0 "" \
  "$(run_fixture "$(snap "$(issue 15 '["type/bug","status/in-progress","status/needs-refinement"]' "$MS_OPEN" '[]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"

assert_result "in-progress while blocked by an open issue fails" 1 blocked \
  "$(run_fixture "$(snap "$(issue 16 '["type/bug","status/in-progress"]' "$MS_OPEN" '[{"number": 3, "state": "open"}]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"
assert_result "an open blocker on a non-in-progress issue is fine" 0 "" \
  "$(run_fixture "$(snap "$(issue 16 '["type/bug","status/needs-review"]' "$MS_OPEN" '[{"number": 3, "state": "open"}]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"
assert_result "open blocker passes without --blocked-in-progress" 0 "" \
  "$(run_fixture "$(snap "$(issue 16 '["type/bug","status/in-progress"]' "$MS_OPEN" '[{"number": 3, "state": "open"}]')" "$MS_LIST")" --require-milestone --single-select type)"

assert_result "open issue in a closed milestone fails" 1 closed-milestone \
  "$(run_fixture "$(snap "$(issue 17 '["type/bug"]' "$MS_CLOSED" '[]')" "$MS_LIST")" "${ALL_FLAGS[@]}")"

OVERDUE='[{"number": 1, "title": "01 - Open", "state": "open", "due_on": "2026-01-01T00:00:00Z", "open_issues": 1}]'
assert_result "open milestone past due with open issues fails" 1 overdue-milestone \
  "$(run_fixture "$(snap "$(issue 18 '["type/bug"]' "$MS_OPEN" '[]')" "$OVERDUE")" "${ALL_FLAGS[@]}")"
NOT_YET='[{"number": 1, "title": "01 - Open", "state": "open", "due_on": "2030-01-01T00:00:00Z", "open_issues": 1}]'
assert_result "open milestone due in the future passes" 0 "" \
  "$(run_fixture "$(snap "$(issue 18 '["type/bug"]' "$MS_OPEN" '[]')" "$NOT_YET")" "${ALL_FLAGS[@]}")"
DRAINED='[{"number": 1, "title": "01 - Open", "state": "open", "due_on": "2026-01-01T00:00:00Z", "open_issues": 0}]'
assert_result "overdue milestone with no open issues passes" 0 "" \
  "$(run_fixture "$(snap "" "$DRAINED")" "${ALL_FLAGS[@]}")"

# --- live mode: a failing snapshot fetch must never report a clean tracker ---
#
# The only test that exercises snapshot_live, and it still needs no network: a stub `gh` on PATH
# stands in for an expired token or a transient 5xx. Without `inherit_errexit` in the script, the
# failed fetch left `issues` empty, `jq -s 'add // []'` turned that into `[]`, and the audit
# printed "tracker-audit: OK (0 open issues)" and exited 0 -- a green audit of nothing. Deleting
# that shopt must fail this test.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: HTTP 401: Bad credentials" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

live_out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --repo ginsys/nonexistent --now "$NOW" 2>&1)
live_rc=$?
rm -rf "$STUB_DIR"

if [ "$live_rc" -ne 0 ] && ! grep -q "^tracker-audit: OK" <<<"$live_out"; then
  pass_count=$((pass_count + 1))
else
  echo "FAIL: a failing gh api must abort, not report OK - rc=$live_rc, output: $live_out" >&2
  failures=$((failures + 1))
fi

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
