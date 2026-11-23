#!/usr/bin/env bash
# release-test.sh — fixture tests for scripts/release/release.sh and scripts/release/wait-merge.sh.
#
# Every case builds a bare "remote", a clone of it as the working tree, and a fake `gh` that keeps its
# state in files and merges the release PR into the bare remote by cherry-pick (a rebase merge). The
# scripts run from the clone, as the reusable workflow runs them, and never touch a real forge.
# Exit 0 only if every case passed.
#
# Usage: release-test.sh [REPO_ROOT]

set -u

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
REL="$ROOT/scripts/release/release.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX") || exit 2
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
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain: $2" "actual: $3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "expected NOT to contain: $2" "actual: $3" ;; *) ok "$1" ;; esac; }

# The fake gh. One file, written once; its state directory is $GHSTATE, the bare remote $GHREMOTE.
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
S=$GHSTATE
R=$GHREMOTE
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >>"$S/calls"
jqexpr=""
prev=""
for a in "$@"; do
	[ "$prev" = --jq ] && jqexpr=$a
	prev=$a
done
out() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
g() { git -c user.name=fake -c user.email=fake@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

# A helper clone that does what GitHub does on a merge: replay the PR's commits onto main.
helper() {
	[ -d "$S/mc" ] || g clone -q "$R" "$S/mc"
	g -C "$S/mc" fetch -q origin
}
advance() { # an unrelated commit lands on main
	helper
	g -C "$S/mc" checkout -q -B m origin/main
	printf 'x\n' >>"$S/mc/other.txt"
	g -C "$S/mc" add other.txt
	g -C "$S/mc" commit -q -m "other: unrelated change"
	g -C "$S/mc" push -q origin m:main
}
merge() {
	helper
	local head base c i=0
	head=$(cat "$S/pr-head")
	base=$(g -C "$S/mc" merge-base origin/main "origin/$head")
	g -C "$S/mc" checkout -q -B m origin/main
	for c in $(g -C "$S/mc" rev-list --reverse "$base..origin/$head"); do
		i=$((i + 1))
		if [ "$i" = "$tamper" ] || { [ "$tamper" = del ] && [ "$i" = 1 ]; }; then
			# replay this commit with an extra file, same message
			g -C "$S/mc" cherry-pick --no-commit "$c" >/dev/null || exit 1
			echo evil >"$S/mc/evil.txt"
			g -C "$S/mc" add evil.txt
			g -C "$S/mc" commit -q -C "$c"
		elif [ "$tamper" = del ] && [ "$i" = 2 ]; then # and the next one takes it out again
			g -C "$S/mc" cherry-pick --no-commit "$c" >/dev/null || exit 1
			g -C "$S/mc" rm -q -f evil.txt
			g -C "$S/mc" commit -q -C "$c"
		else
			g -C "$S/mc" cherry-pick "$c" >/dev/null || exit 1
		fi
	done
	g -C "$S/mc" push -q origin m:main
	g -C "$S/mc" rev-parse HEAD >"$S/merged"
}
merged_json() { printf '{"state":"MERGED","mergeCommit":{"oid":"%s"}}' "$(cat "$S/merged")" | out; }

mode=$(cat "$S/mode" 2>/dev/null || echo merge)
case "$mode" in tamper*) tamper=${mode#tamper} ;; *) tamper=0 ;; esac
case "$1 $2" in
"api repos/"*)
	path=$2
	case "$path" in
	*/rules/branches/*)
		[ ! -e "$S/rules-fail" ] || { echo "HTTP 500" >&2; exit 1; }
		{ cat "$S/rules.json" 2>/dev/null || echo '[]'; } | out
		;;
	*/git/ref/heads/*)
		[ ! -e "$S/ref-fail" ] || { echo "HTTP 502" >&2; exit 1; }
		if [ -e "$S/ref-flaky" ]; then # every other read fails
			c=$(cat "$S/ref-n" 2>/dev/null || echo 0)
			c=$((c + 1))
			echo "$c" >"$S/ref-n"
			[ $((c % 2)) = 0 ] || { echo "HTTP 502" >&2; exit 1; }
		fi
		if [ "$mode" = racemerge ] && [ ! -e "$S/merged" ]; then merge; fi
		printf '{"object":{"sha":"%s"}}' "$(g -C "$R" rev-parse "refs/heads/${path##*/}")" | out
		;;
	esac
	;;
