#!/usr/bin/env bash
# called-workflow-concurrency-test.sh — a reusable workflow must not build a concurrency group from
# `github.workflow`.
#
# Inside a called workflow `github.workflow` is the CALLER's workflow name, so a group built from it
# equals the caller's own group (when the caller keeps the usual `${{ github.workflow }}-...`), and
# GitHub cancels the run as a deadlock. A fixed prefix is fine, and so is no group: the caller owns it.
#
# The check reads every workflow here that has a `workflow_call` trigger, at the top level and in each
# job. It runs on fixtures first, so a check that never matches cannot pass for a clean tree.
#
# Usage: called-workflow-concurrency-test.sh [REPO_ROOT]

# The fixtures below are YAML text holding GitHub expressions, so the dollar sign must stay literal.
# shellcheck disable=SC2016
set -u

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/called-workflow-concurrency-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
	shift
	printf '     %s\n' "$@"
}

# groups <file>: every concurrency group string of a reusable workflow, one per line; nothing when the
# file is not reusable.
groups() {
	local f=$1
	# has(), not "!= null": a bare `workflow_call:` key is a null value.
	[ "$(yq '.on | has("workflow_call")' "$f")" = true ] || return 0
	yq '[.concurrency, .jobs[].concurrency] | .[] | select(. != null) | (.group // .)' "$f"
}

# offending <file>: the groups that contain github.workflow.
offending() {
	groups "$1" | grep -F 'github.workflow' || true
}

# expect_bad / expect_ok <name> <yaml>: the check on a fixture.
fixture() {
	local name=$1 yaml=$2 file
	file="$T/$name.yml"
	printf '%s\n' "$yaml" >"$file"
	offending "$file"
}

out=$(fixture called-top 'on:
  workflow_call:
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]')
if [ -n "$out" ]; then ok "control: a called workflow with a top-level github.workflow group is caught"; else bad "control: a called workflow with a top-level github.workflow group is caught" "nothing found"; fi

out=$(fixture called-job 'on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    concurrency: ${{ github.workflow }}
    steps: [{run: "true"}]')
if [ -n "$out" ]; then ok "control: a job-level github.workflow group is caught"; else bad "control: a job-level github.workflow group is caught" "nothing found"; fi

out=$(fixture called-prefix 'on:
  workflow_call:
concurrency:
  group: fixed-prefix-${{ github.event.pull_request.number }}
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]')
eq_empty() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "found: $2"; fi; }
eq_empty "control: a fixed prefix passes" "$out"

out=$(fixture called-none 'on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]')
eq_empty "control: a called workflow with no concurrency passes" "$out"

out=$(fixture not-called 'on:
  pull_request:
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]')
eq_empty "control: a workflow that is not called may use github.workflow" "$out"

n=0
for f in "$ROOT"/.github/workflows/*.yml; do
	[ -e "$f" ] || continue
	n=$((n + 1))
	eq_empty "$(basename "$f"): no group built from github.workflow" "$(offending "$f")"
done
if [ "$n" -gt 0 ]; then ok "the check read $n workflow file(s)"; else bad "the check read workflow files" "none found under $ROOT/.github/workflows"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
