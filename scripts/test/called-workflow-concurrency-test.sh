#!/usr/bin/env bash
# called-workflow-concurrency-test.sh — a reusable workflow must not build a concurrency group from
# `github.workflow`.
#
# Inside a called workflow `github.workflow` is the CALLER's workflow name, so a group built from it
# equals the caller's own group (when the caller keeps the usual `${{ github.workflow }}-...`), and
# GitHub cancels the run as a deadlock. A fixed prefix is fine, and so is no group: the caller owns it.
#
# The check reads every *.yml and *.yaml workflow here that has a `workflow_call` trigger, written as a
# map, a list or a plain string, at the top level and in each job. It runs on fixtures first, so a
# check that never matches cannot pass for a clean tree.
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

# is_called <file>: true when the workflow has a workflow_call trigger. `on` is a map, a list or a
# string, and a bare `workflow_call:` key is a null value, so has() is used and not "!= null".
is_called() {
	[ "$(yq '.on | ((tag == "!!map" and has("workflow_call")) or (tag == "!!seq" and contains(["workflow_call"])) or (tag == "!!str" and . == "workflow_call"))' "$1")" = true ]
}

# groups <file>: every concurrency group string of a reusable workflow, one per line; nothing when the
# file is not reusable.
groups() {
	is_called "$1" || return 0
	yq '[.concurrency, .jobs[].concurrency] | .[] | select(. != null) | (.group // .)' "$1"
}

# offending <file>: the groups that contain github.workflow.
offending() {
	groups "$1" | grep -F 'github.workflow' || true
}

# scan_tree <root>: "<file>: <group>" for every offending workflow under <root>/.github/workflows,
# *.yml and *.yaml alike, and a final line "scanned N" with the number of files read.
scan_tree() {
	local f n=0 hit
	for f in "$1"/.github/workflows/*.yml "$1"/.github/workflows/*.yaml; do
		[ -e "$f" ] || continue
		n=$((n + 1))
		hit=$(offending "$f")
		[ -z "$hit" ] || printf '%s: %s\n' "$(basename "$f")" "$hit"
	done
	printf 'scanned %d\n' "$n"
}

# fixture <name> <yaml>: write $T/<name> and print its offending groups.
fixture() {
	local file="$T/$1"
	printf '%s\n' "$2" >"$file"
	offending "$file"
}

caught() { if [ -n "$2" ]; then ok "$1"; else bad "$1" "nothing found"; fi; }
passes() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "found: $2"; fi; }

BODY='jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]'
GROUP='concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}'

caught "control: map trigger, top-level github.workflow group, is caught" \
	"$(fixture map.yml "on:
  workflow_call:
$GROUP
$BODY")"
caught "control: map trigger with inputs is caught" \
	"$(fixture map-inputs.yml "on:
  workflow_call:
    inputs:
      x:
        type: string
$GROUP
$BODY")"
caught "control: scalar trigger (on: workflow_call) is caught" \
	"$(fixture scalar.yml "on: workflow_call
$GROUP
$BODY")"
caught "control: list trigger (on: [workflow_call]) is caught" \
	"$(fixture list.yml "on: [pull_request, workflow_call]
$GROUP
$BODY")"
caught "control: block-list trigger is caught" \
	"$(fixture block-list.yml "on:
  - pull_request
  - workflow_call
$GROUP
$BODY")"
caught "control: a job-level github.workflow group is caught" \
	"$(fixture job.yml 'on:
  workflow_call:
jobs:
  j:
    runs-on: ubuntu-latest
    concurrency: ${{ github.workflow }}
    steps: [{run: "true"}]')"
passes "control: a fixed prefix passes" \
	"$(fixture prefix.yml "on:
  workflow_call:
concurrency:
  group: fixed-prefix-\${{ github.event.pull_request.number }}
$BODY")"
passes "control: a called workflow with no concurrency passes" \
	"$(fixture none.yml "on:
  workflow_call:
$BODY")"
passes "control: a workflow that is not called may use github.workflow (map)" \
	"$(fixture not-called.yml "on:
  pull_request:
$GROUP
$BODY")"
passes "control: a workflow that is not called may use github.workflow (list)" \
	"$(fixture not-called-list.yml "on: [push, pull_request]
$GROUP
$BODY")"

# The tree scan: a .yaml file is read as well, and the count says how many files it read.
mkdir -p "$T/tree/.github/workflows"
printf '%s\n' "on: workflow_call
$GROUP
$BODY" >"$T/tree/.github/workflows/reusable.yaml"
printf '%s\n' "on:
  workflow_call:
$BODY" >"$T/tree/.github/workflows/clean.yml"
out=$(scan_tree "$T/tree")
case "$out" in
*"reusable.yaml:"*"scanned 2"*) ok "control: a .yaml reusable workflow is scanned and caught, both files counted" ;;
*) bad "control: a .yaml reusable workflow is scanned and caught, both files counted" "$out" ;;
esac

out=$(scan_tree "$ROOT")
n=${out##*scanned }
hits=${out%scanned *}
passes "the repository's workflows: none builds a group from github.workflow" "$hits"
if [ "${n:-0}" -gt 0 ]; then ok "the check read $n workflow file(s) under $ROOT"; else bad "the check read workflow files" "none found under $ROOT/.github/workflows"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
