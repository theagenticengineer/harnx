#!/usr/bin/env bash
echo 'SABOTAGE-POSTER-RAN' >&2
# post-findings.sh — posts each ai-review finding as its own resolvable PR
# review-comment thread, deduped by a stable marker so a re-run never
# double-posts, updates the comment if the same finding's reported severity
# changed, and reopens a thread whose finding recurred after a human
# resolved it (a regression).
#
# The dedup KEY marker and the SEVERITY marker are separate HTML comments,
# not one combined string: severity is real content that can change between
# runs of the same underlying finding (the model re-assesses it), and if it
# were baked into the dedup key, a severity change would look like a brand
# new finding instead of an update to the existing thread, letting
# duplicates accumulate for what is really one finding.
#
# A finding that cannot be posted (e.g. its line is not part of this PR's
# diff hunk) is retried once anchored at line 1 of the same file rather than
# dropped; if that also fails, the script exits non-zero so the required
# ai-review job goes red instead of silently completing with a finding that
# was never tracked as a resolvable thread.
#
# Env:
#   GH_TOKEN   required; a token with pull-requests: write.
#   OWNER      required; repo owner login.
#   REPO_NAME  required; repo name.
#   PR_NUMBER  required; the pull request number.
#   HEAD_SHA   required; the PR head commit SHA (comments anchor to it).
#   FINDINGS   required; path to the findings JSON array
#              ({file, line, title, severity}).
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${FINDINGS:?FINDINGS is required}"
export GH_TOKEN

# Fetches ALL review threads via GraphQL cursor pagination, not just the
# first page: a dedup/reopen lookup that missed a thread past page 1 would
# post a duplicate comment for a finding that was already tracked.
all_thread_nodes="$(mktemp)"
printf '[]' >"$all_thread_nodes"
# -F sends the first request's literal "null" as GraphQL null; every later
# iteration uses -f (raw string, no type coercion) instead, since -F would
# coerce a purely-numeric cursor into a JSON number and a String! argument
# would reject it. See check-resolved.sh for the same pattern.
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
            nodes { id isResolved comments(first: 1) { nodes { databaseId body } } }
          }
        }
      }
    }' -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" "${after_field[@]}" \
    -q '.data.repository.pullRequest.reviewThreads')"

  merged="$(mktemp)"
  jq -s '.[0] + .[1].nodes' "$all_thread_nodes" <(printf '%s' "$page") >"$merged"
  mv "$merged" "$all_thread_nodes"

  [ "$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage')" = "true" ] || break
  cursor="$(printf '%s' "$page" | jq -r '.pageInfo.endCursor')"
done
threads="$(cat "$all_thread_nodes")"
rm -f "$all_thread_nodes"

reopen_thread() {
  local id="$1"
  # shellcheck disable=SC2016  # $id is a GraphQL variable here, not shell.
  gh api graphql -f query='
    mutation($id:ID!) { unresolveReviewThread(input:{threadId:$id}) { thread { id } } }
    ' -f id="$id" >/dev/null
}

update_comment() {
  local comment_id="$1" body="$2"
  gh api -X PATCH "repos/$OWNER/$REPO_NAME/pulls/comments/$comment_id" \
    -f body="$body" >/dev/null
}

# Findings are worded by an LLM, so trivial formatting differences (case,
# punctuation, whitespace) are not guaranteed stable across re-runs of the
# same underlying issue. Normalizing tolerates that. Deliberately NOT
# truncated to a fixed word count: an earlier version cut to the first 8
# words, which let two genuinely DIFFERENT findings that happened to share
# an opening phrase collapse onto the same key, causing the second one to be
# silently skipped as "already tracked" instead of posted. The full
# normalized title is used instead, so an accidental collision between two
# real, distinct findings would require them to be byte-identical after
# normalization, not just similarly worded.
normalize_title() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:] ' ' ' | tr -s ' '
}

