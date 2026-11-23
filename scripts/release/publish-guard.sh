#!/usr/bin/env bash
# publish-guard.sh — the checks and text work of publish-github.yml (docs/release.md, "The publish workflow").
#
# Usage:
#   publish-guard.sh absent <tag>                  the tag has no release yet
#   publish-guard.sh tagged <tag> <sha>            the tag in the repository names the commit <sha>
#   publish-guard.sh notes <notes> <footer> <out> [<changelog url>]
#                                                  write the release notes: <notes>, then <footer>; a body over
#                                                  BODY_MAX bytes links <changelog url> in place of the notes
#   publish-guard.sh prerelease <tag>              exit 0 for a pre-release tag, 1 for a stable one
#
# `absent` and `tagged` call `gh api` for $GITHUB_REPOSITORY and need GH_TOKEN. A tag is vMAJOR.MINOR.PATCH,
# optionally followed by -<pre-release part>; anything else is refused before it reaches a command.

set -euo pipefail

stable_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
pre_re='^v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.]+$'

error() { echo "::error::$*" >&2; }

need_tag() {
	if ! [[ $1 =~ $stable_re || $1 =~ $pre_re ]]; then
		error "'$1' is not a version tag (vMAJOR.MINOR.PATCH, optionally with a pre-release part)."
		exit 1
	fi
}

# Three outcomes: 404 is "none", success is "refuse", anything else is "cannot tell" and also refuses.
# This runs before anything is built, so that a re-run of a half-published release stops here.
cmd_absent() {
	local tag=$1 rc=0 err
	need_tag "$tag"
	err=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag" 2>&1 >/dev/null) || rc=$?
	case "$rc:$err" in
	*"(HTTP 404)"*) echo "No release exists for $tag." ;;
	0:*)
		error "$tag already has a release; nothing is published over it."
		exit 1
		;;
	*)
		error "could not read whether $tag has a release: $err"
		exit 1
		;;
	esac
}

# The tag's object, read through the API (a checkout would need the token kept in its git config).
# An annotated tag is peeled once; a tag of a tag is not followed.
tag_object() {
	local got
	got=$(gh api "repos/$GITHUB_REPOSITORY/git/$1" --jq '.object.type + " " + .object.sha' 2>&1) || {
		error "could not read $1: $got"
		exit 1
	}
	echo "$got"
}

cmd_tagged() {
	local tag=$1 sha=$2 got type obj
	need_tag "$tag"
	if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
		error "'$sha' is not a full commit SHA."
		exit 1
	fi
	# `|| exit 1`: tag_object runs in a command substitution, where its own exit ends only that subshell.
	got=$(tag_object "ref/tags/$tag") || exit 1
	read -r type obj <<<"$got"
	if [ "$type" = tag ]; then
		got=$(tag_object "tags/$obj") || exit 1
		read -r type obj <<<"$got"
	fi
	if [ "$type" != commit ]; then
		error "the tag $tag names a $type, not a commit."
		exit 1
	fi
	if [ "$obj" != "$sha" ]; then
		error "the tag $tag names $obj, not $sha."
		exit 1
	fi
	echo "The tag $tag names $sha."
}

# The notes are the release's changelog section; a release with none is a mistake. The footer is a fixed
# text of the caller's. A GitHub release body holds at most 125,000 characters, so a body over BODY_MAX
# bytes (bytes are never fewer than characters) puts a pointer to the section in CHANGELOG.md at the tag,
# whose URL the caller passes, in place of the notes. A body that is still too long fails.
BODY_MAX=120000
footer_block() { if [ -n "${1//[[:space:]]/}" ]; then printf '\n%s\n' "$1"; fi; }
cmd_notes() {
	local in=$1 footer=$2 out=$3 url=${4:-} size
	if [ ! -f "$in" ]; then
		error "the release notes $in are missing."
		exit 1
	fi
	if ! grep -q '[^[:space:]]' "$in"; then
		error "the release notes $in are empty."
		exit 1
	fi
	{
		cat "$in"
		if [ -n "$(tail -c 1 "$in")" ]; then echo; fi # the last line of the notes ends in a newline
		footer_block "$footer"
	} >"$out.new"
	size=$(wc -c <"$out.new")
	if [ "$size" -gt "$BODY_MAX" ]; then
		if [ -z "$url" ]; then
			rm -f "$out.new"
			error "the release body is $size bytes, over the $BODY_MAX a release can hold, and no CHANGELOG.md URL was given."
			exit 1
		fi
		{
			printf 'The notes of this release are too long for a GitHub release (%s bytes). They are its section in CHANGELOG.md:\n%s\n' "$size" "$url"
			footer_block "$footer"
		} >"$out.new"
		size=$(wc -c <"$out.new")
		if [ "$size" -gt "$BODY_MAX" ]; then
			rm -f "$out.new"
			error "the release body is $size bytes even with the notes replaced by a link: the footer is too long."
			exit 1
		fi
	fi
	mv "$out.new" "$out"
}

cmd_prerelease() {
	if [[ $1 =~ $pre_re ]]; then exit 0; fi
	if [[ $1 =~ $stable_re ]]; then exit 1; fi
	error "'$1' is not a version tag."
	exit 2
}

usage() {
	echo "usage: publish-guard.sh absent <tag> | tagged <tag> <sha> | notes <notes> <footer> <out> [<changelog url>] | prerelease <tag>" >&2
	exit 2
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd:$#" in
absent:1) cmd_absent "$@" ;;
tagged:2) cmd_tagged "$@" ;;
notes:3 | notes:4) cmd_notes "$@" ;;
prerelease:1) cmd_prerelease "$@" ;;
*) usage ;;
esac
