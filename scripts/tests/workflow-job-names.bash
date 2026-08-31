#!/usr/bin/env bash
# Standalone test for job names in workflow_run-triggered workflows.
# Run: bash scripts/tests/workflow-job-names.bash
#
# WHAT THIS FORBIDS, and why it is a gate-integrity problem rather than a
# cosmetic one. A job's `name:` becomes the display name of the check run
# GitHub creates for that job. Branch protection resolves a required context by
# NAME, so a job named after a required context puts a second, unrelated
# producer behind that name.
#
# It happened. The trunk workflow's gate job was called `ai-review-resolved`,
# the same string post-check-run.sh publishes deliberately against the reviewed
# head commit, and the anchor branch's head accumulated seven check runs under
# that one name: one real verdict and six job check runs from other pull
# requests' trunk runs, four of them failures. Which one protection reads is
# not something this repository gets to decide.
#
# The workflow_run trigger is what makes the collision reach the wrong commit:
# such a run is attributed to the DEFAULT branch's head rather than to the pull
# request that caused it, so its job check runs land on a commit that has
# nothing to do with them.
#
# The required-context list is read from scripts/configure-protection.sh itself
# rather than duplicated here, so a check added to the floor is covered the day
# it is added.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The script's last line invokes main, so it cannot simply be sourced. Dropping
# that one line and sourcing the rest gives the real function, which is the
# whole point: re-listing the checks here would be a second copy free to drift
# from the one that is actually applied.
#
# THE STRIP IS VERIFIED, not assumed, and this is the part that matters. If a
# refactor ever changes that last line, the sed matches nothing, the source
# runs main() for real, and an ordinary `mise run test` starts writing branch
# protection through the live API. The `|| true` on the read below would then
# hide the resulting error rather than surface it. So the invocation must be
# gone, asserted before anything is sourced.
sed '/^main "\$@"$/d' "$repo_root/scripts/configure-protection.sh" >"$tmp/checks.sh"
if grep -qE '^[[:space:]]*main[[:space:]]' "$tmp/checks.sh"; then
  fail_case "configure-protection.sh still invokes main after the strip; sourcing it would run the real script against the live API. Update the sed pattern before this suite is trusted again."
else
  pass=$((pass + 1))
fi

# BELT AND BRACES: a stub PATH for the source, so even a strip that somehow
# let an invocation through cannot reach GitHub. The script's every side
# effect goes through `gh`, and the stub exits non-zero, so a leaked main()
# fails loudly here instead of mutating a repository.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "workflow-job-names.bash: the sourced configure-protection.sh tried to call gh; the strip of main() failed." >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"

# `|| true`: an unguarded assignment aborts the suite under `set -e` before
# the diagnostic below can run, swallowing the very error it exists to report.
required="$(PATH="$tmp/bin:$PATH" bash -c ". '$tmp/checks.sh'; floor_required_checks" 2>"$tmp/src.err" || true)"
if [ -n "$required" ]; then
  pass=$((pass + 1))
else
  fail_case "could not read floor_required_checks out of configure-protection.sh: $(cat "$tmp/src.err" 2>/dev/null)"
fi
# Sourcing must be SILENT. Anything on stderr means the file did something
# beyond defining functions, which is exactly what this guard exists to catch.
if [ ! -s "$tmp/src.err" ]; then
  pass=$((pass + 1))
else
  fail_case "sourcing configure-protection.sh produced output, so it did more than define functions: $(cat "$tmp/src.err")"
fi

# A workflow is in scope when its `on:` block names workflow_run.
scanned=0
for wf in "$repo_root"/.github/workflows/*.yml; do
  [ -f "$wf" ] || continue
  grep -qE '^  workflow_run:' "$wf" || continue
  scanned=$((scanned + 1))

  # BOTH the explicit name and the job ID, because GitHub falls back to the ID
  # when a job declares no `name:`. Checking only the explicit form would let
  # the identical collision back in through a job written as
  # `ai-review-resolved:` with no name at all, which is the shorter and
  # therefore likelier way to write it.
  #
  # Job-level `name:` only, not a step's: a job key sits at two spaces and its
  # own keys at four, while a step's name is a list item at six with a leading
  # dash, so the four-space anchored form matches jobs and nothing else. Job
  # IDs are the two-space keys under `jobs:`.
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if printf '%s\n' "$required" | grep -Fxq "$candidate"; then
      fail_case "$(basename "$wf") has a job named or keyed '$candidate', which is a REQUIRED branch-protection context; GitHub names the job's own check run after its \`name:\` or, absent that, its ID (the published check name is set in the step's env, not by either)"
    else
      pass=$((pass + 1))
    fi
  done < <({
    sed -n 's/^    name: //p' "$wf"
    sed -n 's/^  \([A-Za-z0-9_-]*\):$/\1/p' "$wf"
  })
done

if [ "$scanned" -gt 0 ]; then
  pass=$((pass + 1))
else
  fail_case "no workflow_run-triggered workflow was found; this test would pass vacuously"
fi

# The other half of the same property. Renaming the job must not have renamed
# the context it publishes: branch protection pins that literal string, so if
# it drifts the required check simply never reports and every pull request
# blocks forever on a check that cannot arrive.
trunk="$repo_root/.github/workflows/ai-review-trunk.yml"
if grep -qE '^ +CHECK_NAME: ai-review-resolved$' "$trunk"; then
  pass=$((pass + 1))
else
  fail_case "ai-review-trunk.yml must still publish CHECK_NAME: ai-review-resolved"
fi
if printf '%s\n' "$required" | grep -Fxq 'ai-review-resolved'; then
  pass=$((pass + 1))
else
  fail_case "ai-review-resolved must still be a required context"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
