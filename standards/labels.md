# Issue Label Conventions

Label taxonomy for ginsys repositories managed from this repo. The canonical list is
[`labels.json`](labels.json); the settings audit (`.github/workflows/settings.yml`) reconciles every
managed repo against it. A label that exists live but is not declared here is reported as `EXTRA`
and deleted by the next `apply`; colour or description drift is reported as `WRONG` and rewritten.

The structure follows go-kure's convention (`category/value`, one separator, everything declared,
`repos:` scoping); the set originated as bronzeward's own. Managed repos today: `.github` (this
repo), `bronzeward`, `parley` and `opsmaster` — the last as a temporary import exception, below.

## Naming

`category/value`, lowercase, hyphenated. No `::`: the two-separator convention bronzeward used
until 2026-09-07 carried no enforcement and was dropped when its labels were renamed
(`status::x` → `status/x`).

**opsmaster exception:** its pre-existing label set was imported into `labels.json` unchanged
rather than migrated to this convention on onboarding — its `status::`, `priority::` and
`effort::` labels keep the colon separator, and its own `type/`/`area/` values and their
individual colours (not the fixed per-namespace colours below) are declared as-is. This is a
scoped, deferred exception, not a second sanctioned convention: the `::` → `/` rename, and
folding its `type/`/`area/` values into the shared taxonomy, remain future work. Every rule below
describes the shared taxonomy that `.github`, bronzeward and parley follow; opsmaster's imported
labels are the stated exception to each of them, not a contradiction of this document.

Every label is multi-select on GitHub. The single-value rules below are convention, checked by the
tracker audit (`scripts/tracker-audit.sh`, called weekly from each managed repo), never enforced
by the forge.

## Categories

| Category | Values | Rule |
|---|---|---|
| `type/` | `investigation`, `decision`, `specification`, `implementation`, `validation`, `bug`, `feature` | exactly one per issue |
| `status/` | `in-progress`, `needs-review`, `needs-refinement` | `in-progress` and `needs-review` are mutually exclusive; `needs-refinement` may coexist with either |
| `area/` | `api`, `database`, `secrets`, `compiler`, `publisher`, `operations`, `transport`, `observer`, `observability`, `design`, `docs`, `ci`, `store`, `dispatch`, `controller`, `adapters` | any number; open namespace (below) |
| none | `dependencies`, `needs-human`, `unattended`, `security` | applied by Renovate to PRs; never chosen by a person |

No `priority/` and no `effort/` in the shared taxonomy: milestones order the work. No
`status/blocked`: blocking is expressed with GitHub's native issue dependencies, which the
tracker audit reads. (opsmaster's imported `priority::`, `effort::` and `status::blocked` labels
are the stated exception above, not additions to this rule.)

`type/bug` and `type/feature` are declared before any code ships because the settings script's
rename map turns GitHub's default `bug` and `enhancement` into them (a rename keeps issue
associations; a delete would not). They are used only once there is shipped behaviour to be
defective or to extend.

Colours are fixed per namespace (`type/` `#1D76DB`, `status/` `#FEF2C0`, `area/` `#5319E7`; the
Renovate labels keep go-kure's colours), so an author never chooses one. opsmaster's imported
labels keep their own pre-existing per-label colours instead, per the exception above.

### `area/` is an open namespace

The nine component areas mirror the design's core components (bronzeward
`docs/design/Talos_Configuration_and_Machine_Management_Design.md`, section 5.1); `design`, `docs`
and `ci` cover the repository itself. parley's own set mirrors its package layout instead:
`store`, `dispatch`, `controller` and `adapters` (`internal/store`, `internal/dispatch`,
`internal/controller`/`cmd/parleyctl`, and the Claude/Codex transport adapters respectively); it
shares `docs` and `ci` with bronzeward rather than duplicating those two (widen a shared label's
scope instead of declaring a second one with the same meaning). A new `area/<component>` may be
created directly on a repo to unblock triage, but **the same unit of work back-fills it into
`labels.json` and the table above.** Until it is declared here the daily audit reports it as
`EXTRA`, and the next `apply` deletes it.

## Repo scoping

Every label carries a `repos` list. A label without `repos` applies to every managed repo; a
scoped one is required only on the listed repos and reported as extra elsewhere. When a repo is
onboarded, widen the scope of the labels it shares rather than duplicating entries.

`.github` carries only the generic labels: `type/bug`, `type/feature` and the four Renovate
labels. bronzeward and parley both use the full work-type and `status/` label set for their
tracking workflow; their `area/` labels differ per repo and stay scoped to it. `type/bug` and
`type/feature` are declared on every managed repo on purpose: where the targets are declared, the
settings script *renames* GitHub's default `bug`/`enhancement` labels to them, which keeps issue
associations; where they are not, the defaults are plain extras and `apply` deletes them.

opsmaster keeps its own full pre-existing label set — its own `type/` and `area/` values, plus
its colon-separated `status::`/`priority::`/`effort::` labels — declared in `labels.json` under
`"repos": ["opsmaster"]` rather than reproduced in the table above; see the exception note under
Naming.

## Renovate labels

`needs-human`, `unattended` and `security` are applied by the shared preset
(`github>go-kure/.github//renovate/shared`) that every managed repo's `renovate.json` extends;
`dependencies` is the conventional bot label. `security` here is a PR label added by
`vulnerabilityAlerts`, unrelated to any issue classification.
