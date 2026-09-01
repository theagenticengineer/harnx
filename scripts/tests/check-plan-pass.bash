#!/usr/bin/env bash
# Standalone test for scripts/ai-review/check-plan-pass.sh.
# Run: bash scripts/tests/check-plan-pass.bash
#
# "A plan pass implements nothing" is the kind of rule that is worth nothing as
# an instruction, because the pass that ignored it is also the pass reporting on
# itself. This makes it deterministic.
#
# BOTH DIRECTIONS ARE TESTED, and the second is the one a one-sided check would
# miss: a pass that touched NOTHING satisfies "implement nothing" perfectly. A
# gate that only asked question one would reward doing no work at all.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/check-plan-pass.sh"

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
mkdir -p "$repo/.harnx/loop"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'one\n' >"$repo/a.txt"
printf '*\n!.gitignore\n' >"$repo/.harnx/loop/.gitignore"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the first commit here'

loop="$repo/.harnx/loop"
run() { (cd "$repo" && bash "$script" >"$work/out" 2>&1); }

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
snapshot() {
  {
    printf 'mode=%s\n' "$1"
    printf 'prompt_sha=deadbeef\n'
    printf 'plan_sha=%s\n' "$(sha_of "$loop/plan.md")"
    printf 'status_sha=x\n'
  } >"$loop/.pass-snapshot"
}

printf '# Plan\n\n- [ ] nothing yet\n' >"$loop/plan.md"

# --- 1. no snapshot is not a pass --------------------------------------------
# Exit 2, distinct from a failed check: "nothing to compare against" and "the
# pass did the wrong thing" are different facts and a caller may want to tell
# them apart.
rm -f "$loop/.pass-snapshot"
if run; then
  fail_case "a missing snapshot must not pass"
else ok; fi
if grep -q 'nothing to compare against' "$work/out"; then ok; else
  fail_case "a missing snapshot must say so, got: $(cat "$work/out")"
fi

# --- 2. THE GOOD CASE: the plan changed and nothing else did -----------------
snapshot plan
printf '# Plan\n\n- [ ] a real item\n- [ ] another\n' >"$loop/plan.md"
if run; then ok; else
  fail_case "a plan pass that only changed the plan must pass, got: $(cat "$work/out")"
fi

# --- 3. a plan pass that changed a TRACKED file fails ------------------------
snapshot plan
printf '# Plan\n\n- [ ] changed again\n' >"$loop/plan.md"
printf 'two\n' >>"$repo/a.txt"
if run; then
  fail_case "a plan pass that edited a tracked file must fail"
else ok; fi
if grep -q 'changed tracked files' "$work/out"; then ok; else
  fail_case "the failure must name what went wrong, got: $(cat "$work/out")"
fi
# The offending path is named, because a gate that says only "something changed"
# sends its reader to `git status` to find out what the gate already knew.
if grep -q 'a.txt' "$work/out"; then ok; else
  fail_case "the failure must name the changed file, got: $(cat "$work/out")"
fi
git -C "$repo" checkout -- a.txt

# --- 4. a plan pass that planned NOTHING fails -------------------------------
# The half a one-sided check misses.
snapshot plan
if run; then
  fail_case "a plan pass that did not change the plan must fail"
else ok; fi
if grep -q 'planned nothing' "$work/out"; then ok; else
  fail_case "the failure must say the plan is unchanged, got: $(cat "$work/out")"
fi

# --- 5. an UNTRACKED new file is still a change ------------------------------
# A plan pass that dropped a new script in the tree has implemented something,
# and `git status --porcelain` reports untracked files, so this must fail. It is
# worth pinning: the loop state itself is untracked, so a reader might expect
# untracked files to be excluded wholesale.
snapshot plan
printf '# Plan\n\n- [ ] moved on\n' >"$loop/plan.md"
printf 'x\n' >"$repo/new-thing.sh"
if run; then
  fail_case "a plan pass that added an untracked file must fail"
else ok; fi
rm -f "$repo/new-thing.sh"

# --- 6. THE LOOP STATE ITSELF IS NOT A VIOLATION -----------------------------
# .harnx/loop/ is gitignored, so writing learnings and decisions (which a plan
# pass is told to do) must not trip the gate. If it did, every correct plan pass
# would fail and the gate would be switched off within a day.
snapshot plan
printf '# Plan\n\n- [ ] onward\n' >"$loop/plan.md"
printf 'learned a thing\n' >>"$loop/learnings.md"
printf 'decided a thing\n' >>"$loop/decisions.md"
if run; then ok; else
  fail_case "writing loop state must not count as implementing, got: $(cat "$work/out")"
fi

# --- 7. a BUILD pass is not judged by this gate ------------------------------
# A build pass is supposed to change files. Applying the plan-pass rule to it
# would fail every successful build.
snapshot build
printf 'three\n' >>"$repo/a.txt"
if run; then ok; else
  fail_case "a build pass must not be judged by the plan-pass rule, got: $(cat "$work/out")"
fi
if grep -q "not 'plan'" "$work/out"; then ok; else
  fail_case "it must say why it did not apply, got: $(cat "$work/out")"
fi
git -C "$repo" checkout -- a.txt

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
