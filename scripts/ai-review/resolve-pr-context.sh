#!/usr/bin/env bash
# resolve-pr-context.sh — works out WHICH pull request the trunk workflow is
# reviewing, and writes it to $GITHUB_OUTPUT as `pr` and `base`.
#
# `base` is the pull request's BASE BRANCH NAME, and it is not a convenience:
# extract-diff.sh recomputes the reviewed diff on the trusted side and needs
# the branch to diff against. It comes from the same server-side payload the
# number does, for the same reason: a base branch named by pull-request
# content could be pointed at the pull request's own head, which diffs to
# nothing and reviews nothing.
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
base=""
source="the workflow_run payload"

# The payload's number is VERIFIED, not trusted, on BOTH of the properties the
# fallback path below checks, and for the same reasons.
#
#   head.sha  One branch can carry more than one open pull request (same head,
#             different bases), and pull_requests[0] is an ordering GitHub
#             chose, not a statement about which one this run reviewed. If it
#             named the wrong one, findings would post onto that pull request
#             while the check run was anchored to this run's head commit: a
#             verdict about one pull request published against another's code.
#
#   state     The fallback path has always filtered on `state == "open"`; the
#             primary path did not, and the inconsistency was the giveaway.
#             The workflow_run payload is a snapshot of the moment the
#             triggering run started, and the trunk run that reads it starts
#             later, so a pull request closed or merged in between is still
#             named there. Posting a review onto a closed pull request is never
#             the intent, and on a MERGED one it is worse than useless: the
#             threads land where nobody is looking and the gate is computed
#             from them.
#
# Verifying costs one API call on a path that already has a token. Falling
# through to the head.sha lookup, rather than failing, keeps the common case
# working when the payload is simply stale.
if [ -n "$pr" ]; then
  payload_pr="$(gh api "repos/$OWNER/$REPO_NAME/pulls/$pr" 2>/dev/null || true)"
  payload_head="$(printf '%s' "$payload_pr" | jq -r '.head.sha // empty' 2>/dev/null || true)"
  payload_state="$(printf '%s' "$payload_pr" | jq -r '.state // empty' 2>/dev/null || true)"
  base="$(printf '%s' "$payload_pr" | jq -r '.base.ref // empty' 2>/dev/null || true)"
  if [ "$payload_head" != "$HEAD_SHA" ]; then
    echo "resolve-pr-context.sh: the workflow_run payload named pull request #$pr, whose head is '${payload_head:-unknown}', not the reviewed commit $HEAD_SHA; ignoring it and resolving from the commit instead." >&2
    pr=""
    base=""
  elif [ "$payload_state" != "open" ]; then
    echo "resolve-pr-context.sh: the workflow_run payload named pull request #$pr, which is '${payload_state:-unknown}', not open; ignoring it and resolving from the commit instead." >&2
    pr=""
    base=""
  fi
fi

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
    -q '[.[] | select(.state == "open") | select(.head.sha == env.HEAD_SHA) | {number, base: .base.ref}]' \
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
  pr="$(printf '%s' "$matches" | jq -r '.[0].number // empty' 2>/dev/null || true)"
  base="$(printf '%s' "$matches" | jq -r '.[0].base // empty' 2>/dev/null || true)"
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

# The base branch is refused when empty for the same reason the number is when
# non-numeric: extract-diff.sh would otherwise be handed an empty ref name,
# `git fetch` would resolve it to something unintended or fail somewhere far
# less legible, and a review computed against the wrong base is a review of the
# wrong thing.
if [ -z "$base" ]; then
  echo "::error::resolve-pr-context.sh: resolved pull request #$pr but not its base branch; refusing to hand the extractor an empty ref." >&2
  exit 1
fi

echo "pr=$pr" >>"$GITHUB_OUTPUT"
echo "base=$base" >>"$GITHUB_OUTPUT"
echo "resolve-pr-context.sh: reviewing pull request #$pr against base '$base' (resolved from $source)."
