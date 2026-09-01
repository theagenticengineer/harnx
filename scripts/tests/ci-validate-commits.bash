#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/ci-validate-commits.sh.
# Run: bash scripts/tests/ci-validate-commits.bash
#
# This is the CI wrapper that runs validate-commit-msg.sh over a pull request's
# commit range. Its own logic is small, and the case worth pinning is the one
# that is invisible when it breaks: an empty range must FAIL, not report a green
# `commitlint` check having validated nothing.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/ci-validate-commits.sh"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Builds a repo with a base commit plus one commit per subject given, then runs
# the wrapper over base..HEAD with the branch name it should cross-check against.
run_range() {
  local label="$1" expect="$2" branch="$3"
  shift 3
  local sb base status subject
  sb="$(mktemp -d)"
  git -C "$sb" init -q -b "$branch"
  git -C "$sb" config user.name Dev
  git -C "$sb" config user.email dev@acme.org
  git -C "$sb" commit -q --allow-empty -m "base"
  base="$(git -C "$sb" rev-parse HEAD)"
  for subject in "$@"; do
    git -C "$sb" commit -q --allow-empty -m "$subject

A body paragraph, required by the header validator."
  done
  set +e
  (cd "$sb" && env BASE_SHA="$base" HEAD_SHA=HEAD COMMIT_MSG_BRANCH="$branch" \
    bash "$hook") >"$out" 2>&1
  status=$?
  set -e
  rm -rf "$sb"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected exit $expect, got $status: $(cat "$out")"
  fi
}

run_range "valid-single-commit-passes" 0 "feat-7-a-branch" "feat(#7): a valid enough title"
run_range "valid-multiple-commits-pass" 0 "feat-7-a-branch" \
  "feat(#7): a valid enough title" "fix(#7): another valid title"
run_range "malformed-header-fails" 1 "feat-7-a-branch" "not a conventional header at all"
# The failure must be caught wherever it sits in the range, not only first.
run_range "malformed-later-in-range-fails" 1 "feat-7-a-branch" \
  "feat(#7): a valid enough title" "nope, malformed"
# Issue-number drift between the commit header and the branch is the whole
# reason the branch name is threaded through.
run_range "issue-number-mismatch-fails" 1 "feat-7-a-branch" "feat(#8): a valid enough title"
# Every bad commit in the range is reported, not just the first. Unguarded
# under `set -e` the loop aborted on the first failure, so a pull request with
# three bad messages burned one CI round per commit to discover them all.
run_range "all-bad-commits-reported-not-just-the-first" 1 "feat-7-a-branch" \
  "first malformed header" "second malformed header" "third malformed header"

# The case this suite exists for: base == head validated nothing, so reporting
# success would make the required check green over an unexamined range.
run_range "empty-range-fails" 1 "feat-7-a-branch"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
