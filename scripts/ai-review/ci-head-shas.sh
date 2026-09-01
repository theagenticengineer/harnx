#!/usr/bin/env bash
# ci-head-shas.sh — print the number of DISTINCT commit SHAs that CI has run
# against for a branch, or exit 1 if that cannot be read.
#
# WHY DISTINCT SHAS AND NOT RUNS. One push starts several workflows, so a run
# count would tick by four or five per push and any cap expressed in it would
# mean something different on a branch with a different number of workflows. A
# distinct head SHA is one pushed state of the code, which is the unit the round
# cap is actually about.
#
# WHY THIS IS ITS OWN SCRIPT rather than a function copied into the two callers.
# loop-init.sh records this number in the baseline row and check-round-cap.sh
# SUBTRACTS that recorded number from a freshly computed one. Two independent
# implementations of the same count are free to disagree, and a disagreement
# between them does not look like a bug: it looks like rounds that were never
# spent, or a cap that fires early. One implementation cannot drift from itself.
#
# EXIT 1 RATHER THAN PRINTING 0 when gh is missing, unauthenticated, or the API
# call fails. Zero is a claim that CI has never run for this branch, and a
# caller that believed it would count local passes only while reporting that it
# had counted both. Callers turn a non-zero exit into an explicit null.
#
# Args:
#   $1  branch name; defaults to the current branch.
set -euo pipefail

branch="${1:-$(git rev-parse --abbrev-ref HEAD)}"

command -v gh >/dev/null 2>&1 || {
  echo "ci-head-shas: gh is not on PATH." >&2
  exit 1
}

# --limit 500 rather than the default 20. The default silently truncates, and a
# truncated count is worse than no count: it is wrong in the direction that
# makes the cap fire late, which is the direction nobody notices.
shas="$(gh run list --branch "$branch" --limit 500 --json headSha \
  -q '.[].headSha' 2>/dev/null)" || {
  echo "ci-head-shas: could not read workflow runs for '$branch'." >&2
  exit 1
}

printf '%s\n' "$shas" | sed '/^$/d' | sort -u | wc -l | tr -d ' '
