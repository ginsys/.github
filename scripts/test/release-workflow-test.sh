#!/usr/bin/env bash
# release-workflow-test.sh — the structure of .github/workflows/release.yml and release-dry-run.yml.
#
# The real-run job cannot run in this repository (no App, no environment), so what keeps it safe is
# read here: no secret outside the one job that has the environment, the job limit above the wait
# deadline, a concurrency group that never cancels, the dry-run caller that can only dry-run. Each
# check also runs on a deliberately broken copy first, so a check that never matches cannot pass.
#
# Usage: release-workflow-test.sh [REPO_ROOT]

# The strings below are YAML text holding GitHub expressions, so the dollar sign must stay literal.
# shellcheck disable=SC2016
set -u

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
RELEASE="$ROOT/.github/workflows/release.yml"
DRYRUN="$ROOT/.github/workflows/release-dry-run.yml"
WAIT="$ROOT/scripts/release/wait-merge.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/release-workflow-test.XXXXXX") || exit 2
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

# The wait deadline (seconds) the script defaults to, read from the script and never retyped here.
deadline=$(sed -n 's/^limit=\${WAIT_DEADLINE:-\([0-9][0-9]*\)}$/\1/p' "$WAIT")
case "$deadline" in
'' | *[!0-9]*) bad "the wait deadline is read from wait-merge.sh" "got: '$deadline'"; deadline=0 ;;
*) ok "the wait deadline is read from wait-merge.sh: $deadline seconds" ;;
esac

# problems <release.yml copy>: one line per rule the file breaks; nothing when it keeps them all.
problems() {
	local f=$1 v
	v=$(yq '.jobs.release."timeout-minutes" // 0' "$f")
	# The steps after the wait take a few minutes: ten are required beyond the deadline.
	[ $((v * 60)) -ge $((deadline + 600)) ] || echo "release job timeout-minutes $v is not above the wait deadline plus 10 minutes"
	[ "$(yq '[.jobs | to_entries[] | select(.value.environment != null) | .key] | join(",")' "$f")" = release ] \
		|| echo "the environment is not on the release job alone"
	[ "$(yq '.jobs.guard | tostring' "$f" | grep -c 'secrets\.')" = 0 ] || echo "the guard job reads a secret"
	[ "$(yq '.jobs.guard.environment // ""' "$f")" = "" ] || echo "the guard job has an environment"
	[ "$(yq '.jobs.guard.permissions | to_json(0)' "$f")" = '{"contents":"read"}' ] || echo "the guard job holds more than contents: read"
	[ "$(yq '.jobs.release.permissions | to_json(0)' "$f")" = '{"contents":"write"}' ] || echo "the release job holds more than contents: write"
	[ "$(yq '.jobs.release.concurrency.group' "$f")" = 'release-${{ github.repository }}' ] || echo "the release job's group is not release-<repository>"
	[ "$(yq '.jobs.release.concurrency."cancel-in-progress"' "$f")" = false ] || echo "the release group cancels"
	[ "$(yq '[.concurrency, .jobs.guard.concurrency] | .[] | select(. != null)' "$f")" = "" ] || echo "a concurrency group is set outside the release job"
	[ "$(yq '.jobs.release.if' "$f")" = '${{ !inputs.dry_run }}' ] || echo "the release job does not run only for a real run"
	[ "$(yq '.jobs.release.steps[] | select(.id == "run") | .env.TAG_TOKEN' "$f")" = '${{ github.token }}' ] \
		|| echo "the tag is not made with the workflow token"
	[ "$(yq '.jobs.release.steps[] | select(.id == "run") | .env.GH_TOKEN' "$f")" = '${{ steps.app.outputs.token }}' ] \
		|| echo "the release step does not use the App token"
	[ "$(yq '.on.workflow_call.inputs.dry_run.default' "$f")" = true ] || echo "dry_run does not default to true"
	[ "$(yq '.on.workflow_call.outputs | keys | sort | join(",")' "$f")" = "sha,tag,version" ] || echo "the outputs are not tag, version and sha"
}

