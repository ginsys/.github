# Release standard

How ginsys repositories make a release. The version and the changelog are automated, and the parts
that do not depend on a language are shared, so a project that is not written in Go can use them too.
The workflows and scripts live in this repository (`.github/workflows/`, `scripts/release/`). A
caller repository holds no copy of any script.

## Changelog fragments

Every change adds one file in `changelog.d/` instead of editing `CHANGELOG.md`. Two pull requests
then never edit the same lines. A release turns the fragments into one section of `CHANGELOG.md`
and deletes them.

- **Name:** `<issue>-<slug>.md`, for example `587-dsn-error-text.md`. `<issue>` is the issue number,
  or the pull request number if there is no issue. `<slug>` is lowercase letters, digits and dashes.
- **Line 1:** the section: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`.
- **The rest:** exactly one bullet, as in `CHANGELOG.md`. It starts with `- `, its continuation lines
  are indented two spaces, and it should end with `Fixes owner/repo#N.` or `Refs owner/repo#N.`
  (the check does not enforce the reference).

```
Fixed
- A malformed database DSN no longer reaches the error text. Fixes owner/repo#587.
```

`CHANGELOG.md` keeps a `## [Unreleased]` heading. Write nothing under it by hand: use a fragment.
Lines already there stay until a release, and the release keeps them, first, in the section it cuts,
so a `### Fixed` written by hand and one from a fragment can both appear in one section.

### What `changelog-assemble.sh` does

It works on the git repository of the current directory.

- No argument: prints the body of the section a release would cut: the lines under
  `## [Unreleased]`, then one `###` block for each section that has a fragment, in the order
  Added, Changed, Deprecated, Removed, Fixed, Security. Fragments inside a block are in number order.
  It changes nothing.
- `--validate FILE...`: checks fragment files and changes nothing.
- `--write X.Y.Z`: cuts the section `## [X.Y.Z] - <date>`, leaves an empty `## [Unreleased]` above it
  and deletes the fragments. `CHANGELOG_DATE=YYYY-MM-DD` sets the date, so a caller that read the date
  once keeps it.

The preview and the write build the section with the same code, and a test compares them line for
line. The release notes and the changelog cannot say different things.

Exit codes: 0 done, 2 a fragment or `CHANGELOG.md` is invalid and nothing was written, 3 there is no
fragment.

## The pull request check

`changelog-fragment.yml` is a reusable workflow. It fails a pull request that does not add a fragment.

A caller:

```yaml
name: Changelog fragment
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened, labeled, unlabeled]
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  changelog-fragment:
    permissions:
      contents: read
    uses: ginsys/.github/.github/workflows/changelog-fragment.yml@<40-character commit> # <date>
```

The reusable workflow sets no `concurrency` of its own: inside a called workflow `github.workflow` is the
caller's name, so a group built from it would equal the caller's and GitHub would cancel the run as a
deadlock. The caller owns the group, as above. A test fails any reusable workflow here whose group is
built from `github.workflow`.

The check gives one verdict:

| Verdict | When |
|---|---|
| PASS | The pull request adds a valid fragment, leaves every fragment it edits valid, and adds no line to `CHANGELOG.md`. |
| SKIP | The head branch starts with `dependabot/`, `renovate/` or `release/` (the release pull request), or the pull request has the label `no-changelog`. |
| FAIL | Anything else, with what to do. |

A skip lifts the need for a fragment, not the format: a fragment the pull request adds or edits is
validated either way, and so is where it sits (directly in `changelog.d/`, never in a subdirectory).
A diff that cannot be read, such as a base with no merge base, is an error and never a skip. Use the label `no-changelog` for a change that needs no entry (CI, tests, a
change to documentation only). The required check name is the caller's job name; none is fixed here.

To run it by hand, change into the repository to check and run
`BASE_REF=main HEAD_REF_NAME=<branch> bash <this repository>/scripts/release/check-changelog-fragment.sh`.
It compares `HEAD` with `origin/main`, so fetch that first.

## The release script

`release.sh` holds the release logic, and `wait-merge.sh` waits for the release pull request. Both
work on the git repository of the current directory. `VERSION` holds the version, as `vX.Y.Z` or
`vX.Y.Z-alpha|beta|rc.N`. One run does one action:

