#!/usr/bin/env bash
# changelog-assemble.sh — turn changelog fragments into CHANGELOG.md text.
#
# Each change adds one file, changelog.d/<n>-<slug>.md, so two PRs never edit the
# same CHANGELOG.md lines (format: docs/release.md, "Changelog fragments").
#
#   changelog-assemble.sh                   print the body of the section a release would
#                                           cut (the lines under "## [Unreleased]", then
#                                           the fragment sections), change nothing
#   changelog-assemble.sh --validate FILE…  check fragment files, change nothing
#   changelog-assemble.sh --write VERSION   cut a release: keep every line under
#                                           "## [Unreleased]", add the fragment sections
#                                           after them, give the block the heading
#                                           "## [VERSION] - <date>", leave an empty
#                                           "## [Unreleased]" above it and delete the
#                                           fragments (git rm where tracked)
#
# The preview and the write build the new CHANGELOG.md text with one function, and the preview is
# the body of that very section: the release notes and the cut section cannot differ.
#
# It works on the git repository of the current directory, never on the checkout it was read from:
# a reusable workflow runs it from a copy of ginsys/.github placed beside the caller's tree.
#
# Exit codes: 0 done, 2 a fragment, argument or CHANGELOG.md is invalid (nothing is
# written), 3 there are no fragments.
# CHANGELOG_DATE=YYYY-MM-DD overrides today's date, so a caller that read the date once keeps it.
set -euo pipefail
# The C locale: [a-z] in the name rule must not match an accented letter, and sort -V must order the
# same on every runner.
export LC_ALL=C

SECTIONS="Added Changed Deprecated Removed Fixed Security"
NAME_RE='^[0-9]+-[a-z0-9][a-z0-9-]*\.md$'
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$'
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

FRAG_DIR=changelog.d
CHANGELOG=CHANGELOG.md

usage() {
	echo "usage: changelog-assemble.sh [--validate FILE… | --write VERSION]" >&2
	exit 2
}

is_section() {
	local s
	for s in $SECTIONS; do
		[ "$s" = "$1" ] && return 0
	done
	return 1
}

# validate_file <path>: print one ERROR line and return 1 when the fragment is invalid.
validate_file() {
	local path=$1 base section verdict
	base=$(basename "$path")
	if ! [[ $base =~ $NAME_RE ]]; then
		echo "ERROR $path: the name must be <issue>-<slug>.md: digits, a dash, then lowercase letters, digits and dashes" >&2
		return 1
	fi
	section=
	IFS= read -r section <"$path" || true
	if ! is_section "$section"; then
		echo "ERROR $path: line 1 must be one of: $SECTIONS (got '$section')" >&2
		return 1
	fi
	verdict=$(awk '
		NR == 1 { next }
		!seen && $0 ~ /^[[:space:]]*$/ { next }
		{
			if (!seen) { seen = 1; if ($0 !~ /^- /) bad = "the entry must start with \"- \"" }
			else if ($0 ~ /^- /) multi = 1
			else if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^  /) cont = 1
		}
		END {
			if (!seen) print "the entry is empty"
			else if (bad != "") print bad
			else if (multi) print "one entry per file: a second line starts with \"- \""
			else if (cont) print "every line after the first must be blank or indented two spaces"
		}' "$path")
	if [ -n "$verdict" ]; then
		echo "ERROR $path: $verdict" >&2
		return 1
	fi
	return 0
}

# body <path>: the entry, without the section line and without blank lines around it.
body() {
	awk '
		NR == 1 { next }
		{ lines[++n] = $0 }
		END {
			s = 1
			while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
			e = n
			while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
			for (i = s; i <= e; i++) print lines[i]
		}' "$1"
}

# new_changelog <version> <date> <generated file>: the whole new CHANGELOG.md on stdout.
# The one place the cut section is built, for the preview and for the write.
new_changelog() {
	awk -v ver="$1" -v date="$2" -v gen="$3" '
		function flush(tail,   i, line) {
			for (i = 1; i <= n; i++) print buf[i]
			if (n == 0 || buf[n] != "") print ""
			while ((getline line < gen) > 0) print line
			close(gen)
			if (tail) print ""
		}
		state == 0 {
			print
			if ($0 == "## [Unreleased]") { print ""; print "## [" ver "] - " date; state = 1; n = 0 }
			next
		}
		state == 1 {
			if ($0 ~ /^## \[/) { flush(1); state = 2; print; next }
			buf[++n] = $0
			next
		}
		{ print }
		END { if (state == 1) flush(0) }
	' "$CHANGELOG"
}

# section_body <file> <version>: the lines of the cut section, blank lines trimmed at both ends.
section_body() {
	awk -v ver="$2" '
		inside && /^## \[/ { exit }
		inside { l[++n] = $0 }
		index($0, "## [" ver "] - ") == 1 { inside = 1 }
		END {
			s = 1; while (s <= n && l[s] ~ /^[[:space:]]*$/) s++
			e = n; while (e >= s && l[e] ~ /^[[:space:]]*$/) e--
			for (i = s; i <= e; i++) print l[i]
		}' "$1"
}

mode=preview
version=
case "${1-}" in
--validate)
	shift
	[ "$#" -gt 0 ] || usage
	rc=0
	for f in "$@"; do
		validate_file "$f" || rc=2
	done
	exit "$rc"
	;;