# broken <name> <perl substitution> <expected problem substring>: a copy of release.yml with one rule
# broken must report that problem.
broken() {
	local out
	perl -0pe "$2" "$RELEASE" >"$T/$1.yml"
	if cmp -s "$RELEASE" "$T/$1.yml"; then bad "control: $1" "the substitution changed nothing"; return; fi
	out=$(problems "$T/$1.yml")
	case "$out" in
	*"$3"*) ok "control: $1 is reported" ;;
	*) bad "control: $1 is reported" "wanted: $3" "got: ${out:-nothing}" ;;
	esac
}

broken short-limit 's/timeout-minutes: 120/timeout-minutes: 90/' "timeout-minutes 90"
broken guard-secret 's/\$\{\{ github\.token \}\}/\${{ secrets.RELEASE_APP_ID }}/' "guard job reads a secret"
broken guard-env 's/(  guard:\n)/$1    environment: release\n/' "environment is not on the release job alone"
broken cancel 's/cancel-in-progress: false/cancel-in-progress: true/' "release group cancels"
broken wrong-group 's/group: release-\$\{\{ github.repository \}\}/group: \${{ github.workflow }}/' "not release-<repository>"
broken always-runs 's/if: \$\{\{ !inputs.dry_run \}\}/if: true/' "does not run only for a real run"
broken tag-token 's/TAG_TOKEN: \$\{\{ github.token \}\}/TAG_TOKEN: \${{ steps.app.outputs.token }}/' "not made with the workflow token"
broken dry-default 's/default: true/default: false/' "does not default to true"
broken guard-write 's/(    permissions:\n      contents: )read/${1}write/' "guard job holds more"

out=$(problems "$RELEASE")
if [ -z "$out" ]; then ok "release.yml keeps every rule"; else bad "release.yml keeps every rule" "$out"; fi

# The dry-run caller can only dry-run, and nothing in the repository starts a real run.
# check <name> <expected> <actual>
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi; }
check "release-dry-run.yml passes dry_run: true" true "$(yq '.jobs."dry-run".with.dry_run' "$DRYRUN")"
check "the dry run is of start-next-minor, which makes no tag" start-next-minor "$(yq '.jobs."dry-run".with.action' "$DRYRUN")"
check "release-dry-run.yml reads no secret" 0 "$(yq '. | tostring' "$DRYRUN" | grep -c 'secrets\.' || true)"
# The snapshots must fail on a failed read (bash with pipefail) and list every open pull request.
check "release-dry-run.yml runs its steps with bash -e and pipefail" bash "$(yq '.defaults.run.shell' "$DRYRUN")"
check "both snapshots list up to 1000 open pull requests" 2 "$(grep -c -- '--state open --limit 1000' "$DRYRUN" || true)"
check "control: the same checks fail on a copy without them" "|0" \
	"$(sed -e '/shell: bash/d' -e 's/ --limit 1000//' "$DRYRUN" >"$T/dry.yml"; echo "$(yq '.defaults.run.shell // ""' "$T/dry.yml")|$(grep -c -- '--state open --limit 1000' "$T/dry.yml" || true)")"
hits=$(grep -rnE 'dry_run: *(false|"?0"?)$|--admin|bypass' "$ROOT/.github/workflows" "$ROOT/scripts/release" || true)
if [ -z "$hits" ]; then ok "no workflow or release script has a real-run call, --admin or a bypass"; else bad "no real-run call, --admin or bypass" "$hits"; fi
printf 'x\n  dry_run: false\n' >"$T/probe.yml"
if grep -qE 'dry_run: *(false|"?0"?)$' "$T/probe.yml"; then ok "control: the real-run pattern matches a dry_run: false line"; else bad "control: the real-run pattern matches a dry_run: false line"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
