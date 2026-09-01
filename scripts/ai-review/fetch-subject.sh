#!/usr/bin/env bash
# fetch-subject.sh — reads the description a drift pass reviews.
#
# `pr-body` compares the pull request's own description against what was
# delivered. `issue-body` compares the linked issue's description against the
# same thing. Both are read from the API on the trusted side, never from
# anything the pull request produced.
#
# THE LINKED ISSUE COMES FROM THE BRANCH NAME, NOT THE PULL REQUEST BODY, and
# that is the interesting decision here. The body is exactly what a `pr-body`
# pass may be about to call wrong, so trusting it to say which issue to compare
# against would let a drifted description choose its own examiner: edit the
# body to link a different issue and the drift disappears. The branch name is
# fixed at creation, validated by the branch-name gate, and cannot be edited
# without opening a different pull request.
#
# AN API FAILURE IS NOT AN EMPTY DESCRIPTION, and conflating them is a
# fail-open this script shipped with. The first version swallowed the call's
# exit status with `|| true`, so a token without `issues: read` produced an
# empty body, which took the "empty description" path, and the pass then
# reviewed a placeholder while reporting success. Measured on this
# repository's own pull request: an 86,045-byte issue was read as 146 bytes,
# and the pass reported on a stub.
#
# So the two are separated. A call that FAILS is a hard error naming the
# probable cause, which is the same reasoning check-dispositions.sh uses to
# tell a 403 from a 404: reporting a permission problem as "there is nothing
# there" sends whoever reads it looking in exactly the wrong place.
#
# AN EMPTY OR MISSING DESCRIPTION IS A FINDING, NOT A FAILURE. A pull request
# whose body says nothing about what it delivered has drifted from it in the
# most complete way available, and a branch naming no issue cannot have its
# issue reviewed. Both write an explicit subject saying so, and the model
# reports it as an ordinary finding. Failing instead would turn a description
# problem into a pipeline problem, which is the wrong report and the wrong
# person's problem.
#
# Env:
#   GH_TOKEN      required; a token with pull-requests: read and issues: read.
#   OWNER         required; repo owner login.
#   REPO_NAME     required; repo name.
#   PR_NUMBER     required; the pull request number.
#   HEAD_BRANCH   required for issue-body; the pull request's branch name.
#   PASS          required; "pr-body" or "issue-body".
#   SUBJECT_FILE  required; path to write the description to.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${PASS:?PASS is required}"
: "${SUBJECT_FILE:?SUBJECT_FILE is required}"
export GH_TOKEN

mkdir -p "$(dirname "$SUBJECT_FILE")"

case "$PASS" in
pr-body)
  err="$(mktemp)"
  if ! body="$(gh api "repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER" -q '.body // ""' 2>"$err")"; then
    echo "::error::fetch-subject.sh: could not read pull request #$PR_NUMBER. This is a pipeline failure, not an empty description: the pass must not review a placeholder and report success. The job needs pull-requests: read. The API said: $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    printf '%s\n' "(This pull request has an EMPTY description. Report that as a finding: a pull request that says nothing about what it delivered cannot be checked against what it delivered.)" >"$SUBJECT_FILE"
    echo "fetch-subject.sh: pull request #$PR_NUMBER has an empty body; the pass will report that."
    exit 0
  fi
  printf '%s\n' "$body" >"$SUBJECT_FILE"
  echo "fetch-subject.sh: read $(wc -c <"$SUBJECT_FILE" | tr -d ' ') bytes of pull request #$PR_NUMBER's description."
  ;;
issue-body)
  : "${HEAD_BRANCH:?HEAD_BRANCH is required for an issue-body pass}"
  # The branch naming convention this repository's own gate enforces:
  # <type>-<issue>-<slug>.
  issue=""
  case "$HEAD_BRANCH" in
  *[!a-zA-Z0-9._/-]*) ;;
  *) issue="$(printf '%s' "$HEAD_BRANCH" | sed -n 's/^[a-z][a-z]*-\([0-9][0-9]*\)-.*$/\1/p')" ;;
  esac

  if [ -z "$issue" ]; then
    printf '%s\n' "(The branch '$HEAD_BRANCH' names no issue, so there is no linked issue to compare against. Report that as a finding: this repository's branch convention is <type>-<issue>-<slug>, and work with no issue behind it cannot be checked against one.)" >"$SUBJECT_FILE"
    echo "fetch-subject.sh: branch '$HEAD_BRANCH' names no issue; the pass will report that."
    exit 0
  fi

  err="$(mktemp)"
  if ! body="$(gh api "repos/$OWNER/$REPO_NAME/issues/$issue" -q '.body // ""' 2>"$err")"; then
    echo "::error::fetch-subject.sh: could not read issue #$issue, named by branch '$HEAD_BRANCH'. This is a pipeline failure, not an empty issue: the pass must not review a placeholder and report success. The job needs issues: read, which is NOT covered by pull-requests: read. The API said: $(tr '\n' ' ' <"$err")" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    printf '%s\n' "(Issue #$issue, named by the branch, has an EMPTY description. Report that as a finding: work cannot be checked against an issue that says nothing.)" >"$SUBJECT_FILE"
    echo "fetch-subject.sh: issue #$issue has an empty body; the pass will report that."
    exit 0
  fi
  printf '%s\n' "$body" >"$SUBJECT_FILE"
  echo "fetch-subject.sh: read $(wc -c <"$SUBJECT_FILE" | tr -d ' ') bytes of issue #$issue's description, linked from branch '$HEAD_BRANCH'."
  ;;
*)
  echo "fetch-subject.sh: PASS must be 'pr-body' or 'issue-body', got '$PASS'." >&2
  exit 1
  ;;
esac
