#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/stack.sh. Builds a throwaway
# origin plus a clone with a linked worktree, so the interesting case (running
# the command from INSIDE a worktree and still landing under the primary
# clone) is exercised rather than assumed.
# Run: bash scripts/tests/stack.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/git-discipline/stack.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

git_q() { git -c user.email=t@example.com -c user.name=t "$@"; }

# origin, with main and one feature branch to stack on
origin="$sandbox/origin.git"
seed="$sandbox/seed"
git_q init -q -b main "$seed"
# The scripts go INTO the sandbox repo, not just alongside it, so test 10 can
# drive the real `git stack` alias end to end: the alias resolves its script
# through the caller's own worktree top level, which only means anything if the
# script is actually tracked in that repository.
mkdir -p "$seed/scripts/git-discipline" "$seed/scripts/mise"
# `stacking-policy.sh` is in this list because `setup-git-config.sh` SOURCES it.
# A fixture missing a sourced fragment fails at runtime, in CI, for a reason
# that has nothing to do with the case under test, and it fails only in CI: on a
# developer machine the fragment may already exist in the sandbox from an
# earlier run, so the omission is invisible locally. That is exactly how this
# was missed, and it is why the list is spelled out rather than globbed.
cp "$repo_root/scripts/git-discipline/stack.sh" \
  "$repo_root/scripts/git-discipline/validate-branch-name.sh" \
  "$repo_root/scripts/git-discipline/parse-commit-header.sh" \
  "$repo_root/scripts/git-discipline/stacking-policy.sh" \
  "$seed/scripts/git-discipline/"
cp "$repo_root/scripts/mise/setup-git-config.sh" "$seed/scripts/mise/"
git_q -C "$seed" add -A
git_q -C "$seed" commit -q -m "init"
git_q -C "$seed" branch feat-2-base
# -b main is load-bearing, not tidiness. Without it a bare repo's HEAD follows
# the MACHINE's init.defaultBranch, so on a runner defaulting to `master` HEAD
# points at a ref this test never creates, `git clone` warns "remote HEAD
# refers to nonexistent ref" and produces an EMPTY working tree, and every
# assertion that reads a file out of the clone fails for a reason that has
# nothing to do with the code under test. Passed locally and failed in CI
# exactly once before this line existed.
git_q init -q --bare -b main "$origin"
git_q -C "$seed" remote add origin "$origin"
git_q -C "$seed" push -q origin main feat-2-base

clone="$sandbox/clone"
git_q clone -q "$origin" "$clone"
[[ -f "$clone/scripts/git-discipline/stack.sh" ]] ||
  fail "the sandbox clone has no working tree; check the bare repo's HEAD"

# --- test 1: wrong argument count is a usage error, exit 2 ---
# An ARRAY, not an unquoted string. The point of the loop is to vary the
# argument COUNT, which an unquoted expansion achieves through word splitting
# and an array expresses directly. It also stops the floor's `quote-safe-
# variables` check from having to be silenced here: that check arrived with
# .shellcheckrc one rung down, measured at zero findings against that tree, and
# this was the first place above it that needed an answer. Rewriting is the
# answer; a disable directive would have been a second one.
for count in 0 1; do
  args=()
  [ "$count" -eq 0 ] || args=("only-one")
  set +e
  out="$(bash "$script" ${args[@]+"${args[@]}"} 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "expected exit 2 for $count argument(s), got $status"
  [[ "$out" == *"usage: git stack"* ]] || fail "expected usage text for $count argument(s)"
done

# --- test 2: malformed arguments are refused before any git command runs ---
# `branch` is interpolated into the worktree path, so traversal must not reach
# `git worktree add`; a leading dash on either argument must not reach git as a
# flag. Both are refused by the floor's own branch-name gate, reused rather
# than reimplemented here.
for bad in "../../escape" "feat-1-ok/../../escape" "-x" "has space" "UPPER-1-nope"; do
  set +e
  out="$(cd "$clone" && bash "$script" "$bad" feat-2-base 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "expected exit 2 for <branch> '$bad', got $status"
  [[ "$out" == *"not a valid branch name"* ]] || fail "expected a validation message for '$bad', got '$out'"
done
[[ ! -e "$sandbox/escape" && ! -e "$clone/../escape" ]] ||
  fail "a traversing branch name created something outside .worktrees/"

for bad in "../../escape" "-x" "has space"; do
  set +e
  status=0
  (cd "$clone" && bash "$script" feat-77-ok "$bad" >/dev/null 2>&1) || status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "expected exit 2 for <parent> '$bad', got $status"
done

# --- test 3: a parent that does not exist on origin is refused ---
set +e
# a WELL-FORMED name that simply is not on origin, so this exercises the
# show-ref check rather than tripping the argument validation above
out="$(cd "$clone" && bash "$script" feat-9-new feat-999-missing 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 for a missing parent, got $status"
[[ "$out" == *"does not exist"* ]] || fail "expected a missing-parent message, got '$out'"
[[ ! -d "$clone/.worktrees/feat-9-new" ]] || fail "a refused rung must leave no worktree behind"

