#!/usr/bin/env bash
# Standalone test for scripts/ai-review/loop-init.sh.
# Run: bash scripts/tests/loop-init.bash
#
# The script seeds the loop's working memory. Two properties carry the weight,
# and only the first is obvious:
#
#   - it creates what a pass needs to read;
#   - it NEVER OVERWRITES. This is the one that matters. `loop:prompt` invokes
#     it on every pass, so a version that rewrote its templates would erase the
#     plan, the decisions and the discovered facts of the loop that was standing
#     on them, every single pass, and the loop would run forever without
#     accumulating anything. The tests below therefore write recognisable
#     content into each seeded file and assert it survives.
#
# Runs against a REAL throwaway git repository: the script resolves its own
# location with `git rev-parse --show-toplevel` and writes a baseline row keyed
# to the current branch, so a stub would be asserting against a
# reimplementation of the thing under test.
#
# `gh` IS FORCED ABSENT for most cases, via a PATH with no gh on it. Reaching
# the real GitHub from a test suite would make the result depend on the network
# and on the runner's credentials; the null-baseline path it produces is a case
# that has to work anyway, since a contributor without gh is ordinary.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/loop-init.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

# A PATH carrying the real tool directory but no `gh`. Symlinking the binaries
# the script actually needs (git, jq, and the coreutils it shells out to) rather
# than emptying PATH entirely, which would break the script for reasons that
# have nothing to do with what is being tested.
nogh="$work/nogh"
mkdir -p "$nogh"
# `bash` is on this list too, and its absence is not a hypothetical oversight:
# `env PATH=... bash script` resolves bash through the NEW path, so a list that
# forgets it fails with "env: bash: No such file or directory" and every
# assertion below reports a missing file rather than the real cause.
for tool in bash git jq date sed sort wc tr cat mkdir grep printf; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$nogh/$tool"
done

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'one\n' >"$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -qm 'feat(#1): the first commit here'
git -C "$repo" branch -M feat-9-a-rung

loop="$repo/.harnx/loop"
run() { (cd "$repo" && env PATH="$nogh" bash "$script" >"$work/out" 2>&1); }

# --- 1. it seeds what a pass has to read -------------------------------------
run || true
# Kept, because later cases overwrite $work/out and the baseline messages below
# are properties of the FIRST run, when the baseline is actually written.
first_out="$work/first-out"
cp "$work/out" "$first_out"
for f in .gitignore plan.md learnings.md decisions.md manual.md handoff.md last-failure.txt passes.jsonl; do
  if [ -f "$loop/$f" ]; then ok; else
    fail_case "loop-init must seed $f; output was: $(cat "$work/out")"
  fi
done

# --- 2. the ignore is a catch-all with one exception --------------------------
# An enumeration would leave a silent gap for the next file added here, and
# every file in this directory except the ignore itself is instance state.
if [ "$(grep -c '^\*$' "$loop/.gitignore")" = "1" ] &&
  grep -qx '!.gitignore' "$loop/.gitignore"; then ok; else
  fail_case "the seeded .gitignore must be '*' plus '!.gitignore'"
fi

# --- 3. git must actually ignore the state ------------------------------------
# Asserted through git rather than by reading the pattern, because the question
# is whether loop state can reach a commit, not whether a file contains a glob.
# THE IGNORE IS STAGED FIRST, which mirrors harnx itself, where .harnx/loop/.gitignore
# is the one tracked file in the directory. It is not a convenience: git
# collapses a wholly-untracked directory into a single `?? .harnx/loop/` entry
# and never looks inside, so without something tracked in there the assertion
# would report the directory rather than answer whether the state is ignored.
git -C "$repo" add -f .harnx/loop/.gitignore
printf 'x\n' >"$loop/plan.md"
untracked="$(git -C "$repo" status --porcelain --untracked-files=all -- .harnx/loop | grep -v '\.gitignore' || true)"
if [ -z "$untracked" ]; then ok; else
  fail_case "loop state must be ignored by git, got: $untracked"
fi
# ...and asked directly of git as well, so a passing status cannot be an
# artifact of how status collapses directories.
if (cd "$repo" && env PATH="$nogh" git check-ignore -q .harnx/loop/plan.md); then ok; else
  fail_case "git must report .harnx/loop/plan.md as ignored"
fi

