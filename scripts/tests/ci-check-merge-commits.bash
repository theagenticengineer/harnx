#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/ci-check-merge-commits.sh.
# Run: bash scripts/tests/ci-check-merge-commits.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/git-discipline/ci-check-merge-commits.sh"

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
base="$(git rev-parse HEAD)"

# --- test 1: a linear range passes ---
echo two >>f.txt
git_q commit -q -am "second"
echo three >>f.txt
git_q commit -q -am "third"
head="$(git rev-parse HEAD)"

set +e
out="$(BASE_SHA="$base" HEAD_SHA="$head" bash "$script" 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 for a linear range, got $status: $out"
[[ "$out" == *"2 commit(s) in range"* ]] || fail "expected the examined count reported, got '$out'"

# --- test 2: an EMPTY range fails rather than passing silently ---
# Same rule as the sibling ci-validate-commits.sh: a check that examined
# nothing must not report success.
set +e
out="$(BASE_SHA="$head" HEAD_SHA="$head" bash "$script" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 for an empty range, got $status"
[[ "$out" == *"contains no commits"* ]] || fail "expected an empty-range message, got '$out'"

# --- test 3: a merge commit in the range fails, and is named ---
git_q checkout -q -b side "$base"
echo side >g.txt
git_q add g.txt
git_q commit -q -m "side work"
git_q checkout -q main
git_q merge -q --no-edit --no-ff side >/dev/null 2>&1
merged_head="$(git rev-parse HEAD)"

set +e
out="$(BASE_SHA="$base" HEAD_SHA="$merged_head" bash "$script" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 when the range contains a merge, got $status"
[[ "$out" == *"1 merge commit(s)"* ]] || fail "expected the merge count, got '$out'"
[[ "$out" == *"$merged_head"* ]] || fail "expected the offending SHA named, got '$out'"

# --- test 4: EVERY merge is reported, not just the first ---
# Reporting one per push costs a CI round-trip per merge commit, which is the
# accumulate-rather-than-abort rule the sibling checks in this job follow.
git_q checkout -q -b side2 "$base"
echo side2 >h.txt
git_q add h.txt
git_q commit -q -m "side2 work"
git_q checkout -q main
git_q merge -q --no-edit --no-ff side2 >/dev/null 2>&1
two_head="$(git rev-parse HEAD)"

set +e
out="$(BASE_SHA="$base" HEAD_SHA="$two_head" bash "$script" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 with two merges, got $status"
[[ "$out" == *"2 merge commit(s)"* ]] || fail "expected both merges counted, got '$out'"
named="$(printf '%s\n' "$out" | grep -c '^::error::merge commit ' || true)"
[[ "$named" == "2" ]] || fail "expected both merge commits named individually, got $named"

# --- test 5: missing environment is a hard error, not a silent pass ---
for missing in BASE_SHA HEAD_SHA; do
  set +e
  if [ "$missing" = "BASE_SHA" ]; then
    out="$(HEAD_SHA="$head" bash "$script" 2>&1)"
  else
    out="$(BASE_SHA="$base" bash "$script" 2>&1)"
  fi
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected a non-zero exit when $missing is unset"
  [[ "$out" == *"$missing is required"* ]] || fail "expected '$missing is required', got '$out'"
done

echo "PASS: ci-check-merge-commits.bash"
