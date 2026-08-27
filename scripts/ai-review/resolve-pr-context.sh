#!/usr/bin/env bash
# resolve-pr-context.sh — works out WHICH pull request the trunk workflow is
# reviewing, and writes it to $GITHUB_OUTPUT as `pr`.
#
# Why a script and not an inline expression: the pull request number decides
# where every finding gets posted and which threads the gate reads, so getting
# it wrong posts one pull request's review onto another. It has two sources,
# both of them GitHub's own server-side data, and neither of them the artifact
# the pull request uploaded:
#
#   1. github.event.workflow_run.pull_requests[0].number, passed in as
#      EVENT_PR_NUMBER. Populated for a SAME-REPOSITORY pull request, and the
#      cheapest answer when it is there.
#   2. The commits/{sha}/pulls API, asked which open pull request the reviewed
#      head commit belongs to. This is the fallback for a pull request opened
#      from a FORK, where GitHub leaves the payload's pull_requests array
#      empty. Without it the whole pipeline breaks on fork pull requests, with
#      an empty PR_NUMBER reaching scripts that would then address the API
#      path repos/o/r/pulls//comments.
#
# The artifact is never consulted. Letting pull-request-authored content name
# its own pull request number would hand any contributor the ability to post
# review comments, and resolve threads, on somebody else's pull request under
# the review App's identity.
#
# Env:
#   GH_TOKEN         required; a token with pull-requests: read.
#   OWNER            required; repo owner login.
#   REPO_NAME        required; repo name.
#   HEAD_SHA         required; the reviewed head commit SHA
#                    (github.event.workflow_run.head_sha).
#   EVENT_PR_NUMBER  optional; the workflow_run payload's pull request number,
#                    empty for a fork's pull request.
#   GITHUB_OUTPUT    required; the step-output file Actions provides.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
# HEAD_SHA is exported, not just set, because the jq filter below reads it as
# `env.HEAD_SHA`. gh's `-q` has no --arg equivalent, and splicing the value
# into the filter text would make an attacker-influenceable string part of a
# jq program. Reading it from the environment keeps it data.
export GH_TOKEN HEAD_SHA

pr="${EVENT_PR_NUMBER:-}"
source="the workflow_run payload"

if [ -z "$pr" ]; then
  source="the commits/{sha}/pulls API"
  # Two filters, both load-bearing, and neither is `[0]`:
  #
  #   - OPEN only. A head commit also appears on closed pull requests (a
  #     superseded one from the same branch), and posting a review onto a
  #     closed pull request is never the intent.
  #   - `.head.sha == HEAD_SHA`. The endpoint answers "which pull requests is
  #     this commit associated with", which includes ones where it is merely
  #     an ancestor. Only the pull request whose HEAD is this commit is the
  #     one under review.
  #
  # `|| true`: a lookup that finds nothing is not an API failure, and the
  # validation below turns "no pull request" into a clear error.
  matches="$(gh api "repos/$OWNER/$REPO_NAME/commits/$HEAD_SHA/pulls" \
    -q '[.[] | select(.state == "open") | select(.head.sha == env.HEAD_SHA) | .number]' \
    2>/dev/null || true)"
  [ -n "$matches" ] || matches='[]'
  count="$(printf '%s' "$matches" | jq 'length' 2>/dev/null || echo 0)"
  # More than one survivor is refused, not resolved by picking the first.
  # Two open pull requests can share a head commit (branches cut from the
  # same tip), and "whichever GitHub happened to list first" would silently
  # post one pull request's review, under the App's identity, onto the other.
  # An operator seeing this error can disambiguate; a wrong guess is
  # invisible.
  if [ "$count" -gt 1 ]; then
    echo "::error::resolve-pr-context.sh: $HEAD_SHA is the head of more than one open pull request ($(printf '%s' "$matches" | jq -c .)); refusing to guess which one is under review." >&2
    exit 1
  fi
  pr="$(printf '%s' "$matches" | jq -r '.[0] // empty' 2>/dev/null || true)"
fi

# Digits only. Everything downstream splices this straight into an API path,
# and a non-numeric value would either address the wrong resource or fail
# somewhere far less legible than here.
case "$pr" in
'' | *[!0-9]*)
  echo "::error::resolve-pr-context.sh: could not resolve an open pull request for $HEAD_SHA (checked the workflow_run payload and the commits/{sha}/pulls API); refusing to guess." >&2
  exit 1
  ;;
esac

echo "pr=$pr" >>"$GITHUB_OUTPUT"
echo "resolve-pr-context.sh: reviewing pull request #$pr (resolved from $source)."
