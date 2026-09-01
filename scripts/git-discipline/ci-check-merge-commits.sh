#!/usr/bin/env bash
# ci-check-merge-commits.sh
# CI mirror of forbid-merge-commit.sh: fails when the pull request's own commit
# range contains a merge commit.
#
# The local hooks are the fast feedback and are bypassable with --no-verify,
# which the project's discipline forbids but git does not. This reads the
# commits themselves, so a merge commit cannot exist on a branch while CI
# reports green over it. Same relationship ci-validate-commits.sh has to
# validate-commit-msg.sh, in the same job.
#
# Env:
#   BASE_SHA  required; the PR base commit SHA.
#   HEAD_SHA  required; the PR head commit SHA.
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"

# --merges selects commits with more than one parent, which is exactly the
# definition being enforced; there is no need to parse parents by hand.
merges="$(git rev-list --merges "${BASE_SHA}..${HEAD_SHA}")"

# Counted separately from the merge list so an empty RANGE and a range with no
# merges are distinguishable. They are not the same result: the first means the
# check examined nothing.
total="$(git rev-list --count "${BASE_SHA}..${HEAD_SHA}")"

if [ -n "$merges" ]; then
  count="$(printf '%s\n' "$merges" | wc -l | tr -d ' ')"
  echo "::error::$count merge commit(s) in ${BASE_SHA}..${HEAD_SHA}. A stacked branch is rebased onto its base, never merged with it." >&2
  # Every offender, not just the first: reporting one per push costs a CI
  # round-trip per merge commit, the same accumulate-rather-than-abort rule the
  # sibling checks in this job already follow.
  while read -r sha; do
    [ -n "$sha" ] || continue
    echo "::error::merge commit $sha: $(git log -1 --format=%s "$sha")" >&2
  done <<<"$merges"
  echo "Recover by rebasing the branch onto its base instead:" >&2
  echo "  git pull        # rebases, because pull.rebase is set" >&2
  exit 1
fi

if [ "$total" -eq 0 ]; then
  echo "::error::ci-check-merge-commits: the range ${BASE_SHA}..${HEAD_SHA} contains no commits, so nothing was examined. Refusing to report success for a check that saw nothing." >&2
  exit 1
fi

echo "ci-check-merge-commits: $total commit(s) in range, no merge commits."