"api -X")
	# gh api -X POST repos/o/r/git/refs -f ref=refs/tags/T -f sha=S
	echo x >>"$S/tag-attempts"
	[ ! -e "$S/tag-fail" ] || { echo "HTTP 422" >&2; exit 1; }
	ref=""
	sha=""
	for a in "$@"; do
		case "$a" in ref=*) ref=${a#ref=} ;; sha=*) sha=${a#sha=} ;; esac
	done
	g -C "$R" update-ref "$ref" "$sha"
	echo '{}'
	;;
"pr list")
	head=""
	prev=""
	for a in "$@"; do
		[ "$prev" = --head ] && head=$a
		prev=$a
	done
	if [ -e "$S/open-pr-head" ] && [ "$(cat "$S/open-pr-head")" = "$head" ]; then echo '[{"number":9}]' | out; else echo '[]' | out; fi
	;;
"pr create")
	prev=""
	for a in "$@"; do
		[ "$prev" = --head ] && printf '%s' "$a" >"$S/pr-head"
		[ "$prev" = --title ] && printf '%s' "$a" >"$S/pr-title"
		[ "$prev" = --body-file ] && cp "$a" "$S/pr-body"
		prev=$a
	done
	echo "https://github.com/o/r/pull/7"
	;;
"pr merge")
	case " $* " in
	*" --disable-auto "*)
		[ ! -e "$S/cancel-fail" ] && [ ! -e "$S/disable-fail" ] || { echo "HTTP 403" >&2; exit 1; }
		if [ "$mode" = latemerge ] && [ ! -e "$S/merged" ]; then merge; fi # the merge slips in as it is cancelled
		;;
	esac
	;;
"pr close")
	[ ! -e "$S/cancel-fail" ] && [ ! -e "$S/close-fail" ] || { echo "HTTP 403" >&2; exit 1; }
	[ ! -e "$S/merged" ] || { echo "already merged" >&2; exit 1; }
	echo closed >"$S/closed"
	case " $* " in *" --delete-branch "*) g -C "$R" update-ref -d "refs/heads/$(cat "$S/pr-head")" ;; esac
	;;
"pr view")
	[ ! -e "$S/view-fail" ] || { echo "HTTP 502" >&2; exit 1; }
	[ ! -e "$S/closed" ] || { echo '{"state":"CLOSED","mergeCommit":null}' | out; exit 0; }
	[ ! -e "$S/merged" ] || { merged_json; exit 0; }
	case "$mode" in
	merge | tamper1 | tamper2 | tamperdel) merge; merged_json ;;
	gap) advance; merge; merged_json ;;
	gapempty) # main moves with a commit that changes no file: the trees match, the parent does not
		helper
		g -C "$S/mc" checkout -q -B m origin/main
		g -C "$S/mc" commit -q --allow-empty -m "other: empty"
		g -C "$S/mc" push -q origin m:main
		merge
		merged_json
		;;
	moved)
		if [ ! -e "$S/advanced" ]; then advance; echo x >"$S/advanced"; fi
		echo '{"state":"OPEN","mergeCommit":null}' | out
		;;
	foreign) # two commits that are not the release, on the tip the PR was cut from
		helper
		g -C "$S/mc" checkout -q -B m origin/main
		for n in one two; do
			printf '%s\n' "$n" >"$S/mc/f-$n.txt"
			g -C "$S/mc" add .
			g -C "$S/mc" commit -q -m "foreign: $n"
		done
		g -C "$S/mc" push -q origin m:main
		g -C "$S/mc" rev-parse HEAD >"$S/merged"
		merged_json
		;;
	closed) echo '{"state":"CLOSED","mergeCommit":null}' | out ;;
	*) echo '{"state":"OPEN","mergeCommit":null}' | out ;;
	esac
	;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"

