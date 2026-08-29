#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/parse-commit-header.sh.
# Run: bash scripts/tests/parse-commit-header.bash
#
# The fragment is two variables, which is exactly why it needs a test: both are
# sourced by validate-commit-msg.sh AND validate-branch-name.sh, so a change
# here silently changes what two different gates accept. The point of the
# fragment is that those two can never drift apart, and nothing else checks
# that the shared value still means what its callers assume.
#
# Every helper call below that is not already inside an `if` carries `|| true`.
# Under `set -e` a bare failing call aborts the suite, and a suite that aborts
# reports the assertions it had reached rather than a failure, which reads as
# a smaller run rather than a broken one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/git-discipline/parse-commit-header.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$repo_root/scripts/git-discipline/parse-commit-header.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

accepts() {
  if printf '%s' "$1" | grep -qE "$COMMIT_HEADER_RE"; then ok; else
    fail_case "must accept: '$1'"
  fi
}
rejects() {
  if printf '%s' "$1" | grep -qE "$COMMIT_HEADER_RE"; then
    fail_case "must reject ($2): '$1'"
  else ok; fi
}

# --- the shape every commit in this repository uses ---------------------------
accepts 'feat(#2): genesis self-verifying floor'
accepts 'fix(#1234): a title of sufficient length'
accepts 'docs(#7): explain the arrangement'

# --- EVERY declared type is actually accepted ---------------------------------
# Iterated from the variable rather than listed again here. A second hand-kept
# list would be the drift the fragment exists to prevent, one level up.
while IFS= read -r t; do
  accepts "$t(#1): a title of sufficient length"
done < <(printf '%s' "$COMMIT_TYPES_RE" | tr '|' '\n')

# `revert` specifically, because it is the type with an argument attached to
# it. Its presence is what makes an issue-scoped revert authorable at all.
if printf '%s' "$COMMIT_TYPES_RE" | grep -q 'revert'; then ok; else
  fail_case "revert must remain a declared type, or no conventional revert can be authored"
fi
# ...and git's OWN default revert subject must still fail, which is the
# fragment's stated claim about why including the type is safe.
rejects 'Revert "feat(#2): genesis self-verifying floor"' "git's default revert subject carries no (#N) scope"

# --- the issue scope is mandatory ---------------------------------------------
rejects 'feat: a title of sufficient length' "no issue scope"
rejects 'feat(): a title of sufficient length' "empty issue scope"
rejects 'feat(#): a title of sufficient length' "no issue number"
rejects 'feat(#abc): a title of sufficient length' "non-numeric issue"
rejects 'feat(2): a title of sufficient length' "missing the #"

# --- the type must be one of the declared ones --------------------------------
rejects 'nonsense(#1): a title of sufficient length' "undeclared type"
rejects 'Feat(#1): a title of sufficient length' "type is lower-case only"

# --- title length and trailing whitespace -------------------------------------
# >=10 characters. Both sides of the boundary, so an off-by-one in the {9,}
# quantifier is visible rather than inferred.
rejects 'feat(#1): 123456789' "a nine-character title is one short"
accepts 'feat(#1): 1234567890'
rejects 'feat(#1): a title of sufficient length ' "a trailing space"
rejects 'feat(#1): a title of sufficient length	' "a trailing tab"
rejects 'feat(#1):no space after the colon' "no space after the colon"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
