#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/check-branch-rebased.sh.
# Run: bash scripts/tests/check-branch-rebased.bash
#
# Runs against a throwaway repository with a real remote, because the property
# under test is about the REMOTE's tip: a gate comparing against a stale local
# copy passes exactly when the branch is most out of date, which is the failure
# worth catching and cannot be reproduced with stubs.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

origin="$work/origin.git"
git init -q --bare -b main "$origin"

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
mkdir -p "$repo/scripts/git-discipline"
cp "$repo_root/scripts/git-discipline/check-branch-rebased.sh" "$repo/scripts/git-discipline/"
cp "$repo_root/scripts/git-discipline/resolve-base.sh" "$repo/scripts/git-discipline/"
cp "$repo_root/scripts/git-discipline/stacking-policy.sh" "$repo/scripts/git-discipline/"
printf 'base\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the base commit'
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q origin main

git -C "$repo" checkout -q -b feat-1-child
printf 'child\n' >"$repo/b.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): a change on the child'

out="$work/out"
run() { (cd "$repo" && env "$@" bash scripts/git-discipline/check-branch-rebased.sh) >"$out" 2>&1; }

# --- a branch that contains its base passes ----------------------------------
if run BASE=main; then ok; else
  fail_case "a branch containing its base must pass: $(cat "$out")"
fi
if grep -q 'contains' "$out"; then ok; else
  fail_case "the success line must name what it contains: $(cat "$out")"
fi

# --- THE BASE MOVES, and the branch is now behind ----------------------------
git -C "$repo" checkout -q main
printf 'moved\n' >>"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): a commit that lands on the base'
git -C "$repo" push -q origin main
git -C "$repo" checkout -q feat-1-child

if run BASE=main; then
  fail_case "a branch behind its base must fail"
else ok; fi
if grep -q 'does not contain the current tip' "$out"; then ok; else
  fail_case "the error must say the branch is behind: $(cat "$out")"
fi
# The COUNT is reported, because "behind" without a number tells nobody whether
# this is one commit or forty.
if grep -q '1 commit(s) behind' "$out"; then ok; else
  fail_case "the error must count how far behind: $(cat "$out")"
fi
# ...and it says what to do, in this repository's own terms.
if grep -q 'git pull' "$out"; then ok; else
  fail_case "the error must name the remedy: $(cat "$out")"
fi

# --- THE REMOTE'S TIP IS WHAT COUNTS, not a stale local ref ------------------
# THE CASE THIS GATE EXISTS FOR. The local `main` here is deliberately left at
# the old commit, so a check comparing against it would report the branch as up
# to date at exactly the moment it is not.
git -C "$repo" branch -f main HEAD~1 2>/dev/null || true
if run BASE=main; then
  fail_case "a stale LOCAL base must not make an out-of-date branch pass"
else ok; fi

# --- rebasing onto the moved base passes again -------------------------------
git -C "$repo" fetch -q origin main
git -C "$repo" rebase -q FETCH_HEAD >/dev/null 2>&1 || true
if run BASE=main; then ok; else
  fail_case "after rebasing onto the moved base it must pass again: $(cat "$out")"
fi

# --- A BRANCH THAT IS ITS OWN BASE has nothing to be behind ------------------
# The ordinary state of the stack's bottom when the fallback answers, and not a
# failure.
if run BRANCH=main BASE=main; then ok; else
  fail_case "a branch that is its own base must pass: $(cat "$out")"
fi
if grep -q 'nothing to check' "$out"; then ok; else
  fail_case "the no-op case must say why it did nothing: $(cat "$out")"
fi

# --- A BASE THAT DOES NOT EXIST ON THE REMOTE is not this gate's subject -----
# The chain-integrity gate reports that, with the whole chain for context. Here
# it would be a confusing second voice, so this says what it could not do.
if run BASE=no-such-branch; then
  fail_case "an unfetchable base must fail rather than pass silently"
else ok; fi
if grep -q 'stack-chain-integrity' "$out"; then ok; else
  fail_case "the error must point at the gate that owns that problem: $(cat "$out")"
fi

# --- THE BASE IS RESOLVED when not given -------------------------------------
# Through resolve-base.sh, so this gate and the chain gate mean the same thing
# by "base". Tier 1 is a local declaration, which `git stack` writes.
git -C "$repo" config branch.feat-1-child.base main
if run; then ok; else
  fail_case "a declared base must be resolved and used: $(cat "$out")"
fi
if grep -q "contains 'main'" "$out"; then ok; else
  fail_case "the resolved base must be the declared one: $(cat "$out")"
fi

# --- A BASE NAME GIT WOULD READ AS AN OPTION IS REFUSED ----------------------
# `BASE` is a documented override, so this name can come straight from a
# caller, and git reads a leading dash as an option wherever it can.
# check-stack-chain.sh and stack.sh guard the identical input at the identical
# boundary.
for bad in '--upload-pack=evil' 'has a space' 'refs/../../etc'; do
  if run BASE="$bad"; then
    fail_case "a base named '$bad' must be refused"
  else ok; fi
done
if grep -q 'not a usable branch name' "$out"; then ok; else
  fail_case "the error must say why the name is unusable: $(cat "$out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
