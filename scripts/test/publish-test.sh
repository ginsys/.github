#!/usr/bin/env bash
# publish-test.sh — fixture tests for scripts/release/{write-sums,check-dist,publish-guard}.sh and the
# structure of .github/workflows/publish-github.yml and build-go.yml.
#
# The scripts run against files in a temporary directory and a fake `gh` that answers from state files,
# so nothing touches a forge. The workflows cannot publish here (no tag, no release, no caller), so what
# keeps them safe is read from their YAML; each structure rule also runs on a deliberately broken copy,
# so a rule that never matches cannot pass. Exit 0 only if every case passed.
#
# Usage: publish-test.sh [REPO_ROOT]

# The strings below are YAML text holding GitHub expressions, so the dollar sign must stay literal.
# shellcheck disable=SC2016
set -u

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
SUMS="$ROOT/scripts/release/write-sums.sh"
DIST="$ROOT/scripts/release/check-dist.sh"
GUARD="$ROOT/scripts/release/publish-guard.sh"
PUB="$ROOT/.github/workflows/publish-github.yml"
BGO="$ROOT/.github/workflows/build-go.yml"

T=$(mktemp -d "${TMPDIR:-/tmp}/publish-test.XXXXXX") || exit 2
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
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain: $2" "actual: $3" ;; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "expected NOT to contain: $2" "actual: $3" ;; *) ok "$1" ;; esac; }

# run <command...>: output and exit status in $out and $rc.
run() {
	out=$("$@" 2>&1)
	rc=$?
}

# --- write-sums.sh ----------------------------------------------------------------------------------

S="$T/sums"
mkdir -p "$S/dist"
printf 'b\n' >"$S/dist/b.tar.gz"
printf 'a\n' >"$S/dist/a.zip"
printf 'with space\n' >"$S/dist/my file.tar.gz"
printf 'old\n' >"$S/dist/SHA256SUMS"
printf 'sig\n' >"$S/dist/x.sigstore.json"
run bash "$SUMS" "$S/dist"
eq "write-sums: exits 0 on a directory with files" 0 "$rc"
eq "write-sums: lists the files in byte order, without itself or a signature" \
	"a.zip|b.tar.gz|my file.tar.gz" "$(sed 's/^[0-9a-f]*  //' "$S/dist/SHA256SUMS" | paste -sd'|')"
if (cd "$S/dist" && sha256sum --quiet -c SHA256SUMS 2>/dev/null); then ok "write-sums: the sums verify"; else bad "write-sums: the sums verify"; fi
first=$(cat "$S/dist/SHA256SUMS")
run bash "$SUMS" "$S/dist"
eq "write-sums: a second run writes the same bytes" "$first" "$(cat "$S/dist/SHA256SUMS")"

mkdir -p "$S/empty"
printf 'old\n' >"$S/empty/SHA256SUMS"
run bash "$SUMS" "$S/empty"
eq "write-sums: a directory with no file fails" 1 "$rc"
has "write-sums: the failure says there is nothing to sum" "no files" "$out"
run bash "$SUMS" "$S/missing"
eq "write-sums: a missing directory fails" 1 "$rc"
run bash "$SUMS"
eq "write-sums: no argument fails" 2 "$rc"

# --- check-dist.sh ----------------------------------------------------------------------------------

