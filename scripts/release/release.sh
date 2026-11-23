#!/usr/bin/env bash
# release.sh — the release script of the reusable release workflow (docs/release.md).
# Adapted from ginsys/shelly-manager's scripts/release/release.sh: the same seven actions, but the
# release commit reaches the default branch through a pull request, never a push, and the tag is made
# through the API on the commit that merged.
#
# One action per run (RELEASE_ACTION), where VERSION is vX.Y.Z-alpha|beta|rc.N:
#   release                  tag VERSION as it stands; VERSION -> the next number
#   release-as-beta|rc       move to that stage (.0) and tag it; a VERSION already at that stage is
#                            tagged as it stands, like `release`
#   release-as-stable        tag vX.Y.Z; VERSION -> vX.Y.(Z+1)-alpha.0
#   start-next-minor|major   no tag; VERSION -> the next line's alpha.0
#   skip-prerelease-number   no tag; VERSION -> the next number (recovery)
#
#   release.sh --check   every refusal and the preview; reads only, writes nothing, needs no secret
#   release.sh           the real run (DRY_RUN=0): --check, then the release branch with two commits
#                        (A "release: <tag>": CHANGELOG.md assembled, VERSION at the tag; B: VERSION
#                        moved on; a VERSION-only action makes B alone), the pull request, auto-merge,
#                        wait-merge.sh, a check of the merged commits, and the tag on A' (A as merged)
#
# Environment:
#   RELEASE_ACTION      one of the actions (default: release)
#   DRY_RUN             1 = preview only, the default; 0 = a real run (the script never defaults to real)
#   RELEASE_BRANCH      the branch being released (default: the checked-out one)
#   RELEASE_REF_TYPE    `branch` or `tag`, the workflow's github.ref_type (default: branch)
#   DEFAULT_BRANCH      the branch the release lands on (default: main)
#   CHANGELOG_DATE      YYYY-MM-DD for the changelog heading, read once by the caller (default: today, UTC)
#   RELEASE_NOTES_FILE  where --check writes the changelog section (the release notes)
#   GITHUB_REPOSITORY, GH_TOKEN  for gh; TAG_TOKEN, the workflow token, makes the tag (default: GH_TOKEN)
#   TAG_RETRY_SLEEP     seconds between the three tag attempts (default 10)
# Outputs (GITHUB_OUTPUT): tag, version, next_version, queue, changelog_date from --check; tag, version,
# sha from a real run (sha is the tagged commit, or the merged commit when no tag is made).
# Exit: 0 done, 1 refused, 3 a tagging action with no changelog fragment left.

set -euo pipefail
# Keep set -e inside $(...) too; bash turns it off there by default.
shopt -s inherit_errexit
export LC_ALL=C

VERSION_FILE=VERSION
CHANGELOG_FILE=CHANGELOG.md
REMOTE=origin
HERE="$(dirname "${BASH_SOURCE[0]}")"
ASSEMBLE="$HERE/changelog-assemble.sh"
WAIT="$HERE/wait-merge.sh"
ACTIONS="release release-as-beta release-as-rc release-as-stable start-next-minor start-next-major skip-prerelease-number"

DRY_RUN="${DRY_RUN:-1}"
RELEASE_ACTION="${RELEASE_ACTION:-release}"
RELEASE_BRANCH="${RELEASE_BRANCH:-}"
RELEASE_REF_TYPE="${RELEASE_REF_TYPE:-branch}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
CHANGELOG_DATE="${CHANGELOG_DATE:-$(date -u +%F)}"
export CHANGELOG_DATE DEFAULT_BRANCH
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set (owner/repo)}"
export GH_REPO="$GITHUB_REPOSITORY"

log_info() { printf 'INFO: %s\n' "$1"; }
log_ok() { printf 'OK: %s\n' "$1"; }
log_warn() { printf 'WARN: %s\n' "$1"; }
# die <message> [exit code]: to stderr, which also holds the workflow command the runner reads.
die() {
	printf 'ERROR: %s\n' "$1" >&2
	if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error::%s\n' "$1" >&2; fi
	exit "${2:-1}"
}

set_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
}

# ── Versions ──────────────────────────────────────────────────────────────

