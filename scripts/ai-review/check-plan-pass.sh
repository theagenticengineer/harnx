#!/usr/bin/env bash
# check-plan-pass.sh — a plan pass plans. This is what makes that a gate rather
# than a sentence in a prompt.
#
# TWO QUESTIONS, and both have to be asked or the check is worth little:
#
#   1. Did the pass touch anything but the plan? A plan pass that edited code
#      did the wrong job, and "implement nothing" is unenforceable as an
#      instruction because the pass that ignored it is also the one reporting on
#      itself.
#   2. Did the pass change the plan at all? A pass that touched nothing passes
#      question 1 perfectly. Without this second question the gate would reward
#      doing nothing, which is the failure mode a one-sided check always has.
#
# `.harnx/loop/plan.md` IS GITIGNORED, which makes question 1 simpler than it
# looks: the plan cannot appear in `git status --porcelain` at all, so the
# requirement "clean except for plan.md" is just "clean". That is stated here
# because a reader who does not know the plan is ignored would expect an
# exception in the code and conclude it is missing.
#
# Question 2 cannot be answered from git for the same reason, so it is answered
# from the snapshot loop-prompt.sh wrote immediately before the pass.
#
# Env:
#   (none required)
# Exit: 0 if the pass planned and only planned; 1 otherwise; 2 if there is no
#       snapshot to compare against.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

loop_dir=".harnx/loop"
snapshot="$loop_dir/.pass-snapshot"

if [ ! -f "$snapshot" ]; then
  echo "check-plan-pass: no $snapshot, so there is nothing to compare against." >&2
  echo "  Run 'mise run loop:prompt plan' before the pass; it records the pre-pass state." >&2
  exit 2
fi

# `s/^name=//p` strips only the FIRST `=`, so a value containing one survives
# intact. `head -1` because a snapshot is rewritten per pass and a duplicated
# key would otherwise silently concatenate two values into one comparison.
field() { sed -n "s/^$1=//p" "$snapshot" | head -1; }

mode="$(field mode)"
if [ "$mode" != plan ]; then
  echo "check-plan-pass: the last pass ran in '$mode' mode, not 'plan'; nothing to check." >&2
  echo "  This gate applies to plan passes only. A build pass is expected to change files." >&2
  exit 0
fi

status_now="$(git status --porcelain)"
if [ -n "$status_now" ]; then
  echo "::error::check-plan-pass: a plan pass changed tracked files. A plan pass writes $loop_dir/plan.md and nothing else." >&2
  printf '%s\n' "$status_now" >&2
  echo "  If this work needs doing, it is a plan ITEM, not this pass's job." >&2
  exit 1
fi

plan_before="$(field plan_sha)"
plan_now="$(shasum -a 256 "$loop_dir/plan.md" | awk '{print $1}')"
if [ "$plan_before" = "$plan_now" ]; then
  echo "::error::check-plan-pass: the plan is unchanged, so this pass planned nothing." >&2
  echo "  A pass that touches no file satisfies 'implement nothing' perfectly and is still a failed plan pass." >&2
  exit 1
fi

echo "check-plan-pass: the plan changed and nothing else did."
