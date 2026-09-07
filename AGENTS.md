# ginsys/.github — agent instructions

This repository holds the ginsys organization's repo standards and is a thin consumer of
go-kure/.github. Read `README.md` first: it states what lives here and what lives upstream.

## Rules

- **Nothing upstream is copied here.** The settings script, the action-pin checker, the PR-review
  reusable workflow and the Renovate preset are used from go-kure/.github at `main`. A change to
  their behaviour is an upstream PR, never a local fork.
- **Every third-party action is pinned to a 40-character commit SHA**, tag as a trailing comment.
  `ci.yml`'s `action-pins` job enforces it. First-party reusable *workflows* (`go-kure/...` and
  `ginsys/...` under `.github/workflows/`) may use `@main`; composite actions may not.
- **`apply` never runs from a workstation.** Local tooling audits only (`mise run settings-audit`).
  Applying goes through the `settings.yml` dispatch with `SETTINGS_PAT`, after reading the audit
  and snapshotting the labels of every managed repo.
- **An `area/` label created live is back-filled in the same PR** into `standards/labels.json` and
  `standards/labels.md`; otherwise the next apply deletes it.
- **No workstation paths, session links or private-repo references** in anything committed or
  posted to the forge.
- Conventional commits (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`); one PR per change; code and
  docs change together.

## Before opening a PR

`mise run verify` (actionlint, shellcheck, the tracker-audit fixture tests, action pins). If the
policy or the labels changed, also `mise run settings-audit` and list the drift lines the change
is expected to produce in the PR description, so the reviewer can tell intended drift from a
mistake.

## Layout

```
.github/workflows/
  settings.yml        daily audit / manual apply, runs go-kure's script from upstream/
  tracker-audit.yml   reusable issue-tracker audit (workflow_call)
  ci.yml              this repo's checks; `checks` aggregates them
governance/
  repository-settings-policy.yaml
standards/
  labels.json         canonical label set, repo-scoped
  labels.md           conventions
scripts/
  tracker-audit.sh
  test/tracker-audit-test.sh
profile/README.md     organization profile
renovate.json         extends go-kure's shared preset
mise.toml             tool pins and the tasks ci.yml runs
```
