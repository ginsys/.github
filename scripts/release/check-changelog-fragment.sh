#!/usr/bin/env bash
# check-changelog-fragment.sh — a PR records its release note as a fragment.
#
# Compares HEAD with origin/<base> (three-dot, so only the PR's own changes) and
# prints one verdict:
#   SKIP  the head branch is a bot's (dependabot/, renovate/) or the release PR's
#         own (release/<tag>, made by release.sh), or the PR carries the label
#         no-changelog (CI, tests and docs-only changes); a skip lifts the need for
#         a fragment, not the validation of one the PR adds or edits, or of where it sits
#   PASS  the PR adds a valid changelog.d/<issue>-<slug>.md, leaves every fragment
#         it edits valid, and adds no line to CHANGELOG.md
#   FAIL  anything else, with what to do
#   ERROR the base ref is missing, or has no merge base with HEAD (a shallow checkout):
#         never read as "no fragment"
#
# Inputs (environment): BASE_REF (default main), HEAD_REF_NAME (the PR's head
# branch), PR_NO_CHANGELOG (the word true when the PR has the label no-changelog;
# the workflow sets it with contains() over the label list, an exact match).
# Exit codes: 0 PASS or SKIP, 1 FAIL, 2 ERROR. Format: docs/release.md.
#
# It works on the git repository of the current directory, and finds the assembler beside itself.
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
cd "$(git rev-parse --show-toplevel)"

base="origin/${BASE_REF:-main}"
head_ref=${HEAD_REF_NAME-}
no_changelog=${PR_NO_CHANGELOG-}

if ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then
	echo "ERROR $base not found: fetch it first (actions/checkout needs fetch-depth: 0)"
	exit 2
fi

skip_reason=
case "$head_ref" in
dependabot/* | renovate/*) skip_reason="bot branch $head_ref" ;;
release/*) skip_reason="release branch $head_ref" ;;
esac

if ! tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-changelog-fragment.XXXXXX"); then
	echo "ERROR no temporary directory: check that TMPDIR is writable"
	exit 2
fi
trap 'rm -rf "$tmp"' EXIT

# The diff goes to a file first, NUL-delimited: a failed diff (no merge base with the base ref) must
# be an ERROR and never an empty list, which a process substitution would hide, and a name with
# non-ASCII characters must reach the case below as it is, never as git's quoted form.
if ! git diff -z --name-status --no-renames "$base...HEAD" >"$tmp/changes"; then
	echo "ERROR git diff $base...HEAD failed: no merge base? fetch the full history (actions/checkout needs fetch-depth: 0)"
	exit 2
fi

added=()
modified=()
subdir=()
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
	case "$path" in
	changelog.d/README.md) continue ;;
	changelog.d/*/*.md) [ "$status" = A ] && subdir+=("$path") ;;
	changelog.d/*.md)
		[ "$status" = A ] && added+=("$path")
		[ "$status" = M ] && modified+=("$path")
		;;
	esac
done <"$tmp/changes"

# A fragment the PR adds or edits is read by the release, so both are validated, and so is where an
# added one sits, the skip or not. A deleted fragment is not read, so a release PR still passes.
fail=0
for p in ${added[@]+"${added[@]}"} ${modified[@]+"${modified[@]}"}; do
	if ! msg=$("$here/changelog-assemble.sh" --validate "$p" 2>&1); then
		echo "FAIL $msg"
		fail=1
	fi
done
for p in ${subdir[@]+"${subdir[@]}"}; do
	echo "FAIL $p is in a subdirectory: fragments sit directly in changelog.d/"
	fail=1
done

if [ -z "$skip_reason" ] && [ "$no_changelog" = true ]; then
	skip_reason="label no-changelog"
fi
if [ -n "$skip_reason" ]; then
	if [ "$fail" -ne 0 ]; then
		exit 1
	fi
	echo "SKIP $skip_reason"
	exit 0
fi

changelog_lines=$(git diff --no-renames -U0 "$base...HEAD" -- CHANGELOG.md |
	awk '/^\+\+\+ /{next} /^\+/{n++} END{print n+0}')

if [ "$changelog_lines" -gt 0 ]; then
	echo "FAIL CHANGELOG.md has $changelog_lines added line(s): put the entry in changelog.d/<issue>-<slug>.md instead"
	fail=1
fi
if [ "${#added[@]}" -eq 0 ]; then
	echo "FAIL no fragment added: add changelog.d/<issue>-<slug>.md, or label the PR no-changelog when it needs no entry"
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	exit 1
fi
if [ "${#modified[@]}" -gt 0 ]; then
	echo "PASS ${#added[@]} fragment(s) added, ${#modified[@]} modified"
else
	echo "PASS ${#added[@]} fragment(s) added"
fi
