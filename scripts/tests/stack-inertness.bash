#!/usr/bin/env bash
# Standalone test: the stacking machinery is POLICY-NEUTRAL and INERT.
# Run: bash scripts/tests/stack-inertness.bash
#
# Two properties, and neither is provable by reading the scripts.
#
# POLICY-NEUTRAL. Whether and how to stack is a property of the project, not of
# the harness. `.harnx/custom-hooks/git-discipline/policy.sh` is the slot a
# repository uses to say so; an absent or empty slot means this floor's default,
# which is that stacking is on.
#
# INERT. On a repository that never sets a non-main base, the stacking machinery
# must take NO ACTION and FAIL NOTHING. "Fails nothing" is the half that is easy
# to get wrong: a gate that exits non-zero on a repository with no stack is not
# inert, it is broken for everybody who does not stack, and harnx generates
# repositories for both kinds of project.
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

# A repository that never stacks: one branch, `main`, no worktrees, no bases
# declared, no pull requests. The shape of every project that adopts this floor
# and never adopts stacking.
repo="$work/plain"
mkdir -p "$repo/scripts/git-discipline" "$repo/scripts/mise" "$repo/.harnx/custom-hooks/git-discipline"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
for f in check-stack-chain.sh resolve-base.sh check-branch-rebased.sh stacking-policy.sh; do
  cp "$repo_root/scripts/git-discipline/$f" "$repo/scripts/git-discipline/"
done
cp "$repo_root/scripts/mise/setup-git-config.sh" "$repo/scripts/mise/"
printf 'x\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): a repository that never stacks'

out="$work/out"
run() { (cd "$repo" && env "$@" bash "$1" "${@:2}") >"$out" 2>&1; }
run_script() {
  local s="$1"
  shift
  (cd "$repo" && env "$@" bash "$s") >"$out" 2>&1
}

# --- INERT: the base resolver answers without a stack ------------------------
if run_script scripts/git-discipline/resolve-base.sh BASE_NO_NETWORK=1; then ok; else
  fail_case "resolve-base must succeed on a repository with no stack: $(cat "$out")"
fi

# --- INERT: branch-rebased takes no action on `main` -------------------------
# `main` is its own base under the fallback, so there is nothing to be behind.
if run_script scripts/git-discipline/check-branch-rebased.sh BASE_NO_NETWORK=1; then ok; else
  fail_case "check-branch-rebased must not fail a repository with no stack: $(cat "$out")"
fi
if grep -q 'nothing to check' "$out"; then ok; else
  fail_case "the no-op must say why it did nothing: $(cat "$out")"
fi

# --- POLICY-NEUTRAL: the slot turns the machinery off ------------------------
# With `HARNX_STACKING=off`, the chain gate must not walk and the git settings
# must not be written. Both must SUCCEED: off means inert, not broken.
printf 'HARNX_STACKING=off\n' >"$repo/.harnx/custom-hooks/git-discipline/policy.sh"

# Run with NO `gh` on PATH at all. "Inert" means taking no action, and a network
# call is an action: a repository that turned stacking off must not have this
# gate reaching for the API, and it must not fail offline for a project that
# never asked for any of this. An earlier version resolved the terminus before
# consulting the policy, so this case failed with a network error.
if PATH="/usr/bin:/bin" run_script scripts/git-discipline/check-stack-chain.sh HEAD_BRANCH=main; then ok; else
  fail_case "with stacking off, the chain gate must succeed without gh on PATH: $(cat "$out")"
fi
if grep -q 'stacking is off' "$out"; then ok; else
  fail_case "the gate must say the policy turned it off: $(cat "$out")"
fi
# It must not have walked anything, which is the difference between inert and
# "passed because the chain happened to be fine".
if grep -q 'walking from' "$out"; then
  fail_case "with stacking off, the gate must not walk at all: $(cat "$out")"
else ok; fi

# EVERY consumer, not the two that were wired first. `check-branch-rebased.sh`
# is stacking machinery too, and an earlier version of this criterion wired the
# policy into `setup-git-config.sh` and the chain gate and not into it, so
# `off` left that gate still acting and "inert" was not true.
#
# Asserted on a branch where the gate WOULD otherwise act: on `main` it no-ops
# because a branch is its own base, so testing it there passes for a reason that
# has nothing to do with the policy. That is exactly why the gap survived the
# first version of this suite.
git -C "$repo" checkout -q -b feat-1-would-act
if run_script scripts/git-discipline/check-branch-rebased.sh BASE=nonexistent-base; then ok; else
  fail_case "with stacking off, check-branch-rebased must be inert even where it would act: $(cat "$out")"
fi
if grep -q 'stacking is off' "$out"; then ok; else
  fail_case "check-branch-rebased must say the policy turned it off: $(cat "$out")"
fi
# ...and with the policy removed it DOES act on that same branch, or the case
# above passes on a gate that never does anything.
mv "$repo/.harnx/custom-hooks/git-discipline/policy.sh" "$work/policy.saved"
if run_script scripts/git-discipline/check-branch-rebased.sh BASE=nonexistent-base; then
  fail_case "without the policy, that same branch must NOT be inert"
else ok; fi
mv "$work/policy.saved" "$repo/.harnx/custom-hooks/git-discipline/policy.sh"
git -C "$repo" checkout -q main

if run_script scripts/mise/setup-git-config.sh; then ok; else
  fail_case "with stacking off, setup-git-config must succeed: $(cat "$out")"
fi
if grep -q 'not written' "$out"; then ok; else
  fail_case "setup-git-config must say it wrote nothing: $(cat "$out")"
fi
# THE ASSERTION THAT MATTERS for policy-neutrality: no stacking configuration
# was actually written. A message saying so while writing anyway is the failure.
for key in pull.rebase push.default alias.stack; do
  if [ -z "$(git -C "$repo" config --local --get "$key" || true)" ]; then ok; else
    fail_case "with stacking off, $key must not be set, got '$(git -C "$repo" config --local --get "$key")'"
  fi
done

# --- THE DEFAULT IS UNCHANGED when the slot is absent or empty ---------------
# Otherwise the slot would be a way to break a repository by adding an empty
# file, and "absent" and "off" would be the same thing.
rm -f "$repo/.harnx/custom-hooks/git-discipline/policy.sh"
if run_script scripts/mise/setup-git-config.sh; then ok; else
  fail_case "with no policy, setup-git-config must run normally: $(cat "$out")"
fi
if [ -n "$(git -C "$repo" config --local --get pull.rebase || true)" ]; then ok; else
  fail_case "with no policy, the stacking settings must be written"
fi

: >"$repo/.harnx/custom-hooks/git-discipline/policy.sh"
git -C "$repo" config --local --unset-all pull.rebase 2>/dev/null || true
if run_script scripts/mise/setup-git-config.sh &&
  [ -n "$(git -C "$repo" config --local --get pull.rebase || true)" ]; then ok; else
  fail_case "an EMPTY policy must mean the default, not off: $(cat "$out")"
fi

# --- THE SLOT IS TRACKED, so a generated repository has somewhere to put one --
if [ -f "$repo_root/.harnx/custom-hooks/git-discipline/.gitignore" ]; then ok; else
  fail_case "the injection slot must exist in this repository, or a generated one has nowhere to inject"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
