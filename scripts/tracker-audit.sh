#!/usr/bin/env bash
# tracker-audit.sh — report-only hygiene audit of a GitHub issue tracker.
#
# Checks, each on its own switch (the last two are always on):
#   milestone          open issue without a milestone                       --require-milestone
#   single-select      zero or several labels of one namespace on an issue  --single-select NS[,NS]
#   exclusive          both labels of a pair on one issue                    --exclusive A:B[,C:D]
#   blocked            in-progress issue blocked by an open issue            --blocked-in-progress
#   closed-milestone   open issue assigned to a closed milestone
#   overdue-milestone  open milestone past its due date with open issues
#
# Input is live (--repo owner/name, read through `gh api`) or a fixture (--fixture file.json) of
# the same shape, so every check has a network-free negative test in scripts/test/. Output: one
# line per finding on stdout, a table appended to $GITHUB_STEP_SUMMARY when set, exit 1 when any
# finding exists. The script never writes to the tracker.
#
# Snapshot shape (live mode builds it; a fixture supplies it):
#   {"issues": [{"number": 1, "title": "t", "labels": ["type/bug"],
#                "milestone": {"number": 1, "title": "m", "state": "open", "due_on": null},
#                "blocked_by": [{"number": 2, "state": "open"}]}],
#    "milestones": [{"number": 1, "title": "m", "state": "open", "due_on": null, "open_issues": 1}]}
#   milestone may be null; blocked_by may be absent (treated as empty).
#
# Usage: tracker-audit.sh (--repo owner/name | --fixture file.json) [options]
#   --require-milestone        report open issues with no milestone
#   --single-select NS[,NS]    namespaces that must carry exactly one label per open issue
#   --exclusive A:B[,C:D]      label pairs that must not coexist on one issue
#   --blocked-in-progress      report issues carrying the in-progress label while blocked by an open issue
#   --in-progress-label NAME   label the blocked check keys on (default status/in-progress)
#   --now EPOCH                reference time for overdue milestones (default: now; fixtures pin it)

set -euo pipefail
# `set -e` alone does not reach inside a command substitution: bash runs `$(...)` in a subshell
# that does NOT inherit errexit unless this shopt is set. Without it, a `gh api` failure inside
# snapshot_live left the function running, `jq -s 'add // []'` turned the empty output into `[]`,
# and an audit of nothing reported "OK (0 open issues)" and exited 0 -- a green audit produced by
# an expired token or a transient 5xx. The blocked_by endpoint returns `[]` with status 0 for an
# issue with no dependencies (verified live), so no legitimate empty case aborts here.
shopt -s inherit_errexit

REPO="" FIXTURE="" REQUIRE_MS=0 SINGLE="" EXCLUSIVE="" BLOCKED=0 INPROG="status/in-progress" NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --require-milestone) REQUIRE_MS=1; shift ;;
    --single-select) SINGLE="$2"; shift 2 ;;
    --exclusive) EXCLUSIVE="$2"; shift 2 ;;
    --blocked-in-progress) BLOCKED=1; shift ;;
    --in-progress-label) INPROG="$2"; shift 2 ;;
    --now) NOW="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "tracker-audit: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$REPO" ] && [ -z "$FIXTURE" ]; then
  echo "tracker-audit: --repo or --fixture is required" >&2; exit 2
fi
if [ -n "$REPO" ] && [ -n "$FIXTURE" ]; then
  echo "tracker-audit: --repo and --fixture are mutually exclusive" >&2; exit 2
fi
[ -n "$NOW" ] || NOW=$(date +%s)
command -v jq >/dev/null || { echo "tracker-audit: jq is required" >&2; exit 2; }