fxgit() {
	git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
		-c core.hooksPath=/dev/null "$@"
}

# newfx <name> [version]: a bare remote, a clone at W on main, VERSION, CHANGELOG.md and one fragment.
newfx() {
	N=$((N + 1))
	D="$T/$N-$1"
	W="$D/work"
	REMOTE="$D/remote.git"
	GHS="$D/ghstate"
	mkdir -p "$GHS" "$D/home"
	git init -q --bare -b main "$REMOTE"
	git clone -q "$REMOTE" "$W" 2>/dev/null
	(
		cd "$W" || exit 1
		git config user.name test
		git config user.email test@example.invalid
		git config commit.gpgsign false
		git config core.hooksPath /dev/null
		mkdir changelog.d
		printf '%s\n' "${2:-v0.1.0-alpha.0}" >VERSION
		printf '# Changelog\n\n## [Unreleased]\n' >CHANGELOG.md
		printf 'Added\n- A thing. Refs o/r#12.\n' >changelog.d/12-a-thing.md
		git add -A
		git commit -q -m "base"
		git push -q origin HEAD:main
	) >/dev/null 2>&1
	: >"$D/out"
}

# rel [VAR=value ...] -- [args]: run release.sh in the clone with the fake gh; sets OUT and RC.
# CHANGELOG_DATE=UNSET runs it with that variable absent from the environment, not empty.
rel() {
	local envs=() date=(CHANGELOG_DATE=2030-01-02) unset=()
	while [ "${1:-}" != -- ]; do
		if [ "$1" = CHANGELOG_DATE=UNSET ]; then
			date=()
			unset=(-u CHANGELOG_DATE)
		else
			envs+=("$1")
		fi
		shift
	done
	shift
	OUT=$(cd "$W" && env "${unset[@]}" PATH="$T/bin:$PATH" GHSTATE="$GHS" GHREMOTE="$REMOTE" HOME="$D/home" \
		GITHUB_REPOSITORY=o/r GITHUB_OUTPUT="$D/out" GH_TOKEN=app TAG_TOKEN=workflow \
		WAIT_POLL=0 WAIT_MISSES=3 WAIT_DEADLINE=60 TAG_RETRY_SLEEP=0 \
		RELEASE_ACTION=release DRY_RUN=1 RELEASE_BRANCH=main RELEASE_REF_TYPE=branch DEFAULT_BRANCH=main \
		"${date[@]}" "${envs[@]}" bash "$REL" "$@" 2>&1)
	RC=$?
}

