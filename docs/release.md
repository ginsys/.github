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

`CHANGELOG.md` keeps a `## [Unreleased]` heading. Lines written under it by hand stay there until
a release, and the release keeps them, first, in the section it cuts.

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
jobs:
  changelog-fragment:
    permissions:
      contents: read
    uses: ginsys/.github/.github/workflows/changelog-fragment.yml@<40-character commit> # <date>
```

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
