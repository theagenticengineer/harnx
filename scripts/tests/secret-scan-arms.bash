#!/usr/bin/env bash
# Standalone test: the secret-scanning hook, AS CONFIGURED, actually detects a
# secret.
# Run: bash scripts/tests/secret-scan-arms.bash
#
# WHY THIS EXISTS. Two different configurations of this one hook have now
# reported success over a tree they never read, and neither was visible from the
# config:
#
#   1. `gitleaks git --staged` reads the git INDEX. At commit time that is
#      right. Under `pre-commit run --all-files`, which is what CI runs and what
#      `mise run lint` runs, nothing is staged: it scanned "0 commits", printed
#      "no leaks found", and exited 0.
#   2. `gitleaks dir` with filenames appended by pre-commit. `dir` takes ONE
#      path. Given two it does not error; it silently finds nothing and exits 0,
#      whether the secret is in the first argument or the second.
#
# Both are the same failure, and reading the config file cannot tell you about
# either. So this test does not read the config to decide whether it looks
# right. It EXTRACTS the hook's real entry line, runs it against a tree with a
# planted secret, and requires a non-zero exit. Any future rewrite of the hook
# has to survive that, whatever it is spelled like.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
# requires-tool: gitleaks
#
# That line is READ, not decoration. This suite runs the hook's real entry, so
# it needs the hook's tool, but it does not name that tool anywhere a scanner
# could find: the entry is extracted from the config at runtime and eval'd. Every
# other suite that shells out writes `mise exec -- <tool>` literally, which is
# discoverable. scripts/tests/ci-toolchain.bash reads both forms when it checks
# that the shell-tests job installs what its suites invoke.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$repo_root/.pre-commit-config.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

# The hook's real command, taken from the config rather than restated here. A
# copy would pass while the hook itself was broken, which is this suite's whole
# subject one level up.
entry="$(awk '
  /^      - id: gitleaks$/ { found = 1 }
  found && /^        entry: / { sub(/^        entry: /, ""); print; exit }
' "$config")"
if [ -n "$entry" ]; then ok; else
  fail_case "could not find the gitleaks hook's entry line in $config"
  echo "RESULT: $pass passed, $fail failed"
  exit 1
fi

# `always_run` with no filenames, asserted because the entry alone cannot say
# it: a `dir` scan is only correct when pre-commit is NOT appending paths.
hook_block="$(awk '
  /^      - id: gitleaks$/ { inblock = 1; next }
  /^      - id: / { inblock = 0 }
  inblock { print }
' "$config")"
if printf '%s' "$hook_block" | grep -q 'pass_filenames: false'; then ok; else
  fail_case "the gitleaks hook must set pass_filenames: false; appended paths make its scan silently empty"
fi

# --- A PLANTED SECRET IS FOUND ------------------------------------------------
# Generated rather than written literally, so this file does not itself contain
# a string that every other secret scanner in the world will flag.
planted="ghp_$(head -c 200 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 36)"
mkdir -p "$work/tree/nested"
cp "$repo_root/.gitleaks.toml" "$work/tree/"
printf 'nothing interesting here\n' >"$work/tree/clean.txt"
printf 'token = "%s"\n' "$planted" >"$work/tree/nested/leaked.txt"

set +e
(cd "$work/tree" && eval "$entry") >"$work/out" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then ok; else
  fail_case "the hook as configured did NOT detect a planted secret; it scanned nothing and reported success: $(cat "$work/out")"
fi

# --- AND A CLEAN TREE IS NOT FLAGGED ------------------------------------------
# Without this the case above would pass on a hook that always fails.
rm -f "$work/tree/nested/leaked.txt"
set +e
(cd "$work/tree" && eval "$entry") >"$work/out" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then ok; else
  fail_case "a clean tree must not be flagged: $(cat "$work/out")"
fi

# --- THE PLANT MUST BE NESTED, NOT ONLY AT THE ROOT ---------------------------
# A scan that only reads the top directory would pass both cases above. The
# planted file sits in a subdirectory for that reason, and this asserts the
# fixture actually kept it there.
if [ ! -e "$work/tree/nested/leaked.txt" ] && [ -d "$work/tree/nested" ]; then ok; else
  fail_case "the fixture must plant its secret in a subdirectory"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