# --- 4. NEVER OVERWRITES ------------------------------------------------------
# The property the whole design rests on: loop:prompt runs this every pass.
for f in plan.md learnings.md decisions.md manual.md handoff.md last-failure.txt; do
  printf 'PRESERVE-ME-%s\n' "$f" >"$loop/$f"
done
run || true
survived=1
for f in plan.md learnings.md decisions.md manual.md handoff.md last-failure.txt; do
  grep -q "PRESERVE-ME-$f" "$loop/$f" || survived=0
done
if [ "$survived" = 1 ]; then ok; else
  fail_case "a second run must not overwrite existing loop state"
fi

# --- 5. idempotent, and it says so --------------------------------------------
if grep -q 'already seeded' "$work/out"; then ok; else
  fail_case "a no-op run must say so, got: $(cat "$work/out")"
fi

# --- 6. exactly ONE baseline row per rung ------------------------------------
# Two baselines would halve every round count computed from the later one,
# which is a silent weakening of the stop condition rather than a visible break.
if [ "$(jq -s '[.[] | select(.type == "baseline")] | length' "$loop/passes.jsonl")" = "1" ]; then ok; else
  fail_case "running twice must not write a second baseline row, got $(cat "$loop/passes.jsonl")"
fi

# --- 7. the baseline is keyed to the rung, and says CI is unknown -------------
# `null`, not 0. Zero is a claim that CI has never run, which would let the cap
# count only local passes while looking like it had counted both.
if [ "$(jq -s -r '.[0] | "\(.type) \(.rung) \(.ci_head_shas)"' "$loop/passes.jsonl")" = "baseline feat-9-a-rung null" ]; then ok; else
  fail_case "the baseline must name the rung and record an unknown CI count as null, got $(head -1 "$loop/passes.jsonl")"
fi
if grep -q 'ci_head_shas: null' "$first_out"; then ok; else
  fail_case "a null baseline must be reported out loud, got: $(cat "$first_out")"
fi

# --- 8. a DIFFERENT rung gets its own baseline -------------------------------
# Rungs are counted separately; inheriting another branch's baseline would
# start a fresh branch pre-spent.
git -C "$repo" branch -M feat-10-another-rung
run || true
if [ "$(jq -s '[.[] | select(.type == "baseline")] | length' "$loop/passes.jsonl")" = "2" ] &&
  [ "$(jq -s -r '[.[] | select(.type == "baseline") | .rung] | sort | join(",")' "$loop/passes.jsonl")" = "feat-10-another-rung,feat-9-a-rung" ]; then ok; else
  fail_case "a second rung must get its own baseline row, got $(cat "$loop/passes.jsonl")"
fi

# --- 9. a baseline is not re-detected by key ORDER ---------------------------
# The presence check must be structural. A substring match on jq's output order
# passes today and breaks silently the moment a field is inserted before `rung`.
git -C "$repo" branch -M feat-9-a-rung
printf '%s\n' '{"rung":"feat-9-a-rung","type":"baseline","ci_head_shas":7}' >"$loop/passes.jsonl"
run || true
if [ "$(jq -s '[.[] | select(.type == "baseline")] | length' "$loop/passes.jsonl")" = "1" ]; then ok; else
  fail_case "an existing baseline written with different key order must still be recognised, got $(cat "$loop/passes.jsonl")"
fi

# --- 10. seeded templates carry their own instructions -----------------------
# The files are read by an agent in a clean context window, so a bare empty file
# would arrive with no statement of what may be written into it. The two rules
# that are not guessable are the ones asserted.
rm -rf "$loop"
run || true
if grep -q 'APPEND ONLY' "$loop/learnings.md" &&
  grep -q 'APPEND AND SUPERSEDE' "$loop/decisions.md" &&
  grep -q 'NO STATUS' "$loop/manual.md"; then ok; else
  fail_case "the seeded templates must state the rules a pass cannot guess"
fi

# --- 11. it runs from a subdirectory -----------------------------------------
# pre-commit runs hooks from the repository root; `mise run` and a human do not.
rm -rf "$loop"
mkdir -p "$repo/deep/er"
if (cd "$repo/deep/er" && env PATH="$nogh" bash "$script" >"$work/out" 2>&1) &&
  [ -f "$loop/plan.md" ]; then ok; else
  fail_case "loop-init must work from a subdirectory, got: $(cat "$work/out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
