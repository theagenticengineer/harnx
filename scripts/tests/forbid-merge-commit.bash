#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/forbid-merge-commit.sh. Drives a
# throwaway repo through a REAL conflicted merge, because the second wiring
# (commit-msg, via MERGE_HEAD) only exists on that path and asserting it any
# other way would assert nothing.
# Run: bash scripts/tests/forbid-merge-commit.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/forbid-merge-commit.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

git_q() { git -c user.email=t@example.com -c user.name=t "$@"; }

repo="$sandbox/repo"
git_q init -q -b main "$repo"
cd "$repo"
echo one >f.txt
git_q add f.txt
git_q commit -q -m "init"

# --- test 1: an ordinary commit is untouched (no MERGE_HEAD, so a no-op) ---
set +e
(cd "$repo" && "$hook")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 with no merge in progress, got $status"

# --- test 2: mid-merge, the hook refuses ---
git_q checkout -q -b side
echo side >f.txt
git_q commit -q -am "side"
git_q checkout -q main
echo mainline >f.txt
git_q commit -q -am "mainline"

# A conflicting merge leaves MERGE_HEAD set and the merge paused, which is
# exactly the state `git commit` would complete and pre-merge-commit misses.
set +e
git_q merge side >/dev/null 2>&1
merge_status=$?
set -e
[[ "$merge_status" -ne 0 ]] || fail "expected the merge to conflict; the fixture is not exercising the paused-merge path"

git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 ||
  fail "expected MERGE_HEAD to be set during a paused merge"

set +e
out="$(cd "$repo" && "$hook" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 during a paused merge, got $status"
[[ "$out" == *"merge commit refused"* ]] || fail "expected a refusal message, got '$out'"
[[ "$out" == *"pull.rebase"* ]] || fail "expected the recovery advice to name pull.rebase"

# --- test 3: once the merge is aborted, the hook is a no-op again ---
git_q merge --abort
set +e
(cd "$repo" && "$hook")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 after 'git merge --abort', got $status"

# --- test 4: a clean (non-conflicting) merge also leaves MERGE_HEAD unset
# afterwards, so the hook must be caught at pre-merge-commit, not here ---
# Assert the complementary fact the two-stage wiring rests on: after git has
# CREATED a merge commit, MERGE_HEAD is gone, so commit-msg alone would never
# have seen it.
git_q checkout -q -b other main
echo other >g.txt
git_q add g.txt
git_q commit -q -m "other file"
git_q checkout -q main
git_q merge -q --no-edit other >/dev/null 2>&1 || fail "expected a clean merge for this fixture"
git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 &&
  fail "MERGE_HEAD should be cleared once the merge commit exists; the pre-merge-commit stage is what covers this path"

echo "PASS: forbid-merge-commit.bash"
