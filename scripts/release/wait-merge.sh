#!/usr/bin/env bash
# wait-merge.sh <pr> <tip> <branch> — wait for the release pull request to merge, then print the oid
# of the commit it merged as (stdout; everything else goes to stderr). Needs gh, GH_TOKEN,
# GITHUB_REPOSITORY.
#
# Each poll reads the PR and, while it is open, the tip of the default branch (DEFAULT_BRANCH, main).
# If that tip is no longer <tip>, the commit the PR was cut from, auto-merge rebases the PR onto
# something its checks never saw. The script then cancels the release: auto-merge off, the PR closed,
# <branch> deleted. The same cancel ends a run that times out or cannot read, because an auto-merge
# left on would merge after the script stopped watching, with nothing to check or tag it. A run
# cancelled while the PR merged anyway still prints the merged oid, and the caller judges it.
# A read that fails or answers nothing is a miss; WAIT_MISSES polls in a row with a miss end the run
# (a bad token must not look like a slow merge). A PR closed unmerged ends the run at once.
#
# Exit: 0 merged (the oid on stdout), 1 anything else, with the reason and whether the cancel worked.
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

# read_pr: sets state and oid (empty until merged); state is empty when the read failed.
read_pr() {
	local row
	state=""
	oid=""
	row=$(gh pr view "$pr" --json state,mergeCommit --jq '[.state, (.mergeCommit.oid // "")] | @tsv' 2>"$err") \
		&& [ -n "$row" ] || return 1
	state=${row%%$'\t'*}
	oid=${row#*$'\t'}
}

# stop <reason>: cancel the release, then say what is true. A PR that merged in the meantime is a
# merge: print its oid and let the caller judge the commits.
stop() {
	local off=1 closed=1 note
	gh pr merge "$pr" --disable-auto >&2 || off=0
	gh pr close "$pr" --delete-branch >&2 || closed=0
	read_pr || true
	if [ "$state" = MERGED ]; then
		echo "$oid"
		exit 0
	fi
	# gh closes first and deletes the branch after, so a failed command can still have closed the PR:
	# the re-read state decides whether it is closed, and the command results say what else failed.
	if [ "$state" = CLOSED ] || { [ -z "$state" ] && [ "$closed" = 1 ]; }; then
		if [ "$closed" = 0 ]; then
			note="Pull request #$pr is closed, but deleting $branch failed: delete it by hand."
		elif [ "$off" = 0 ]; then
			note="WARNING: could not turn auto-merge off for #$pr; it is closed, which stops a merge, but check it by hand."
		else
			note="Auto-merge is off, pull request #$pr is closed and $branch is deleted."
		fi
	elif [ "$off" = 1 ]; then
		note="Auto-merge is off, but #$pr could not be closed or $branch deleted: close it and delete the branch by hand."
	else
		note="WARNING: could not turn auto-merge off for #$pr or close it; it may still merge. Turn it off and close it by hand."
	fi
	fail "$1 $note"
}

misses=0
# miss <what>: count one failed or empty read of a poll.
miss() {
	misses=$((misses + 1))
	printf 'WARN: %s gave no answer (%d/%d): %s\n' "$1" "$misses" "$max_misses" "$(cat "$err")" >&2
	[ "$misses" -lt "$max_misses" ] || stop "$1 failed $max_misses reads in a row: $(cat "$err")"
}

# moved <current tip>: the base moved under an open PR. A merge between the two reads is not a move.
moved() {
	read_pr || true
	if [ "$state" = MERGED ]; then
		echo "$oid"
		exit 0
	fi
	stop "$base moved from $tip to $1 while pull request #$pr waited; the release was cut from the old tip."
}

deadline=$(($(date +%s) + limit))
echo "Waiting for pull request #$pr (cut from $tip)..." >&2
while [ "$(date +%s)" -lt "$deadline" ]; do
	if read_pr; then
		case "$state" in
		MERGED)
			echo "$oid"
			exit 0
			;;
		CLOSED) fail "Pull request #$pr was closed without merging. Nothing reached $base." ;;
		OPEN)
			if cur=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/$base" --jq .object.sha 2>"$err") && [ -n "$cur" ]; then
				[ "$cur" = "$tip" ] || moved "$cur"
				misses=0
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
stop "Pull request #$pr did not merge within $limit seconds."
