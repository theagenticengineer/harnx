#!/usr/bin/env bash
# loop-prompt.sh <plan|build> — print one pass's complete instruction.
#
# THE PROMPT IS FIXED; WHAT VARIES IS THE STATE. The selected prompt file is
# emitted verbatim, byte for byte, every pass. Everything that differs between
# passes comes after it, in the state block, and comes from files. Swapping to a
# different issue swaps the contents of plan.md; it does not change one byte of
# the instruction.
#
# THE MODE IS THE CALLER'S DECISION, NEVER THE AGENT'S, which is why it is a
# required argument and why this script refuses without one. A single prompt that
# branched on whether plan.md still had unchecked items would hand the agent the
# choice of which job it is doing, and that judgement is exactly what a fixed
# prompt exists to remove.
#
# THE LAST FAILURE COMES FIRST, before the plan, the decisions or the manual.
# It is the most recent thing that went wrong and usually the whole of the next
# pass's work, and a context window degrades from the middle, so the position is
# not cosmetic.
#
# IT DOES NOT INVOKE A MODEL. It prints. Piping it into one is the caller's job,
# and keeping it that way is what makes the output assertable byte for byte.
#
# Env:
#   (none required)
# Exit: 0 on success; 2 on a missing or unrecognised mode.
set -euo pipefail

usage() {
  echo "usage: loop-prompt.sh <plan|build>" >&2
  echo "  plan   read the acceptance criteria and write .harnx/loop/plan.md; implement nothing" >&2
  echo "  build  implement the top unchecked item of .harnx/loop/plan.md, and only that" >&2
  echo "" >&2
  echo "The mode is required. It is deliberately not inferred from the state:" >&2
  echo "choosing which job this pass is doing belongs to the caller, not to the agent." >&2
}

mode="${1-}"
case "$mode" in
plan | build) ;;
'')
  echo "loop-prompt.sh: no mode given." >&2
  usage
  exit 2
  ;;
*)
  echo "loop-prompt.sh: unrecognised mode '$mode'." >&2
  usage
  exit 2
  ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

loop_dir=".harnx/loop"
# Seeded on every invocation. loop-init.sh never overwrites, so this costs
# nothing when the state exists and means a fresh checkout does not need a
# separate setup step it will forget.
bash scripts/ai-review/loop-init.sh >/dev/null

prompt_file="$loop_dir/prompt-$mode.md"
if [ ! -f "$prompt_file" ]; then
  echo "loop-prompt.sh: $prompt_file is missing and could not be seeded." >&2
  exit 2
fi

# A SNAPSHOT OF WHAT THE TREE LOOKED LIKE BEFORE THE PASS, so
# check-plan-pass.sh can answer two questions afterwards that nothing else can:
# did a plan pass touch a tracked file (it must not), and did it actually change
# the plan (it must). Written here rather than by the caller because this is the
# last moment before the pass at which the pre-state is still true.
#
# The name starts with a dot only to keep it visually apart from the files a
# human reads; .harnx/loop/.gitignore ignores everything here either way.
{
  printf 'mode=%s\n' "$mode"
  # WHEN THIS PASS WAS HANDED ITS PROMPT. record-pass.sh copies it onto the pass
  # row beside the mode, and it is there because the mode alone can be stale.
  # The snapshot records the last `loop:prompt` invocation, so a review run
  # outside any loop pass inherits whatever mode was last asked for. That is not
  # preventable from here: nothing distinguishes "the review belonging to this
  # pass" from "a review somebody ran afterwards". Carrying the timestamp makes
  # the gap VISIBLE in the record, which is the same treatment prompt drift
  # gets, rather than leaving a field that can quietly attribute a build pass to
  # a plan.
  printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'prompt_sha=%s\n' "$(shasum -a 256 "$prompt_file" | awk '{print $1}')"
  printf 'plan_sha=%s\n' "$(shasum -a 256 "$loop_dir/plan.md" | awk '{print $1}')"
  printf 'status_sha=%s\n' "$(git status --porcelain | shasum -a 256 | awk '{print $1}')"
} >"$loop_dir/.pass-snapshot"

# THE PROMPT, VERBATIM. No substitution, no interpolation, no header of its own:
# anything added here would vary with this script rather than with the file, and
# the byte-identity assertion in scripts/tests/loop-prompt.bash would be pinning
# this script's formatting instead of the prompt's content.
cat "$prompt_file"

# --- the state block ---------------------------------------------------------
# FIXED ORDER, ALWAYS ALL SIX SECTIONS, even when a file is empty. An empty
# section says "nothing is known here", which is information; an omitted section
# is indistinguishable from a section the assembler forgot, and the reader
# cannot tell those apart.
emit() {
  local title="$1" path="$2"
  printf '\n--- BEGIN %s ---\n' "$title"
  if [ -f "$path" ]; then
    cat "$path"
  fi
  printf -- '--- END %s ---\n' "$title"
}

printf '\n\n=== LOOP STATE (mode: %s) ===\n' "$mode"
emit "LAST FAILURE" "$loop_dir/last-failure.txt"
emit "PLAN" "$loop_dir/plan.md"
emit "DECISIONS" "$loop_dir/decisions.md"
emit "DISCOVERED FACTS" "$loop_dir/learnings.md"
emit "MANUAL" "$loop_dir/manual.md"
emit "HANDOFF" "$loop_dir/handoff.md"
