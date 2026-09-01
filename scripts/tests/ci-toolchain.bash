#!/usr/bin/env bash
# Standalone test for ci.yml's per-job tool scoping.
# Run: bash scripts/tests/ci-toolchain.bash
#
# The floor's counterpart to trunk-toolchain.bash, which makes the same
# assertions about the credentialed trunk workflow. The property and the reason
# are the same: every installed tool's bin directory joins PATH, so a job that
# installs a tool it never invokes is carrying a shadowing risk for nothing.
#
# It breaks INVISIBLY in one direction only, which is why a test is the only
# thing that catches it. Narrowing a scope too far breaks the job at runtime,
# loudly. WIDENING one, or deleting install_args altogether, breaks nothing:
# the job goes green with the whole toolchain restored and nobody looks again.
#
# Three assertions, each catching a different mistake:
#
#   presence  every jdx/mise-action step carries install_args at all.
#   reverse   every install_args entry is a key mise.toml actually pins, so a
#             typo or a renamed tool cannot sit there resolving to nothing.
#   forward   the pre-commit job installs every tool a hook invokes. That job
#             is the one that drifts, because adding a hook is how the floor
#             grows and the hook and the job are in different files.
#
# The pre-commit job is checked against .pre-commit-config.yaml rather than
# against a list written here. A hand-kept list would be a second declaration of
# the gate set, which is the exact duplication the config's own header rejects.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${CI_WORKFLOW:-$repo_root/.github/workflows/ci.yml}"
config="${CI_PRECOMMIT_CONFIG:-$repo_root/.pre-commit-config.yaml}"
mise_toml="${CI_MISE_TOML:-$repo_root/mise.toml}"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

# The mise tool key that provides a given binary. Hand-maintained because there
# is no machine-readable link between a mise key and the command it installs,
# and the obvious guess (strip the backend prefix, take the basename) is wrong
# for the npm entries: `npm:markdownlint-cli` provides `markdownlint`.
tool_key_for_binary() {
  case "$1" in
  markdownlint) echo "npm:markdownlint-cli" ;;
  claude) echo "npm:@anthropic-ai/claude-code" ;;
  *) echo "$1" ;;
  esac
}

# --- mise.toml's [tools] keys -------------------------------------------------
# Only the [tools] table. A [tasks.*] body naming a binary is not a pin, and
# counting it as one would make the reverse assertion vacuous.
tools_keys="$(awk '
  /^\[tools\]/ { in_tools = 1; next }
  /^\[/        { in_tools = 0 }
  in_tools && /^[^#[:space:]]/ { key = $1; gsub(/"/, "", key); print key }
' "$mise_toml")"
if [ -n "$tools_keys" ]; then ok; else
  fail_case "could not parse any [tools] entries from $mise_toml"
fi

# --- presence: every mise-action step names its tools -------------------------
# install_args is folded (`>-`) in at least one job, so the value may continue
# on following lines. Everything from the key up to the next key or list item
# at the same or shallower indentation belongs to it.
jobs_with_args="$(awk '
  function indent_of(line,   n) { n = match(line, /[^ ]/); return n == 0 ? 0 : n - 1 }
  /^  [a-z-]+:$/ { job = $1; sub(/:$/, "", job); next }
  /install_args:/ {
    key_indent = indent_of($0)
    line = $0
    sub(/^.*install_args:[[:space:]]*/, "", line)
    if (line == ">-" || line == ">" || line == "") { buf = ""; collecting = 1 }
    else { print job "|" line; collecting = 0 }
    next
  }
  # A folded value continues only while lines are indented DEEPER than the key.
  # Anything at the key indent or shallower is the next key, a list item, or a
  # comment, and none of those belong to the value. An earlier version had no
  # indentation test and swallowed the comment block that follows the gitleaks
  # job every tool name in it.
  collecting {
    if ($0 ~ /^[[:space:]]*$/ || indent_of($0) <= key_indent) {
      print job "|" buf
      collecting = 0
      buf = ""
    } else {
      sub(/^[[:space:]]+/, "")
      buf = buf " " $0
    }
  }
  END { if (collecting) print job "|" buf }
' "$workflow")"

arg_steps="$(printf '%s\n' "$jobs_with_args" | grep -c . || true)"
mise_steps="$(grep -c 'jdx/mise-action' "$workflow" || true)"
if [ "$arg_steps" -eq "$mise_steps" ] && [ "$arg_steps" -gt 0 ]; then ok; else
  fail_case "every jdx/mise-action step must carry install_args: $mise_steps step(s), $arg_steps with install_args"
fi

# --- reverse: every named tool is pinned --------------------------------------
unpinned=""
while IFS='|' read -r job args; do
  [ -n "$job" ] || continue
  for t in $args; do
    printf '%s\n' "$tools_keys" | grep -Fxq "$t" || unpinned="$unpinned $job:$t"
  done
done <<CI_JOBS
$jobs_with_args
CI_JOBS
if [ -z "$unpinned" ]; then ok; else
  fail_case "these install_args entries are not pinned in mise.toml:$unpinned"
fi

# --- forward: the pre-commit job installs every tool a hook runs --------------
hook_binaries="$(grep -oE 'entry: mise exec -- [a-z-]+' "$config" | awk '{print $NF}' | sort -u || true)"
if [ -n "$hook_binaries" ]; then ok; else
  fail_case "could not parse any 'mise exec --' hook entries from $config"
fi

precommit_args="$(printf '%s\n' "$jobs_with_args" | awk -F'|' '$1 == "pre-commit" { print $2 }' || true)"
if [ -n "$precommit_args" ]; then ok; else
  fail_case "the pre-commit job must carry install_args"
fi

missing=""
while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  key="$(tool_key_for_binary "$bin")"
  case " $precommit_args " in *" $key "*) ;; *) missing="$missing $key" ;; esac
