#!/usr/bin/env bash
# evaluate-gate.sh: decides the ai-review-resolved verdict, and says WHY.
#
# WHY IT IS A SCRIPT AND NOT AN INLINE `run:` BLOCK. Same reason as
# require-diff.sh: this is the logic that decides whether a pull request can
# merge, and an inline block in .github/workflows/ai-review-trunk.yml cannot be
# reached by scripts/tests/*.bash, so nothing could pin it. Its paired test is
# scripts/tests/evaluate-gate.bash.
#
# THE PROBLEM IT SOLVES, beyond deciding the verdict. The two sub-checks below
# already print precise, actionable errors, and every one of them used to be
# discarded: the workflow captured nothing, and post-check-run.sh published the
# fixed sentence "The ai-review gate is red." for every possible cause. An
# expired engine token and a backlog of undispositioned findings are unrelated
# problems with unrelated fixes, and both surfaced on the pull request as that
# one string, so reading the workflow logs was the only way to tell them apart.
#
# So this script emits two things alongside its exit status:
#
#   GATE_CAUSE   one line, the headline reason, which becomes the check run's
#                TITLE (the only text GitHub renders in the merge box).
#   GATE_DETAIL  everything the sub-checks printed, which becomes the check
#                run's expandable body.
#
# BOTH SUB-CHECKS RUN, even when the first fails. Under a bare `set -e` the
# script would abort at check-resolved.sh and never reach check-dispositions.sh,
# so a pull request with both problems would fix one, push, and only then
# discover the other, burning a CI round per problem. The sibling
# ci-validate-commits.sh accumulates across its whole range for exactly this
# reason; this matches it.
#
# Env:
#   CONTEXT_RESULT optional; needs.context.result from the workflow. When it is
#                  anything but "success" the pull request number was never
#                  resolved, so no sub-check can run and this is the ONLY thing
#                  that can still publish a verdict.
#   REVIEW_RESULT  required; needs.review.result from the workflow.
#   POST_RESULT    required; needs.post_findings.result from the workflow.
#   GATE_CAUSE_FILE   optional; path to write the one-line cause to.
#   GATE_DETAIL_FILE  optional; path to write the full detail to.
#   GH_TOKEN, OWNER, REPO_NAME, PR_NUMBER: passed through to the sub-checks.
set -euo pipefail

: "${REVIEW_RESULT:?REVIEW_RESULT is required}"
: "${POST_RESULT:?POST_RESULT is required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detail="$(mktemp)"
trap 'rm -f "$detail"' EXIT

cause=""
fail=0

# Records a cause. The FIRST one recorded wins the headline, because the
# checks below run in order of how fundamental they are: a pipeline that never
# completed makes everything after it meaningless, so it must not be displaced
# by a finding count derived from a review that did not happen.
note_cause() {
  [ -n "$cause" ] || cause="$1"
}

# A SUB-CHECK CAN FAIL IN TWO COMPLETELY DIFFERENT WAYS, and calling them the
# same thing is the exact defect this file exists to remove, reintroduced one
# level down.
#
#   It reported.  It ran to a verdict and printed an `::error::` line saying
#                 which findings are open or undispositioned. The contributor
#                 has something to do.
#   It crashed.   It never reached a verdict: an unset GH_TOKEN, a token
#                 missing `issues: read`, a GraphQL error under `set -e`.
#                 bash prints "GH_TOKEN: parameter null or not set", which is
#                 not an `::error::` line, so the grep found nothing and the
#                 fallback announced a finding backlog. The contributor then
#                 goes looking for threads to resolve on a pull request whose
#                 problem is a misconfigured pipeline, which is precisely the
#                 wrong place, and no number of resolutions clears it.
#
# So a run that produced no `::error::` line at all is reported as what it is,
# quoting whatever the sub-check did manage to say.
crashed_cause() {
  local out="$1" script="$2" last
  last="$(grep -v '^[[:space:]]*$' "$out" | tail -n1 || true)"
  note_cause "$script exited non-zero without reaching a verdict: ${last:-no output}. This is a pipeline failure, not a finding backlog."
}

