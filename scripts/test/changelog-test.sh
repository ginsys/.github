#!/usr/bin/env bash
# changelog-test.sh — fixture tests for scripts/release/changelog-assemble.sh and
# scripts/release/check-changelog-fragment.sh.
#
# Every case builds a throw-away git repository and runs the scripts against it from OUTSIDE it:
# the scripts live in this repository and are checked out beside the caller's tree by the reusable
# workflows, so they must work on the current directory's repository and never on their own
# location. Exit 0 only if every case passed; a failing case prints what it expected and what it got.
#
# Usage: changelog-test.sh [REPO_ROOT]

set -u

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
TOOLS="$ROOT/scripts/release"
ASSEMBLE="$TOOLS/changelog-assemble.sh"
CHECK="$TOOLS/check-changelog-fragment.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/changelog-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
N=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() {
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
	shift
	printf '     %s\n' "$@"
}

# eq <name> <expected> <actual>
eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi
}

# has <name> <needle> <haystack>
has() {
	case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain: $2" "actual: $3" ;; esac
}

# git in a fixture, with a fixed identity and no signing.
fxgit() {
	git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
		-c core.hooksPath=/dev/null "$@"
}

# newfx <name>: a repository on branch main with a CHANGELOG and changelog.d/README.md, and
# refs/remotes/origin/main pointing at main. The scripts are not copied in.
newfx() {
	N=$((N + 1))
	FX="$T/$N-$1"
	mkdir -p "$FX/changelog.d"
	cat >"$FX/CHANGELOG.md" <<'EOF'
# Changelog

Intro line.

## [Unreleased]

### Added
- Legacy entry one.
  Second line of it. Refs owner/repo#1.

### Added
- A repeated heading, as a real file has. Refs owner/repo#2.

### Fixed
- Legacy fix. Fixes owner/repo#3.

## [0.5.4] - 2024-01-15

### Added
- Old release entry.
EOF
	printf 'Format notes.\n' >"$FX/changelog.d/README.md"
	(
		cd "$FX" || exit 1
		fxgit init -q -b main .
		fxgit add -A
		fxgit commit -q -m base
		fxgit update-ref refs/remotes/origin/main main
	) >/dev/null 2>&1
}

# newfx_empty <name>: as newfx, with nothing under [Unreleased].
newfx_empty() {
	newfx "$1"
	cat >"$FX/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.5.4] - 2024-01-15

### Added
- Old release entry.
EOF
	(cd "$FX" && fxgit add -A && fxgit commit -q -m empty-unreleased && fxgit update-ref refs/remotes/origin/main main) >/dev/null 2>&1
}

# frag <file> <section> <bullet text...>: write a fragment in the fixture.
frag() {
	local f=$1 section=$2
	shift 2
	printf '%s\n%s\n' "$section" "$*" >"$FX/changelog.d/$f"
}

# run <cmd...>: run in the fixture, set OUT (stdout+stderr) and RC.
run() {
	OUT=$(cd "$FX" && "$@" 2>&1)
	RC=$?
}

