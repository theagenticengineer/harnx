#!/usr/bin/env bash
# Standalone test for scripts/ai-review/check-locally-reviewed.sh.
# Run: bash scripts/tests/check-locally-reviewed.bash
#
# The gate's job is to refuse a push of a tree that has not passed a clean full
# local ai-review, so that nothing reaches the metered CI review without first
# converging locally. Two failure directions matter and only one of them is
# obvious:
#
#   - it must BLOCK an unreviewed or changed tree, the case everybody thinks of;
#   - it must NOT block a tree that only had its COMMITS rewritten. Folding a
#     fixup and rebasing change every commit hash while preserving the content,
#     and a gate that blocked on that would fire on every amend in this
#     repository's workflow and be disabled within a day. Keying off the tree
#     hash is what buys that, and this suite is what proves the key is the tree
#     and not the commit.
#
# Runs against a REAL throwaway git repository rather than stubbing git: the
# whole mechanism is `git write-tree` over a temp index, so a stub would be
# asserting against a reimplementation of the thing under test.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/check-locally-reviewed.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'one\n' >"$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm 'feat(#1): the first commit here'

statefile="$repo/$(git -C "$repo" rev-parse --git-dir)/ai-review-reviewed-tree"
statefile="$(git -C "$repo" rev-parse --git-path ai-review-reviewed-tree)"

run() { (cd "$repo" && bash "$script" >"$work/out" 2>&1); }

# The tree hash the gate will compute, produced the same way the gate does.
current_tree() {
  local idx
  idx="$work/idx"
  rm -f "$idx"
  # `git -C`, not a subshell `cd &&`. The `cd && cmd || true` form is not
  # if-then-else: the `|| true` also swallows a failing `cd`, so a wrong path
  # would compute a tree for the wrong directory and this suite would compare
  # two values that agree for the wrong reason.
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree HEAD 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git -C "$repo" add -A 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git -C "$repo" write-tree
}

# --- NEVER REVIEWED must block ------------------------------------------------
rm -f "$repo/$statefile"
if run; then
  fail_case "a tree with no recorded review must be blocked"
else ok; fi
if grep -q 'never passed a local ai-review' "$work/out"; then ok; else
  fail_case "the message must say the tree was never reviewed: $(cat "$work/out")"
fi

# --- A RECORDED, MATCHING tree passes -----------------------------------------
mkdir -p "$(dirname "$repo/$statefile")"
current_tree >"$repo/$statefile"
if run; then ok; else
  fail_case "a tree matching its recorded review must pass: $(cat "$work/out")"
fi

# --- A CHANGED tree blocks ----------------------------------------------------
# The change is only in the WORKING TREE, uncommitted, which is the case a
# commit-hash-based gate would miss entirely.
printf 'two\n' >>"$repo/a.txt"
if run; then
  fail_case "an uncommitted working-tree change must be blocked"
else ok; fi
if grep -q 'differs from the last locally-reviewed one' "$work/out"; then ok; else
  fail_case "the message must say the tree differs: $(cat "$work/out")"
fi
# The message must name both hashes, or nobody can tell what changed.
if grep -q 'current:' "$work/out" && grep -q 'reviewed:' "$work/out"; then ok; else
  fail_case "both the current and reviewed hashes must be printed"
fi

# A NEW UNTRACKED FILE also counts as a change. `git add -A` sees it, and a
# review that never read it has not reviewed this tree.
git -C "$repo" checkout -q -- a.txt
printf 'new\n' >"$repo/b.txt"
if run; then
  fail_case "an untracked new file must be blocked"
else ok; fi
rm -f "$repo/b.txt"

# --- THE KEY IS THE TREE, NOT THE COMMIT --------------------------------------
# Re-record against the clean tree, then rewrite history without touching
# content. Amending changes the commit hash and must NOT block.
current_tree >"$repo/$statefile"
before_commit="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" commit -q --amend -m 'feat(#1): the same content, a new message'
after_commit="$(git -C "$repo" rev-parse HEAD)"
if [ "$before_commit" != "$after_commit" ]; then ok; else
  fail_case "the amend must actually have changed the commit, or this case proves nothing"
fi
if run; then ok; else
  fail_case "an amend that preserves content must NOT block a push: $(cat "$work/out")"
fi

# The same claim through a REBASE, which is how this repository folds fixups.
git -C "$repo" branch -q base HEAD
printf 'second\n' >"$repo/c.txt"
git -C "$repo" add c.txt
git -C "$repo" commit -qm 'feat(#1): a second commit to rebase'
current_tree >"$repo/$statefile"
tree_before="$(current_tree)"
GIT_SEQUENCE_EDITOR=true git -C "$repo" rebase -q --autosquash base >/dev/null 2>&1 || true
if [ "$(current_tree)" = "$tree_before" ]; then ok; else
  fail_case "the rebase must preserve the tree, or this case proves nothing"
fi
if run; then ok; else
  fail_case "a rebase that preserves content must NOT block a push: $(cat "$work/out")"
fi

# --- AN EMPTY state file is treated as never reviewed, not as a match ---------
# `cat` of an empty file gives the empty string, and an empty string must not
# be allowed to compare equal to anything.
: >"$repo/$statefile"
if run; then
  fail_case "an empty state file must be treated as never reviewed"
else ok; fi
if grep -q 'never passed a local ai-review' "$work/out"; then ok; else
  fail_case "an empty state file must give the never-reviewed message"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