emit() {
  [ -z "${GATE_CAUSE_FILE:-}" ] || printf '%s\n' "$cause" >"$GATE_CAUSE_FILE"
  [ -z "${GATE_DETAIL_FILE:-}" ] || cp "$detail" "$GATE_DETAIL_FILE"
}

# 1. Did the pipeline that produces the review even finish? This is checked
#    first and short-circuits: with no review there are no threads to judge,
#    so running the two checks below would report "no findings" about a review
#    that never ran, which is the exact fail-open require-diff.sh exists to
#    prevent one stage earlier.
context_result="${CONTEXT_RESULT:-success}"
if [ "$context_result" != "success" ] ||
  [ "$REVIEW_RESULT" != "success" ] || [ "$POST_RESULT" != "success" ]; then
  note_cause "The review pipeline did not complete (context=$context_result, review=$REVIEW_RESULT, post-findings=$POST_RESULT), so the review never ran."
  {
    echo "The ai-review pipeline did not complete, so no verdict about findings is possible."
    echo
    echo "  context job:       $context_result"
    echo "  review job:        $REVIEW_RESULT"
    echo "  post-findings job: $POST_RESULT"
    echo
    echo "This is a pipeline failure, not a finding backlog. Common causes: an expired or revoked engine token, a diff the extractor refused because the pull request's head moved, the GitHub App credentials being unreadable, or the pull request number failing to resolve. Open the run linked under Details and read the failed job."
    echo
    echo "This check run exists precisely so that a broken pipeline still REPORTS. ai-review-resolved is a required context, so publishing nothing would leave the pull request on 'Expected' with nothing to read and no way to recover but a re-run nobody knows to ask for."
  } >"$detail"
  echo "::error::ai-review-resolved: $cause"
  cat "$detail"
  emit
  exit 1
fi

# 2. Is anything still OPEN? Output is captured rather than streamed so it can
#    become the check run's body, then echoed so it still appears in the logs.
resolved_out="$(mktemp)"
if ! bash "$script_dir/check-resolved.sh" >"$resolved_out" 2>&1; then
  fail=1
  # The script's own ::error:: line is already a precise one-liner, so it is
  # reused verbatim rather than paraphrased into something that could drift
  # away from what the check actually reports. No such line means it never got
  # that far; see crashed_cause.
  line="$(grep -m1 '^::error::' "$resolved_out" | sed 's/^::error:://' || true)"
  if [ -n "$line" ]; then
    note_cause "$line"
  else
    crashed_cause "$resolved_out" "check-resolved.sh"
  fi
fi
cat "$resolved_out" >>"$detail"
cat "$resolved_out"
rm -f "$resolved_out"

# 3. For everything that was CLOSED, what happened to it? check-resolved.sh
#    asks whether anything is still open; this asks whether resolving a thread
#    was used to bury it.
disp_out="$(mktemp)"
if ! bash "$script_dir/check-dispositions.sh" >"$disp_out" 2>&1; then
  fail=1
  # Counted, not quoted: check-dispositions.sh prints one ::error:: line per
  # offending finding plus a trailing summary line, so quoting its first line
  # would name a single finding and hide that there are eleven more. The count
  # is the actionable number.
  #
  # The `::error::` test comes FIRST, before the count, because a crash
  # produces neither a count nor an error line and must not fall through to a
  # sentence about findings.
  if ! grep -q '^::error::' "$disp_out"; then
    crashed_cause "$disp_out" "check-dispositions.sh"
  else
    n="$(grep -c 'has no disposition' "$disp_out" || true)"
    if [ "${n:-0}" -gt 0 ]; then
      note_cause "$n resolved Major finding(s) have no disposition."
    else
      note_cause "Resolved Major ai-review findings are not properly accounted for."
    fi
  fi
fi
cat "$disp_out" >>"$detail"
cat "$disp_out"
rm -f "$disp_out"

if [ "$fail" -ne 0 ]; then
  echo "::error::ai-review-resolved: $cause"
  emit
  exit 1
fi

cause="No unresolved Major ai-review findings."
emit
echo "evaluate-gate: $cause"
