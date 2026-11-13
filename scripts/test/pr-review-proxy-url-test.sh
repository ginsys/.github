#!/usr/bin/env bash
# pr-review-proxy-url-test.sh — the proxy URL that pr-review.yml hands to the
# pr-review-threads action, as a function of the caller's CCPROXY_URL variable.
#
# The test states something about the value the action input receives, not about where the
# URL is written. It evaluates the expression of the workflow's `proxy-url` input over three
# caller states (variable unset, set, set to an empty string) and checks each result.
#
# Usage: pr-review-proxy-url-test.sh [REPO_ROOT]
# Needs yq (mikefarah, v4).

set -uo pipefail # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
WORKFLOW="$ROOT/.github/workflows/pr-review.yml"

# The URL a run used before the variable existed. A run with no override must still get these
# exact bytes. Change it only when the proxy's own address changes.
DEFAULT_URL='http://claude-proxy.claude-proxy.svc:3456'

failures=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'" >&2
    failures=$((failures + 1))
  fi
}

step_query='.jobs.pr-review.steps[] | select(.with."proxy-url" != null)'
expr="$(yq "$step_query | .with.\"proxy-url\"" "$WORKFLOW")"
env_default="$(yq '.jobs.pr-review.env.CCPROXY_URL' "$WORKFLOW")"

# eval_expr VARS_VALUE_OR_@: evaluate the `${{ a || b }}` expression the way Actions does for
# the shapes this workflow uses: `vars.NAME` and `env.NAME` terms joined by `||`, the first
# non-empty term wins. A term of any other shape is reported, never guessed.
# VARS_VALUE is the caller's CCPROXY_URL variable; `@` means the variable is not set.
eval_expr() {
  local vars_value="$1" body term name value
  body="${expr#\$\{\{}"
  body="${body%\}\}}"
  while IFS= read -r term; do
    term="$(printf '%s' "$term" | tr -d ' ')"
    case "$term" in
      vars.*)
        name="${term#vars.}"
        value=""
        if [ "$name" = CCPROXY_URL ] && [ "$vars_value" != "@" ]; then value="$vars_value"; fi
        ;;
      env.*)
        name="${term#env.}"
        value="$(yq ".jobs.pr-review.env.$name // \"\"" "$WORKFLOW")"
        ;;
      *)
        printf 'UNSUPPORTED-TERM:%s' "$term"
        return
        ;;
    esac
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
  done < <(printf '%s\n' "$body" | sed 's/||/\n/g')
  printf ''
}

assert_eq "the env default is the pre-change URL, byte for byte" "$DEFAULT_URL" "$env_default"
assert_eq "no override: the action receives the default URL" "$DEFAULT_URL" "$(eval_expr @)"
assert_eq "variable set: the action receives the variable" "https://override.example:8443" "$(eval_expr https://override.example:8443)"
assert_eq "variable set to an empty string: the action receives the default URL" "$DEFAULT_URL" "$(eval_expr '')"

if [ "$failures" -gt 0 ]; then
  echo "pr-review-proxy-url-test: $failures failed, $pass_count passed" >&2
  exit 1
fi
echo "pr-review-proxy-url-test: $pass_count passed"
