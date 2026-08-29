#!/usr/bin/env bash
# fetch-review-threads.sh — writes every review thread on a pull request to
# THREADS_OUTPUT as one JSON array of
# {id, isResolved, path, comments: {nodes: [{databaseId, body}]}} nodes.
#
# Cursor-paginated, not first-page-only: a PR with more than 100 threads is
# not unusual once ordinary human discussion is counted, and every caller
# here draws a conclusion (what is already handled, how many Majors are
# open) that a truncated read would get silently wrong.
#
# This is the shared copy for the two scripts added alongside it
# (handled-from-threads.sh, post-ci-status.sh). check-resolved.sh and
# post-findings.sh still carry their own inline copy of the same pagination,
# and check-dispositions.sh a third, because each needs a different slice of
# the thread (first comment only, first comment plus id, every comment). Both
# of the first two gate merge today, and rewriting a working required gate to
# save a duplicated loop is not a trade worth making while the shapes still
# differ.
#
# The earlier version of this note deferred that cleanup to #34. That is no
# longer where it would land: #37 owns the changes to post-findings.sh and
# check-dispositions.sh now, so the deferral pointed a reader at an issue that
# does not own the work. Recorded as an open shape rather than assigned, since
# no criterion asks for it.
#
# Env:
#   GH_TOKEN        required; a token with pull-requests: read (read-only,
#                   so this is safe to run in a job that holds no write
#                   credential).
#   OWNER           required; repo owner login.
#   REPO_NAME       required; repo name.
#   PR_NUMBER       required; the pull request number.
#   THREADS_OUTPUT  required; path to write the JSON array to. Deliberately
#                   not named OUTPUT: callers set their own OUTPUT for their
#                   own result file, and a child process inheriting that
#                   name would overwrite it.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${THREADS_OUTPUT:?THREADS_OUTPUT is required}"
export GH_TOKEN

# `merged` IS DECLARED HERE, not just inside the loop, so ONE handler owns
# every temp file this script makes. Created per iteration and consumed by the
# `mv`, it survives only when something between the two fails: a GraphQL error
# under `set -e` exits the script mid-loop and leaves the file in the runner's
# temp directory. Reset after each move so the trap never names a path that was
# already consumed. Same shape, and same fix, as post-findings.sh and
# check-dispositions.sh.
all_nodes="$(mktemp)"
merged=""
trap 'rm -f "$all_nodes" "$merged"' EXIT
printf '[]' >"$all_nodes"

# gh api's -F treats the literal keyword "null" as GraphQL null (the query's
# $after:String is optional, so null == "start from the first page"), needed
# only for the first request. Every later iteration uses -f, not -F: -F
# type-coerces a purely-numeric value into a JSON number, which a String!
# argument would reject, and GitHub's cursors are opaque strings not
# guaranteed to avoid looking numeric. -f always sends a raw string,
# matching the argument's actual type regardless of the cursor's shape.
cursor=""
while :; do
  if [ -z "$cursor" ]; then
    after_field=(-F after=null)
  else
    after_field=(-f after="$cursor")
  fi
  # `path` is requested alongside the comment body because the file a
  # finding belongs to lives on the THREAD (the review comment's anchor);
  # post-findings.sh does not repeat it inside the body it writes.
  # shellcheck disable=SC2016  # single-quoted deliberately: $owner/$repo/$pr/$after
  # are GraphQL variable syntax here, not shell expansions.
  page="$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$after:String) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              path
              comments(first: 1) { nodes { databaseId body } }
            }
          }
        }
      }
    }' -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" "${after_field[@]}" \
    -q '.data.repository.pullRequest.reviewThreads')"

  merged="$(mktemp)"
  jq -s '.[0] + .[1].nodes' "$all_nodes" <(printf '%s' "$page") >"$merged"
  mv "$merged" "$all_nodes"
  merged=""

  [ "$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage')" = "true" ] || break
  cursor="$(printf '%s' "$page" | jq -r '.pageInfo.endCursor')"
done

cp "$all_nodes" "$THREADS_OUTPUT"