output() { sed -n "s/^$1=//p" "$D/out" | tail -1; }
remote_tag() { git -C "$REMOTE" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null; }
remote_branch() { git -C "$REMOTE" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
subject() { git -C "$REMOTE" log -1 --format=%s "$1"; }
calls() { cat "$GHS/calls" 2>/dev/null; }

# ── the dry run (--check) ─────────────────────────────────────────────────

newfx dry
rel -- --check
eq "check: a clean dry run exits 0" 0 "$RC"
eq "check: tag output" v0.1.0-alpha.0 "$(output tag)"
eq "check: version output has no leading v" 0.1.0-alpha.0 "$(output version)"
eq "check: no merge queue is read as false" false "$(output queue)"
eq "check: the changelog date is output once" 2030-01-02 "$(output changelog_date)"
eq "check: nothing is pushed" "" "$(remote_branch release/v0.1.0-alpha.0)"
eq "check: the working tree is left alone" "" "$(cd "$W" && git status --porcelain)"
eq "check: no gh write was made" "" "$(calls | rg 'pr (create|merge|close)|POST' || true)"

newfx notes
rel RELEASE_NOTES_FILE="$D/notes.md" -- --check
has "check: the notes file holds the fragment text" "A thing. Refs o/r#12." "$(cat "$D/notes.md" 2>/dev/null)"
lacks "check: the notes carry no heading" "## [" "$(cat "$D/notes.md" 2>/dev/null)"

newfx queue
echo '[{"type":"merge_queue"},{"type":"deletion"}]' >"$GHS/rules.json"
rel -- --check
eq "check: a merge_queue rule reads as queue=true" true "$(output queue)"

# action table: action, VERSION, tag, next VERSION
table() {
	local action=$1 version=$2 tag=$3 next=$4
	newfx "act-$action" "$version"
	rel RELEASE_ACTION="$action" -- --check
	eq "action $action on $version: exits 0" 0 "$RC"
	eq "action $action on $version: tag" "$tag" "$(output tag)"
	eq "action $action on $version: VERSION after" "$next" "$(output next_version)"
}
table release v0.1.0-alpha.0 v0.1.0-alpha.0 v0.1.0-alpha.1
table release-as-beta v0.1.0-alpha.3 v0.1.0-beta.0 v0.1.0-beta.1
table release-as-beta v0.1.0-beta.2 v0.1.0-beta.2 v0.1.0-beta.3
table release-as-rc v0.1.0-beta.2 v0.1.0-rc.0 v0.1.0-rc.1
table release-as-stable v0.1.0-rc.1 v0.1.0 v0.1.1-alpha.0
table start-next-minor v0.1.0-alpha.0 "" v0.2.0-alpha.0
table start-next-major v0.1.0-alpha.0 "" v1.0.0-alpha.0
table skip-prerelease-number v0.1.0-alpha.0 "" v0.1.0-alpha.1

# ── the guards: each refuses, names why, and writes nothing ───────────────

refuses() { # <name> <expected exit> <expected text>: after a rel call
	eq "refused: $1 (exit)" "$2" "$RC"
	has "refused: $1 (text)" "$3" "$OUT"
}

newfx g-action
rel RELEASE_ACTION=nonsense -- --check
refuses "an unknown action" 1 "Unknown action"

newfx g-dry
rel DRY_RUN=2 -- --check
refuses "DRY_RUN other than 0 or 1" 1 "DRY_RUN must be 0 or 1"

newfx g-tagref
rel RELEASE_REF_TYPE=tag -- --check
refuses "a run from a tag" 1 "from a branch"

newfx g-off
git -C "$W" switch -q -c topic
rel RELEASE_BRANCH=topic DRY_RUN=0 -- --check
refuses "a real run off the default branch" 1 "runs only from main"
rel RELEASE_BRANCH=topic DRY_RUN=1 -- --check
eq "a dry run off the default branch is allowed" 0 "$RC"
has "a dry run off the default branch warns" "Dry run from 'topic'" "$OUT"

newfx g-badver notaversion
rel -- --check
refuses "a malformed VERSION" 1 "Invalid version"

newfx g-back v0.1.0-rc.1
rel RELEASE_ACTION=release-as-beta -- --check
refuses "going back a stage" 1 "going back from rc to beta"

newfx g-stable v0.1.0
rel RELEASE_ACTION=release -- --check
refuses "release on a stable VERSION" 1 "not a prerelease"

newfx g-tag-local
git -C "$W" update-ref refs/tags/v0.1.0-alpha.0 HEAD
rel -- --check
refuses "a tag that exists in the checkout" 1 "Tag v0.1.0-alpha.0 already exists"

newfx g-tag-remote
git -C "$REMOTE" update-ref refs/tags/v0.1.0-alpha.0 "$(git -C "$REMOTE" rev-parse main)"
rel -- --check
refuses "a tag that exists on the remote" 1 "already exists on origin"

newfx g-next-tag
git -C "$REMOTE" update-ref refs/tags/v0.1.0-alpha.1 "$(git -C "$REMOTE" rev-parse main)"
rel -- --check
refuses "the next VERSION already being a tag" 1 "Tag v0.1.0-alpha.1 already exists"

newfx g-branch
git -C "$REMOTE" update-ref refs/heads/release/v0.1.0-alpha.0 "$(git -C "$REMOTE" rev-parse main)"
rel -- --check
refuses "a release branch that exists" 1 "release/v0.1.0-alpha.0 exists"

newfx g-pr
echo release/v0.1.0-alpha.0 >"$GHS/open-pr-head"
rel -- --check
refuses "an open release PR" 1 "open pull request"

newfx g-nofrag
rm "$W/changelog.d/12-a-thing.md"
(cd "$W" && git add -A && fxgit commit -q -m "no fragment" && git push -q origin HEAD:main)
rel -- --check
refuses "a tagging action with no fragment" 3 "empty notes"
rel RELEASE_ACTION=start-next-minor -- --check
eq "a VERSION-only action needs no fragment" 0 "$RC"

newfx g-tip
git -C "$REMOTE" update-ref refs/heads/main "$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
	git -C "$REMOTE" commit-tree -p main -m other "$(git -C "$REMOTE" rev-parse 'main^{tree}')")"