# nfrags: how many fragment files (every changelog.d/*.md but README.md) the fixture holds.
nfrags() {
	local n=0 f
	for f in "$FX"/changelog.d/*.md; do
		[ -e "$f" ] || continue
		[ "$(basename "$f")" = README.md ] && continue
		n=$((n + 1))
	done
	echo "$n"
}

# section_body <file> <version>: the body of the cut section, written independently of the script
# (sed), blank lines trimmed at both ends. The heading is "## [<version>] - <date>".
section_body() {
	sed -n "/^## \[$2\] - /,/^## \[/p" "$1" | sed '1d' | sed '$d' |
		awk '{ l[NR] = $0 } END {
			s = 1; while (s <= NR && l[s] ~ /^[[:space:]]*$/) s++
			e = NR; while (e >= s && l[e] ~ /^[[:space:]]*$/) e--
			for (i = s; i <= e; i++) print l[i] }'
}

# ---------------------------------------------------------------- assemble

newfx order
frag 12-b.md Fixed '- Fix b. Fixes owner/repo#12.'
frag 3-a.md Added '- Add a. Refs owner/repo#3.'
frag 12-a.md Fixed '- Fix a. Fixes owner/repo#12.'
frag 7-x.md Changed '- Change x. Refs owner/repo#7.'
frag 3-z.md Fixed '- Fix z. Fixes owner/repo#3.'
run bash "$ASSEMBLE"
EXPECT='### Added
- Legacy entry one.
  Second line of it. Refs owner/repo#1.

### Added
- A repeated heading, as a real file has. Refs owner/repo#2.

### Fixed
- Legacy fix. Fixes owner/repo#3.

### Added
- Add a. Refs owner/repo#3.

### Changed
- Change x. Refs owner/repo#7.

### Fixed
- Fix z. Fixes owner/repo#3.
- Fix a. Fixes owner/repo#12.
- Fix b. Fixes owner/repo#12.'
eq "preview: the carried [Unreleased] lines first, then the sections in fixed order, files by number (sort -V)" "$EXPECT" "$OUT"
eq "preview: exit 0" 0 "$RC"
eq "preview: CHANGELOG.md untouched" "" "$(cd "$FX" && fxgit status --porcelain -- CHANGELOG.md)"
eq "preview: fragments still there" 5 "$(nfrags)"

newfx_empty order-empty
frag 12-b.md Fixed '- Fix b. Fixes owner/repo#12.'
frag 3-a.md Added '- Add a. Refs owner/repo#3.'
run bash "$ASSEMBLE"
eq "preview with an empty [Unreleased]: the fragment sections only" '### Added
- Add a. Refs owner/repo#3.

### Fixed
- Fix b. Fixes owner/repo#12.' "$OUT"

# section_raw <file> <version>: every line between the cut section's heading and the next heading,
# untrimmed, for the layout check below.
section_raw() {
	sed -n "/^## \[$2\] - /,/^## \[/p" "$1" | sed '1d' | sed '$d'
}

# The preview is the notes of a release, the written section is its CHANGELOG entry: one body, two
# readers. For the same input the preview must equal the section --write cuts line for line, and
# the file must hold that section with exactly one blank line before it and one after it, so the
# trimmed comparison cannot hide a blank line the file keeps and the preview drops.
check_equal() { # <case name>, in the current fixture
	local name=$1 preview body
	run bash "$ASSEMBLE"
	preview=$OUT
	[ "$RC" -eq 0 ] || { bad "$name: the preview ran" "exit $RC: $OUT"; return; }
	run env CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
	[ "$RC" -eq 0 ] || { bad "$name: the write ran" "exit $RC: $OUT"; return; }
	body=$(section_body "$FX/CHANGELOG.md" 1.2.3)
	eq "preview equals the written section: $name" "$body" "$preview"
	printf '\n%s\n\n' "$preview" >"$T/layout.want"
	section_raw "$FX/CHANGELOG.md" 1.2.3 >"$T/layout.got"
	if cmp -s "$T/layout.want" "$T/layout.got"; then
		ok "the written section is the preview with one blank line each side: $name"
	else
		bad "the written section is the preview with one blank line each side: $name" "$(diff "$T/layout.want" "$T/layout.got")"
	fi
}

newfx_empty equal-one
frag 3-a.md Added '- Add a. Refs owner/repo#3.'
check_equal "one fragment"

newfx_empty equal-several
frag 3-a.md Added '- Add a. Refs owner/repo#3.'
frag 12-a.md Fixed '- Fix a. Fixes owner/repo#12.'
frag 12-b.md Fixed '- Fix b. Fixes owner/repo#12.'
frag 7-x.md Changed '- Change x. Refs owner/repo#7.'
check_equal "several fragments"

for kind in Added Changed Deprecated Removed Fixed Security; do
	newfx_empty "equal-$kind"
	frag 5-k.md "$kind" "- A $kind entry. Refs owner/repo#5."
	check_equal "heading kind $kind"
done

newfx equal-carried
frag 3-a.md Added '- Add a. Refs owner/repo#3.'
frag 12-a.md Fixed '- Fix a. Fixes owner/repo#12.'
check_equal "fragments plus carried [Unreleased] lines"

newfx_empty equal-wrapped
printf 'Fixed\n- One entry,\n  wrapped onto a second line.\n\n  And a second paragraph. Fixes owner/repo#9.\n' >"$FX/changelog.d/9-wrap.md"
frag 10-b.md Added '- Plain. Refs owner/repo#10.'
check_equal "entries wrapped onto indented lines"

newfx unknown-section
frag 5-a.md Fixed '- Good one.'
frag 6-b.md Feature '- Bad section.'
run bash "$ASSEMBLE" --write 1.2.3
eq "unknown section: exit 2" 2 "$RC"
has "unknown section: names the file" "6-b.md" "$OUT"
eq "unknown section: nothing written" "" "$(cd "$FX" && fxgit status --porcelain -- CHANGELOG.md)"
eq "unknown section: no fragment removed" 2 "$(nfrags)"

for badname in 'Fix-thing.md' 'abc.md' '12.md' '12-Foo.md' '12-a_b.md' '12-é.md'; do
	newfx badname
	printf 'Fixed\n- text.\n' >"$FX/changelog.d/$badname"
	run bash "$ASSEMBLE"
	eq "bad file name $badname: exit 2" 2 "$RC"
done

newfx empty-body
printf 'Fixed\n' >"$FX/changelog.d/9-empty.md"
run bash "$ASSEMBLE"
eq "empty body: exit 2" 2 "$RC"

newfx not-a-bullet
printf 'Fixed\nplain text, no bullet\n' >"$FX/changelog.d/9-plain.md"
run bash "$ASSEMBLE"
eq "body that is not a bullet: exit 2" 2 "$RC"

newfx two-bullets
printf 'Fixed\n- one.\n- two.\n' >"$FX/changelog.d/9-two.md"
run bash "$ASSEMBLE"
eq "two bullets in one file: exit 2" 2 "$RC"

newfx star-bullet
printf 'Fixed\n- one.\n* two.\n' >"$FX/changelog.d/9-star.md"
run bash "$ASSEMBLE"
eq "a second bullet written with * : exit 2" 2 "$RC"

newfx heading-line
printf 'Fixed\n- one.\n## [9.9.9] - 2030-01-01\n' >"$FX/changelog.d/9-heading.md"
run bash "$ASSEMBLE"
eq "an unindented heading line in the body: exit 2" 2 "$RC"
has "heading line: the error names the file" "9-heading.md" "$OUT"

newfx continuation
printf 'Fixed\n- one,\n  continued.\n\n  A second paragraph. Fixes owner/repo#9.\n' >"$FX/changelog.d/9-cont.md"
run bash "$ASSEMBLE"
eq "indented continuation lines and an indented paragraph pass: exit 0" 0 "$RC"

newfx none
run bash "$ASSEMBLE"
eq "no fragments, preview: exit 3" 3 "$RC"
run bash "$ASSEMBLE" --write 1.2.3
eq "no fragments, write: exit 3" 3 "$RC"

newfx no-unreleased
printf '# Changelog\n\n## [0.5.4] - 2024-01-15\n' >"$FX/CHANGELOG.md"
frag 3-a.md Added '- Add a.'
run bash "$ASSEMBLE"
eq "preview: a CHANGELOG.md with no [Unreleased] line is refused (exit 2)" 2 "$RC"
run bash "$ASSEMBLE" --write 1.2.3
eq "write: a CHANGELOG.md with no [Unreleased] line is refused (exit 2)" 2 "$RC"

newfx write
frag 3-a.md Added '- Add a. Refs owner/repo#3.'
frag 12-a.md Fixed '- Fix a. Fixes owner/repo#12.'
(cd "$FX" && fxgit add -A && fxgit commit -q -m frags)
LEGACY=$(sed -n '/^## \[Unreleased\]$/,/^## \[0.5.4\]/p' "$FX/CHANGELOG.md" | sed '1d;$d')
run env CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
eq "write: exit 0" 0 "$RC"
EXPECT_FILE='# Changelog

Intro line.

## [Unreleased]

## [1.2.3] - 2026-01-02
'"$LEGACY"'

### Added
- Add a. Refs owner/repo#3.

### Fixed
- Fix a. Fixes owner/repo#12.

## [0.5.4] - 2024-01-15

### Added
- Old release entry.'
eq "write: legacy lines kept byte for byte and first, fragments after, one version heading" \
	"$EXPECT_FILE" "$(cat "$FX/CHANGELOG.md")"
eq "write: fragments removed from the tree" 0 "$(nfrags)"
eq "write: fragments removed from the index" "changelog.d/README.md" \
	"$(cd "$FX" && fxgit ls-files changelog.d)"
eq "write: README.md kept" "Format notes." "$(cat "$FX/changelog.d/README.md")"
BEFORE=$(cat "$FX/CHANGELOG.md")
run env CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
eq "second write: exit 3" 3 "$RC"
eq "second write: CHANGELOG.md unchanged" "$BEFORE" "$(cat "$FX/CHANGELOG.md")"

# CHANGELOG_DATE decides the heading date, so a caller that read the date once keeps it.
newfx date
frag 3-a.md Added '- Add a.'
run env CHANGELOG_DATE=2031-12-31 bash "$ASSEMBLE" --write 1.2.3
has "write: the heading carries CHANGELOG_DATE" "## [1.2.3] - 2031-12-31" "$(cat "$FX/CHANGELOG.md")"
newfx date-bad
frag 3-a.md Added '- Add a.'
run env CHANGELOG_DATE=31-12-2031 bash "$ASSEMBLE" --write 1.2.3
eq "write: a malformed CHANGELOG_DATE is refused (exit 2)" 2 "$RC"
eq "write: a malformed CHANGELOG_DATE changes nothing" "" "$(cd "$FX" && fxgit status --porcelain -- CHANGELOG.md)"
newfx date-impossible
frag 3-a.md Added '- Add a.'
run env CHANGELOG_DATE=2026-02-31 bash "$ASSEMBLE" --write 1.2.3
eq "write: a date with the shape and no calendar day is refused (exit 2)" 2 "$RC"
eq "write: an impossible date changes nothing" "" "$(cd "$FX" && fxgit status --porcelain -- CHANGELOG.md)"
eq "write: an impossible date leaves the fragment" 1 "$(nfrags)"
# The calendar check reads the date under UTC. In a zone that skipped local midnight on that day,
# date -d refuses a day that exists. The control below tells whether this host has such a zone.
newfx date-zone
frag 3-a.md Added '- Add a.'
if TZ=America/Sao_Paulo date -d 2018-11-04 +%F >/dev/null 2>&1; then
	printf 'SKIP daylight-saving zone case: this host reads America/Sao_Paulo 2018-11-04 fine\n'
else
	run env TZ=America/Sao_Paulo CHANGELOG_DATE=2018-11-04 bash "$ASSEMBLE" --write 1.2.3
	eq "write: a real date is accepted in a zone that skipped its local midnight (exit 0)" 0 "$RC"
fi
newfx date-leap
frag 3-a.md Added '- Add a.'
run env CHANGELOG_DATE=2024-02-29 bash "$ASSEMBLE" --write 1.2.3
eq "write: a leap day is accepted (exit 0)" 0 "$RC"

# A locked index makes "git rm" fail. The run must then change nothing: with CHANGELOG.md already
# replaced and the fragments still there, a retry would cut the same entries twice.
newfx index-locked
frag 3-a.md Added '- Add a.'
(cd "$FX" && fxgit add -A && fxgit commit -q -m frags)
frag 3-a.md Added '- Add a, edited and not committed.'
BEFORE=$(cat "$FX/CHANGELOG.md")
FRAG_BEFORE=$(cat "$FX/changelog.d/3-a.md")
: >"$FX/.git/index.lock"
run env CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
rm -f "$FX/.git/index.lock"
if [ "$RC" -ne 0 ]; then ok "locked index: the write is refused"; else bad "locked index: the write is refused" "exit was 0"; fi
eq "locked index: CHANGELOG.md restored byte for byte" "$BEFORE" "$(cat "$FX/CHANGELOG.md")"
eq "locked index: the fragment is still there, with its uncommitted edit" "$FRAG_BEFORE" "$(cat "$FX/changelog.d/3-a.md")"
eq "locked index: no temporary file left beside CHANGELOG.md" "" "$(find "$FX" -maxdepth 1 -name 'CHANGELOG.md.*')"

# The release is written beside CHANGELOG.md and renamed over it, so a failed
# write leaves the original whole: with the directory unwritable no temporary
# file can be made, and nothing may change.
# Two faults in a row: git rm fails (locked index), then the restore of CHANGELOG.md fails too. The
# saved original must survive and its path must be printed, or CHANGELOG.md keeps the release while
# the fragments remain, and a retry cuts the entries twice. A stub mv, first on PATH, lets the first
# call (the rename of the release over CHANGELOG.md) through and fails every later one.
newfx double-fault
frag 3-a.md Added '- Add a.'
(cd "$FX" && fxgit add -A && fxgit commit -q -m frags)
BEFORE=$(cat "$FX/CHANGELOG.md")
STUB="$T/stub-mv"
mkdir -p "$STUB"
REAL_MV=$(command -v mv)
cat >"$STUB/mv" <<EOF
#!/usr/bin/env bash
n=\$(cat "$STUB/count" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$STUB/count"
if [ "\$n" -ge 1 ]; then echo "stub mv: injected failure" >&2; exit 1; fi
exec "$REAL_MV" "\$@"
EOF
chmod +x "$STUB/mv"
: >"$FX/.git/index.lock"
run env PATH="$STUB:$PATH" CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
rm -f "$FX/.git/index.lock"
if [ "$RC" -ne 0 ]; then ok "double fault: the write is refused"; else bad "double fault: the write is refused" "exit was 0"; fi
eq "double fault: the fragment is still there" 1 "$(nfrags)"
SAVED=$(printf '%s\n' "$OUT" | sed -n 's/.*original is kept at \(.*\); copy it over.*/\1/p' | head -n 1)
if [ -n "$SAVED" ] && [ -f "$SAVED" ]; then
	eq "double fault: the printed path holds the original CHANGELOG.md" "$BEFORE" "$(cat "$SAVED")"
	rm -rf "$(dirname "$SAVED")"
else
	bad "double fault: the printed path holds the original CHANGELOG.md" "no kept file named in: $OUT"
fi

newfx write-atomic
frag 3-a.md Added '- Add a.'
(cd "$FX" && fxgit add -A && fxgit commit -q -m frags)
BEFORE=$(cat "$FX/CHANGELOG.md")
if [ "$(id -u)" = 0 ]; then
	# root writes into a directory without the write bit, so the case cannot fail the way it means to.
	printf 'SKIP unwritable directory cases: running as root\n'
else
	chmod a-w "$FX"
	run env CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
	chmod u+w "$FX"
	if [ "$RC" -ne 0 ]; then ok "unwritable directory: the write is refused"; else bad "unwritable directory: the write is refused" "exit was 0"; fi
	eq "unwritable directory: CHANGELOG.md unchanged" "$BEFORE" "$(cat "$FX/CHANGELOG.md")"
	eq "unwritable directory: the fragment is still there" 1 "$(nfrags)"
fi

newfx write-mode
frag 3-a.md Added '- Add a.'
chmod 640 "$FX/CHANGELOG.md"
run env CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3
eq "write: CHANGELOG.md keeps its mode" 1 "$(find "$FX/CHANGELOG.md" -perm 640 | wc -l | tr -d ' ')"

newfx bad-version
frag 3-a.md Added '- Add a.'
run bash "$ASSEMBLE" --write v1
eq "invalid version: exit 2" 2 "$RC"
run bash "$ASSEMBLE" --write
eq "missing version: exit 2" 2 "$RC"

newfx validate
frag 1-a.md Fixed '- Fix.'
frag 2-b.md Feature '- Bad.'
run bash "$ASSEMBLE" --validate changelog.d/1-a.md
eq "--validate: a valid fragment passes (exit 0)" 0 "$RC"
run bash "$ASSEMBLE" --validate changelog.d/1-a.md changelog.d/2-b.md
eq "--validate: one bad fragment fails the run (exit 2)" 2 "$RC"
has "--validate: names the bad one" "2-b.md" "$OUT"
eq "--validate: changes nothing" 2 "$(nfrags)"

# ------------------------------------------------------------------- check

# prbranch <name>: branch off main in the fixture and check it out.
prbranch() { (cd "$FX" && fxgit checkout -q -b "$1" main); }
commit_all() { (cd "$FX" && fxgit add -A && fxgit commit -q -m "$1"); }
check() { run env "$@" bash "$CHECK"; }

newfx check-pass
prbranch fix/1-a
frag 1-a.md Fixed '- Fix. Fixes owner/repo#1.'
commit_all c
check HEAD_REF_NAME=fix/1-a
eq "check: a PR with a fragment passes (exit 0)" 0 "$RC"
has "check: PASS line" "PASS" "$OUT"

newfx check-nofrag
prbranch fix/2-a
printf 'code\n' >"$FX/code.txt"
commit_all c
check HEAD_REF_NAME=fix/2-a
eq "check: no fragment fails (exit 1)" 1 "$RC"
has "check: FAIL line says what to add" "changelog.d/" "$OUT"

newfx check-readme-only
prbranch docs/3-a
printf 'more notes\n' >>"$FX/changelog.d/README.md"
commit_all c
check HEAD_REF_NAME=docs/3-a
eq "check: editing README.md is not a fragment (exit 1)" 1 "$RC"

newfx check-edit-unreleased
prbranch fix/4-a
frag 4-a.md Fixed '- Fix. Fixes owner/repo#4.'
(cd "$FX" && sed -i 's/^- Legacy fix. Fixes owner\/repo#3.$/&\n- Added the old way. Fixes owner\/repo#4./' CHANGELOG.md)
commit_all c
check HEAD_REF_NAME=fix/4-a
eq "check: a CHANGELOG.md edit fails even with a fragment (exit 1)" 1 "$RC"
has "check: FAIL names CHANGELOG.md" "CHANGELOG.md" "$OUT"

# The workflow passes the exact-membership answer (contains() over the label
# array), never a joined label list, so a label such as "docs,no-changelog"
# cannot pass for the label no-changelog.
newfx check-label
prbranch ci/5-a
printf 'ci\n' >"$FX/ci.txt"
commit_all c
check HEAD_REF_NAME=ci/5-a PR_NO_CHANGELOG=true
eq "check: PR_NO_CHANGELOG=true skips (exit 0)" 0 "$RC"
has "check: SKIP line names the reason" "SKIP" "$OUT"
check HEAD_REF_NAME=ci/5-a PR_NO_CHANGELOG=false
eq "check: PR_NO_CHANGELOG=false does not skip (exit 1)" 1 "$RC"
check HEAD_REF_NAME=ci/5-a PR_NO_CHANGELOG=
eq "check: an empty PR_NO_CHANGELOG does not skip (exit 1)" 1 "$RC"
check HEAD_REF_NAME=ci/5-a PR_NO_CHANGELOG=yes
eq "check: only the word true skips (exit 1)" 1 "$RC"

newfx check-bots
prbranch dependabot/go_modules/x
printf 'dep\n' >"$FX/dep.txt"
commit_all c
check HEAD_REF_NAME=dependabot/go_modules/x
eq "check: dependabot ref skips (exit 0)" 0 "$RC"
check HEAD_REF_NAME=renovate/x
eq "check: renovate ref skips (exit 0)" 0 "$RC"
check HEAD_REF_NAME=fix/dependabot/x
eq "check: dependabot only as a prefix (exit 1)" 1 "$RC"

newfx check-badfrag
prbranch fix/6-a
frag 6-a.md Feature '- Bad section.'
commit_all c
check HEAD_REF_NAME=fix/6-a
eq "check: an invalid fragment fails (exit 1)" 1 "$RC"
has "check: FAIL names the fragment" "6-a.md" "$OUT"

newfx check-subdir
prbranch fix/7-a
mkdir -p "$FX/changelog.d/sub"
printf 'Fixed\n- text.\n' >"$FX/changelog.d/sub/7-a.md"
commit_all c
check HEAD_REF_NAME=fix/7-a
eq "check: a fragment in a subdirectory is not one (exit 1)" 1 "$RC"
check HEAD_REF_NAME=fix/7-a PR_NO_CHANGELOG=true
eq "check: the label no-changelog does not excuse a fragment in a subdirectory (exit 1)" 1 "$RC"
check HEAD_REF_NAME=release/v7.7.7
eq "check: a release branch does not excuse a fragment in a subdirectory (exit 1)" 1 "$RC"

# git quotes a name with non-ASCII characters in its default output: the check must still see the
# fragment, so the label cannot skip it and a valid fragment beside it cannot pass for it.
newfx check-quoted-name
prbranch ci/17-a
frag 17-é.md Fixed '- Fix.'
commit_all c
check HEAD_REF_NAME=ci/17-a PR_NO_CHANGELOG=true
eq "check: a non-ASCII fragment name under the label is validated (exit 1)" 1 "$RC"
has "check: FAIL names the non-ASCII fragment" "17-é.md" "$OUT"
frag 17-b.md Fixed '- Fix b.'
commit_all c2
check HEAD_REF_NAME=ci/17-a
eq "check: a non-ASCII fragment name beside a valid one fails (exit 1)" 1 "$RC"

# A base ref with no merge base makes the diff fail: an ERROR, never an empty list that skips or passes.
newfx check-no-tmp
prbranch fix/19-a
frag 19-a.md Fixed '- Fix.'
commit_all c
check HEAD_REF_NAME=fix/19-a TMPDIR="$T/does-not-exist"
eq "check: an unusable TMPDIR is an error (exit 2), never a bare exit 1" 2 "$RC"
has "check: ERROR line names the temporary directory" "ERROR no temporary directory" "$OUT"

newfx check-no-merge-base
(cd "$FX" && fxgit checkout -q --orphan unrelated && fxgit rm -rf -q . && printf 'x\n' >x.txt && fxgit add x.txt && fxgit commit -q -m unrelated && fxgit update-ref refs/remotes/origin/main unrelated && fxgit checkout -q main) >/dev/null 2>&1
prbranch ci/18-a
printf 'ci\n' >"$FX/ci.txt"
commit_all c
check HEAD_REF_NAME=ci/18-a PR_NO_CHANGELOG=true
eq "check: a base with no merge base is an error under the label (exit 2)" 2 "$RC"
has "check: ERROR line names the diff" "ERROR git diff" "$OUT"
check HEAD_REF_NAME=release/v1.0.0
eq "check: a base with no merge base is an error on a release branch (exit 2)" 2 "$RC"

newfx check-nobase
(cd "$FX" && fxgit update-ref -d refs/remotes/origin/main)
prbranch fix/8-a
frag 8-a.md Fixed '- Fix.'
commit_all c
check HEAD_REF_NAME=fix/8-a
eq "check: a missing base ref is an error, never an empty diff (exit 2)" 2 "$RC"
has "check: ERROR line names the ref" "ERROR origin/main not found" "$OUT"

newfx check-base-ref
(cd "$FX" && fxgit update-ref refs/remotes/origin/develop main)
prbranch fix/9-a
frag 9-a.md Fixed '- Fix.'
commit_all c
check BASE_REF=develop HEAD_REF_NAME=fix/9-a
eq "check: BASE_REF selects another base (exit 0)" 0 "$RC"

# The release PR (head branch release/<tag>) carries the cut section and no fragment: it is skipped by
# its branch name. A branch that only looks like one is not.
newfx check-release
frag 3-a.md Added '- Add a.'
commit_all frags
(cd "$FX" && fxgit update-ref refs/remotes/origin/main main)
prbranch release/v1.2.3
(cd "$FX" && CHANGELOG_DATE=2026-01-02 bash "$ASSEMBLE" --write 1.2.3 >/dev/null 2>&1)
commit_all release
check HEAD_REF_NAME=release/v1.2.3
eq "check: the release PR's own head branch skips (exit 0)" 0 "$RC"
has "check: SKIP line names the release branch" "SKIP release branch release/v1.2.3" "$OUT"
check HEAD_REF_NAME=chore/release
eq "check: a PR that only names itself release, with no label, fails (exit 1)" 1 "$RC"
check HEAD_REF_NAME=fix/release/v1.2.3
eq "check: release/ only as a prefix (exit 1)" 1 "$RC"
check HEAD_REF_NAME=chore/release PR_NO_CHANGELOG=true
eq "check: the label no-changelog still skips a release made by hand (exit 0)" 0 "$RC"

# A fragment the PR edits is validated like one it adds: changelog-assemble.sh reads every fragment
# at release time, so an edit that breaks one fails the release even when the PR also adds a valid
# fragment. basefrag <file> <section> <bullet>: a fragment that already exists on origin/main.
basefrag() {
	frag "$@"
	commit_all basefrag
	(cd "$FX" && fxgit update-ref refs/remotes/origin/main main)
}

newfx check-modified-invalid
basefrag 10-a.md Fixed '- Fix a. Fixes owner/repo#10.'
prbranch fix/10-b
frag 10-a.md Fix '- Fix a. Fixes owner/repo#10.'
frag 10-b.md Fixed '- Fix b. Fixes owner/repo#10.'
commit_all c
check HEAD_REF_NAME=fix/10-b
eq "check: an edit that breaks a fragment fails even with a valid one added (exit 1)" 1 "$RC"
has "check: FAIL names the modified fragment" "10-a.md" "$OUT"

newfx check-modified-valid
basefrag 11-a.md Fixed '- Fix a. Fixes owner/repo#11.'
prbranch fix/11-b
frag 11-a.md Fixed '- Fix a, reworded. Fixes owner/repo#11.'
frag 11-b.md Fixed '- Fix b. Fixes owner/repo#11.'
commit_all c
check HEAD_REF_NAME=fix/11-b
eq "check: an edit that keeps the fragment valid passes (exit 0)" 0 "$RC"
has "check: PASS counts the added fragment" "PASS 1 fragment(s) added, 1 modified" "$OUT"

newfx check-modified-only
basefrag 12-a.md Fixed '- Fix a. Fixes owner/repo#12.'
prbranch fix/12-b
frag 12-a.md Fixed '- Fix a, reworded. Fixes owner/repo#12.'
commit_all c
check HEAD_REF_NAME=fix/12-b
eq "check: editing a fragment is not adding one (exit 1)" 1 "$RC"
has "check: FAIL says no fragment added" "no fragment added" "$OUT"

newfx check-deleted-bad
basefrag 13-a.md Feature '- Bad section already on main.'
prbranch fix/13-b
(cd "$FX" && fxgit rm -q changelog.d/13-a.md)
frag 13-b.md Fixed '- Fix b. Fixes owner/repo#13.'
commit_all c
check HEAD_REF_NAME=fix/13-b
eq "check: a deleted fragment is not validated (exit 0)" 0 "$RC"

newfx check-label-modified-invalid
basefrag 14-a.md Fixed '- Fix a. Fixes owner/repo#14.'
prbranch ci/14-b
frag 14-a.md Fix '- Fix a. Fixes owner/repo#14.'
commit_all c
check HEAD_REF_NAME=ci/14-b PR_NO_CHANGELOG=true
eq "check: the label no-changelog does not excuse an edit that breaks a fragment (exit 1)" 1 "$RC"
has "check: FAIL names the modified fragment under the label" "14-a.md" "$OUT"

newfx check-release-modified-invalid
basefrag 16-a.md Fixed '- Fix a. Fixes owner/repo#16.'
prbranch release/v9.9.9
frag 16-a.md Fix '- Fix a. Fixes owner/repo#16.'
commit_all c
check HEAD_REF_NAME=release/v9.9.9
eq "check: the release branch does not excuse an edit that breaks a fragment (exit 1)" 1 "$RC"

newfx check-label-modified-valid
basefrag 15-a.md Fixed '- Fix a. Fixes owner/repo#15.'
prbranch ci/15-b
frag 15-a.md Fixed '- Fix a, reworded. Fixes owner/repo#15.'
commit_all c
check HEAD_REF_NAME=ci/15-b PR_NO_CHANGELOG=true
eq "check: the label with a valid edit still skips (exit 0)" 0 "$RC"
has "check: SKIP line under the label" "SKIP label no-changelog" "$OUT"

# ------------------------------------------------- the acceptance: two PRs

newfx merge-either-order
(cd "$FX" && fxgit checkout -q -b a main)
frag 1-a.md Fixed '- Fix a.'
commit_all a
(cd "$FX" && fxgit checkout -q -b b main)
frag 2-b.md Fixed '- Fix b.'
commit_all b
(cd "$FX" && fxgit checkout -q -b ab a && fxgit merge -q --no-edit b >/dev/null 2>&1)
AB=$?
(cd "$FX" && fxgit checkout -q -b ba b && fxgit merge -q --no-edit a >/dev/null 2>&1)
BA=$?
eq "two branches that each add a fragment merge, a then b (exit 0)" 0 "$AB"
eq "two branches that each add a fragment merge, b then a (exit 0)" 0 "$BA"
eq "both orders give the same tree" \
	"$(cd "$FX" && git rev-parse 'ab^{tree}')" "$(cd "$FX" && git rev-parse 'ba^{tree}')"

newfx merge-control
(cd "$FX" && fxgit checkout -q -b a main && sed -i 's/^- Legacy fix. Fixes owner\/repo#3.$/&\n- Entry a./' CHANGELOG.md)
commit_all a
(cd "$FX" && fxgit checkout -q -b b main && sed -i 's/^- Legacy fix. Fixes owner\/repo#3.$/&\n- Entry b./' CHANGELOG.md)
commit_all b
(cd "$FX" && fxgit merge -q --no-edit a >/dev/null 2>&1)
CTRL=$?
if [ "$CTRL" -ne 0 ]; then ok "control: two PRs editing the same CHANGELOG.md place do conflict"; else bad "control: two PRs editing the same CHANGELOG.md place do conflict" "merge exit was 0"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
