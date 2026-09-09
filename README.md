# ginsys/.github

Org-level standards for the ginsys GitHub organization: the repository settings policy, the issue
label set, and the reusable workflows managed repos call. It is a **thin consumer** of
[go-kure/.github](https://github.com/go-kure/.github): the settings script, the action-pin checker
and the Renovate preset live upstream and are used at `main` (first-party reusables at a mutable
ref is go-kure's own pinning policy); only ginsys-owned configuration lives here. The one upstream
job carried here rather than called is the Claude PR review (`pr-review.yml`): a called workflow
reaches the caller's self-hosted runners only when both share an owner, so a ginsys repo calling
go-kure's reusable could not land on `autops-kube-ginsys`, the only runners that reach the in-cluster
claude proxy. The job body is go-kure's; the review logic stays upstream as the `pr-review-threads`
composite action, pinned to a commit.

Managed repos: this one, [`bronzeward`](https://github.com/ginsys/bronzeward) and
[`parley`](https://github.com/ginsys/parley). Onboarding another is a policy edit ("Onboarding a
repo" below), not new tooling. This repo governs itself with the same defaults (rebase-only
merges, auto-merge, delete on merge) and a non-queue `main-protection` ruleset requiring the
`checks` context, up to date. Its own tracker is audited weekly by `tracker-audit-self.yml`. Not
done for this repo: the Claude `pr-review` caller (onboarding step 5). Its PRs are configuration
reviewed by Codex; add the caller if that changes.

parley carries settings and labels, plus overrides for four `github_defaults` values a private
repo on this org's GitHub Free plan can't actually have: `allow_forking` (422 — the org disallows
forking private repos), `allow_auto_merge` (silently ignored — auto-merge on private repos needs
GitHub Team or Enterprise Cloud), and `security.secret_scanning` /
`security.secret_scanning_push_protection` (422 — GitHub Advanced Security isn't offered for
private repos on Free) — no ruleset either (`gh api repos/ginsys/parley/rulesets` returns 403; no
rulesets or required status checks on private Free-plan repos). Its CI (`checks`) and Claude review
(`PR Review`) run and report but are not required checks yet; revisit if parley goes public or the
org upgrades.

## What is here

| Path | Purpose |
|---|---|
| `governance/repository-settings-policy.yaml` | Repo settings, security settings and rulesets, in go-kure's schema |
| `standards/labels.json`, `standards/labels.md` | Label set and the conventions behind it |
| `.github/workflows/settings.yml` | Daily audit of the managed repos; `apply` by manual dispatch |
| `.github/workflows/tracker-audit.yml` | Reusable, report-only issue-tracker hygiene audit |
| `.github/workflows/tracker-audit-self.yml` | This repo's weekly caller of it |
| `.github/workflows/pr-review.yml` | Reusable Claude PR review: go-kure's job wrapper on ginsys runners, upstream's `pr-review-threads` action pinned |
| `scripts/tracker-audit.sh` | The audit itself, fixture-tested by `scripts/test/tracker-audit-test.sh` |
| `.github/workflows/ci.yml` | This repo's own checks: lint, tests, action pins |
| `profile/README.md` | Organization profile |

## Settings flow

1. `settings.yml` runs daily at 06:00 UTC and on every push to `governance/` or `standards/`, in
   **audit** mode: it reports drift in the job summary and fails the run, changing nothing.
2. Changes are applied by dispatching it with `mode=apply`
   (`gh workflow run settings.yml -R ginsys/.github -f mode=apply`) after reading an audit. The
   `repo` input narrows a run to one managed repo; anything that is not `all` or a name in the
   workflow's `GITHUB_REPOS` is refused before the script sees it.
3. `apply` is destructive for labels: a live label not declared in `standards/labels.json` is
   deleted. Snapshot first: `gh label list -R ginsys/<repo> --json name,color,description`.

The workflow needs the `SETTINGS_PAT` repository secret: a fine-grained personal access token
owned by the org, scoped to the managed repos, with Administration and Issues read/write and
Metadata read. It has no `admin:org` scope, which is why the policy declares no `github_org` block
and the org-level settings below are applied by hand.

## Org-level settings applied by hand

Not modelled by the policy schema; recorded so they can be re-checked. Set 2026-09-07.

| Setting | Value | Why |
|---|---|---|
| Runner group `Default` (id 1) | `visibility: selected` with an explicit repository allow-list; `allows_public_repositories: true` | The in-cluster runners must not be reachable from every repo in the org, and the Free plan allows no second group. The current membership is whatever the read-back below returns; it is not restated here |
| Fork-PR approval (org) | `all_external_contributors` | Every fork PR waits for approval before its workflows run on the cluster |
| `bronzeward` and `.github` Actions | `sha_pinning_required: true`, `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false` | Repo-level on purpose: the org-level flag would break a repo that pins actions by major tag. Reusable workflows are exempt from SHA pinning, so this repo's own `go-kure/.github@main` callers keep working |

Read back with `gh api orgs/ginsys/actions/runner-groups/1`,
`gh api orgs/ginsys/actions/permissions/fork-pr-contributor-approval` and
`gh api repos/ginsys/<repo>/actions/permissions`.

## Onboarding a repo

1. Add it to `GITHUB_REPOS_DEFAULT` and `GITHUB_REPOS` in `settings.yml`, and to the `repos:`
   scope of every label it should carry in `standards/labels.json`.
2. Add a `github_repos.<repo>` block to the policy if it needs overrides or rulesets.
3. Add its id to the runner group
   (`gh api -X PUT orgs/ginsys/actions/runner-groups/1/repositories/<repo_id>`) and extend
   `SETTINGS_PAT` to it.
4. Rename any `::` labels by hand first (a rename keeps issue associations; create-and-delete does
   not), dispatch `mode=audit`, read the report, then `mode=apply`.
5. In the repo: a `renovate.json` extending `github>go-kure/.github//renovate/shared`, a caller of
   `tracker-audit.yml` (auditing a *different* repo's tracker needs the `token` secret — the
   caller's `GITHUB_TOKEN` only reads its own issues), and, for the Claude review, a caller of
   this repo's `pr-review.yml` (`uses: ginsys/.github/.github/workflows/pr-review.yml@main`, with
   `pr_review_context` set and `merge_group:` among its triggers so a required context still
   reports in a queue). The mode is the repo variable `PR_REVIEW_THREADS_MODE`: unset or
   `advisory` posts one review comment and creates no threads; `enforce` creates a resolvable
   thread per finding; `off` skips the job. `enforce` also needs a human-owned actor for thread
   resolution — see the header of `pr-review.yml`.

## Local checks

`mise run verify` runs what `ci.yml` runs: actionlint, shellcheck, the tracker-audit fixture tests
and the action-pin check. `mise run settings-audit` clones go-kure/.github into `upstream/`
(gitignored) and runs a read-only audit with your own `gh` credentials; it forwards only `--ci`
and `--json` and refuses everything else, so `apply` cannot run from a workstation.
