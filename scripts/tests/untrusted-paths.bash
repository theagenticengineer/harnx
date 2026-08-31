#!/usr/bin/env bash
# Standalone test for where .github/workflows/ai-review-trunk.yml puts
# pull-request-derived content.
# Run: bash scripts/tests/untrusted-paths.bash
#
# A suite over a workflow rather than over a script, the same shape as
# action-pins.bash and workflow-job-names.bash, because the property lives in
# YAML and nothing else would catch it breaking.
#
# THE RULE THE WORKFLOW STATES ABOUT ITSELF: anything derived from the pull
# request lands under RUNNER_TEMP, never in $GITHUB_WORKSPACE, because the
# workspace is where the TRUSTED scripts live and these jobs hold the review
# engine's token and the App's private key.
#
# It had drifted in one place. The diff and the review memory obeyed it; the
# model's own OUTPUT did not. ai-review-findings.json was written to the
# checkout root, uploaded from there, and downloaded straight back into the
# checkout root of the job holding the App private key. Nothing sources or
# executes that file, so this was never an open hole; it was a rule with an
# exception nobody could justify, and a rule with one of those stops being a
# rule. This suite is what stops the exception coming back.
#
# WHAT COUNTS AS DERIVED FROM THE PULL REQUEST, and it is broader than "the
# diff": the findings are the model's reading of an attacker-authored diff, and
# the timing file is written by the same job. Both cross to the credentialed
# job as an artifact.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/ai-review-trunk.yml"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

if [ -f "$workflow" ]; then ok; else
  fail_case "$workflow must exist"
  echo "RESULT: $pass passed, $fail failed"
  exit 1
fi

# Every line that names one of the pull-request-derived files must place it
# under RUNNER_TEMP (as a shell variable) or runner.temp (as an expression).
# Matched on the FILENAME rather than on a directory, so a file moved back to
# the workspace is caught by the same assertion that would catch it being
# renamed there.
for artefact in diff.txt ai-review-findings.json ai-review-seconds.txt \
  ai-review-handled.json ai-review-open.json; do
  offending=""
  while IFS= read -r line; do
    # Comments describe the rule; they are not what runs.
    case "$line" in
    *"#"*"$artefact"*) continue ;;
    esac
    # shellcheck disable=SC2016  # these are the literal strings being searched
    # for in the workflow, not expansions this script wants performed.
    case "$line" in
    *'$RUNNER_TEMP'* | *'runner.temp'*) continue ;;
    *) offending="$offending
    $line" ;;
    esac
  done <<EOF
$(grep -n -- "$artefact" "$workflow" | grep -vE '^\s*[0-9]+:\s*#')
EOF
  if [ -z "$offending" ]; then ok; else
    fail_case "$artefact is referenced outside RUNNER_TEMP, so pull-request-derived content lands in the workspace:$offending"
  fi
done

# The upload and the download must agree about the directory, or the download
# silently lands the artifact somewhere the consumer is not reading from and
# the job fails on a missing file rather than on anything informative.
if grep -qE '^\s+path: \$\{\{ runner\.temp \}\}/ai-review-out/?$' "$workflow"; then ok; else
  fail_case "both the upload and the download must carry an explicit runner.temp path"
fi
if [ "$(grep -cE '^\s+path: \$\{\{ runner\.temp \}\}/ai-review-out/?$' "$workflow")" -ge 2 ]; then ok; else
  fail_case "the download step must carry a path: too; without one it unpacks into the checkout root"
fi

# The diff artifact is gone, and must stay gone: it was the review INPUT, and
# a pull_request-triggered workflow wrote it. extract-diff.sh replaced it.
if ! grep -q 'name: ai-review-diff' "$workflow"; then ok; else
  fail_case "the pull request's diff artifact must not be consumed again; the trunk computes the diff itself"
fi
if grep -q 'extract-diff.sh' "$workflow"; then ok; else
  fail_case "the trunk must compute the reviewed diff itself"
fi

# THE JOB BUDGET AND THE CHUNK LIMIT ARE A PAIR. Chunking multiplies the
# engine's wall clock by the chunk count; a job timeout sized for one call gets
# the run CANCELLED, and the gate then reports "the review pipeline did not
# complete", which is indistinguishable from a dead token. Raising either one
# alone reintroduces that, so the workflow is pinned to a budget that fits the
# engine's own limit.
# Scoped to the REVIEW JOB, by the same awk walk the resolved-job check uses.
# Unscoped it passed if ANY job anywhere in the file happened to carry a
# timeout in range, so the review job could keep a one-call budget while the
# assertion reported green. That is the same vacuity as the resolved-job check
# before it was scoped, in the same file, and it is worth naming: an assertion
# about "the workflow" is almost never the assertion you meant.
review_timeout="$(awk '
  /^  review:/    { injob = 1; next }
  /^  [a-z_]+:/   { injob = 0 }
  injob && /^    timeout-minutes: / { print $2; exit }
' "$workflow")"
case "$review_timeout" in
'' | *[!0-9]*)
  fail_case "could not read the review job's timeout-minutes"
  ;;
*)
  if [ "$review_timeout" -ge 20 ]; then ok; else
    fail_case "the review job's timeout is ${review_timeout}m, too short for a chunked review; a one-call budget gets a large diff cancelled and the gate then reports a broken pipeline"
  fi
  ;;
esac

# THE GATE JOB MUST NOT DEPEND ON THE CONTEXT JOB SUCCEEDING. ai-review-resolved
# is a required context, so a gate job that is skipped publishes nothing and the
# pull request sits on "Expected" forever, with no red check to read and no
# recovery but a re-run nobody knows to ask for. That is worse than a red gate.
# Scoped to the RESOLVED JOB's own `if:`, not to the file. A bare grep for
# "!cancelled()" matches the status-comment step in post_findings too, so it
# passed whatever the resolved job said: an assertion that pinned nothing,
# caught by mutating the job and watching nothing fail.
resolved_if="$(awk '
  /^  resolved:/ { injob = 1; next }
  /^  [a-z_]+:/  { injob = 0 }
  injob && /^    if: / { print; exit }
' "$workflow")"
case "$resolved_if" in
*"needs.context.result"*)
  fail_case "the resolved job must not require the context job to have succeeded; a context failure would then publish no verdict at all and the required check would sit on Expected forever. Got: $resolved_if"
  ;;
*"!cancelled()"*)
  ok
  ;;
*)
  fail_case "could not read the resolved job's condition. Got: ${resolved_if:-<none>}"
  ;;
esac
# And it must still skip a SUPERSEDED run. A new push cancels the pull request
# side, and a verdict published for that run is a red check about a review that
# was never meant to finish. The context job carries the same filter; the two
# have to agree or superseded commits collect failures that were never real.
case "$resolved_if" in
*"workflow_run.conclusion != 'cancelled'"*) ok ;;
*)
  fail_case "the resolved job must skip a cancelled triggering run, as the context job does. Got: $resolved_if"
  ;;
esac

# No checkout in this workflow may point at pull request content. Restated
# here rather than assumed, because it is the property every other guarantee
# in the file rests on and it is one `ref:` away from being lost.
if ! grep -qE '^\s+ref: ' "$workflow"; then ok; else
  fail_case "a checkout in the trunk workflow carries a ref:, which would place pull request code beside the credentials"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