--write)
	[ "$#" -eq 2 ] || usage
	version=$2
	[[ $version =~ $VERSION_RE ]] || {
		echo "ERROR the version '$version' must look like 1.2.3 or 1.2.3-rc.1" >&2
		exit 2
	}
	mode="write"
	;;
"")
	;;
*)
	usage
	;;
esac
[ "$#" -le 2 ] || usage

ROOT=$(git rev-parse --show-toplevel) || {
	echo "ERROR not inside a git repository" >&2
	exit 2
}
cd "$ROOT"

names=()
while IFS= read -r n; do
	[ -n "$n" ] && names+=("$n")
done < <(
	for f in "$FRAG_DIR"/*.md; do
		[ -e "$f" ] || continue
		[ "$(basename "$f")" = README.md ] && continue
		basename "$f"
	done | sort -V
)

if [ "${#names[@]}" -eq 0 ]; then
	echo "no fragments in $FRAG_DIR/" >&2
	exit 3
fi

invalid=0
for n in "${names[@]}"; do
	validate_file "$FRAG_DIR/$n" || invalid=1
done
[ "$invalid" -eq 0 ] || exit 2

if ! grep -qx '## \[Unreleased\]' "$CHANGELOG" 2>/dev/null; then
	echo "ERROR $CHANGELOG has no '## [Unreleased]' line" >&2
	exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/changelog-assemble.XXXXXX")
next=
trap 'rm -rf "$tmp"; [ -z "$next" ] || rm -f "$next"' EXIT

gen=$tmp/generated
: >"$gen"
first=1
for s in $SECTIONS; do
	have=0
	for n in "${names[@]}"; do
		sec=
		IFS= read -r sec <"$FRAG_DIR/$n" || true
		[ "$sec" = "$s" ] || continue
		if [ "$have" -eq 0 ]; then
			[ "$first" -eq 1 ] || echo >>"$gen"
			echo "### $s" >>"$gen"
			have=1
			first=0
		fi
		body "$FRAG_DIR/$n" >>"$gen"
	done
done

if [ "$mode" = preview ]; then
	# The heading is a placeholder: only the body of the section is printed.
	new_changelog preview 0000-00-00 "$gen" >"$tmp/new"
	section_body "$tmp/new" preview
	exit 0
fi

date=${CHANGELOG_DATE:-$(date +%F)}
# The shape, then the calendar: 2026-02-31 has the shape and is no date.
# Read under UTC: in a zone that skipped local midnight on that day (a daylight-saving jump), date -d
# refuses a day that exists.
if ! [[ $date =~ $DATE_RE ]] || [ "$(TZ=UTC date -d "$date" +%F 2>/dev/null)" != "$date" ]; then
	echo "ERROR CHANGELOG_DATE '$date' must be a real date, YYYY-MM-DD" >&2
	exit 2
fi

new_changelog "$version" "$date" "$gen" >"$tmp/new"

# Write beside CHANGELOG.md, then rename over it: a failed or interrupted write leaves the original
# whole, and no fragment is touched before the rename succeeds. The tracked fragments then go in one
# "git rm", which takes the index lock before it removes anything. When it fails (a locked index),
# CHANGELOG.md is put back and every fragment is as it was: a retry would otherwise cut the same
# entries twice.
next=$(mktemp "$ROOT/$CHANGELOG.XXXXXX")
cp -p "$CHANGELOG" "$next"
cat "$tmp/new" >"$next"
tracked=()
loose=()
for n in "${names[@]}"; do
	if git ls-files --error-unmatch -- "$FRAG_DIR/$n" >/dev/null 2>&1; then
		tracked+=("$FRAG_DIR/$n")
	else
		loose+=("$FRAG_DIR/$n")
	fi
done
cp -p "$CHANGELOG" "$tmp/original"
mv -f "$next" "$CHANGELOG"
next=
if [ "${#tracked[@]}" -gt 0 ] && ! git rm -q -f -- "${tracked[@]}"; then
	next=$(mktemp "$ROOT/$CHANGELOG.XXXXXX")
	cp -p "$tmp/original" "$next"
	mv -f "$next" "$CHANGELOG"
	next=
	echo "ERROR git rm failed (a locked index?): $CHANGELOG restored, no fragment removed" >&2
	exit 1
fi
if [ "${#loose[@]}" -gt 0 ]; then
	rm -f -- "${loose[@]}"
fi
echo "wrote $CHANGELOG: ## [$version] - $date from ${#names[@]} fragment(s); fragments removed"