NUM='(0|[1-9][0-9]*)'
VERSION_RE="^v${NUM}\.${NUM}\.${NUM}(-(alpha|beta|rc)\.${NUM})?\$"

# parse_version <v>: sets V_MAJOR V_MINOR V_PATCH, and V_TYPE V_NUM (empty for a stable version).
parse_version() {
	[[ "$1" =~ $VERSION_RE ]] || die "Invalid version '$1': expected vX.Y.Z or vX.Y.Z-alpha|beta|rc.N"
	V_MAJOR=${BASH_REMATCH[1]}
	V_MINOR=${BASH_REMATCH[2]}
	V_PATCH=${BASH_REMATCH[3]}
	V_TYPE=${BASH_REMATCH[5]}
	V_NUM=${BASH_REMATCH[6]}
	check_bounds "$1" "Invalid version '$1'"
}

# check_bounds <version> <what to say>: every number in it has at most 9 digits. Bash arithmetic is
# 64-bit, so a longer number would wrap around into an older release line, and a 9-digit one plus 1
# would be a 10-digit number that the next run refuses.
check_bounds() {
	local n
	# The unquoted expansion splits the digit groups on purpose.
	# shellcheck disable=SC2086
	for n in ${1//[!0-9]/ }; do
		[ "${#n}" -le 9 ] || die "$2: a number of more than 9 digits is not supported."
	done
}

stage_order() {
	case "$1" in
	alpha) echo 0 ;;
	beta) echo 1 ;;
	rc) echo 2 ;;
	esac
}

require_prerelease() {
	[ -n "$V_TYPE" ] || die "VERSION is $CURRENT, not a prerelease. start-next-minor or start-next-major begins a new line."
}

# plan_action: sets TAG (empty for a VERSION-only action), NEXT (VERSION after) and BUMP_MSG.
plan_action() {
	local base="v$V_MAJOR.$V_MINOR.$V_PATCH" target
	TAG=""
	case "$RELEASE_ACTION" in
	release)
		require_prerelease
		TAG=$CURRENT
		NEXT="$base-$V_TYPE.$((V_NUM + 1))"
		BUMP_MSG="chore: bump version: $CURRENT -> $NEXT"
		;;
	release-as-beta | release-as-rc)
		require_prerelease
		target=${RELEASE_ACTION#release-as-}
		if [ "$(stage_order "$target")" -lt "$(stage_order "$V_TYPE")" ]; then
			die "VERSION is $CURRENT: going back from $V_TYPE to $target is refused. To restart at $target, begin a new line with start-next-minor first."
		fi
		if [ "$target" = "$V_TYPE" ]; then
			TAG=$CURRENT
			NEXT="$base-$V_TYPE.$((V_NUM + 1))"
		else
			TAG="$base-$target.0"
			NEXT="$base-$target.1"
		fi
		BUMP_MSG="chore: bump version: $TAG -> $NEXT"
		;;
	release-as-stable)
		require_prerelease
		TAG=$base
		NEXT="v$V_MAJOR.$V_MINOR.$((V_PATCH + 1))-alpha.0"
		BUMP_MSG="chore: start next cycle: $NEXT"
		;;
	start-next-minor)
		NEXT="v$V_MAJOR.$((V_MINOR + 1)).0-alpha.0"
		BUMP_MSG="chore: start next cycle: $NEXT"
		;;
	start-next-major)
		NEXT="v$((V_MAJOR + 1)).0.0-alpha.0"
		BUMP_MSG="chore: start next cycle: $NEXT"
		;;
	skip-prerelease-number)
		require_prerelease
		NEXT="$base-$V_TYPE.$((V_NUM + 1))"
		BUMP_MSG="chore: bump prerelease: $CURRENT -> $NEXT"
		;;
	esac
	# The next VERSION must be one this script accepts, or the run after this one is stuck.
	check_bounds "$NEXT" "VERSION $CURRENT would become $NEXT, which the next run refuses"
}

# ── Checks (all of them read only) ────────────────────────────────────────

