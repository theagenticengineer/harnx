#!/usr/bin/env bash
# Standalone test for .pre-commit-config.yaml's hook declarations.
# Run: bash scripts/tests/hook-stages.bash
#
# A suite over a config file rather than over a script, the same shape as
# action-pins.bash and workflow-job-names.bash, because the properties below
# live in YAML and nothing else would catch them breaking.
#
# WHAT IT PROTECTS.
#
# 1. EVERY HOOK DECLARES ITS STAGE. A hook with no `stages:` key runs at every
#    INSTALLED stage, and scripts/mise/setup-hooks.sh installs four. An
#    unstaged hook therefore re-runs shellcheck on every push and every
#    checkout, and runs it at commit-msg time against the commit message file,
#    where it matches nothing and prints "(no files to check) Skipped". None of
#    that catches anything the pre-commit stage did not catch a moment earlier.
#    It spends time and prints lines, and a tool that decorates every operation
#    with output nobody acts on teaches its readers to skip the output that
#    matters. That is this repository's own stated reason for `cache: false` in
#    the trunk workflow.
#
# 2. EVERY HOOK RUNS A PINNED TOOL. The config's whole argument for using
#    `local` hooks instead of remote hook repositories is that mise.toml stays
#    the single place a version is pinned. A hook whose `entry:` names a bare
#    binary would silently use whatever the developer happens to have, which is
#    the drift the `local` choice exists to prevent, and it would pass here on
#    one machine and fail on another.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$repo_root/.pre-commit-config.yaml"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

if [ -f "$config" ]; then ok; else
  fail_case "$config must exist; the anchor's local gates are declared there"
  echo "RESULT: $pass passed, $fail failed"
  exit 1
fi

# One record per hook: "<id> <has-stages> <entry>". Parsed with awk rather than
# a YAML library because this file is hand-written, deliberately small, and
# adding a parser dependency to a shell suite costs more than it buys. The
# parse is asserted below by checking the hook count it found.
records="$(awk '
  /^      - id: / { if (id != "") print id, stages, entry; id = $3; stages = "no"; entry = "none"; next }
  /^        stages: / { stages = "yes"; next }
  /^        entry: / { sub(/^        entry: /, ""); entry = $0; next }
  END { if (id != "") print id, stages, entry }
' "$config")"

hook_count="$(printf '%s\n' "$records" | grep -c . || true)"
if [ "$hook_count" -ge 3 ]; then ok; else
  fail_case "expected at least 3 hooks, parsed $hook_count; the awk parse and the file's shape have drifted"
fi

# --- 1. every hook declares a stage ------------------------------------------
unstaged=""
while read -r id stages _; do
  [ -n "$id" ] || continue
  [ "$stages" = "yes" ] || unstaged="$unstaged $id"
done <<EOF
$records
EOF
if [ -z "$unstaged" ]; then ok; else
  fail_case "these hooks declare no stages, so they run at EVERY installed stage:$unstaged"
fi

# --- 2. every hook runs something pinned or in-repo ---------------------------
# Either `mise exec -- <tool>`, which takes the version from mise.toml, or a
# script under scripts/, which is this repository's own code and is itself
# covered by check-paired-tests.
unpinned=""
while read -r id _ entry; do
  [ -n "$id" ] || continue
  case "$entry" in
  "mise exec -- "*) ;;
  scripts/*) ;;
  *) unpinned="$unpinned $id" ;;
  esac
done <<EOF
$records
EOF
if [ -z "$unpinned" ]; then ok; else
  fail_case "these hooks run an unpinned binary rather than 'mise exec --' or a repo script:$unpinned"
fi

# --- 3. every tool a hook runs through mise is pinned in mise.toml -----------
# The config's argument only holds if the pin is actually there. A `mise exec`
# on a tool mise.toml does not pin resolves to whatever is installed globally,
# which is the same drift with an extra step.
missing_pin=""
while read -r id _ entry; do
  [ -n "$id" ] || continue
  case "$entry" in
  "mise exec -- "*)
    tool="$(printf '%s' "${entry#mise exec -- }" | awk '{print $1}')"
    grep -qE "^${tool} = " "$repo_root/mise.toml" || missing_pin="$missing_pin $tool"
    ;;
  esac
done <<EOF
$records
EOF
if [ -z "$missing_pin" ]; then ok; else
  fail_case "these tools are run by a hook but not pinned in mise.toml:$missing_pin"
fi

# --- 4. the shfmt hook keeps the flags that make it a gate -------------------
# Without `-d`, shfmt writes formatted output to stdout and exits 0, so the
# hook reports Passed on an unformatted file. That is a one-flag difference
# between a gate and a decoration, and this repository has shipped the
# decoration before.
if grep -qE '^        entry: mise exec -- shfmt .*-d' "$config"; then ok; else
  fail_case "the shfmt hook must pass -d, or it formats to stdout and always exits 0"
fi
if grep -qE '^        entry: mise exec -- shfmt .*-i 2' "$config"; then ok; else
  fail_case "the shfmt hook must pass -i 2, matching how every script here is written"
fi

# --- 5. the paired-test gate looks at the whole tree -------------------------
# Its question is "does every script have a test", which is about the tree, not
# about the files in one commit. Passing it filenames would let a commit that
# DELETES a test pass, because the deleted file is not among them.
# The block is extracted by awk rather than with `grep -A<n>`: a fixed window
# is a hidden dependency on how many comment lines the hook happens to carry,
# so adding a sentence of explanation would silently stop the assertion from
# seeing the keys it checks.
gate_block="$(awk '
  /^      - id: check-paired-tests$/ { inblock = 1; next }
  /^      - id: / { inblock = 0 }
  inblock { print }
' "$config")"
if printf '%s' "$gate_block" | grep -q 'pass_filenames: false' &&
  printf '%s' "$gate_block" | grep -q 'always_run: true'; then ok; else
  fail_case "check-paired-tests must run always_run with pass_filenames: false"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
