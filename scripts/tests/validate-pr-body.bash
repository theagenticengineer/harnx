#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/validate-pr-body.sh.
# Run: bash scripts/tests/validate-pr-body.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/validate-pr-body.sh"

pass=0
fail=0

fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

check() {
  local expect="$1" desc="$2" body="$3" branch="${4:-}" out status
  out="$(mktemp)"
  set +e
  bash "$hook" "$body" "$branch" >"$out" 2>&1
  status=$?
  set -e
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "'$desc' expected exit $expect, got $status: $(cat "$out")"
  fi
  rm -f "$out"
}

check 0 "body with Closes #N matching branch passes" $'Closes #6\n\nBody text.' "fix-6-a-title"
check 1 "body missing Closes #N rejected" "Body text with no closing keyword." "fix-6-a-title"
check 1 "body Closes #N mismatched against branch issue number" $'Closes #7\n\nBody text.' "fix-6-a-title"
check 0 "cross-check skipped silently when branch does not match the pattern" "Body text with no closing keyword." "main"
check 0 "Closes #N anywhere in the body, not just the first line" $'Some intro text.\n\nCloses #6' "fix-6-a-title"
check 1 "Closes #67 does not satisfy a required Closes #6 (substring, not exact number)" "Closes #67" "fix-6-a-title"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
