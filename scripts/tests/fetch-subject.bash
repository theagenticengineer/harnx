#!/usr/bin/env bash
# Standalone test for scripts/ai-review/fetch-subject.sh.
# Run: bash scripts/tests/fetch-subject.bash
#
# WHAT THIS PROTECTS. A drift pass compares a DESCRIPTION against what was
# delivered, and this decides which description that is. Two properties carry
# the weight:
#
#   the issue comes from the BRANCH, not the pull request body. The body is
#   exactly what a `pr-body` pass may be about to call wrong, so trusting it to
#   name the issue would let a drifted description choose its own examiner:
#   edit the body to link a different issue and the drift disappears.
#
#   an empty or missing description is a FINDING, not a failure. A pull request
#   whose body says nothing about what it delivered has drifted from it in the
#   most complete way there is. Failing instead would turn a description
#   problem into a pipeline problem, which is the wrong report and lands on the
#   wrong person.
#
# `gh` is stubbed on PATH, so no API call is made.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/fetch-subject.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"
mkdir -p "$stub_dir"
subject="$work/subject.txt"
log="$work/log.txt"
calls="$work/calls.txt"

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_CALLS"
# GH_STUB_FAIL makes the stub refuse the way a token without the right scope
# does: non-zero exit, a message on stderr, nothing on stdout.
if [ -n "${GH_STUB_FAIL:-}" ]; then
  echo "gh: Resource not accessible by integration (HTTP 403)" >&2
  exit 1
