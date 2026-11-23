#!/usr/bin/env bash
# wait-merge.sh <pr> <tip> <branch> — wait for the release pull request to merge, then print the oid
# of the commit it merged as (stdout; everything else goes to stderr). Needs gh, GH_TOKEN,
# GITHUB_REPOSITORY.
#
# Each poll reads the PR and, while it is open, the tip of the default branch (DEFAULT_BRANCH, main).
# If that tip is no longer <tip>, the commit the PR was cut from, auto-merge rebases the PR onto
# something its checks never saw: the script turns auto-merge off, closes the PR, deletes <branch>
# and exits 1. Nothing has reached the default branch; a rerun cuts a new release.
# A read that fails or answers nothing is a miss; WAIT_MISSES in a row end the run (a bad token must
# not look like a slow merge). A PR closed unmerged ends the run at once.
#
# Exit: 0 merged (the oid on stdout), 1 anything else, with the reason.
# Tunables, for the tests: WAIT_POLL seconds between polls (30), WAIT_MISSES (6), WAIT_DEADLINE
# elapsed seconds (5400, 90 minutes).
set -euo pipefail

pr=${1:?usage: wait-merge.sh <pr> <tip> <branch>}
tip=${2:?usage: wait-merge.sh <pr> <tip> <branch>}
branch=${3:?usage: wait-merge.sh <pr> <tip> <branch>}
base=${DEFAULT_BRANCH:-main}
poll=${WAIT_POLL:-30}
max_misses=${WAIT_MISSES:-6}
limit=${WAIT_DEADLINE:-5400}

err=$(mktemp)
trap 'rm -f "$err"' EXIT

fail() {
	printf 'ERROR: %s\n' "$1" >&2
	if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error::%s\n' "$1" >&2; fi
	exit 1
}

misses=0
# miss <what>: count one failed or empty read.
miss() {
	misses=$((misses + 1))
	printf 'WARN: %s gave no answer (%d/%d): %s\n' "$1" "$misses" "$max_misses" "$(cat "$err")" >&2
	[ "$misses" -lt "$max_misses" ] || fail "$1 failed $max_misses reads in a row: $(cat "$err")"
}

# read_pr: sets state and oid (empty until merged).
read_pr() {
	local row
	row=$(gh pr view "$pr" --json state,mergeCommit --jq '[.state, (.mergeCommit.oid // "")] | @tsv' 2>"$err") \
		&& [ -n "$row" ] || return 1
	state=${row%%$'\t'*}
	oid=${row#*$'\t'}
}

# moved <current tip>: the base moved under an open PR. A merge between the two reads is not a move.
moved() {
	read_pr || true
	if [ "${state:-}" = MERGED ]; then
		echo "$oid"
		exit 0
	fi
	gh pr merge "$pr" --disable-auto >&2 || echo "WARN: could not turn auto-merge off" >&2
	gh pr close "$pr" --delete-branch >&2 || echo "WARN: could not close the pull request or delete $branch" >&2
	fail "$base moved from $tip to $1 while pull request #$pr waited. Nothing reached $base; it is closed and $branch is deleted. Start the release again."
}

deadline=$(($(date +%s) + limit))
echo "Waiting for pull request #$pr (cut from $tip)..." >&2
while [ "$(date +%s)" -lt "$deadline" ]; do
	if read_pr; then
		misses=0
		case "$state" in
		MERGED)
			echo "$oid"
			exit 0
			;;
		CLOSED) fail "Pull request #$pr was closed without merging. Nothing reached $base." ;;
		OPEN)
			if cur=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$base" --jq .object.sha 2>"$err") && [ -n "$cur" ]; then
				[ "$cur" = "$tip" ] || moved "$cur"
			else
				miss "Reading $base"
			fi
			;;
		*) fail "Pull request #$pr is in the state '$state'." ;;
		esac
	else
		miss "Reading pull request #$pr"
	fi
	sleep "$poll"
done
fail "Pull request #$pr did not merge within $limit seconds. It is still open: look at its checks, then rerun."