rel -- --check
refuses "a dispatched commit that is not the tip" 1 "is not the tip of main"

newfx g-phantom
(cd "$W" && printf '# Changelog\n\n## [Unreleased]\n\n## [0.0.9] - 2029-12-31\n\n### Added\n- Old.\n' >CHANGELOG.md \
	&& git add -A && fxgit commit -q -m "cut" && git push -q origin HEAD:main)
rel -- --check
refuses "a cut section whose tag does not exist (U6)" 1 "no tag v0.0.9"
has "the phantom-section refusal names the repair" "revert" "$OUT"
git -C "$REMOTE" update-ref refs/tags/v0.0.9 "$(git -C "$REMOTE" rev-parse main)"
rel -- --check
eq "a cut section whose tag exists passes" 0 "$RC"

newfx g-bigchangelog
(
	cd "$W" && {
		printf '# Changelog\n\n## [Unreleased]\n\n## [0.0.9] - 2029-12-31\n\n'
		seq 1 40000 | sed 's/^/- line /'
		printf '\n## [0.0.8] - 2029-01-01\n'
	} >CHANGELOG.md && git add -A && fxgit commit -q -m "big" && git push -q origin HEAD:main
)
git -C "$REMOTE" update-ref refs/tags/v0.0.9 "$(git -C "$REMOTE" rev-parse main)"
rel -- --check
eq "a changelog of several hundred KB is read to the end (no SIGPIPE)" 0 "$RC"

newfx g-bignum v18446744073709551616.0.0
rel RELEASE_ACTION=start-next-major -- --check
refuses "a number that would wrap around 64 bits" 1 "more than 9 digits"

newfx g-nextbig v0.1.0-alpha.999999999
rel RELEASE_ACTION=skip-prerelease-number -- --check
refuses "a VERSION whose next number the next run would refuse" 1 "which the next run refuses"
rel RELEASE_ACTION=release -- --check
refuses "a release whose next VERSION the next run would refuse" 1 "which the next run refuses"
rel RELEASE_ACTION=release-as-rc -- --check
eq "an action that resets the number is still allowed" 0 "$RC"

newfx g-rules
touch "$GHS/rules-fail"
rel -- --check
refuses "an unreadable rules endpoint" 1 "merge queue"

newfx g-real-dry
rel DRY_RUN=1 --
refuses "a real run with DRY_RUN=1" 1 "DRY_RUN=0"
rel DRY_RUN= --
refuses "a real run with DRY_RUN unset: the default is a preview" 1 "DRY_RUN=0"

# ── a real run ────────────────────────────────────────────────────────────