# Tries the reported line first; GitHub rejects an anchor outside the PR's
# diff hunk, so on failure this retries once at line 1 of the same file
# rather than dropping the finding. Returns non-zero only if both attempts
# fail.
post_comment() {
  local file="$1" line="$2" body="$3"
  if gh api "repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" \
    -f body="$body" -f commit_id="$HEAD_SHA" -f path="$file" -F line="$line" -f side=RIGHT \
    >/dev/null 2>&1; then
    return 0
  fi
  if [ "$line" != 1 ]; then
    local fallback_body="$body

(originally reported at line $line; anchored here because that line is not part of this PR's diff)"
    if gh api "repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" \
      -f body="$fallback_body" -f commit_id="$HEAD_SHA" -f path="$file" -F line=1 -f side=RIGHT \
      >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# Process substitution, not a pipe: a `cmd | while read; do ...; done` runs
# the loop in a subshell, and `failed` set inside it would be lost the moment
# the pipeline exits, silently discarding every posting failure it was
# supposed to surface.
failed=0
# Keys already handled THIS run, separate from `threads` (fetched once,
# above, before this loop): two structurally-identical findings emitted by
# the model within the same FINDINGS array would otherwise both find no
# match in that stale snapshot and both post, becoming two duplicate
# threads for one underlying finding. Newline-delimited plus grep -Fx,
# matching the dedup style already used against `threads` below, rather
# than an associative array: this script's shebang has to run under
# whatever `bash` is on PATH, including macOS's system bash 3.2, which has
# no `declare -A`.
posted_keys=""
while read -r finding; do
  file="$(printf '%s' "$finding" | jq -r '.file')"
  line="$(printf '%s' "$finding" | jq -r '.line // 1')"
  title="$(printf '%s' "$finding" | jq -r '.title')"
  severity="$(printf '%s' "$finding" | jq -r '.severity')"
  # The title is model-generated text derived from an untrusted PR diff (see
  # the anti-injection framing in review-engine.sh's prompt). Sanitized before it is
  # embedded in the comment body: newlines collapsed to spaces so a title
  # can never inject a new line of its own, and any literal "<!--" broken up
  # so a title can never forge a fake "<!-- ai-review-severity:... -->"
  # marker line that would make check-resolved.sh misclassify this finding.
  title="$(printf '%s' "$title" | tr '\n' ' ' | sed 's/<!--/< !--/g')"
  # Line is deliberately NOT part of the key, only file + normalized title:
  # an unrelated edit earlier in the same file can shift the reported line
  # for the same underlying finding between review runs, and that drift
  # should not be treated as a new finding any more than title wording
  # drift is (see normalize_title above).
  key="$(printf '%s:%s' "$file" "$(normalize_title "$title")" | sha256sum | cut -d' ' -f1)"

  if printf '%s\n' "$posted_keys" | grep -Fxq "$key"; then
    continue
  fi
  posted_keys="$posted_keys
$key"

  key_marker="<!-- ai-review-key:$key -->"
  severity_marker="<!-- ai-review-severity:$severity -->"
  body="$key_marker
$severity_marker
**[$severity]** $title"

  match="$(printf '%s' "$threads" | jq -c --arg m "$key_marker" \
    '[.[] | select(.comments.nodes[0].body // "" | contains($m))][0] // empty')"

  if [ -n "$match" ]; then
    thread_id="$(printf '%s' "$match" | jq -r '.id')"
    resolved="$(printf '%s' "$match" | jq -r '.isResolved')"
    comment_id="$(printf '%s' "$match" | jq -r '.comments.nodes[0].databaseId')"
    old_body="$(printf '%s' "$match" | jq -r '.comments.nodes[0].body')"

    # A failure here must count exactly like a post_comment failure: a
    # tracking action that silently didn't happen (a Major finding left
    # showing a stale severity, or a regressed thread left resolved) is
    # just as much an untracked finding as one that was never posted at
    # all, and must never let the script report success.
    #
    # Compares the WHOLE new body against the old one, not just whether the
    # severity marker changed: the key intentionally tolerates title-wording
    # drift across runs (see normalize_title above), which means a reworded
    # same-severity finding matches the SAME existing thread by key, but
    # checking only the severity marker would then see nothing to update,
    # leaving the visible title text stale on that thread indefinitely even
    # though the underlying finding's wording genuinely changed.
    if [ "$old_body" != "$body" ]; then
      # The severity and/or title text changed since this thread was last
      # posted; update the comment so both check-resolved.sh (which reads
      # the severity marker) and a human reading the thread see the current
      # assessment, not a stale one.
      if ! update_comment "$comment_id" "$body"; then
        echo "::error::could not update comment $comment_id for $file (\"$title\") with its current content." >&2
        failed=1
      fi
    fi
    # Regression: the same finding recurred after a human resolved it. Reopen
    # the existing thread instead of posting a duplicate.
    if [ "$resolved" = "true" ] && ! reopen_thread "$thread_id"; then
      echo "::error::could not reopen thread $thread_id for $file (\"$title\"), which recurred after being resolved." >&2
      failed=1
    fi
    continue
  fi

  if ! post_comment "$file" "$line" "$body"; then
    echo "::error::could not post a comment for $file:$line (\"$title\"); this finding cannot be tracked as a resolvable thread." >&2
    failed=1
  fi
done < <(jq -c '.[]' "$FINDINGS")

if [ "$failed" = 1 ]; then
  echo "::error::one or more ai-review findings could not be posted; failing so this is never silently merged." >&2
  exit 1
fi