fi
case "$*" in
*/pulls/*) printf '%s' "${GH_STUB_PR_BODY-a pull request description}" ;;
*/issues/*) printf '%s' "${GH_STUB_ISSUE_BODY-an issue description}" ;;
esac
STUB
chmod +x "$stub_dir/gh"

run() {
  local status
  rm -f "$subject"
  : >"$calls"
  set +e
  env PATH="$stub_dir:$PATH" GH_STUB_CALLS="$calls" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=38 \
    SUBJECT_FILE="$subject" "$@" bash "$script" >"$log" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# --- pr-body reads the pull request's own description ------------------------
if [ "$(run PASS=pr-body)" = "0" ] && grep -q 'a pull request description' "$subject"; then ok; else
  fail_case "the pr-body pass must read the pull request's description: $(cat "$log")"
fi
if grep -q 'pulls/38' "$calls"; then ok; else
  fail_case "it must ask for THIS pull request: $(cat "$calls")"
fi

# --- THE ISSUE COMES FROM THE BRANCH -----------------------------------------
if [ "$(run PASS=issue-body HEAD_BRANCH=feat-37-ai-review-security)" = "0" ] &&
  grep -q 'an issue description' "$subject"; then ok; else
  fail_case "the issue-body pass must read the linked issue: $(cat "$log")"
fi
if grep -q 'issues/37' "$calls"; then ok; else
  fail_case "the issue number must come from the branch name, got: $(cat "$calls")"
fi
# It must NOT consult the pull request body to find the issue: that body is
# what a pr-body pass may be about to call wrong.
if ! grep -q 'pulls/38' "$calls"; then ok; else
  fail_case "the issue-body pass must not read the pull request body to choose its issue"
fi
# Any type prefix, any issue number.
run PASS=issue-body HEAD_BRANCH=fix-102-a-thing >/dev/null
if grep -q 'issues/102' "$calls"; then ok; else
  fail_case "the derivation must work for any type prefix and number"
fi

# --- an empty or missing description is a FINDING, not a failure -------------
if [ "$(run PASS=pr-body GH_STUB_PR_BODY=)" = "0" ]; then ok; else
  fail_case "an empty pull request body must not fail the pass"
fi
if grep -q 'EMPTY description' "$subject"; then ok; else
  fail_case "an empty body must produce a subject the model can report on: $(cat "$subject")"
fi
# Whitespace-only is empty. A body of one newline says exactly as much as none.
run PASS=pr-body GH_STUB_PR_BODY='   
' >/dev/null
if grep -q 'EMPTY description' "$subject"; then ok; else
  fail_case "a whitespace-only body must count as empty"
fi
if [ "$(run PASS=issue-body HEAD_BRANCH=feat-37-x GH_STUB_ISSUE_BODY=)" = "0" ] &&
  grep -q 'EMPTY description' "$subject"; then ok; else
  fail_case "an empty issue body must be a finding, not a failure"
fi

# --- a branch that names no issue --------------------------------------------
# Not a pipeline failure: it is a finding, because this repository's branch
# convention requires an issue and work with none behind it cannot be checked
# against one. It must still write a subject, or the pass produces no findings
# file and the union's count reports the reviewer as missing.
if [ "$(run PASS=issue-body HEAD_BRANCH=main)" = "0" ]; then ok; else
  fail_case "a branch with no issue must not fail the pass"
fi
if [ -s "$subject" ] && grep -q 'names no issue' "$subject"; then ok; else
  fail_case "a branch with no issue must still write a subject: $(cat "$subject" 2>/dev/null)"
fi
if [ ! -s "$calls" ]; then ok; else
  fail_case "with no issue to read, no API call should be made: $(cat "$calls")"
fi
# A branch name carrying shell metacharacters must not reach the API path.
#
# THE INJECTION PAYLOAD IS A CANARY, NOT A DESTRUCTIVE COMMAND. An earlier
# version of this suite used `rm -rf /`. The reasoning was that the assertion
# refuses the value, so the command never runs, but that reasoning is backwards:
# the payload only executes in the exact case this test exists to catch, so the
# consequence of the regression it hunts was to wipe the machine running the
# suite. This file tells a developer to run it locally, which makes that
# machine theirs. A test may not depend on the correctness of the code under
# test for its own safety.
#
# `touch <canary>` is equally metacharacter-rich, and it is strictly stronger:
# refusal is asserted, and the canary's absence then proves nothing executed,
# where a destructive payload proves that only by the machine surviving.
canary="$work/canary-must-not-exist"
run PASS=issue-body "HEAD_BRANCH=feat-1-x;touch $canary" >/dev/null
if [ ! -s "$calls" ] && grep -q 'names no issue' "$subject"; then ok; else
  fail_case "a branch name with metacharacters must be refused, not spliced into a path"
fi
if [ ! -e "$canary" ]; then ok; else
  fail_case "a rejected HEAD_BRANCH reached a shell: the canary at $canary was created"
fi

# --- an unknown pass is refused ----------------------------------------------
if [ "$(run PASS=code)" != "0" ]; then ok; else
  fail_case "the code pass has no subject to fetch and must be refused here"
fi
if [ "$(run PASS=nonsense)" != "0" ]; then ok; else
  fail_case "an unknown pass must be refused"
fi

# --- required inputs ----------------------------------------------------------
for missing in GH_TOKEN OWNER REPO_NAME PR_NUMBER PASS SUBJECT_FILE; do
  set +e
  (env PATH="$stub_dir:$PATH" GH_STUB_CALLS="$calls" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=38 PASS=pr-body \
    SUBJECT_FILE="$subject" "$missing=" bash "$script") >"$log" 2>&1
  st=$?
  set -e
  if [ "$st" -ne 0 ]; then ok; else fail_case "$missing must be required"; fi
done
# HEAD_BRANCH is required only for the pass that uses it.
set +e
(env PATH="$stub_dir:$PATH" GH_STUB_CALLS="$calls" GH_TOKEN=t OWNER=o REPO_NAME=r \
  PR_NUMBER=38 PASS=issue-body SUBJECT_FILE="$subject" bash "$script") >"$log" 2>&1
st=$?
set -e
if [ "$st" -ne 0 ]; then ok; else fail_case "HEAD_BRANCH must be required for an issue-body pass"; fi

# --- AN API REFUSAL IS NOT AN EMPTY DESCRIPTION ------------------------------
# The first version swallowed the call's exit status, so a token without
# `issues: read` produced an empty body, took the "empty description" path, and
# the pass reviewed a placeholder while reporting SUCCESS. Measured on this
# repository's own pull request: an 86,045-byte issue was read as 146 bytes.
#
# Same reasoning as check-dispositions.sh telling a 403 from a 404: reporting a
# permission problem as "there is nothing there" sends the reader to exactly
# the wrong place.
if [ "$(run PASS=issue-body HEAD_BRANCH=feat-37-x GH_STUB_FAIL=1)" != "0" ]; then ok; else
  fail_case "an API refusal must FAIL, not be reported as an empty issue"
fi
if grep -q 'issues: read' "$log"; then ok; else
  fail_case "the refusal must name the scope it needs: $(cat "$log")"
fi
if grep -q 'not an empty issue' "$log"; then ok; else
  fail_case "the refusal must say it is a pipeline failure, not an empty description"
fi
# It must NOT write a subject, or the pass would run against it anyway.
if [ ! -s "$subject" ]; then ok; else
  fail_case "a refused read must leave no subject behind: $(cat "$subject")"
fi
if [ "$(run PASS=pr-body GH_STUB_FAIL=1)" != "0" ]; then ok; else
  fail_case "an API refusal on the pull request must fail too"
fi
if grep -q 'pull-requests: read' "$log"; then ok; else
  fail_case "the pull request refusal must name its scope: $(cat "$log")"
fi
# And the two must stay distinguishable: a genuinely empty body still passes.
if [ "$(run PASS=issue-body HEAD_BRANCH=feat-37-x GH_STUB_ISSUE_BODY=)" = "0" ]; then ok; else
  fail_case "a genuinely empty issue must still be a finding rather than a failure"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