done <<HOOK_BINARIES
$hook_binaries
HOOK_BINARIES
if [ -z "$missing" ]; then ok; else
  fail_case "the pre-commit job runs hooks needing these tools, which it does not install:$missing"
fi

# pre-commit itself, which no hook entry names because it is what runs them.
case " $precommit_args " in
*" pre-commit "*) ok ;;
*) fail_case "the pre-commit job must install pre-commit itself" ;;
esac

# --- the single-tool jobs install exactly what they run -----------------------
# Each of these is one job whose `run:` names one binary. A wider scope here is
# the pure case of the invisible regression: nothing breaks, and the job quietly
# carries tools it never calls.
for job in actionlint gitleaks; do
  args="$(printf '%s\n' "$jobs_with_args" | awk -F'|' -v j="$job" '$1 == j { print $2 }' | tr -s ' ' | sed 's/^ //; s/ $//' || true)"
  if [ "$args" = "$job" ]; then ok; else
    fail_case "the $job job should install exactly '$job', installs: '$args'"
  fi
done

# --- forward, part two: the shell-tests job installs what its suites invoke ---
# The pre-commit job was covered above, from the hook list. This job was NOT,
# and the omission had already cost something: `secret-scan-arms.bash` runs the
# secret-scanning hook's real entry, needs gitleaks, and the job did not install
# it, so the suite would have failed in CI while passing on any machine with the
# full toolchain installed.
#
# Two sources, because a suite can name its tool in two ways: literally, as
# `mise exec -- <tool>`, or by declaring it in a `# requires-tool:` line when the
# command is built at runtime and no scanner could find it.
#
# THIS OVER-APPROXIMATES, DELIBERATELY. A suite that merely QUOTES
# `mise exec -- <tool>` inside a fixture, without running it, is counted as
# needing that tool; `check-no-forward-refs.bash` does exactly that, to prove
# such an entry is not treated as a repository path. Grep cannot tell a fixture
# string from an invocation, and the error is in the safe direction: the job
# installs a tool it does not need, rather than missing one it does. Missing one
# is a CI break that passes on every developer machine, which is the failure
# that produced this check.
suite_tools="$( (
  grep -rhoE 'mise exec -- [a-z-]+' "$repo_root"/scripts/tests/*.bash | awk '{print $NF}'
  grep -rhoE '^# requires-tool: [a-z-]+' "$repo_root"/scripts/tests/*.bash | awk '{print $NF}'
) | sort -u || true)"
if [ -n "$suite_tools" ]; then ok; else
  fail_case "no suite tool requirements discovered; the derivation has drifted from the suites"
fi

shelltests_args="$(printf '%s\n' "$jobs_with_args" | awk -F'|' '$1 == "shell-tests" { print $2 }' || true)"
missing_suite=""
while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  key="$(tool_key_for_binary "$bin")"
  case " $shelltests_args " in *" $key "*) ;; *) missing_suite="$missing_suite $key" ;; esac
done <<SUITE_TOOLS
$suite_tools
SUITE_TOOLS
if [ -z "$missing_suite" ]; then ok; else
  fail_case "the shell-tests job runs suites needing these tools, which it does not install:$missing_suite"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