snapshot_live() {
  command -v gh >/dev/null || { echo "tracker-audit: gh is required for --repo" >&2; exit 2; }
  local issues milestones deps
  # Pull requests share the issues endpoint; drop them.
  issues=$(gh api --paginate "repos/$REPO/issues?state=open&per_page=100" \
    --jq '[.[] | select(.pull_request == null) | {number, title, labels: [.labels[].name],
           milestone: (.milestone | if . == null then null else {number, title, state, due_on} end)}]' \
    | jq -s 'add // []')
  milestones=$(gh api --paginate "repos/$REPO/milestones?state=all&per_page=100" \
    --jq '[.[] | {number, title, state, due_on, open_issues}]' | jq -s 'add // []')
  # Dependencies are fetched only where the blocked check reads them: one call per in-progress
  # issue, not one per issue.
  deps='{}'
  if [ "$BLOCKED" -eq 1 ]; then
    local n blocked_by
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      # Paginated like the issue list: the endpoint pages at 30 by default, and an open blocker
      # past the first page would otherwise read as "unblocked".
      blocked_by=$(gh api --paginate "repos/$REPO/issues/$n/dependencies/blocked_by?per_page=100" \
        --jq '[.[] | {number, state}]' | jq -s 'add // []')
      deps=$(jq -c --arg n "$n" --argjson b "$blocked_by" '. + {($n): $b}' <<<"$deps")
    done < <(jq -r --arg l "$INPROG" '.[] | select(.labels | index($l)) | .number' <<<"$issues")
  fi
  jq -n --argjson i "$issues" --argjson m "$milestones" --argjson d "$deps" \
    '{issues: ($i | map(. + {blocked_by: ($d[(.number | tostring)] // [])})), milestones: $m}'
}

if [ -n "$FIXTURE" ]; then
  SNAPSHOT=$(jq -c . "$FIXTURE")
  LABEL="$FIXTURE"
else
  SNAPSHOT=$(snapshot_live)
  LABEL="$REPO"
fi

FINDINGS=$(jq -c \
  --argjson require_ms "$REQUIRE_MS" --arg single "$SINGLE" --arg exclusive "$EXCLUSIVE" \
  --argjson blocked "$BLOCKED" --arg inprog "$INPROG" --argjson now "$NOW" '
  def carries($l): (.labels | index($l)) != null;
  ($single | split(",") | map(select(. != ""))) as $namespaces
  | ($exclusive | split(",") | map(select(. != "") | split(":"))) as $pairs
  | .issues as $issues | .milestones as $milestones
  | [
      ($issues[] | select($require_ms == 1 and .milestone == null)
        | {check: "milestone", issue: .number, detail: "no milestone"}),
      ($issues[] | . as $i | $namespaces[] | . as $ns
        | ([$i.labels[] | select(startswith($ns + "/"))] | length) as $c | select($c != 1)
        | {check: "single-select", issue: $i.number, detail: "\($c) \($ns)/ labels, expected exactly one"}),
      ($issues[] | . as $i | $pairs[] | select(length == 2) | . as $p
        | select(($i | carries($p[0])) and ($i | carries($p[1])))
        | {check: "exclusive", issue: $i.number, detail: "\($p[0]) and \($p[1]) both present"}),
      ($issues[] | select($blocked == 1 and carries($inprog))
        | ([(.blocked_by // [])[] | select(.state == "open") | .number | tostring]) as $open
        | select(($open | length) > 0)
        | {check: "blocked", issue: .number, detail: "\($inprog) while blocked by open #\($open | join(", #"))"}),
      ($issues[] | select(.milestone != null and .milestone.state == "closed")
        | {check: "closed-milestone", issue: .number, detail: "open issue in closed milestone \(.milestone.title)"}),
      ($milestones[] | select(.state == "open" and .due_on != null and .open_issues > 0
                               and (.due_on | fromdateiso8601) < $now)
        | {check: "overdue-milestone", issue: null, detail: "\(.title) due \(.due_on) with \(.open_issues) open issue(s)"})
    ]' <<<"$SNAPSHOT")

COUNT=$(jq 'length' <<<"$FINDINGS")
if [ "$COUNT" -eq 0 ]; then
  echo "tracker-audit: OK ($LABEL, $(jq '.issues | length' <<<"$SNAPSHOT") open issues)"
else
  echo "tracker-audit: $COUNT finding(s) in $LABEL"
  jq -r '.[] | "  [\(.check)] \(if .issue == null then "milestone" else "#\(.issue)" end): \(.detail)"' <<<"$FINDINGS"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Tracker audit — $LABEL"
    echo
    if [ "$COUNT" -eq 0 ]; then
      echo "No findings."
    else
      echo "| Check | Issue | Detail |"
      echo "|---|---|---|"
      # Detail text carries milestone titles, which anyone with triage can set; escape the cell separator.
      jq -r '.[] | "| \(.check) | \(if .issue == null then "—" else "#\(.issue)" end) | \(.detail | gsub("\\|"; "\\\\|")) |"' <<<"$FINDINGS"
    fi
    echo
    echo "_Generated: $(date -u '+%Y-%m-%d %H:%M UTC')_"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$COUNT" -gt 0 ]; then
  exit 1
fi