guard() {
	case " $ACTIONS " in
	*" $RELEASE_ACTION "*) ;;
	*) die "Unknown action '$RELEASE_ACTION'. Pick one of: $ACTIONS." ;;
	esac
	case "$DRY_RUN" in
	0 | 1) ;;
	*) die "DRY_RUN must be 0 or 1, got '$DRY_RUN'." ;;
	esac
	[ "$RELEASE_REF_TYPE" = branch ] \
		|| die "Release runs from a branch, not from the $RELEASE_REF_TYPE '$RELEASE_BRANCH'. Pick $DEFAULT_BRANCH in 'Use workflow from'."
	[ -n "$RELEASE_BRANCH" ] || die "No branch to release: RELEASE_BRANCH is empty."
	if [ "$RELEASE_BRANCH" != "$DEFAULT_BRANCH" ]; then
		[ "$DRY_RUN" = 1 ] \
			|| die "A release runs only from $DEFAULT_BRANCH, not from '$RELEASE_BRANCH'. Tick 'Dry run' to preview from here."
		log_warn "Dry run from '$RELEASE_BRANCH': a real run is refused on this branch."
	fi
}

# check_tag_absent <tag> [hint]
check_tag_absent() {
	local tag="$1" hint="${2:-}" remote
	if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
		die "Tag $tag already exists in this checkout.${hint:+ $hint}"
	fi
	remote=$(git ls-remote --tags "$REMOTE" "refs/tags/$tag") || die "Could not list the tags on $REMOTE."
	[ -z "$remote" ] || die "Tag $tag already exists on $REMOTE.${hint:+ $hint}"
}

# check_branch_free <branch>: no branch of that name on the remote and no open pull request from it.
check_branch_free() {
	local open
	[ -z "$(git ls-remote --heads "$REMOTE" "refs/heads/$1")" ] \
		|| die "The branch $1 exists on $REMOTE: a release was started and not finished. Look at its pull request, then delete the branch."
	open=$(gh pr list --head "$1" --state open --json number --jq length) || die "Could not list the open pull requests."
	[ "$open" = 0 ] || die "There is an open pull request from $1. Finish or close it first."
}

# check_tip: the dispatched commit is the tip of the default branch, so the release is cut from it.
check_tip() {
	local head tip
	git fetch --quiet --no-tags "$REMOTE" "refs/heads/$DEFAULT_BRANCH" || die "Could not fetch $DEFAULT_BRANCH from $REMOTE."
	head=$(git rev-parse HEAD)
	tip=$(git rev-parse FETCH_HEAD)
	[ "$head" = "$tip" ] \
		|| die "HEAD ($head) is not the tip of $DEFAULT_BRANCH on $REMOTE ($tip): the branch moved after this run started. Start the release again."
}

# check_cut_section_tagged: the newest section of CHANGELOG.md must have its tag (design note U6). A
# release that merged and was never tagged leaves a section for a tag that does not exist, and the
# next release must not build on it.
check_cut_section_tagged() {
	local ver
	[ -f "$CHANGELOG_FILE" ] || return 0
	# The second sed reads to the end: a reader that quits early would break the first one with SIGPIPE
	# on a long file, and pipefail would turn that into a failed assignment.
	ver=$(sed -n 's/^## \[\([0-9][^]]*\)\] - .*/\1/p' "$CHANGELOG_FILE" | sed -n 1p)
	[ -n "$ver" ] || return 0
	git rev-parse -q --verify "refs/tags/v$ver" >/dev/null && return 0
	[ -z "$(git ls-remote --tags "$REMOTE" "refs/tags/v$ver")" ] || return 0
	die "CHANGELOG.md has a section for $ver but no tag v$ver exists: a release merged and was never tagged. Repair: revert its commit 'release: v$ver' in a pull request (it restores the fragments and removes the section); VERSION stays, and the skipped number is never released."
}

# changelog_preview: the notes a tagging action would publish; exit 3 when no fragment is left.
changelog_preview() {
	local rc=0
	NOTES=$(bash "$ASSEMBLE") || rc=$?
	case "$rc" in
	0) ;;
	3) die "No changelog fragment is left in changelog.d/ for $TAG: a release with empty notes is refused." 3 ;;
	*) die "changelog.d/ is invalid (the output above names the fragment)." ;;
	esac
	[ -z "${RELEASE_NOTES_FILE:-}" ] || printf '%s\n' "$NOTES" >"$RELEASE_NOTES_FILE"
}

