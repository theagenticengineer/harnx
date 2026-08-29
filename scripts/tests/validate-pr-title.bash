#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/validate-pr-title.sh.
# Run: bash scripts/tests/validate-pr-title.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/validate-pr-title.sh"

pass=0
fail=0

fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

check() {
  local expect="$1" desc="$2" title="$3" branch="${4:-}" out status
  out="$(mktemp)"
  set +e
  bash "$hook" "$title" "$branch" >"$out" 2>&1
  status=$?
  set -e
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "'$desc' expected exit $expect, got $status: $(cat "$out")"
  fi
  rm -f "$out"
}

check 0 "valid title passes" "fix(#6): a valid enough title" "fix-6-a-title"
check 1 "malformed type rejected" "style(#6): formatting only change" "style-6-formatting"
check 1 "missing issue number rejected" "fix: a valid enough title" "fix-6-a-title"
check 1 "title shorter than 10 chars rejected" "fix(#6): too short" "fix-6-too-short"
check 1 "trailing whitespace rejected" "fix(#6): a valid enough title " "fix-6-a-title"
check 1 "title issue number mismatched against branch issue number" \
  "fix(#6): a valid enough title" "fix-7-a-title"
check 0 "title issue number matches branch issue number" \
  "fix(#6): a valid enough title" "fix-6-a-title"
check 0 "cross-check skipped silently when branch does not match the pattern" \
  "fix(#6): a valid enough title" "main"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
