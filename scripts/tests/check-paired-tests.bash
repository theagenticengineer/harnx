#!/usr/bin/env bash
# Standalone test for scripts/check-paired-tests.sh.
# Run: bash scripts/tests/check-paired-tests.bash
#
# WHAT THIS PROTECTS. This gate is what turns the homing rule from a preference
# into a check, so its own failure modes are the interesting part:
#
#   - fail-open: a script with no test slips through, which is how six scripts
#     reached the default branch untested in the first place.
#   - fail-closed on the wrong thing: a suite that legitimately has no script
#     (action-pins, trunk-toolchain, workflow-job-names are suites over the
#     workflows and the toolchain) must not be reported as a violation, or the
#     only ways to green are to delete real tests or to create empty scripts.
#
# Hermetic: a scratch git repository is built and the real gate is run inside
# it. The gate reads `git ls-files` and `git rev-parse --show-toplevel`, so a
# real repository is the only honest fixture; nothing here touches this one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/check-paired-tests.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/out.txt"
repo="$work/repo"

# Rebuilds the scratch repository. Arguments are paths to create and `git add`.
setup() {
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet --initial-branch=trunk
  git -C "$repo" config user.email "test@example.invalid"
  git -C "$repo" config user.name "Test"
  local p
  for p in "$@"; do
    mkdir -p "$repo/$(dirname "$p")"
    printf '#!/usr/bin/env bash\n' >"$repo/$p"
  done
  git -C "$repo" add -A
}