# read_queue: sets QUEUE (true when the default branch has a merge queue), which picks the merge route.
read_queue() {
	QUEUE=$(gh api "repos/$GITHUB_REPOSITORY/rules/branches/$DEFAULT_BRANCH" --jq 'any(.[]; .type == "merge_queue")') \
		|| die "Could not read the merge queue rule of $DEFAULT_BRANCH: the merge route is unknown."
}

summary() {
	local title="Release" route="auto-merge, rebase"
	[ "$DRY_RUN" != 1 ] || title="Dry run: nothing is committed, pushed or tagged"
	[ "$QUEUE" != true ] || route="auto-merge into the merge queue"
	printf '\n%s\n' "$title"
	printf '  %-15s %s\n' "Branch:" "$RELEASE_BRANCH" "Action:" "$RELEASE_ACTION" "VERSION now:" "$CURRENT" \
		"Tag:" "${TAG:-none}" "VERSION after:" "$NEXT" "Release branch:" "$RELEASE_PR_BRANCH" "Merge route:" "$route"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '### %s\n\n- Action: %s\n- VERSION: %s to %s\n- Tag: %s\n- Merge route: %s\n' \
			"$title" "$RELEASE_ACTION" "$CURRENT" "$NEXT" "${TAG:-none}" "$route" >>"$GITHUB_STEP_SUMMARY"
	fi
}

# ── The real run ──────────────────────────────────────────────────────────

write_version() { printf '%s\n' "$1" >"$VERSION_FILE"; }

commit_version() {
	write_version "$1"
	git add "$VERSION_FILE"
	git commit --quiet -m "$2"
	log_ok "Committed: $2"
}

# cut_branch: the release branch with commit A (a tagging action) and commit B.
cut_branch() {
	git config user.name "ginsys-release-bot"
	git config user.email "ginsys-release-bot@users.noreply.github.com"
	git switch --quiet -c "$RELEASE_PR_BRANCH"
	if [ -n "$TAG" ]; then
		[ "$TAG" = "$CURRENT" ] || write_version "$TAG"
		bash "$ASSEMBLE" --write "${TAG#v}"
		git add "$VERSION_FILE" "$CHANGELOG_FILE"
		git commit --quiet -m "release: $TAG"
		A_TREE=$(git rev-parse 'HEAD^{tree}')
		log_ok "Committed: release: $TAG"
	fi
	commit_version "$NEXT" "$BUMP_MSG"
	B_TREE=$(git rev-parse 'HEAD^{tree}')
}

# parent_of <commit>: its one parent, or nothing when it has none or several.
parent_of() {
	local row
	row=$(git rev-list --parents -n 1 "$1")
	[ "$(printf '%s\n' "$row" | wc -w)" = 2 ] && printf '%s\n' "${row#* }"
	return 0
}

# verify_merged <merged oid> <the tip it was cut from>: sets RELEASED to the commit the tag names. A
# rebase merge replays the commits onto the tip, so A' and B' must be single-parent commits on the tip
# this run cut from, and their trees must be the trees this run built: a tag is permanent, and it
# names code nobody else may have changed on the way.
verify_merged() {
	local merged=$1 from=$2 a="$1"
	git fetch --quiet --no-tags "$REMOTE" "refs/heads/$DEFAULT_BRANCH" || die "Could not fetch $DEFAULT_BRANCH from $REMOTE."
	[ -z "$TAG" ] || a=$(parent_of "$merged")
	if [ -z "$a" ] || [ "$(parent_of "$a")" != "$from" ]; then
		die "The release commit is not on the tip $from it was cut from: another change merged first, and its code would ship in this tag with no line in its notes, so no tag was made. See docs/release.md, 'A run that was interrupted'."
	fi
	if [ "$(git rev-parse "$merged^{tree}")" != "$B_TREE" ] \
		|| { [ -n "$TAG" ] && { [ "$(git rev-parse "$a^{tree}")" != "$A_TREE" ] || [ "$(git log -1 --format=%s "$a")" != "release: $TAG" ]; }; }; then
		die "The merged commits are not the release commits this run built (a tree or a subject differs from the ones it pushed), so no tag was made."
	fi
	RELEASED=$a
}