D="$T/dist"
mkdir -p "$D/ok" "$D/none" "$D/old" "$D/mixed" "$D/pre" "$D/zip" "$D/badzip"
touch "$D/zip/app_1.2.3_windows_amd64.zip" "$D/badzip/app_1.2.2_windows_amd64.zip"
touch "$D/ok/app_1.2.3_linux_amd64.tar.gz" "$D/ok/app_1.2.3_windows_amd64.zip" "$D/ok/checksums.txt" "$D/ok/config.yaml"
touch "$D/none/checksums.txt" "$D/none/config.yaml"
touch "$D/old/app_1.2.2_linux_amd64.tar.gz"
touch "$D/mixed/app_1.2.3_linux_amd64.tar.gz" "$D/mixed/app_1.2.2_darwin_arm64.tar.gz"
touch "$D/pre/app_v1.2.3-rc.1_linux_amd64.tar.gz"
run bash "$DIST" "$D/ok" v1.2.3
eq "check-dist: tar.gz and zip archives that carry the version pass" 0 "$rc"
run bash "$DIST" "$D/zip" v1.2.3
eq "check-dist: a zip alone is an archive" 0 "$rc"
run bash "$DIST" "$D/badzip" v1.2.3
eq "check-dist: a zip of another version fails" 1 "$rc"
run bash "$DIST" "$D/none" v1.2.3
eq "check-dist: a directory with no archive fails" 1 "$rc"
has "check-dist: the failure says there is no archive" "no archive" "$out"
run bash "$DIST" "$D/old" v1.2.3
eq "check-dist: an archive of another version fails" 1 "$rc"
has "check-dist: the failure names the archive" "app_1.2.2_linux_amd64.tar.gz" "$out"
run bash "$DIST" "$D/mixed" v1.2.3
eq "check-dist: one wrong name among right ones fails" 1 "$rc"
lacks "check-dist: the failure names only the wrong archive" "app_1.2.3_linux_amd64.tar.gz" "$out"
run bash "$DIST" "$D/pre" v1.2.3-rc.1
eq "check-dist: a pre-release version is matched whole" 0 "$rc"
run bash "$DIST" "$D/ok" 1.2.3
eq "check-dist: a tag without its v is refused" 2 "$rc"
run bash "$DIST" "$D/missing" v1.2.3
eq "check-dist: a missing directory fails" 1 "$rc"

# --- publish-guard.sh: a fake gh ---------------------------------------------------------------------

mkdir -p "$T/bin" "$T/gh"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
S=$GHSTATE
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >>"$S/calls"
jqexpr=""
prev=""
for a in "$@"; do
	[ "$prev" = --jq ] && jqexpr=$a
	prev=$a
