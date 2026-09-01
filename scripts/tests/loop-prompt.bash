#!/usr/bin/env bash
# Standalone test for scripts/ai-review/loop-prompt.sh.
# Run: bash scripts/tests/loop-prompt.bash
#
# The contract this suite exists to hold is one sentence: THE PROMPT IS FIXED
# AND THE STATE VARIES. Everything below is a way of asking whether that is
# still true, because the failure it guards against is silent. A prompt that
# drifted with the state would still produce plausible passes; it would just
# stop being a fixed instruction, and nothing about the output would say so.
#
# The strongest assertion here is byte-identity of the prompt half across two
# runs whose state differs in every file. Comparing whole outputs would prove
# nothing (they are meant to differ) and comparing nothing would prove less.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/loop-prompt.sh"
init="$repo_root/scripts/ai-review/loop-init.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

# No gh: loop-prompt seeds through loop-init, which asks GitHub for a baseline.
# Reaching the network from a suite would make the result depend on credentials.
nogh="$work/nogh"
mkdir -p "$nogh"
for tool in bash git jq date sed sort wc tr cat mkdir grep printf awk shasum head; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$nogh/$tool"
done

repo="$work/repo"
mkdir -p "$repo/scripts/ai-review"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
cp "$script" "$repo/scripts/ai-review/loop-prompt.sh"
cp "$init" "$repo/scripts/ai-review/loop-init.sh"
printf 'one\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the first commit here'
git -C "$repo" branch -M feat-9-a-rung

loop="$repo/.harnx/loop"
run() { (cd "$repo" && env PATH="$nogh" bash scripts/ai-review/loop-prompt.sh "$@" >"$work/out" 2>"$work/err"); }

# --- 1. THE MODE IS REQUIRED -------------------------------------------------
# The whole point of two prompts is that the caller chooses. A default would
# hand that choice back to the agent.
if run; then
  fail_case "no mode must be refused"
else
  [ "$?" = 2 ] || true
  ok
fi
if grep -q 'no mode given' "$work/err"; then ok; else
  fail_case "the refusal must say the mode is missing, got: $(cat "$work/err")"
fi
if run wobble; then
  fail_case "an unrecognised mode must be refused"
else ok; fi
if grep -q "unrecognised mode 'wobble'" "$work/err"; then ok; else
  fail_case "the refusal must name the bad mode, got: $(cat "$work/err")"
fi
# It must not have run the pass anyway.
if [ ! -f "$loop/.pass-snapshot" ]; then ok; else
  fail_case "a refused mode must not record a snapshot"
fi

# --- 2. it seeds, so a fresh checkout needs no separate setup ----------------
run plan || true
for f in prompt-plan.md prompt-build.md plan.md decisions.md learnings.md manual.md; do
  if [ -f "$loop/$f" ]; then ok; else
    fail_case "loop-prompt must seed $f; stderr: $(cat "$work/err")"
  fi
done

# --- 3. THE PROMPT IS EMITTED VERBATIM ---------------------------------------
# Byte-for-byte, not "contains". A wrapper line added around it would pass a
# containment check and break the fixed-prompt property.
plan_len="$(wc -c <"$loop/prompt-plan.md" | tr -d ' ')"
if [ "$(head -c "$plan_len" "$work/out" | shasum -a 256 | awk '{print $1}')" = \
  "$(shasum -a 256 "$loop/prompt-plan.md" | awk '{print $1}')" ]; then ok; else
  fail_case "the output must begin with the prompt file, byte for byte"
fi

# --- 4. THE PROMPT HALF IS IDENTICAL ACROSS RUNS WITH DIFFERENT STATE --------
# This is the assertion the whole design rests on. Every state file is changed
# between the two runs, so anything that leaked state into the prompt half
# fails here.
first="$work/first"
cp "$work/out" "$first"
printf 'a failure happened\n' >"$loop/last-failure.txt"
printf '# Plan\n\n- [ ] do a thing\n' >"$loop/plan.md"
printf '# Decisions\n\nchose X\n' >"$loop/decisions.md"
printf '# Discovered facts\n\nmeasured Y\n' >"$loop/learnings.md"
printf '# Operating manual\n\nrun Z\n' >"$loop/manual.md"
run plan || true
if [ "$(head -c "$plan_len" "$first" | shasum -a 256)" = \
  "$(head -c "$plan_len" "$work/out" | shasum -a 256)" ]; then ok; else
  fail_case "the prompt half must be byte-identical across passes with different state"