create_tag() {
	local i cmd="gh api -X POST repos/$GITHUB_REPOSITORY/git/refs -f ref=refs/tags/$TAG -f sha=$RELEASED"
	for i in 1 2 3; do
		if GH_TOKEN="${TAG_TOKEN:-${GH_TOKEN:-}}" gh api -X POST "repos/$GITHUB_REPOSITORY/git/refs" \
			-f ref="refs/tags/$TAG" -f sha="$RELEASED" >/dev/null; then
			log_ok "Tag $TAG is on $RELEASED"
			return
		fi
		log_warn "Creating the tag failed ($i/3)"
		sleep "${TAG_RETRY_SLEEP:-10}"
	done
	die "The release is on $DEFAULT_BRANCH as $RELEASED but the tag could not be made. With the owner's word, run: $cmd"
}

real_run() {
	local from body url pr merged title="$BUMP_MSG"
	[ -z "$(git status --porcelain --untracked-files=no)" ] || die "The working tree has uncommitted changes."
	from=$(git rev-parse HEAD)
	cut_branch
	git push --quiet "$REMOTE" "HEAD:refs/heads/$RELEASE_PR_BRANCH" || die "Could not push $RELEASE_PR_BRANCH."
	body=$(mktemp)
	if [ -n "$TAG" ]; then
		title="release: $TAG"
		printf '%s\n' "$NOTES" >"$body"
	else
		printf 'Moves VERSION to %s.\n' "$NEXT" >"$body"
	fi
	url=$(gh pr create --base "$DEFAULT_BRANCH" --head "$RELEASE_PR_BRANCH" --title "$title" --body-file "$body") \
		|| die "Could not open the pull request. The branch $RELEASE_PR_BRANCH is pushed."
	rm -f "$body"
	pr=${url##*/}
	log_ok "Opened pull request #$pr"
	if [ "$QUEUE" = true ]; then
		gh pr merge "$pr" --auto || die "Could not turn on merge for #$pr."
	else
		gh pr merge "$pr" --auto --rebase || die "Could not turn on auto-merge for #$pr."
	fi
	merged=$(bash "$WAIT" "$pr" "$from" "$RELEASE_PR_BRANCH")
	verify_merged "$merged" "$from"
	[ -z "$TAG" ] || create_tag
	set_output tag "$TAG"
	set_output version "${TAG#v}"
	set_output sha "$RELEASED"
	log_ok "Release ${TAG:-$NEXT} complete."
}

main() {
	local check=0
	case "${1:-}" in
	--check) check=1 ;;
	"") ;;
	*) die "Usage: release.sh [--check] (the action comes from RELEASE_ACTION)" ;;
	esac
	if [ -z "$RELEASE_BRANCH" ]; then
		RELEASE_BRANCH=$(git symbolic-ref --quiet --short HEAD) \
			|| die "HEAD is detached: set RELEASE_BRANCH to the branch being released."
	fi
	guard
	[ "$check" = 1 ] || [ "$DRY_RUN" = 0 ] || die "A real run needs DRY_RUN=0; release.sh --check is the preview."

	[ -f "$VERSION_FILE" ] || die "No $VERSION_FILE file at the repository root"
	CURRENT=$(tr -d '[:space:]' <"$VERSION_FILE")
	parse_version "$CURRENT"
	plan_action
	RELEASE_PR_BRANCH="release/${TAG:-$NEXT}"

	[ -z "$TAG" ] || check_tag_absent "$TAG" "If it was released already, skip-prerelease-number moves VERSION past it."
	check_tag_absent "$NEXT"
	check_branch_free "$RELEASE_PR_BRANCH"
	[ "$RELEASE_BRANCH" != "$DEFAULT_BRANCH" ] || check_tip
	check_cut_section_tagged
	[ -z "$TAG" ] || changelog_preview
	read_queue
	summary
	[ -z "$NOTES" ] || [ -z "$TAG" ] || printf '\nChangelog section for %s:\n\n%s\n\n' "$TAG" "$NOTES"
	set_output tag "$TAG"
	set_output version "${TAG#v}"
	set_output next_version "$NEXT"
	set_output queue "$QUEUE"
	set_output changelog_date "$CHANGELOG_DATE"
	if [ "$check" = 1 ]; then
		log_ok "Checks passed: a real run would release ${TAG:-$NEXT} through $RELEASE_PR_BRANCH."
		return
	fi
	real_run
}

NOTES=""
A_TREE=""
B_TREE=""
main "$@"
