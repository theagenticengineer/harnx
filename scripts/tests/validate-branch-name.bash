#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/validate-branch-name.sh. Exercises both call
# modes: no argument (reads git HEAD, used by the local post-checkout hook)
# and an explicit branch-name argument (used by the branch-name CI job so it
# doesn't need to rely on git HEAD state).
# Run: bash scripts/tests/validate-branch-name.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/validate-branch-name.sh"

pass=0
fail=0

fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

check_arg() {
  local branch="$1" expect="$2" out
  out="$(mktemp)"
  set +e
  bash "$hook" "$branch" >"$out" 2>&1
  local status=$?
  set -e
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "arg-mode '$branch' expected exit $expect, got $status: $(cat "$out")"
  fi
  rm -f "$out"
}

check_arg "main" 0
check_arg "fix-6-self-heal-worktree-check" 0
check_arg "build-9-bump-deps" 0
check_arg "ci-9-bump-deps" 0
check_arg "perf-9-speed-up" 0
check_arg "revert-9-undo-bad-change" 0
check_arg "style-9-formatting" 1
check_arg "fix-6" 1
check_arg "fix-my-feature" 1
check_arg "fix-abc-title" 1
check_arg "Fix-6-title" 1

check_head() {
  local branch="$1" expect="$2"
  local sandbox
  sandbox="$(mktemp -d)"
  git -C "$sandbox" init -q -b main
  git -C "$sandbox" -c user.email=t@e.com -c user.name=t commit -q --allow-empty -m init
  git -C "$sandbox" checkout -q -b "$branch" 2>/dev/null || git -C "$sandbox" checkout -q "$branch"
  local out
  out="$(mktemp)"
  set +e
  (cd "$sandbox" && bash "$hook") >"$out" 2>&1
  local status=$?
  set -e
  rm -rf "$sandbox"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "HEAD-mode '$branch' expected exit $expect, got $status: $(cat "$out")"
  fi
  rm -f "$out"
}

check_head "main" 0
check_head "perf-9-speed-up" 0
check_head "style-9-formatting" 1

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