run() {
  local status
  set +e
  (cd "${1:-$repo}" && bash "$script") >"$out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# --- a paired script and test is the passing shape ---------------------------
setup scripts/a.sh scripts/tests/a.bash
if [ "$(run)" = "0" ]; then ok; else
  fail_case "a script with its paired test must pass: $(cat "$out")"
fi
if grep -q '1 script' "$out"; then ok; else
  fail_case "the pass must say how many scripts it checked: $(cat "$out")"
fi

# --- THE FAIL-OPEN THIS GATE EXISTS TO CLOSE ---------------------------------
setup scripts/a.sh
if [ "$(run)" = "1" ]; then ok; else
  fail_case "a script with no paired test must fail"
fi
# The failure has to be actionable: which script, and which file to write.
if grep -q 'scripts/a.sh -> scripts/tests/a.bash' "$out"; then ok; else
  fail_case "the failure must name the script and the file to write: $(cat "$out")"
fi
# And it must point at the rule rather than only at the symptom.
if grep -q 'tests-homing.md' "$out"; then ok; else
  fail_case "the failure must cite the rule it enforces"
fi

# --- every offender is reported, not just the first --------------------------
# One push must be able to report the whole backlog, the same argument
# evaluate-gate.sh makes for running both of its sub-checks.
setup scripts/a.sh scripts/b.sh scripts/tests/a.bash
if [ "$(run)" = "1" ] && grep -q 'scripts/b.sh' "$out"; then ok; else
  fail_case "an offender after a compliant script must still be reported"
fi
setup scripts/a.sh scripts/b.sh
if [ "$(run)" = "1" ] &&
  grep -q 'scripts/a.sh' "$out" && grep -q 'scripts/b.sh' "$out"; then ok; else
  fail_case "every offender must be listed, not only the first: $(cat "$out")"
fi

# --- nested directories are in scope -----------------------------------------
# scripts/ai-review/ holds the credentialed scripts and scripts/mise/ the task
# runners. A gate that only looked at the top level would exempt exactly the
# code that most needs a test.
setup scripts/ai-review/deep.sh
if [ "$(run)" = "1" ] && grep -q 'scripts/ai-review/deep.sh' "$out"; then ok; else
  fail_case "a script in a subdirectory must be in scope: $(cat "$out")"
fi
# The same property stated as the thing a reader doubts, so a change that
# narrowed the pathspec to the top level fails here by name rather than by a
# count nobody reads. `scripts/*.sh` is a git PATHSPEC, matched with fnmatch
# without FNM_PATHNAME, so `*` crosses `/`; shell-glob intuition says otherwise
# and has produced this exact finding twice.
setup scripts/top.sh scripts/ai-review/nested.sh scripts/mise/deeper.sh scripts/tests/top.bash
if [ "$(run)" = "1" ] &&
  grep -q 'scripts/ai-review/nested.sh' "$out" &&
  grep -q 'scripts/mise/deeper.sh' "$out"; then ok; else
  fail_case "the pathspec must reach every depth, not just the top level: $(cat "$out")"
fi
# And the count the gate reports must be the whole set, which is the other half
# of the same claim: a narrowed pathspec would still pass the case above if it
# happened to catch one level, but it could not report all three.
setup scripts/top.sh scripts/ai-review/nested.sh scripts/mise/deeper.sh scripts/tests/top.bash scripts/tests/nested.bash scripts/tests/deeper.bash
if [ "$(run)" = "0" ] && grep -q '3 script' "$out"; then ok; else
  fail_case "the gate must count scripts at every depth: $(cat "$out")"
fi
setup scripts/mise/task.sh scripts/tests/task.bash
if [ "$(run)" = "0" ]; then ok; else
  fail_case "the pairing is by basename regardless of depth: $(cat "$out")"
fi

# --- THE DIRECTION IS ONE WAY ------------------------------------------------
# A suite with no script is legitimate: action-pins.bash, trunk-toolchain.bash
# and workflow-job-names.bash cover the workflows and the toolchain, which have
# no basename to pair with. Reporting them would leave two ways to green, both
# wrong: delete real tests, or create empty scripts to satisfy a checker.
setup scripts/tests/action-pins.bash scripts/tests/workflow-job-names.bash
if [ "$(run)" = "0" ]; then ok; else
  fail_case "a suite with no script must not be a violation: $(cat "$out")"
fi

# --- untracked scripts are nobody's business ---------------------------------
# A scratch file in a worktree must not red the gate. What must NOT be exempt
# is a newly ADDED script, which is in the index by the time a pre-commit hook
# runs, so the gate fires on the commit that introduces it.
setup scripts/a.sh scripts/tests/a.bash
printf '#!/usr/bin/env bash\n' >"$repo/scripts/scratch.sh"
if [ "$(run)" = "0" ]; then ok; else
  fail_case "an untracked script must not fail the gate: $(cat "$out")"
fi
git -C "$repo" add scripts/scratch.sh
if [ "$(run)" = "1" ] && grep -q 'scripts/scratch.sh' "$out"; then ok; else
  fail_case "a STAGED new script must fail the gate, on its own commit"
fi

# --- it runs from anywhere in the tree ---------------------------------------
# pre-commit invokes hooks from the repository root, `mise run` and a human do
# not have to, and the gate resolves the root itself.
setup scripts/a.sh
mkdir -p "$repo/scripts/ai-review"
if [ "$(run "$repo/scripts/ai-review")" = "1" ]; then ok; else
  fail_case "the gate must work when invoked from a subdirectory: $(cat "$out")"
fi

# --- a repository with no scripts at all is not a failure --------------------
# Unlike test.sh's empty-suite case, "no scripts" here means there is nothing
# to pair, not that a check verified nothing.
setup
if [ "$(run)" = "0" ]; then ok; else
  fail_case "a tree with no scripts must pass: $(cat "$out")"
fi

# --- a basename collision is refused, not silently half-paired ---------------
# scripts/tests/ is flat, so pairing by basename means two scripts with the
# same basename in different directories are BOTH satisfied by one test file,
# and one of them is untested while this gate reports green. That is the exact
# fail-open the gate exists to close, reintroduced by its own matching rule.
setup scripts/ai-review/x.sh scripts/mise/x.sh scripts/tests/x.bash
if [ "$(run)" = "1" ]; then ok; else
  fail_case "two scripts sharing a basename must not both be paired by one test"
fi
if grep -q 'share a basename' "$out"; then ok; else
  fail_case "the collision must be named as a collision: $(cat "$out")"
fi
# Both offenders have to be identifiable, or the fix is a guessing game.
if grep -q 'scripts/ai-review/x.sh' "$out" && grep -q 'scripts/mise/x.sh' "$out"; then ok; else
  fail_case "both colliding paths must be reported: $(cat "$out")"
fi
# The collision is refused even when NEITHER has a test, so the message the
# author gets is the actionable one rather than "write two files with the same
# name".
setup scripts/ai-review/x.sh scripts/mise/x.sh
if [ "$(run)" = "1" ] && grep -q 'share a basename' "$out"; then ok; else
  fail_case "a collision must be reported ahead of the missing-test list: $(cat "$out")"
fi
# Distinct basenames at different depths are not a collision.
setup scripts/ai-review/x.sh scripts/mise/y.sh scripts/tests/x.bash scripts/tests/y.bash
if [ "$(run)" = "0" ]; then ok; else
  fail_case "different basenames at different depths must still pass: $(cat "$out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
