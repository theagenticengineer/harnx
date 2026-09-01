#!/usr/bin/env bash
# Standalone suite over the LOOP SURFACE as a whole, rather than over one script.
# Run: bash scripts/tests/loop-surface.bash
#
# WHY A WHOLE-SURFACE TEST EXISTS AT ALL, when every script here already has its
# own. Because the scripts are not what can go missing. This branch is the trust
# anchor; the child branch above it owns SAME-PATH copies of
# .pre-commit-config.yaml, mise.toml and docs/, and replaces each one wholesale
# rather than merging into it. A per-script suite passes perfectly on a branch
# whose config forgot to declare the hook that runs the script, and the loop is
# then silently unarmed on the branch where most of the work actually happens.
#
# The child branch inherits all of this branch's test files, so THIS SUITE
# RUNNING THERE is what catches that. It asserts the wiring, not the code: the
# hook entries, the tasks, and the scripts they name. It is deliberately a suite
# with no paired script, which check-paired-tests.sh allows in this direction.
#
# It reads the FILES, not the running environment, so it answers "is the loop
# declared in this tree" rather than "did it happen to work here once".
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

config=".pre-commit-config.yaml"
mise="mise.toml"

# --- 1. every loop script exists ---------------------------------------------
for s in loop-init.sh loop-prompt.sh record-pass.sh check-round-cap.sh \
  check-plan-pass.sh check-locally-reviewed.sh ci-head-shas.sh; do
  if [ -f "scripts/ai-review/$s" ]; then ok; else
    fail_case "scripts/ai-review/$s is missing from this tree"
  fi
done
if [ -f scripts/mise/ai-review-local.sh ]; then ok; else
  fail_case "scripts/mise/ai-review-local.sh is missing from this tree"
fi

# --- 2. THE PUSH CHOKEPOINT IS DECLARED --------------------------------------
# The hooks are installed by mise's postinstall regardless; what can go missing
# is the DECLARATION, and an installed hook with nothing to run exits 0 and
# looks exactly like a passing gate. That is the state this branch was in before
# the loop landed, and it is the state a wholesale config replacement would
# restore.
for id in locally-reviewed round-cap; do
  if grep -q "id: $id" "$config"; then ok; else
    fail_case "$config does not declare the '$id' hook, so the push gate is unarmed"
  fi
done
# Declared AND staged at pre-push. A hook with no stage runs at every installed
# stage, which for these two would mean running at commit-msg and post-checkout
# time as well.
if [ "$(grep -c 'stages: \[pre-push\]' "$config")" -ge 2 ]; then ok; else
  fail_case "both push gates must be staged at pre-push"
fi

# --- 3. EVERY HOOK ENTRY NAMES A FILE THAT EXISTS ----------------------------
# A `language: system` hook whose entry names an absent script fails at RUNTIME,
# on every push, for everyone. It is also exactly the forward reference the
# git-discipline gates forbid: a spine file referring to something not present
# in the same tree.
while read -r entry; do
  [ -n "$entry" ] || continue
  cmd="$(printf '%s' "$entry" | awk '{print $1}')"
  case "$cmd" in
  scripts/*)
    if [ -f "$cmd" ]; then ok; else
      fail_case "$config names '$cmd', which is not in this tree"
    fi
    ;;
  esac
done <<EOF
$(sed -n 's/^ *entry: //p' "$config")
EOF

# --- 4. THE TASKS ARE DECLARED -----------------------------------------------
# Same failure mode one level up: the prompt tells a pass to run
# `mise run ai-review:local`, and a tree without that task turns the instruction
# into a command that does not exist.
for t in 'tasks."ai-review:local"' 'tasks."loop:init"' 'tasks."loop:prompt"' 'tasks."loop:check-plan"' 'tasks.test' 'tasks.lint'; do
  if grep -qF "[$t]" "$mise"; then ok; else
    fail_case "$mise does not declare [$t]"
  fi
done

# --- 5. EVERY TASK BODY NAMES A FILE THAT EXISTS -----------------------------
# mise task bodies must be tracked scripts rather than inline shell, so the
# linters and formatters cover them. That only holds if the script is there.
#
# (The previous wording began a line with a hash and the word shellcheck, which
# that tool reads as a directive rather than as prose, and it refused to parse
# the file. Worth a note: it is a comment that breaks the linter.)
while read -r body; do
  [ -n "$body" ] || continue
  case "$body" in
  *scripts/*)
    f="$(printf '%s' "$body" | tr ' ' '\n' | grep '^scripts/' | head -1)"
    if [ -n "$f" ] && [ -f "$f" ]; then ok; else
      fail_case "$mise runs '$f', which is not in this tree"
    fi
    ;;
  esac
done <<EOF
$(sed -n 's/^run = "//p' "$mise" | sed 's/"$//')
EOF

# --- 6. THE LOOP STATE IS IGNORED, AND ITS IGNORE IS TRACKED -----------------
# The one tracked file in .harnx/loop/. If it were lost, a pass's plan,
# decisions and discovered facts would start showing up in `git status` and,
# sooner or later, in a commit.
if [ -f .harnx/loop/.gitignore ]; then ok; else
  fail_case ".harnx/loop/.gitignore is missing, so loop state is no longer ignored"
fi
if git check-ignore -q .harnx/loop/passes.jsonl; then ok; else
  fail_case "git does not ignore .harnx/loop/passes.jsonl"
fi

# --- 8. EVERY PUSH-BLOCKING GATE IS IN THE FINGERPRINT ------------------------
# gate_sha exists so a result produced under one gate is visibly not comparable
# with one produced under another. A push-blocking gate missing from the array
# is a gate whose weakening, including a change to the cap's own CAP value,
# would leave every recorded row looking identical.
# FULL PATHS, not basenames under one directory. Two of these live outside
# scripts/ai-review/, and neither is a "check" by name: ai-review-local.sh
# writes the reviewed-tree marker the push gate reads and chooses the outcome
# that gets recorded, and ci-head-shas.sh produces the number the cap subtracts.
# Both were missed on the first pass precisely because they do not look like
# gates, which is why the membership rule is about what a file can CHANGE rather
# than what it is called.
for g in \
  scripts/ai-review/check-locally-reviewed.sh \
  scripts/ai-review/check-round-cap.sh \
  scripts/ai-review/ci-head-shas.sh \
  scripts/ai-review/record-pass.sh \
  scripts/mise/ai-review-local.sh; do
  if grep -q "^  $g\$" scripts/ai-review/record-pass.sh; then ok; else
    fail_case "GATE_FILES omits $g, so changing it would not move gate_sha"
  fi
done

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