| Action | Tag | `VERSION` after |
|---|---|---|
| `release` | `VERSION` as it is | the next number of the same stage |
| `release-as-beta`, `release-as-rc` | that stage, `.0` (as it is if `VERSION` is already at that stage) | the next number |
| `release-as-stable` | `vX.Y.Z` | `vX.Y.(Z+1)-alpha.0` |
| `start-next-minor`, `start-next-major` | none | the next line, `alpha.0` |
| `skip-prerelease-number` | none | the next number |

A tagging action needs at least one fragment (exit 3 if there is none). Going back a stage is refused.

**`release.sh --check`** only reads. It refuses an unknown action, a run from a tag, a real run off the
default branch, a bad `VERSION`, a tag that exists (as a tag, or as the next `VERSION`), a
`release/<tag>` branch or open pull request that exists, a dispatched commit that is not the tip of
the default branch, and a newest changelog section with no tag (see below). It reads whether the
default branch has a merge queue, prints the plan, and writes `tag`, `version`, `next_version`,
`queue` and `changelog_date` to `GITHUB_OUTPUT`. With `RELEASE_NOTES_FILE` set it writes the
changelog section there: these are the release notes, in a dry run too.

**`release.sh` with `DRY_RUN=0`** does the same checks, then:

1. cuts `release/<tag>` (or `release/<next version>` for an action with no tag) from the tip, with commit
   A, `release: <tag>` (the changelog cut, `VERSION` at the tag), and commit B (`VERSION` moved on). An
   action with no tag makes B only;
2. pushes the branch, opens the pull request and turns on auto-merge: with `--auto` alone when the
   default branch has a merge queue, otherwise with `--auto --rebase`;
3. runs `wait-merge.sh`, then refuses to go on unless A as merged (A') and B as merged (B') are single-parent
   commits on the commit the release was cut from, with exactly the trees this run built, and A' has the
   subject `release: <tag>`;
4. creates the tag on A' through the API with `TAG_TOKEN` (the workflow token: a tag made with it
   starts no workflow). The other `gh` calls use `GH_TOKEN`.

`DRY_RUN` is 1 unless set, so a bare run never releases. `wait-merge.sh` reads the pull request and the
tip of the default branch on every poll. If the tip is no longer the commit the release was cut from,
it turns auto-merge off, closes the pull request and deletes the branch: nothing reached the default
branch, and a rerun cuts a new release. The deadline (elapsed time; 90 minutes unless `WAIT_DEADLINE`
sets it, and the reusable workflow sets 50) and six failed reads in a
row (of the pull request, or of the tip, counted together) end the run the same way, so that a merge
cannot happen after the script has stopped watching; a closed pull request ends it at once. If the
cancelling itself fails, the message says so and that the pull request may still merge. The job that
runs the script needs a `timeout-minutes` larger than the deadline plus the steps after it, so that
the script's own deadline is the one that fires (the reusable release workflow sets 120).

A `VERSION` number of more than nine digits is refused. The tag call is tried three times, then the
exact command is printed.

### A run that was interrupted

The script does not catch a cancelled run, a timeout or a lost runner: a kill leaves whatever state the
run had reached. Two states are possible, and `release.sh --check` finds both. It only reads and
refuses; a person runs the repair.

`--check` looks at the one release branch its own action would use (`release/<tag>`, or
`release/<next version>` for an action with no tag), so run it with the `RELEASE_ACTION` of the run that
was interrupted: another action looks at another branch and can pass while the abandoned pull request
is still open. To find an open one whatever the action was, list the release branches and pull
requests: `git ls-remote --heads origin 'release/*'` and
`gh pr list --state open --json number,headRefName --jq '.[] | select(.headRefName | startswith("release/"))'`.

- **The pull request is still open.** `--check` refuses because `release/<tag>` exists on the remote
  or has an open pull request, and says so. Turn auto-merge off, close the pull request, delete the
  branch, and run again. Until then the pull request can still merge by itself, and that is the second
  state.
- **The release merged and was never tagged.** `CHANGELOG.md` holds a section for a tag that does not
  exist. `--check` refuses until that is repaired: open a pull request that reverts commit
  `release: <tag>` (it restores the fragments and removes the section). `VERSION` stays where it is,
  and the skipped number is never released. For `release-as-stable` the skipped stable number needs
  the owner.

The same second state follows if another change merges in the seconds after the last poll: the
release commit sits on a newer tip and the script makes no tag.

## The release workflow

`release.yml` is a reusable workflow that runs the release script on the caller's repository. A caller
has the workflow dispatch with the two inputs below and one job that calls it:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      action:
        type: choice
        required: true
        default: release
        options: [release, release-as-beta, release-as-rc, release-as-stable, start-next-minor, start-next-major, skip-prerelease-number]
      dry_run:
        type: boolean
        default: true
