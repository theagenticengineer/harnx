#!/usr/bin/env bash
# check-resolved.sh — the ai-review-resolved required gate: fails if any PR
# review thread carrying an ai-review Major marker is still unresolved.
#
# Fetches ALL review threads via GraphQL cursor pagination, not just the
# first page: a PR with more than 100 threads is not unusual once ordinary
# human discussion is counted, and failing closed on page count alone (an
# earlier version of this script did) would block merge on any busy PR
# regardless of whether an actual unresolved Major finding exists.
#
# Env:
#   GH_TOKEN   required; a token with pull-requests: read.
#   OWNER      required; repo owner login.
#   REPO_NAME  required; repo name.
#   PR_NUMBER  required; the pull request number.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
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
  # shellcheck disable=SC2016  # single-quoted deliberately: $owner/$repo/$pr/$after
  # are GraphQL variable syntax here, not shell expansions.
  page="$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$after:String) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { isResolved comments(first: 1) { nodes { body } } }
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

open_majors="$(jq '[.[] | select(.isResolved == false) | select(.comments.nodes[0].body // "" | test("<!-- ai-review-severity:Major -->"))] | length' "$all_nodes")"

if [ "$open_majors" -gt 0 ]; then
  echo "::error::$open_majors unresolved Major ai-review finding(s). Resolve each thread on the PR before merging."
  exit 1
fi
echo "ai-review-resolved: no unresolved Major findings."
