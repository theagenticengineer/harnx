#!/usr/bin/env bash
# Standalone test for scripts/ai-review/require-diff.sh.
# Run: bash scripts/tests/require-diff.bash
#
# The case this suite exists for is the SECOND one below: a diff.txt that is
# present but zero bytes. The guard used to test existence only, while
# review-engine.sh short-circuits on size, so an empty diff produced zero
# findings and a green ai-review-resolved over a pull request that was never
# reviewed. Nothing downstream of the engine can notice that, because "zero
# findings because the diff was empty" and "zero findings because the code is
# clean" are byte-identical by the time they reach the gate. This is the only
# place the distinction still exists, so it is the only place it can be pinned.
#
# Hermetic by construction: the script under test touches no network and no
# API, it only stats a file.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/require-diff.sh"

work="$(mktemp -d)"
out="$work/out"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Runs the guard over $work/diff.txt in whatever state the caller left it.
run_guard() {
  local label="$1" expect="$2" status
  set +e
  env DIFF_FILE="$work/diff.txt" bash "$script" >"$out" 2>&1
  status=$?
  set -e
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected exit $expect, got $status: $(cat "$out")"
  fi
}

# --- a real diff is reviewable ------------------------------------------------
printf 'diff --git a/x b/x\n+a change\n' >"$work/diff.txt"
run_guard "non-empty-diff-passes" 0

# --- present but zero bytes ---------------------------------------------------
# The regression this file was added for. `: >` truncates to exactly 0 bytes,
# which is what review-engine.sh's `[ ! -s ]` turns into `[]` and exit 0, and
# from there into zero threads, no unresolved Major, and a green required
# check over a pull request nothing read.
: >"$work/diff.txt"
run_guard "empty-diff-fails-closed" 1
if grep -q 'present but empty' "$out"; then
  pass=$((pass + 1))
else
  fail_case "an empty diff must say so, not be reported as a failed extraction: $(cat "$out")"
fi

# --- absent -------------------------------------------------------------------
rm -f "$work/diff.txt"
run_guard "absent-diff-fails-closed" 1
# The two failures must stay distinguishable. Collapsing them into one message
# would send whoever reads a broken pipeline looking for an empty range, and
# whoever reads an empty range looking for a broken pipeline.
if grep -q 'produced no diff.txt' "$out"; then
  pass=$((pass + 1))
else
  fail_case "an absent diff must be named as a failed extraction: $(cat "$out")"
fi

# --- a missing DIFF_FILE is a broken invocation, not a pass -------------------
set +e
env -u DIFF_FILE bash "$script" >"$out" 2>&1
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  pass=$((pass + 1))
else
  fail_case "an unset DIFF_FILE must be refused, not treated as reviewable"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