done
out() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
[ "$1" = api ] || exit 2
case "$2" in
repos/*/releases/tags/*)
	case "$(cat "$S/release")" in
	none) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
	exists) echo '{"id":1}' | out ;;
	*) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
	esac
	;;
repos/*/git/ref/tags/*)
	[ ! -e "$S/ref-missing" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
	printf '{"object":{"type":"%s","sha":"%s"}}' "$(cat "$S/ref-type")" "$(cat "$S/ref-sha")" | out
	;;
repos/*/git/tags/*)
	printf '{"object":{"type":"%s","sha":"%s"}}' "$(cat "$S/peel-type")" "$(cat "$S/peel-sha")" | out
	;;
*) echo "unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/gh"
export GHSTATE="$T/gh" GITHUB_REPOSITORY=ginsys/example GH_TOKEN=test-token
G() { PATH="$T/bin:$PATH" bash "$GUARD" "$@"; }

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# absent <tag>: three outcomes, and only "none" lets the run go on.
echo none >"$T/gh/release"
run G absent v1.2.3
eq "absent: no release is the one outcome that passes" 0 "$rc"
echo exists >"$T/gh/release"
run G absent v1.2.3
eq "absent: an existing release refuses" 1 "$rc"
has "absent: the refusal says the tag already has a release" "already has a release" "$out"
echo broken >"$T/gh/release"
run G absent v1.2.3
eq "absent: a read that fails for another reason refuses too" 1 "$rc"
has "absent: the refusal says it could not tell" "could not read" "$out"
run G absent 'v1.2.3;x'
eq "absent: a tag that is not a version tag is refused" 1 "$rc"
case "$(cat "$T/gh/calls")" in *"test-token|api repos/ginsys/example/releases/tags/v1.2.3"*) ok "absent: reads the release of this repository with GH_TOKEN" ;; *) bad "absent: reads the release of this repository with GH_TOKEN" "$(cat "$T/gh/calls")" ;; esac

# tagged <tag> <sha>: the tag must name the commit, peeling an annotated tag.
rm -f "$T/gh/ref-missing"
echo commit >"$T/gh/ref-type"
echo "$A" >"$T/gh/ref-sha"
run G tagged v1.2.3 "$A"
eq "tagged: a lightweight tag that names the commit passes" 0 "$rc"
run G tagged v1.2.3 "$B"
eq "tagged: a tag that names another commit refuses" 1 "$rc"
has "tagged: the refusal names both commits" "$A" "$out"
echo tag >"$T/gh/ref-type"
echo cccccccccccccccccccccccccccccccccccccccc >"$T/gh/ref-sha"
echo commit >"$T/gh/peel-type"
echo "$A" >"$T/gh/peel-sha"
run G tagged v1.2.3 "$A"
eq "tagged: an annotated tag is peeled to its commit" 0 "$rc"
run G tagged v1.2.3 "$B"
eq "tagged: an annotated tag that peels to another commit refuses" 1 "$rc"
echo tag >"$T/gh/peel-type"
run G tagged v1.2.3 "$A"
eq "tagged: a tag of a tag is not followed and refuses" 1 "$rc"
echo tree >"$T/gh/ref-type"
run G tagged v1.2.3 "$A"
eq "tagged: a tag that names no commit refuses" 1 "$rc"
touch "$T/gh/ref-missing"
run G tagged v1.2.3 "$A"
eq "tagged: a missing tag refuses" 1 "$rc"
has "tagged: the refusal says the tag could not be read, not that it names a nothing" "could not read ref/tags/v1.2.3" "$out"
lacks "tagged: the refusal does not go on to a second message" "names a" "$out"
rm -f "$T/gh/ref-missing"
echo commit >"$T/gh/ref-type"
echo "$A" >"$T/gh/ref-sha"
run G tagged v1.2.3 abc123
eq "tagged: a commit that is not 40 hex digits is refused" 1 "$rc"

# notes <notes> <footer> <out>
printf '### Added\n\n- A thing.\n' >"$T/notes.md"
run G notes "$T/notes.md" "" "$T/out1.md"
eq "notes: the notes pass through with no footer" 0 "$rc"
eq "notes: no footer leaves the notes byte for byte" "$(cat "$T/notes.md")" "$(cat "$T/out1.md")"
run G notes "$T/notes.md" "Back up first." "$T/out2.md"
eq "notes: a footer follows the notes after a blank line" "$(printf '### Added\n\n- A thing.\n\nBack up first.')" "$(cat "$T/out2.md")"
printf 'No newline at the end' >"$T/bare.md"
run G notes "$T/bare.md" "Back up first." "$T/out5.md"
eq "notes: notes with no final newline still put the footer on its own paragraph" "$(printf 'No newline at the end\n\nBack up first.')" "$(cat "$T/out5.md")"
printf '  \n\n' >"$T/blank.md"
run G notes "$T/blank.md" "Back up first." "$T/out3.md"
eq "notes: blank notes fail even with a footer" 1 "$rc"
run G notes "$T/missing.md" "" "$T/out4.md"
eq "notes: missing notes fail" 1 "$rc"
if [ -e "$T/out3.md" ] || [ -e "$T/out4.md" ]; then bad "notes: a failure leaves no output file"; else ok "notes: a failure leaves no output file"; fi

# prerelease <tag>: 0 pre-release, 1 stable, 2 not a version tag
run G prerelease v1.2.3-alpha.0
eq "prerelease: alpha is a pre-release" 0 "$rc"
run G prerelease v1.2.3-rc.1
eq "prerelease: rc is a pre-release" 0 "$rc"
run G prerelease v1.2.3
eq "prerelease: a plain version is stable" 1 "$rc"
run G prerelease latest
eq "prerelease: a name that is not a version tag is refused" 2 "$rc"
run G nothing
eq "an unknown command fails" 2 "$rc"

# --- the workflows ------------------------------------------------------------------------------------

# pub_problems <publish-github.yml copy>: one line per rule the file breaks.
pub_problems() {
	local f=$1 a d p n g
	[ "$(yq '.on.workflow_call.inputs | keys | sort | join(",")' "$f")" = "dry_run,notes-footer,sha,sign,tag" ] || echo "the inputs are not tag, sha, dry_run, sign and notes-footer"
	[ "$(yq '.on.workflow_call.inputs.dry_run.default' "$f")" = true ] || echo "dry_run does not default to true"
	[ "$(yq '.on.workflow_call.inputs.sign.default' "$f")" = false ] || echo "sign does not default to false"
	[ "$(yq '.on.workflow_call.secrets // ""' "$f")" = "" ] || echo "the workflow declares a secret"
	[ "$(yq '. | tostring' "$f" | grep -c 'secrets\.')" = 0 ] || echo "the workflow reads a secret"
	[ "$(yq '[.permissions, .jobs.publish.permissions] | map(select(. != null)) | length' "$f")" = 0 ] || echo "the workflow sets permissions, so it cannot hold what its caller grants for sign"
	[ "$(yq '.jobs.publish.environment // ""' "$f")" = "" ] || echo "the publish job has an environment"
	[ "$(yq '.jobs.publish."timeout-minutes"' "$f")" = 30 ] || echo "the publish job limit is not 30 minutes"
	[ "$(yq '.defaults.run.shell' "$f")" = bash ] || echo "the steps do not run with bash -e and pipefail"
	[ "$(yq '[.jobs.publish.steps[] | select(.run // "" | contains("gh release create"))] | length' "$f")" = 1 ] || echo "gh release create is not in exactly one step"
	[ "$(yq '.jobs.publish.steps[] | select(.run // "" | contains("gh release create")) | .if' "$f")" = '${{ !inputs.dry_run }}' ] || echo "the release is not made only in a real run"
	yq '.jobs.publish.steps[] | select(.run // "" | contains("gh release create")) | .run' "$f" | grep -q -- '--verify-tag' || echo "gh release create has no --verify-tag"
	[ "$(yq '.jobs.publish.steps[] | select(.run // "" | contains("publish-guard.sh\" tagged")) | .if' "$f")" = '${{ !inputs.dry_run }}' ] || echo "the tag check is not made in a real run alone"
	a=$(yq '.jobs.publish.steps | to_entries | .[] | select(.value.run // "" | contains("publish-guard.sh\" absent")) | .key' "$f")
	d=$(yq '.jobs.publish.steps | to_entries | .[] | select(.value.uses // "" | contains("download-artifact")) | .key' "$f" | head -n 1)
	p=$(yq '.jobs.publish.steps | to_entries | .[] | select(.value.run // "" | contains("gh release create")) | .key' "$f")
	if [ -z "$a" ]; then echo "no step refuses a tag that already has a release"
	elif [ "$a" -ge "${d:-0}" ] || [ "$a" -ge "${p:-0}" ]; then echo "the check for an existing release does not come before the downloads and the release"; fi
	n=$(yq '[.jobs.publish.steps[] | select((.uses // "" | test("cosign-installer|attest-build-provenance")) or (.run // "" | contains("cosign sign-blob")))] | length' "$f")
	g=$(yq '[.jobs.publish.steps[] | select((.uses // "" | test("cosign-installer|attest-build-provenance")) or (.run // "" | contains("cosign sign-blob"))) | select(.if == "${{ inputs.sign && !inputs.dry_run }}")] | length' "$f")
	{ [ "$n" -gt 0 ] && [ "$n" = "$g" ]; } || echo "a signing step runs without sign and a real run"
	[ "$(yq '.jobs.publish.steps[] | select(.uses // "" | contains("download-artifact")) | select(.with.name == "changelog-notes") | .with.name' "$f")" = changelog-notes ] || echo "the notes are not read from the changelog-notes artifact"
	[ "$(yq '.jobs.publish.steps[] | select(.with.pattern == "release-*") | .with."merge-multiple"' "$f")" = true ] || echo "the files are not downloaded from every release-* artifact into one directory"
	[ "$(yq '.jobs.publish.steps[] | select(.uses // "" | contains("upload-artifact")) | .with.name' "$f")" = publish-preview ] || echo "a dry run does not upload publish-preview"
	[ "$(yq '.jobs.publish.steps[] | select(.uses // "" | contains("upload-artifact")) | .if' "$f")" = '${{ inputs.dry_run }}' ] || echo "publish-preview is uploaded outside a dry run"
	[ "$(yq '[.jobs.publish.steps[] | select(.env.GH_TOKEN != null) | .env.GH_TOKEN] | unique | join(",")' "$f")" = '${{ github.token }}' ] || echo "gh is given a token other than the workflow token"
}

pub_broken() { # <name> <perl substitution> <expected problem substring>
	local out
	perl -0pe "$2" "$PUB" >"$T/$1.yml"
	if cmp -s "$PUB" "$T/$1.yml"; then bad "control: $1" "the substitution changed nothing"; return; fi
	out=$(pub_problems "$T/$1.yml")
	case "$out" in
	*"$3"*) ok "control: $1 is reported" ;;
	*) bad "control: $1 is reported" "wanted: $3" "got: ${out:-nothing}" ;;
	esac
}

pub_broken publish-always 's/(- name: Publish the release\n\s+)if: \$\{\{ !inputs.dry_run \}\}/$1if: true/' "not made only in a real run"
pub_broken tagged-always 's/(- name: Refuse a tag that does not name the commit\n\s+)if: \$\{\{ !inputs.dry_run \}\}/$1if: true/' "tag check is not made in a real run alone"
pub_broken no-absent 's/publish-guard.sh" absent/publish-guard.sh" nothing/' "no step refuses a tag that already has a release"
pub_broken sign-ungated 's/if: \$\{\{ inputs.sign && !inputs.dry_run \}\}/if: true/' "signing step runs without sign"
pub_broken permissions-set 's/(jobs:\n  publish:\n)/$1    permissions:\n      contents: write\n/' "sets permissions"
pub_broken dry-default 's/default: true/default: false/' "dry_run does not default to true"
pub_broken no-verify-tag 's/--verify-tag //' "no --verify-tag"
pub_broken secret 's/GH_TOKEN: \$\{\{ github.token \}\}/GH_TOKEN: \${{ secrets.X }}/' "reads a secret"

out=$(pub_problems "$PUB")
if [ -z "$out" ]; then ok "publish-github.yml keeps every rule"; else bad "publish-github.yml keeps every rule" "$out"; fi

# bgo_problems <build-go.yml copy>
bgo_problems() {
	local f=$1 c u
	[ "$(yq '.on.workflow_call.inputs | keys | sort | join(",")' "$f")" = "go-version-file,sha,tag" ] || echo "the inputs are not tag, sha and go-version-file"
	[ "$(yq '.on.workflow_call.inputs."go-version-file".default' "$f")" = go.mod ] || echo "go-version-file does not default to go.mod"
	[ "$(yq '. | tostring' "$f" | grep -c 'secrets\.')" = 0 ] || echo "the workflow reads a secret"
	[ "$(yq '.jobs.build.permissions | to_json(0)' "$f")" = '{"contents":"read"}' ] || echo "the build job holds more than contents: read"
	[ "$(yq '.jobs.build.steps[] | select(.uses // "" | contains("goreleaser-action")) | .with.version' "$f")" = 2.20.3 ] || echo "GoReleaser is not pinned to an exact version"
	[ "$(yq '.jobs.build.steps[] | select(.uses // "" | contains("goreleaser-action")) | .with.args' "$f")" = "release --snapshot --clean" ] || echo "GoReleaser does not run in snapshot mode"
	[ "$(yq '.jobs.build.steps[] | select(.uses // "" | contains("goreleaser-action")) | .env.RELEASE_VERSION' "$f")" = '${{ inputs.tag }}' ] || echo "RELEASE_VERSION is not the tag"
	[ "$(yq '.jobs.build.steps[] | select(.uses // "" | contains("upload-artifact")) | .with.name' "$f")" = release-go ] || echo "the archives are not uploaded as release-go"
	c=$(yq '.jobs.build.steps | to_entries | .[] | select(.value.run // "" | contains("check-dist.sh")) | .key' "$f")
	u=$(yq '.jobs.build.steps | to_entries | .[] | select(.value.uses // "" | contains("upload-artifact")) | .key' "$f")
	if [ -z "$c" ]; then echo "no step checks the archives"; elif [ "$c" -ge "${u:-0}" ]; then echo "the archives are checked after they are uploaded"; fi
}

bgo_broken() { # <name> <perl substitution> <expected problem substring>
	local out
	perl -0pe "$2" "$BGO" >"$T/$1.yml"
	if cmp -s "$BGO" "$T/$1.yml"; then bad "control: $1" "the substitution changed nothing"; return; fi
	out=$(bgo_problems "$T/$1.yml")
	case "$out" in
	*"$3"*) ok "control: $1 is reported" ;;
	*) bad "control: $1 is reported" "wanted: $3" "got: ${out:-nothing}" ;;
	esac
}

bgo_broken floating-goreleaser 's/version: "2\.20\.3"/version: "~> v2"/' "not pinned to an exact version"
bgo_broken release-mode 's/release --snapshot --clean/release --clean/' "not run in snapshot mode"
bgo_broken write-permission 's/contents: read/contents: write/' "more than contents: read"
bgo_broken no-check 's/check-dist\.sh/true/' "no step checks the archives"
bgo_broken wrong-artifact 's/name: release-go/name: dist/' "not uploaded as release-go"

out=$(bgo_problems "$BGO")
if [ -z "$out" ]; then ok "build-go.yml keeps every rule"; else bad "build-go.yml keeps every rule" "$out"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
