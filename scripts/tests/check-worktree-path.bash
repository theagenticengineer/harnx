#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/check-worktree-path.sh. Builds a throwaway git
# repo so the hook logic can be exercised without touching the real repo.
# Run: bash scripts/tests/check-worktree-path.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/check-worktree-path.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

git -C "$sandbox" init -q -b main
git -C "$sandbox" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m "init"

# --- test 1: main is exempt, no side effects ---
set +e
(cd "$sandbox" && "$hook")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 on main, got $status"

# --- test 2: bad branch checked out in the primary clone self-heals to main ---
git -C "$sandbox" branch bad-branch
git -C "$sandbox" checkout -q bad-branch

set +e
(cd "$sandbox" && "$hook")
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 for bad branch in primary clone, got $status"

current_branch="$(git -C "$sandbox" rev-parse --abbrev-ref HEAD)"
[[ "$current_branch" == "main" ]] ||
  fail "expected primary clone reverted to main, still on '$current_branch'"

git -C "$sandbox" show-ref --verify --quiet refs/heads/bad-branch ||
  fail "bad-branch ref must survive the self-heal, only the checkout reverts"

# --- test 3: same branch checked out in a linked worktree passes untouched ---
git -C "$sandbox" worktree add -q "$sandbox-wt" bad-branch

set +e
(cd "$sandbox-wt" && "$hook")
status=$?
set -e
rm -rf "$sandbox-wt"
git -C "$sandbox" worktree prune
[[ "$status" -eq 0 ]] || fail "expected exit 0 for bad branch inside a worktree, got $status"

# --- test 4: a file checkout ($3=0) skips the whole check, even a bad branch
# in the primary clone: no ref changed, so no assertion ---
git -C "$sandbox" checkout -q bad-branch
set +e
(cd "$sandbox" && "$hook" HEAD HEAD 0)
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 on a file checkout (\$3=0), got $status"
[[ "$(git -C "$sandbox" rev-parse --abbrev-ref HEAD)" == "bad-branch" ]] ||
  fail "a file checkout (\$3=0) must not revert the branch"
git -C "$sandbox" checkout -q main

# --- test 5: a DIRTY primary clone on a bad branch is refused, not
# auto-reverted (auto-reverting would carry the uncommitted work onto main) ---
git -C "$sandbox" checkout -q bad-branch
touch "$sandbox/uncommitted.txt"
set +e
(cd "$sandbox" && "$hook")
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 (refuse) for a dirty primary clone, got $status"
[[ "$(git -C "$sandbox" rev-parse --abbrev-ref HEAD)" == "bad-branch" ]] ||
  fail "a dirty primary clone must NOT be auto-reverted to main (would carry work onto main)"
[[ -f "$sandbox/uncommitted.txt" ]] || fail "the uncommitted file was lost"
rm -f "$sandbox/uncommitted.txt"
git -C "$sandbox" checkout -q main

# --- test 6: real pre-commit invocation carries no $3 (it exposes the same
# flag as $PRE_COMMIT_CHECKOUT_TYPE instead); a bad branch in the primary
# clone must still be caught via the env var, not just via $3 ---
git -C "$sandbox" checkout -q bad-branch
set +e
(cd "$sandbox" && PRE_COMMIT_CHECKOUT_TYPE=1 "$hook")
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 via \$PRE_COMMIT_CHECKOUT_TYPE=1 (no \$3), got $status"
git -C "$sandbox" checkout -q bad-branch

# --- test 7: $PRE_COMMIT_CHECKOUT_TYPE=0 (pre-commit's file-checkout signal)
# skips the check exactly like $3=0 does, with no $3 given ---
set +e
(cd "$sandbox" && PRE_COMMIT_CHECKOUT_TYPE=0 "$hook")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 via \$PRE_COMMIT_CHECKOUT_TYPE=0 (no \$3), got $status"
[[ "$(git -C "$sandbox" rev-parse --abbrev-ref HEAD)" == "bad-branch" ]] ||
  fail "\$PRE_COMMIT_CHECKOUT_TYPE=0 must not revert the branch"
git -C "$sandbox" checkout -q main

echo "ok: check-worktree-path.sh self-heals a clean primary clone, refuses a dirty one, leaves worktrees untouched, skips a file checkout via \$3 or \$PRE_COMMIT_CHECKOUT_TYPE"
