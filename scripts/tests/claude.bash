#!/usr/bin/env bash
# Standalone test for scripts/ai-review/claude.sh.
# Run: bash scripts/tests/claude.bash
#
# WHAT THIS PROTECTS. This is the file the registry resolves when somebody
# writes "claude" into AI_REVIEWERS, and its one interesting decision is what
# happens when that reviewer has no credential.
#
# THE ANSWER MUST BE A FAILURE, and the test must assert the failure, not only
# the success. That distinction is not pedantry here. This repository shipped
# the git-identity gate dormant: its own genesis commit was authored under a
# leaked host identity while the gate reported `Passed`, and the paired test
# asserted that pass. Dormancy hides inside the test, so a test that only
# checks the happy path would let this reviewer be skipped forever with a
# notice nobody reads.
#
# review-engine.sh is stubbed by shadowing it in a scratch script directory, so
# this suite exercises the shim's own decisions and never calls a model.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
engine_log="$work/engine.txt"

# The shim beside a stub engine, so `$script_dir/review-engine.sh` resolves to
# the stub rather than the real one.
mkdir -p "$work/scripts"
cp "$repo_root/scripts/ai-review/claude.sh" "$work/scripts/claude.sh"
cat >"$work/scripts/review-engine.sh" <<'STUB'
#!/usr/bin/env bash
printf 'reviewer=%s\n' "${AI_REVIEW_REVIEWER:-<unset>}" >"$ENGINE_LOG"
printf 'token=%s\n' "${AI_REVIEW_ENGINE_TOKEN:-<unset>}" >>"$ENGINE_LOG"
printf 'passthrough=%s\n' "${AI_REVIEW_DIFF_FILE:-<unset>}" >>"$ENGINE_LOG"
exit "${ENGINE_EXIT:-0}"
STUB
chmod +x "$work/scripts"/*.sh

run() {
  local status
  : >"$engine_log"
  set +e
  env ENGINE_LOG="$engine_log" "$@" bash "$work/scripts/claude.sh" >"$out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# --- with a credential, it runs the engine -----------------------------------
if [ "$(run AI_REVIEW_ENGINE_TOKEN=secret AI_REVIEW_DIFF_FILE=/tmp/d)" = "0" ]; then ok; else
  fail_case "a reviewer with a credential must run: $(cat "$out")"
fi
if grep -q '^token=secret$' "$engine_log"; then ok; else
  fail_case "the credential must reach the engine: $(cat "$engine_log")"
fi
# Attribution is stamped by the SHELL, never by the model, because union.sh
# joins these to say who raised a finding.
if grep -q '^reviewer=claude$' "$engine_log"; then ok; else
  fail_case "the shim must stamp its own reviewer name: $(cat "$engine_log")"
fi
# Everything else passes through untouched, which is what keeps the shim thin.
if grep -q '^passthrough=/tmp/d$' "$engine_log"; then ok; else
  fail_case "the shim must pass the engine's other inputs through unchanged"
fi

# --- THE RULE: no credential is a FAILURE, not a skip ------------------------
if [ "$(run AI_REVIEW_ENGINE_TOKEN=)" != "0" ]; then ok; else
  fail_case "a named reviewer with no credential must FAIL, not go dormant"
fi
if [ ! -s "$engine_log" ]; then ok; else
  fail_case "a reviewer with no credential must not reach the engine at all"
fi
# The failure has to name the exact secret, or the operator is left guessing
# which of several similarly-named secrets is missing.
if grep -q 'AI_REVIEW_ENGINE_TOKEN_CLAUDE' "$out"; then ok; else
  fail_case "the failure must name the exact secret to set: $(cat "$out")"
fi
# And it must name the reviewer, since with a matrix the log carries several.
if grep -q "reviewer 'claude'" "$out"; then ok; else
  fail_case "the failure must name the reviewer: $(cat "$out")"
fi
# It must offer both real remedies. Removing the reviewer from the registry is
# as legitimate as adding the secret, and an operator who only hears about one
# of them is stuck if the other is what they wanted.
if grep -q 'remove' "$out" && grep -q 'AI_REVIEWERS' "$out"; then ok; else
  fail_case "the failure must offer removing the reviewer as well as adding the secret"
fi
# An UNSET variable and an empty one are the same misconfiguration.
if [ "$(run)" != "0" ]; then ok; else
  fail_case "an unset credential must fail exactly as an empty one does"
fi

# --- it is not a dormancy in disguise ----------------------------------------
# The one thing a reader might do to "soften" this is turn the error into a
# notice and exit 0. Asserted at the source, because that edit would still pass
# every behavioural case above if the exit status went with it.
# Comments are stripped first: the header explains at length why a notice plus
# exit 0 would be wrong, and matching that prose would make this assertion fire
# on the very argument for its own existence.
shim_code="$(sed 's/[[:space:]]*#.*$//' "$repo_root/scripts/ai-review/claude.sh")"
if ! printf '%s' "$shim_code" | grep -qE '^[[:space:]]*exit 0'; then ok; else
  fail_case "claude.sh has an exit 0 path; a named reviewer must never skip itself"
fi
if printf '%s' "$shim_code" | grep -q '::error::' &&
  ! printf '%s' "$shim_code" | grep -q '::notice::'; then ok; else
  fail_case "the missing-credential path must be an error, not a notice"
fi

# --- the engine's failure is the reviewer's failure --------------------------
# The shim must not swallow a non-zero engine exit into a green leg.
if [ "$(run AI_REVIEW_ENGINE_TOKEN=secret ENGINE_EXIT=3)" != "0" ]; then ok; else
  fail_case "an engine failure must fail this reviewer's leg"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