fi
# ...and the whole output must NOT be identical, or the assertion above would
# also pass on a script that ignored the state entirely.
if [ "$(shasum -a 256 <"$first")" != "$(shasum -a 256 <"$work/out")" ]; then ok; else
  fail_case "the state block must actually reflect the state"
fi

# --- 5. THE LAST FAILURE COMES FIRST -----------------------------------------
# Position is the point: a context window degrades from the middle, and the last
# failure is usually the whole of the next pass's work.
order="$(grep -n '^--- BEGIN ' "$work/out" | sed 's/.*BEGIN //; s/ ---$//' | tr '\n' ',')"
if [ "$order" = "LAST FAILURE,PLAN,DECISIONS,DISCOVERED FACTS,MANUAL,HANDOFF," ]; then ok; else
  fail_case "the state block order is fixed and last-failure-first, got: $order"
fi
if grep -q 'a failure happened' "$work/out"; then ok; else
  fail_case "the last failure must appear in the state block"
fi

# --- 6. EVERY SECTION IS ALWAYS PRESENT, EMPTY OR NOT ------------------------
# An omitted section cannot be told apart from one the assembler forgot.
: >"$loop/last-failure.txt"
: >"$loop/decisions.md"
run build || true
count="$(grep -c '^--- BEGIN ' "$work/out")"
if [ "$count" = "6" ]; then ok; else
  fail_case "all six sections must be emitted even when empty, got $count"
fi

# --- 7. build mode emits the BUILD prompt ------------------------------------
build_len="$(wc -c <"$loop/prompt-build.md" | tr -d ' ')"
if [ "$(head -c "$build_len" "$work/out" | shasum -a 256 | awk '{print $1}')" = \
  "$(shasum -a 256 "$loop/prompt-build.md" | awk '{print $1}')" ]; then ok; else
  fail_case "build mode must emit prompt-build.md"
fi
if grep -q 'mode: build' "$work/out"; then ok; else
  fail_case "the state block must name the mode it ran in"
fi

# --- 8. the snapshot is recorded, and records the prompt's hash --------------
# `drafter_prompt_sha` is how a mid-rung prompt change becomes visible in the
# harness record rather than preventable. A snapshot without it records nothing.
# The timestamp is asserted alongside the rest: the mode on a pass row can be
# stale, because the snapshot records the last `loop:prompt` invocation rather
# than a property of the review that follows it, and the timestamp is what makes
# that visible to a reader instead of silently attributing one regime to another.
if grep -qE '^at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$loop/.pass-snapshot"; then ok; else
  fail_case "the snapshot must record when the prompt was issued, got: $(cat "$loop/.pass-snapshot")"
fi
if [ -f "$loop/.pass-snapshot" ] &&
  grep -q "^mode=build$" "$loop/.pass-snapshot" &&
  grep -q "^prompt_sha=$(shasum -a 256 "$loop/prompt-build.md" | awk '{print $1}')$" "$loop/.pass-snapshot"; then ok; else
  fail_case "the snapshot must record the mode and the prompt's hash, got: $(cat "$loop/.pass-snapshot" 2>/dev/null)"
fi

# --- 9. IT DOES NOT INVOKE A MODEL -------------------------------------------
# Asserted by running with a PATH that has no `claude` on it at all. A script
# that shelled out to one would fail rather than print.
if run plan; then ok; else
  fail_case "loop-prompt must not need a model on PATH; stderr: $(cat "$work/err")"
fi

# --- 10. the prompts state the rules a pass cannot guess ---------------------
# The gate-freeze prohibitions are the reason the build prompt is long. If they
# are ever trimmed, this fails rather than the loop quietly gaining the ability
# to resolve its own findings.
for needle in 'resolveReviewThread' 'gh run delete' 'push --no-verify' 'NON-FABRICATION' 'APPEND'; do
  if grep -q -- "$needle" "$loop/prompt-build.md"; then ok; else
    fail_case "the build prompt must state: $needle"
  fi
done
if grep -q 'implement nothing' "$loop/prompt-plan.md" ||
  grep -q 'You implement nothing' "$loop/prompt-plan.md"; then ok; else
  fail_case "the plan prompt must say it implements nothing"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