newfx real
rel DRY_RUN=0 --
eq "real: exits 0" 0 "$RC"
tagc=$(remote_tag v0.1.0-alpha.0)
eq "real: the tag names the release commit" "release: v0.1.0-alpha.0" "$(subject "$tagc")"
eq "real: main's tip is the VERSION bump" "chore: bump version: v0.1.0-alpha.0 -> v0.1.0-alpha.1" "$(subject main)"
eq "real: the tagged commit is main's tip's parent" "$tagc" "$(git -C "$REMOTE" rev-parse 'main^')"
eq "real: VERSION at the tag is the tag" v0.1.0-alpha.0 "$(git -C "$REMOTE" show "$tagc:VERSION")"
eq "real: VERSION on main is the next number" v0.1.0-alpha.1 "$(git -C "$REMOTE" show main:VERSION)"
has "real: the changelog at the tag has the section, dated" "## [0.1.0-alpha.0] - 2030-01-02" "$(git -C "$REMOTE" show "$tagc:CHANGELOG.md")"
eq "real: the fragment is gone at the tag" "" "$(git -C "$REMOTE" ls-tree --name-only "$tagc" changelog.d/12-a-thing.md)"
eq "real: the PR title" "release: v0.1.0-alpha.0" "$(cat "$GHS/pr-title")"
has "real: the PR body is the changelog section" "A thing. Refs o/r#12." "$(cat "$GHS/pr-body")"
has "real: no queue turns on auto-merge with rebase" "|pr merge 7 --auto --rebase" "$(calls)"
has "real: the PR is opened with the App token" "app|pr create" "$(calls)"
has "real: the tag is made with the workflow token" "workflow|api -X POST repos/o/r/git/refs" "$(calls)"
eq "real: the tag output" v0.1.0-alpha.0 "$(output tag)"
eq "real: the sha output is the tagged commit" "$tagc" "$(output sha)"
eq "real: the date comes from CHANGELOG_DATE, not the clock" 1 "$(git -C "$REMOTE" show "$tagc:CHANGELOG.md" | grep -c '2030-01-02')"

newfx real-big
(
	cd "$W" && {
		printf '# Changelog\n\n## [Unreleased]\n\n## [0.0.1] - 2029-01-01\n\n'
		seq 1 40000 | sed 's/^/- line /'
	} >CHANGELOG.md && git add -A && fxgit commit -q -m "big" && git push -q origin HEAD:main
)
git -C "$REMOTE" update-ref refs/tags/v0.0.1 "$(git -C "$REMOTE" rev-parse main)"
rel DRY_RUN=0 --
eq "real run on a changelog of several hundred KB: exits 0" 0 "$RC"
eq "real run on a changelog of several hundred KB: the tag is made" "release: v0.1.0-alpha.0" "$(subject "$(remote_tag v0.1.0-alpha.0)")"

newfx real-stage v0.1.0-alpha.3
rel DRY_RUN=0 RELEASE_ACTION=release-as-beta CHANGELOG_DATE=UNSET --
eq "stage move: exits 0" 0 "$RC"
stagec=$(remote_tag v0.1.0-beta.0)
eq "stage move: VERSION at the tag is the new stage" v0.1.0-beta.0 "$(git -C "$REMOTE" show "$stagec:VERSION")"
eq "stage move: VERSION on main is the number after" v0.1.0-beta.1 "$(git -C "$REMOTE" show main:VERSION)"
today=$(date -u +%F)
has "an unset CHANGELOG_DATE is today, UTC, and reaches the assembler" "## [0.1.0-beta.0] - $today" "$(git -C "$REMOTE" show "$stagec:CHANGELOG.md")"

newfx real-queue
echo '[{"type":"merge_queue"}]' >"$GHS/rules.json"
rel DRY_RUN=0 --
eq "queue: exits 0" 0 "$RC"
has "queue: auto-merge without a method" "|pr merge 7 --auto" "$(calls)"
lacks "queue: no --rebase when a queue chooses the method" "--auto --rebase" "$(calls)"

newfx real-vonly
rel DRY_RUN=0 RELEASE_ACTION=start-next-minor --
eq "version-only: exits 0" 0 "$RC"
eq "version-only: one commit on main" "chore: start next cycle: v0.2.0-alpha.0" "$(subject main)"
eq "version-only: the commit's parent is the old tip" "base" "$(subject 'main^' 2>/dev/null | head -1)"
eq "version-only: no tag is made" "" "$(calls | rg 'git/refs' || true)"
eq "version-only: no tag output" "" "$(output tag)"
eq "version-only: the fragment stays" 1 "$(git -C "$REMOTE" ls-tree --name-only main changelog.d/12-a-thing.md | wc -l)"