permissions:
  contents: read
jobs:
  release:
    permissions:
      contents: write
      pull-requests: read
    uses: ginsys/.github/.github/workflows/release.yml@<40-character commit> # <date>
    with:
      action: ${{ inputs.action }}
      dry_run: ${{ inputs.dry_run }}
```

The caller passes no secret: `release` reads the two secrets from the environment `release` of the
caller's repository.

| | |
|---|---|
| Inputs | `action` (one of the seven actions, required), `dry_run` (default `true`) |
| Secrets, both optional, used by a real run only, read from the environment `release` | `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY`: the App `ginsys-release-bot` |
| Outputs | `tag` (the tag the run makes; in a dry run, the tag a real run would make; empty for an action that only moves `VERSION`), `version` (the tag without `v`), `sha` (the commit the tag names; in a dry run, the dispatched commit) |
| Grants | `contents: write` and `pull-requests: read` on the calling job (a called workflow can only narrow what it is given, so the run does not start without both). `guard` lists open pull requests with the workflow token |

**Pin it by commit SHA, never `@main`.** The real run holds the App key and can push a branch and make a
tag. With `@main`, a change merged here would run in every repository's next release with no pull request
there to read. The pin moves by a pull request in the caller, and a dry run after the move is the proof.
This repository has no tags yet, so the first pins are moved by hand.

**Two jobs.**

1. `guard` has no secret and no environment, and `contents: read` and `pull-requests: read`. It runs `release.sh --check` from this
   repository's scripts at the workflow's own commit, which refuses what the script refuses and prints
   the plan. It uploads the release notes as the run artifact `changelog-notes` (for an action that makes
   a tag), in a dry run too. A dry run ends here.
2. `release` runs only for a real run, with the environment `release`, `contents: write` and a limit of
   120 minutes. It mints the App token for the calling repository alone, checks out the dispatched commit,
   and runs `release.sh` with `DRY_RUN=0`: the pull request and the wait use the App token, and the tag is
   made with the workflow token, so that it starts no workflow. The changelog date is the one `guard` read,
   so a run that crosses midnight cannot change the heading. Only one `release` job runs per repository
   (group `release-<repository>`); it never cancels a run in progress. A third run queued behind a
   running one replaces the second, which is still waiting and has done nothing yet.

**The wait is 50 minutes, because the App token lives one hour.** The release job sets
`WAIT_DEADLINE=3000` for the script. The token is minted at the start of the job and stops working an
hour later; the wait must end, with its cleanup and the check of the merged commits, while it works,
so the deadline leaves ten minutes. They also cover the setup before the wait, which is not counted
in the 50: the checkouts and the script's checks take a minute or two. A repository whose checks or merge queue take longer than 50 minutes
gets a red run that has turned auto-merge off, closed the pull request and deleted the branch: nothing
reached the default branch. Run the release again when the queue or the runners are quieter: a second
run starts new checks, so a repository whose checks alone take longer than 50 minutes cannot release
with this workflow until they are faster. If the cleanup itself failed, the message says so: follow
"A run that was interrupted" above. A test fails a workflow whose deadline leaves less than ten
minutes of the token's hour.

**What the owner sets up, once per repository.**

- The App `ginsys-release-bot`, installed on the callers only, with exactly Contents (read and write),
  Pull requests (read and write) and Metadata (read), and no bypass of any ruleset.
- The environment `release` in the repository, restricted to the default branch, holding the two secrets.
- Auto-merge allowed in the repository. With a merge queue the script turns on `--auto`; without one,
  `--auto --rebase`.

**A busy repository should hold other merges while a release runs.** The release pull request waits for
its checks (about 25 minutes in a large repository). Another merge in that time moves the default
branch, and the run then closes the pull request and makes no tag: nothing reached the default branch,
and a rerun cuts a new release. Nothing enforces a quiet window.

**What only the first real run settles.** Nothing here has run with the App or the environment. Whether
the environment's secrets reach a called workflow, whether a pull request opened by the App starts the
checks, whether the App may turn on auto-merge with the three permissions above (a refusal is a 403
whose `X-Accepted-GitHub-Permissions` header names what the call wanted), what a rebase merge makes of
the two commits, and a real merge queue. The action `create-github-app-token` takes
the App's numeric id as `app-id`, which it marks deprecated in favour of `client-id`; the secret keeps
its name until the owner decides.

**`release-dry-run.yml`** calls `release.yml` here with `dry_run: true` and the action
`start-next-minor`, on this repository's own `VERSION` and `CHANGELOG.md`. A job before it records the
tags, the `release/*` branches and the open release pull requests, and a job after it compares them:
any difference fails. It runs on pull requests that touch the release files, and is not one of the
required checks, because a pull request from a fork has a read-only token and the called workflow asks
for `contents: write`. Releases of this repository itself are not made.

## The publish workflow

`publish-github.yml` turns the files a run built and the release notes into a GitHub release with a
`SHA256SUMS` file. It reads no secret. A caller chains it after `release.yml` and its own build jobs, in
the same run:

```yaml
  publish:
    needs: [release, build]
    permissions:
      contents: write
    uses: ginsys/.github/.github/workflows/publish-github.yml@<40-character commit> # <date>
    with:
      tag: ${{ needs.release.outputs.tag }}
      sha: ${{ needs.release.outputs.sha }}
      dry_run: ${{ inputs.dry_run }}
```

| | |
|---|---|
| Inputs | `tag` and `sha` (required; `release.yml`'s outputs), `dry_run` (default `true`), `sign` (default `false`), `notes-footer` (text appended to the notes) |
| Reads from the run | the artifact `changelog-notes` that `release.yml` uploads, and every artifact named `release-*`: any job of the caller may upload `release-<anything>` |
| Grants | `contents: write` on the calling job; with `sign: true` also `id-token: write` and `attestations: write` |

The workflow names no permissions of its own, so its job holds what the calling job grants. A called
workflow that asked for more than its caller grants does not start, and one that asked for the signing
scopes would force every caller to grant them. It checks out only this repository's scripts, never the
caller's repository: the files, the notes and the tag all come from the run and the API.

**In order.** The job has a limit of 30 minutes.

1. It refuses a tag that already has a release, first, so that a re-run of a half-published release
   stops here. Three outcomes: no release is the one that goes on; a release refuses; a read that
   fails for any other reason also refuses, because it cannot tell.
2. A real run refuses unless the tag in the repository names `sha`. An annotated tag is peeled once.
3. It writes the notes from `changelog-notes` and appends the footer. Missing or empty notes fail.
4. It downloads every `release-*` artifact into `dist/` and fails when there is none: a release with no
   files is a mistake. `write-sums.sh` then writes `SHA256SUMS` over the files in `dist/`, whether the
   caller built sums of its own or not.
5. A dry run prints the notes and the sums to the job summary, uploads them with the files as the
   artifact `publish-preview` for 14 days, and stops. Nothing is signed or published.
6. With `sign`, a real run signs `SHA256SUMS` with cosign (keyless, `SHA256SUMS.sigstore.json`) and
   attests the files by their checksums.
7. A real run runs `gh release create` with `--verify-tag`. A tag with a pre-release part (`-alpha.N`,
   `-beta.N`, `-rc.N`) gets `--prerelease --latest=false` and is never Latest. A stable tag takes
   GitHub's default; no repository has made one yet.

## The Go build workflow

`build-go.yml` builds a Go project with GoReleaser in snapshot mode, which builds and archives and
publishes nothing, and uploads the archives as the run artifact `release-go`, which the publish workflow
picks up. A dry run builds for real, so it proves the build.

| | |
|---|---|
| Inputs | `tag` and `sha` (required), `go-version-file` (default `go.mod`) |
| Grants | `contents: read` |
| Runs | `goreleaser release --snapshot --clean` with `RELEASE_VERSION=<tag>` in the environment, GoReleaser pinned here to an exact version, then `check-dist.sh` |

`check-dist.sh` fails unless `dist/` holds at least one archive (`*.tar.gz` or `*.zip`) and every
archive's name contains the version, which is the tag without its `v`. Only the archives are uploaded.

**What the caller's `.goreleaser.yaml` must hold.** The file stays in the repository, because the
binaries, platforms and archive contents are the repository's: `version: 2`; `release.disable: true`
and `changelog.disable: true`; the version stamped with
`-ldflags "-X <package>.<var>={{ .Env.RELEASE_VERSION }}"`; archives as `tar.gz` into `dist/`; builds
with `-trimpath`; `snapshot.version_template` set so that archive names carry the tag.

Left out because no caller needs it: SBOMs, `go-licenses`, extra GoReleaser arguments. The checkout is
shallow and has no tag, as GoReleaser's snapshot mode allows; the first real caller's dry run is the
proof of that and of the build itself, because this repository has no Go code to build.
