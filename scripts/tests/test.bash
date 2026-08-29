#!/usr/bin/env bash
# Standalone test for scripts/mise/test.sh.
# Run: bash scripts/tests/test.bash
#
# WHAT THIS PROTECTS. test.sh is what `mise run test` and ci.yml's
# `shell-tests` job run, so its exit status IS the required check. Everything
# else under scripts/tests/ verifies a script; this one verifies the thing that
# decides whether any of those verdicts reach CI at all.
#
# The failure mode that matters is silent success. A runner that swallows a
# suite's non-zero exit, or that finds no suites and says nothing, reports a
# green required check over code nothing ran against. That is the same shape as
# this branch's placeholder ci.yml jobs, and the same shape as the tamper
# CODEOWNERS exists to catch, which mise.toml's own header names: "redefining
# mise.toml's test task to a no-op".
#
# Hermetic: a scratch directory with a fake scripts/tests/ is built and the
# real runner is executed inside it. test.sh globs a RELATIVE path, so `cd` is
# the whole isolation mechanism; nothing touches this repository's suites.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/mise/test.sh"

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

# Rebuilds the scratch suite directory. Each argument is "name:exitcode".
setup() {
  rm -rf "$work/scripts"
  mkdir -p "$work/scripts/tests"
  local spec name rc
  for spec in "$@"; do
    name="${spec%%:*}"
    rc="${spec##*:}"
    cat >"$work/scripts/tests/$name.bash" <<SUITE
#!/usr/bin/env bash
echo "ran $name"
exit $rc
SUITE
  done
}

run() {
  local status
  set +e
  (cd "$work" && bash "$script") >"$out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# --- every suite passing is a green run --------------------------------------
setup a:0 b:0
if [ "$(run)" = "0" ]; then ok; else
  fail_case "all suites passing must exit 0: $(cat "$out")"
fi
if grep -q 'ran a' "$out" && grep -q 'ran b' "$out"; then ok; else
  fail_case "every suite must actually run: $(cat "$out")"
fi
# The suite's name is printed before it runs, so a suite that hangs or crashes
# the runner is identifiable from the log rather than from bisection.
if grep -q '== scripts/tests/a.bash' "$out"; then ok; else
  fail_case "each suite must be named as it is run: $(cat "$out")"
fi

# --- ONE failing suite fails the run -----------------------------------------
# The property the required check rests on. A runner that returns 0 here
# reports green over a failing suite.
setup a:0 b:1
if [ "$(run)" = "1" ]; then ok; else
  fail_case "a failing suite must fail the run: $(cat "$out")"
fi

# --- a failure does not abort the remaining suites ---------------------------
# `bash "$t" || status=1` records the failure and continues, so one push
# reports every broken suite. Aborting at the first would cost a CI round per
# broken suite, which is the same argument evaluate-gate.sh makes for running
# both of its sub-checks.
setup a:1 b:0 c:1
if [ "$(run)" = "1" ]; then ok; else
  fail_case "a run with failures must exit non-zero"
fi
if grep -q 'ran b' "$out" && grep -q 'ran c' "$out"; then ok; else
  fail_case "a failing suite must not stop the ones after it: $(cat "$out")"
fi

# --- the case that reports green having verified nothing ---------------------
# An empty suite directory. Left to the bare glob this failed by accident, on
# `bash` being handed a literal `scripts/tests/*.bash`; the message talked
# about a missing file rather than a missing suite. It must fail, and it must
# say why.
setup
if [ "$(run)" = "1" ]; then ok; else
  fail_case "an empty suite directory must fail, not report a green run"
fi
if grep -q 'verified nothing' "$out"; then ok; else
  fail_case "the empty case must say it refused to report a green run: $(cat "$out")"
fi
# And it must not be reported as a missing FILE, which sends whoever reads it
# looking for a deleted suite rather than for a suite directory nobody filled.
if ! grep -qi 'No such file' "$out"; then ok; else
  fail_case "the empty case must not surface as a missing-file error: $(cat "$out")"
fi

# --- a suite directory that does not exist at all ----------------------------
# Same verdict, different cause: a checkout that never had scripts/tests/.
rm -rf "$work/scripts"
mkdir -p "$work/scripts"
if [ "$(run)" = "1" ]; then ok; else
  fail_case "a missing suite directory must fail too"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
