#!/usr/bin/env bash
# publish-guard.sh — the checks and text work of publish-github.yml (docs/release.md, "The publish workflow").
#
# Usage:
#   publish-guard.sh absent <tag>                  the tag has no release yet
#   publish-guard.sh tagged <tag> <sha>            the tag in the repository names the commit <sha>
#   publish-guard.sh notes <notes> <footer> <out>  write the release notes: <notes>, then <footer>
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
	local tag=$1 sha=$2 type obj
	need_tag "$tag"
	if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
		error "'$sha' is not a full commit SHA."
		exit 1
	fi
	read -r type obj <<<"$(tag_object "ref/tags/$tag")"
	if [ "$type" = tag ]; then
		read -r type obj <<<"$(tag_object "tags/$obj")"
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
# text of the caller's.
cmd_notes() {
	local in=$1 footer=$2 out=$3
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
		if [ -n "${footer//[[:space:]]/}" ]; then printf '\n%s\n' "$footer"; fi
	} >"$out.new"
	mv "$out.new" "$out"
}

cmd_prerelease() {
	if [[ $1 =~ $pre_re ]]; then exit 0; fi
	if [[ $1 =~ $stable_re ]]; then exit 1; fi
	error "'$1' is not a version tag."
	exit 2
}

usage() {
	echo "usage: publish-guard.sh absent <tag> | tagged <tag> <sha> | notes <notes> <footer> <out> | prerelease <tag>" >&2
	exit 2
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd:$#" in
absent:1) cmd_absent "$@" ;;
tagged:2) cmd_tagged "$@" ;;
notes:3) cmd_notes "$@" ;;
prerelease:1) cmd_prerelease "$@" ;;
*) usage ;;
esac