# --- test 4: the happy path creates branch, worktree and tracking ref ---
(cd "$clone" && bash "$script" feat-34-thing feat-2-base >/dev/null)

[[ -d "$clone/.worktrees/feat-34-thing" ]] ||
  fail "expected the worktree at $clone/.worktrees/feat-34-thing"

head="$(git -C "$clone/.worktrees/feat-34-thing" rev-parse --abbrev-ref HEAD)"
[[ "$head" == "feat-34-thing" ]] || fail "expected the worktree on feat-34-thing, got '$head'"

# The tracking ref IS the branch's remembered base. Everything the ripple does
# upstack depends on it pointing at the parent, so assert it explicitly rather
# than trusting branch.autoSetupMerge to stay a default.
upstream="$(git -C "$clone/.worktrees/feat-34-thing" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
[[ "$upstream" == "origin/feat-2-base" ]] ||
  fail "expected upstream origin/feat-2-base, got '$upstream'"

base_sha="$(git -C "$clone" rev-parse origin/feat-2-base)"
new_sha="$(git -C "$clone/.worktrees/feat-34-thing" rev-parse HEAD)"
[[ "$base_sha" == "$new_sha" ]] || fail "the new rung must start at origin/feat-2-base"

# --- test 5: run from INSIDE a worktree, the new rung still lands under the
# primary clone, not nested inside the caller's worktree ---
(cd "$clone/.worktrees/feat-34-thing" && bash "$script" feat-41-next feat-2-base >/dev/null)

[[ -d "$clone/.worktrees/feat-41-next" ]] ||
  fail "expected the second rung under the PRIMARY clone"
[[ ! -d "$clone/.worktrees/feat-34-thing/.worktrees/feat-41-next" ]] ||
  fail "the second rung was nested inside the caller's worktree; primary-root resolution is broken"

# --- test 6: the tracking ref survives a hostile branch.autoSetupMerge ---
# The whole ripple depends on that ref. Leaving it to git's default made it a
# function of the developer's config, and a global autoSetupMerge=false would
# have produced an upstream-less branch with no error at all.
git_q -C "$clone" config --local branch.autoSetupMerge false
(cd "$clone" && bash "$script" feat-42-tracked feat-2-base >/dev/null)
upstream="$(git -C "$clone/.worktrees/feat-42-tracked" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
[[ "$upstream" == "origin/feat-2-base" ]] ||
  fail "expected --track to win over branch.autoSetupMerge=false, got '$upstream'"
git_q -C "$clone" config --local --unset branch.autoSetupMerge

# --- test 7: a failed tracking verification rolls the rung back ---
# --track normally succeeds, so the failure branch is unreachable without
# forcing it. Shim `git` on PATH to answer the one upstream query with nothing
# and delegate everything else to the real binary, which exercises the recovery
# path rather than trusting it.
real_git="$(command -v git)"
shim_bin="$sandbox/shim"
mkdir -p "$shim_bin"
cat >"$shim_bin/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = '@{upstream}' ]; then exit 1; fi
done
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_bin/git"

set +e
out="$(cd "$clone" && PATH="$shim_bin:$PATH" bash "$script" feat-99-rollback feat-2-base 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 when the tracking ref cannot be verified, got $status"
[[ "$out" == *"Rolling back"* ]] || fail "expected a rollback message, got '$out'"
[[ ! -d "$clone/.worktrees/feat-99-rollback" ]] ||
  fail "a failed tracking verification must leave no worktree behind"
git -C "$clone" show-ref --verify --quiet refs/heads/feat-99-rollback &&
  fail "a failed tracking verification must leave no branch behind"

# --- test 8: a rollback that cannot complete says so, rather than claiming success ---
# The two cleanup calls swallow their errors on purpose, so the honest report
# has to come from checking the end state. Widen the shim to block the worktree
# removal as well, which also blocks the branch delete (git refuses to delete a
# branch still checked out in a worktree), and assert the message tells the
# truth about both.
cat >"$shim_bin/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = '@{upstream}' ]; then exit 1; fi
done
if [ "\$3" = "worktree" ] && [ "\$4" = "remove" ]; then exit 1; fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_bin/git"

set +e
out="$(cd "$clone" && PATH="$shim_bin:$PATH" bash "$script" feat-98-stuck feat-2-base 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 when the rollback cannot complete, got $status"
[[ "$out" == *"Rollback INCOMPLETE"* ]] ||
  fail "expected an honest incomplete-rollback message, got '$out'"
[[ "$out" != *"Rolled back."* ]] ||
  fail "a failed rollback must NOT also claim it rolled back"
[[ "$out" == *"worktree and branch"* ]] ||
  fail "expected both leftovers named, got '$out'"

# leave the sandbox clean for the remaining tests
git -C "$clone" worktree remove --force ".worktrees/feat-98-stuck" 2>/dev/null || true
git -C "$clone" branch -D feat-98-stuck >/dev/null 2>&1 || true