# ── what stops a real run ─────────────────────────────────────────────────

newfx moved
echo moved >"$GHS/mode"
tip0=$(git -C "$REMOTE" rev-parse main)
rel DRY_RUN=0 --
eq "main moved while waiting: red" 1 "$RC"
has "main moved while waiting: says what moved" "main moved from $tip0 to" "$OUT"
eq "main moved while waiting: no tag" "" "$(remote_tag v0.1.0-alpha.0)"
eq "main moved while waiting: the release branch is deleted" "" "$(remote_branch release/v0.1.0-alpha.0)"
eq "main moved while waiting: only the unrelated commit landed" "other: unrelated change" "$(subject main)"
has "main moved while waiting: auto-merge was turned off" "pr merge 7 --disable-auto" "$(calls)"
has "main moved while waiting: the PR was closed" "pr close 7" "$(calls)"
eq "main moved while waiting: the first tip is still an ancestor" 0 "$(git -C "$REMOTE" merge-base --is-ancestor "$tip0" main; echo $?)"

newfx race
echo racemerge >"$GHS/mode"
rel DRY_RUN=0 --
eq "merged between the two reads: green, not closed" 0 "$RC"
eq "merged between the two reads: the PR was not closed" "" "$(calls | rg 'pr close' || true)"

newfx gap
echo gap >"$GHS/mode"
rel DRY_RUN=0 --
eq "main moved in the gap: red" 1 "$RC"
has "main moved in the gap: names the unreleased section" "no tag was made" "$OUT"
eq "main moved in the gap: no tag" "" "$(remote_tag v0.1.0-alpha.0)"
eq "main moved in the gap: no tag call" "" "$(calls | rg 'git/refs' || true)"

newfx foreign
echo foreign >"$GHS/mode"
rel DRY_RUN=0 --
eq "a merged commit that is not the release commit: red" 1 "$RC"
has "a merged commit that is not the release commit: says so" "are not the release commits this run built" "$OUT"
eq "a merged commit that is not the release commit: no tag" "" "$(remote_tag v0.1.0-alpha.0)"

for n in 1 2 del; do
	newfx "tamper$n"
	echo "tamper$n" >"$GHS/mode"
	rel DRY_RUN=0 --
	eq "commit $n of the release merged with an extra file, same subject: red" 1 "$RC"
	has "commit $n merged with an extra file: says the trees differ" "are not the release commits this run built" "$OUT"
	eq "commit $n merged with an extra file: no tag" "" "$(remote_tag v0.1.0-alpha.0)"
done
# "del" adds the file to the tagged commit and takes it out in the next one: the final tree is right.

newfx gapempty
echo gapempty >"$GHS/mode"
rel DRY_RUN=0 --
eq "main moved by a commit with no change: the parent still differs, no tag" 1 "$RC"
eq "main moved by a commit with no change: no tag made" "" "$(remote_tag v0.1.0-alpha.0)"

newfx closed
echo closed >"$GHS/mode"
rel DRY_RUN=0 --
eq "closed unmerged: red" 1 "$RC"
has "closed unmerged: says so" "closed without merging" "$OUT"
eq "closed unmerged: no tag" "" "$(remote_tag v0.1.0-alpha.0)"

newfx misses
echo never >"$GHS/mode"
touch "$GHS/view-fail"
rel DRY_RUN=0 --
eq "reads that keep failing: red" 1 "$RC"
has "reads that keep failing: counted as misses" "3 reads in a row" "$OUT"
has "reads that keep failing: auto-merge is cancelled" "pr merge 7 --disable-auto" "$(calls)"
has "reads that keep failing: the PR is closed" "pr close 7 --delete-branch" "$(calls)"

