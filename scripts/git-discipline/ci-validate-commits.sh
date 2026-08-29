#!/usr/bin/env bash
# CI commitlint: validates every commit's message in the PR's commit range
# against validate-commit-msg.sh, cross-checked against the PR's own head
# branch (the checkout here is a detached merge ref, so the real branch name
# has to be threaded through explicitly).
#
# Env:
#   BASE_SHA          required; the PR base commit SHA.
#   HEAD_SHA          required; the PR head commit SHA.
#   COMMIT_MSG_BRANCH required; the PR's head branch name (github.head_ref).
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${COMMIT_MSG_BRANCH:?COMMIT_MSG_BRANCH is required}"
export COMMIT_MSG_BRANCH

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Process substitution, not a pipe: a `git log | while read` loop runs the body
# in a subshell, so a counter incremented inside it is discarded the moment the
# pipeline exits, and the empty-range guard below could never see a real count.
checked=0
bad=0
while read -r sha; do
  [ -n "$sha" ] || continue
  checked=$((checked + 1))
  msg_file="$(mktemp)"
  git log -1 --format="%s%n%n%b" "$sha" >"$msg_file"
  echo "Checking commit $sha ..."
  # Guarded, so the loop keeps going. Unguarded under `set -e` the first
  # malformed message aborts the whole script, so a pull request with three bad
  # commits reports one, gets fixed, reports the next, and burns a CI round per
  # commit. The sibling check-commit-authors.sh in this same job already
  # accumulates across the range for exactly that reason; this now matches it.
  if ! bash "$script_dir/validate-commit-msg.sh" "$msg_file"; then
    echo "::error::commit $sha has an invalid message." >&2
    bad=$((bad + 1))
  fi
  rm -f "$msg_file"
done < <(git log --format="%H" "${BASE_SHA}..${HEAD_SHA}")

# A range of zero commits FAILS rather than passing silently, matching the
# sibling check-commit-authors.sh that runs in this same CI job. An empty range
# means base and head resolved to the same commit, which for a pull request is
# a broken invocation, not a clean result: the required `commitlint` check would
# otherwise report green having validated no commit message at all.
if [ "$bad" -ne 0 ]; then
  echo "::error::$bad of $checked commit message(s) in ${BASE_SHA}..${HEAD_SHA} are invalid." >&2
  exit 1
fi

if [ "$checked" -eq 0 ]; then
  echo "::error::ci-validate-commits: the range ${BASE_SHA}..${HEAD_SHA} contains no commits, so no commit message was validated. Refusing to report success for a check that examined nothing." >&2
  exit 1
fi