# --- test 9: re-using an existing branch name is refused by git, not silently
# absorbed, and leaves the existing worktree intact ---
set +e
(cd "$clone" && bash "$script" feat-34-thing feat-2-base >/dev/null 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "expected a non-zero exit when the branch already exists"
head="$(git -C "$clone/.worktrees/feat-34-thing" rev-parse --abbrev-ref HEAD)"
[[ "$head" == "feat-34-thing" ]] || fail "the existing worktree must survive a refused re-create"

# --- test 10: the `git stack` alias works end to end, from a subdirectory ---
# Everything above drives stack.sh directly, which leaves the alias itself
# untested: its whole indirection is `$(git rev-parse --show-toplevel)`,
# resolved by git at run time, and that is the part a stored-config assertion
# cannot reach. Run it for real, and run it from a SUBDIRECTORY, because
# top-level resolution is exactly what a subdirectory would break if the alias
# were written with a relative path instead.
bash "$clone/scripts/mise/setup-git-config.sh" >/dev/null

sub="$clone/scripts/git-discipline"
(cd "$sub" && git stack feat-55-via-alias feat-2-base >/dev/null)

[[ -d "$clone/.worktrees/feat-55-via-alias" ]] ||
  fail "the alias must create the rung under the primary clone, not under the cwd"
upstream="$(git -C "$clone/.worktrees/feat-55-via-alias" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
[[ "$upstream" == "origin/feat-2-base" ]] ||
  fail "the alias path must set the tracking ref too, got '$upstream'"

# and from inside a linked worktree, where --show-toplevel resolves to that
# worktree rather than the primary clone
(cd "$clone/.worktrees/feat-55-via-alias" && git stack feat-56-via-alias feat-2-base >/dev/null)
[[ -d "$clone/.worktrees/feat-56-via-alias" ]] ||
  fail "the alias must still land under the primary clone when run from a worktree"
[[ ! -d "$clone/.worktrees/feat-55-via-alias/.worktrees" ]] ||
  fail "the alias nested a rung inside the calling worktree"

# --- test 11: the validator's own reason reaches the caller ---
set +e
out="$(cd "$clone" && bash "$script" "UPPER-1-nope" feat-2-base 2>&1)"
set -e
[[ "$out" == *"not a valid branch name"* ]] || fail "expected the stack-level message"
[[ "$out" == *"must match"* ]] ||
  fail "expected validate-branch-name.sh's own reason to be surfaced, got '$out'"

# --- test 12: a repository using --separate-git-dir still resolves correctly ---
# dirname(--git-common-dir) looks like a fine way to find the primary clone
# and silently is not: --separate-git-dir puts a .git FILE in the worktree and
# the real git directory somewhere else, so that arithmetic lands next to the
# git dir instead of in the repository. `git worktree list` reports the
# worktree path itself and is unaffected.
sep_clone="$sandbox/sep-clone"
sep_gitdir="$sandbox/sep-gitdir"
git_q clone -q --separate-git-dir "$sep_gitdir" "$origin" "$sep_clone"
[[ -f "$sep_clone/.git" ]] || fail "expected --separate-git-dir to leave a .git FILE"

(cd "$sep_clone" && bash "$script" feat-66-separate feat-2-base >/dev/null)

[[ -d "$sep_clone/.worktrees/feat-66-separate" ]] ||
  fail "expected the rung inside the worktree, not beside the separate git dir"
[[ ! -e "$sandbox/.worktrees" && ! -e "$sep_gitdir/../.worktrees" ]] ||
  fail "a rung was created outside the repository"

# --- test 13: the layout git misreports is refused, not silently misplaced ---
# From a LINKED worktree of a --separate-git-dir clone, `git worktree list`
# names the git dir rather than the working tree, and there is no other command
# that recovers the right answer. Refusing with an explanation is the correct
# outcome; creating a worktree next to the git directory is not.
git_q -C "$sep_clone" worktree add -q "$sandbox/sep-linked" -b feat-67-linked >/dev/null 2>&1
set +e
out="$(cd "$sandbox/sep-linked" && bash "$script" feat-68-nope feat-2-base 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "expected exit 1 in a layout git misreports, got $status"
[[ "$out" == *"could not resolve the primary worktree"* ]] ||
  fail "expected an explanatory refusal, got '$out'"
[[ ! -d "$sep_gitdir/.worktrees" ]] ||
  fail "a rung was created beside the separate git dir"

# --- THE BASE IS RECORDED, not left to be inferred from the tracking ref -----
# `branch.<branch>.base` is what resolve-base.sh's first tier reads and what
# check-stack-chain.sh compares against the pull request's own base. Nothing
# wrote that key before, so tier 1 was unreachable and the chain gate's mismatch
# arm could never fire anywhere. Tracking is not a substitute: it says where
# push and pull go, and a contributor can repoint it in one command.
recorded="$(git -C "$clone" config --get branch.feat-56-via-alias.base || true)"
[[ "$recorded" == "feat-2-base" ]] ||
  fail "git stack must record the parent in branch.<branch>.base, got '$recorded'"

echo "PASS: stack.bash"