newfx tipmiss
echo never >"$GHS/mode"
touch "$GHS/ref-fail"
rel DRY_RUN=0 --
eq "tip reads that keep failing, PR reads fine: red" 1 "$RC"
has "tip reads that keep failing: counted as misses" "Reading main failed 3 reads in a row" "$OUT"
has "tip reads that keep failing: auto-merge is cancelled" "pr merge 7 --disable-auto" "$(calls)"

newfx flaky
echo never >"$GHS/mode"
touch "$GHS/ref-flaky"
rel DRY_RUN=0 WAIT_DEADLINE=2 --
eq "tip reads that fail every other poll: never a streak, red at the deadline" 1 "$RC"
has "tip reads that fail every other poll: ends at the deadline" "within 2 seconds" "$OUT"
lacks "tip reads that fail every other poll: not counted as a streak" "reads in a row" "$OUT"

newfx deadline
echo never >"$GHS/mode"
rel DRY_RUN=0 WAIT_DEADLINE=1 WAIT_POLL=1 --
eq "a PR that never merges: red at the deadline" 1 "$RC"
has "a PR that never merges: says the deadline" "within 1 seconds" "$OUT"
eq "a PR that never merges: no tag" "" "$(remote_tag v0.1.0-alpha.0)"
has "a PR that never merges: auto-merge is cancelled" "pr merge 7 --disable-auto" "$(calls)"
has "a PR that never merges: says the cancel worked" "Auto-merge is off" "$OUT"
eq "a PR that never merges: the release branch is deleted" "" "$(remote_branch release/v0.1.0-alpha.0)"

newfx cancelfail
echo never >"$GHS/mode"
touch "$GHS/cancel-fail"
rel DRY_RUN=0 WAIT_DEADLINE=1 WAIT_POLL=1 --
eq "a cancel that fails: red" 1 "$RC"
has "a cancel that fails: says it may still merge" "may still merge" "$OUT"
lacks "a cancel that fails: does not claim a clean cancel" "Auto-merge is off" "$OUT"

newfx closefail
echo never >"$GHS/mode"
touch "$GHS/close-fail"
rel DRY_RUN=0 WAIT_DEADLINE=1 WAIT_POLL=1 --
eq "auto-merge off but the close fails: red" 1 "$RC"
has "auto-merge off but the close fails: says to close it by hand" "could not be closed" "$OUT"
lacks "auto-merge off but the close fails: no claim that it is closed" "is closed and" "$OUT"

newfx disablefail
echo never >"$GHS/mode"
touch "$GHS/disable-fail"
rel DRY_RUN=0 WAIT_DEADLINE=1 WAIT_POLL=1 --
eq "the close works but auto-merge stays on: red" 1 "$RC"
has "the close works but auto-merge stays on: says so" "could not turn auto-merge off" "$OUT"
lacks "the close works but auto-merge stays on: no claim that auto-merge is off" "Auto-merge is off" "$OUT"

newfx latemerge
echo latemerge >"$GHS/mode"
rel DRY_RUN=0 WAIT_DEADLINE=1 WAIT_POLL=1 --
eq "a merge that slips in as the run is cancelled: judged, not denied" 0 "$RC"
eq "a merge that slips in as the run is cancelled: the tag is made" "release: v0.1.0-alpha.0" "$(subject "$(remote_tag v0.1.0-alpha.0)")"

newfx tagfail
touch "$GHS/tag-fail"
rel DRY_RUN=0 --
eq "a tag call that keeps failing: red" 1 "$RC"
eq "a tag call that keeps failing: three attempts" 3 "$(wc -l <"$GHS/tag-attempts")"
has "a tag call that keeps failing: prints the exact command" "gh api -X POST repos/o/r/git/refs -f ref=refs/tags/v0.1.0-alpha.0 -f sha=" "$OUT"
eq "a tag call that keeps failing: the release is on main" "chore: bump version: v0.1.0-alpha.0 -> v0.1.0-alpha.1" "$(subject main)"

newfx help
rel -- --nonsense
refuses "an unknown argument" 1 "Usage"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
