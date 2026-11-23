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
3. runs `wait-merge.sh`, then refuses to go on unless A as merged (A') has the subject `release: <tag>`,
   `VERSION` at the tag, the changelog section, and the commit it was cut from as its parent;
4. creates the tag on A' through the API with `TAG_TOKEN` (the workflow token: a tag made with it
   starts no workflow). The other `gh` calls use `GH_TOKEN`.

`DRY_RUN` is 1 unless set, so a bare run never releases. `wait-merge.sh` reads the pull request and the
tip of the default branch on every poll. If the tip is no longer the commit the release was cut from,
it turns auto-merge off, closes the pull request and deletes the branch: nothing reached the default
branch, and a rerun cuts a new release. A closed pull request, a deadline of 90 minutes of elapsed time,
or six failed reads in a row also end the run. The tag call is tried three times, then the exact
command is printed.

### A release that merged and was never tagged

If another change merges in the seconds after the last poll, A' sits on a newer tip and the script makes
no tag. `CHANGELOG.md` then holds a section for a tag that does not exist. The next `release.sh --check`
refuses until that is repaired: open a pull request that reverts commit `release: <tag>` (it restores the
fragments and removes the section). `VERSION` stays where it is, and the skipped number is never
released. For `release-as-stable` the skipped stable number needs the owner.
