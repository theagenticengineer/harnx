#!/usr/bin/env bash
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
# diff hunk) falls through a three-step anchoring cascade rather than being
# dropped: the reported line, then line 1 of the same file, then the file
# itself. Only if all three fail does the script exit non-zero, so the
# required ai-review job goes red instead of silently completing with a
# finding that was never tracked as a resolvable thread.
#
# Env:
#   GH_TOKEN   required; a token with pull-requests: write.
#   OWNER      required; repo owner login.
#   REPO_NAME  required; repo name.
#   PR_NUMBER  required; the pull request number.
#   HEAD_SHA   required; the PR head commit SHA (comments anchor to it).
#   FINDINGS   required; path to the findings JSON array
#              ({file, line, side, title, severity, reviewer}).
#
# EVERY API BODY IS SENT FROM A FILE, via `gh api --input`, never assembled
# from `-f body=` flags. Two reasons, both of them defects this replaced:
#
#   - ARG_MAX. A finding's body carries model-authored text derived from the
#     pull request's own diff, and argv is a fixed-size buffer. A large enough
#     body made the `gh` invocation fail with "Argument list too long", which
#     this script reports as an unpostable finding, so a big pull request
#     could red the required check for a reason unrelated to its code.
#   - `-F`'s magic conversion. gh's typed flag reads a local FILE when a value
#     begins with `@`, and `line` was passed with it. A JSON payload built by
#     jq has no such behaviour: a value is a value.
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
#
# Its temp files are owned by an EXIT trap, matching the pattern
# check-resolved.sh and
# fetch-review-threads.sh already use. `all_thread_nodes` was removed
# explicitly after the loop, which covers the happy path only: any non-zero
# exit inside the pagination loop (a GraphQL error under `set -e`) left the
# file, and the per-iteration `merged` file, behind in the runner's temp
# directory. `payload` and `err` below join the same trap so one handler owns
# every temp file this script creates.
all_thread_nodes="$(mktemp)"
merged=""
payload="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$all_thread_nodes" "$merged" "$payload" "$err"' EXIT
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
  merged=""

  [ "$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage')" = "true" ] || break
  cursor="$(printf '%s' "$page" | jq -r '.pageInfo.endCursor')"
done
threads="$(cat "$all_thread_nodes")"

reopen_thread() {
  local id="$1"
  # shellcheck disable=SC2016  # $id is a GraphQL variable here, not shell.
  gh api graphql -f query='
    mutation($id:ID!) { unresolveReviewThread(input:{threadId:$id}) { thread { id } } }
    ' -f id="$id" >/dev/null
}

update_comment() {
  local comment_id="$1" body="$2"
  jq -n --arg body "$body" '{body: $body}' >"$payload"
  gh api -X PATCH "repos/$OWNER/$REPO_NAME/pulls/comments/$comment_id" \
    --input "$payload" >/dev/null
}

# The anchoring cascade appends a note to the body when it could not use the
# reported line ("originally reported at line N", "anchored to the file as a
# whole"). That note is not decoration: it is the only record of WHERE the
# finding actually is, for a thread that is displayed somewhere else.
#
# update_comment rewrote the body wholesale from the freshly computed text,
# which has no note in it, so the first re-review of an unchanged fallback
# finding erased it and left a thread anchored at line 1 claiming to be about
# line 1. This lifts the note off the old body and carries it forward.
#
# Matched on the parenthesised sentence the cascade writes, anchored to the
# end of the body, so ordinary text that happens to contain a bracket is not
# mistaken for one.
carry_fallback_note() {
  local old_body="$1"
  printf '%s' "$old_body" | awk '
    /^\((originally reported at line |reported at line )/ { found = NR }
    { lines[NR] = $0 }
    END { if (found) for (i = found; i <= NR; i++) print lines[i] }'
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

# A THREE-STEP anchoring cascade, tried in order and stopping at the first
# one GitHub accepts:
#
#   1. the reported line, side RIGHT;
#   2. line 1 of the same file, which is inside the diff hunk for any file
#      this pull request adds or rewrites wholesale;
#   3. the FILE itself, via subject_type=file with no line and no side.
#      GitHub anchors that to the file as a whole and needs no hunk at all,
#      which is what makes a finding on a line this pull request never
#      touched postable.
#
# Step 3 is not defensive padding; it closes a failure that actually
# happened. A finding already reported at line 1 skips step 2 (retrying the
# identical anchor would only fail identically), so before step 3 existed a
# single rejected attempt made the whole ai-review job red, which in turn
# left the required check red, for one comment nobody could anchor. A
# finding that cannot be attached to a line is a REPORTING problem; it must
# not become a merge block on every pull request that receives one.
#
# Every attempt's stderr is CAPTURED and surfaced under ::error:: rather
# than discarded into /dev/null, which is what the previous version did.
# "That line is not part of the diff", a 403 from a token missing
# pull-requests: write, and a 422 on a stale commit_id are three completely
# different problems with three different fixes, and thrown away they all
# render as the same silent non-zero exit.
#
# SIDE is now carried through instead of being hard-coded to RIGHT. The engine
# emits it (criterion 39), so a finding about a line this pull request DELETES
# anchors to the left half of the diff, where that line still exists. Hard-
# coding RIGHT sent every such finding down the cascade to line 1 or to the
# file as a whole, because the deleted line is not on the right side at all,
# and the reader then had to work out from prose which line was meant.
line_comment() {
  local file="$1" line="$2" side="$3" body="$4"
  jq -n --arg body "$body" --arg commit "$HEAD_SHA" --arg path "$file" \
    --argjson line "$line" --arg side "$side" \
    '{body: $body, commit_id: $commit, path: $path, line: $line, side: $side}' >"$payload"
  gh api -X POST "repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" \
    --input "$payload" >/dev/null 2>"$err"
}

file_comment() {
  local file="$1" body="$2"
  # No line and no side, deliberately: subject_type=file is rejected when
  # either is sent alongside it.
  jq -n --arg body "$body" --arg commit "$HEAD_SHA" --arg path "$file" \
    '{body: $body, commit_id: $commit, path: $path, subject_type: "file"}' >"$payload"
  gh api -X POST "repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" \
    --input "$payload" >/dev/null 2>"$err"
}

post_comment() {
  local file="$1" line="$2" side="$3" body="$4"
  local why

  if line_comment "$file" "$line" "$side" "$body"; then
    return 0
  fi
  why="line $line ($side): $(tr '\n' ' ' <"$err")"

  if [ "$line" != 1 ] || [ "$side" != RIGHT ]; then
    local fallback_body="$body

(originally reported at line $line on the $side side; anchored here because that line is not part of this PR's diff)"
    if line_comment "$file" 1 RIGHT "$fallback_body"; then
      return 0
    fi
    why="$why | line 1: $(tr '\n' ' ' <"$err")"
  fi

  local file_body="$body

(reported at line $line on the $side side; anchored to the file as a whole because that line is not part of this PR's diff)"
  if file_comment "$file" "$file_body"; then
    return 0
  fi
  why="$why | subject_type=file: $(tr '\n' ' ' <"$err")"

  echo "::error::every anchoring attempt for $file failed. $why" >&2
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
  # Defence in depth. review-engine.sh already reduces `line` to a JSON number
  # or null, and `.line // 1` covers null, but this script also runs against
  # findings produced elsewhere (a local ledger, a future second engine), and
  # `line` is the one value spliced into a JSON payload as a NUMBER. A
  # non-integer would make the jq payload build fail and take the whole script
  # down under `set -e`, losing every finding after it.
  case "$line" in
  '' | *[!0-9]*) line=1 ;;
  esac
  # LEFT or RIGHT only. Anything else, including an absent field on findings
  # written before the engine emitted one, is RIGHT: the common case, and the
  # behaviour every existing thread was posted under.
  side="$(printf '%s' "$finding" | jq -r '.side // "RIGHT"')"
  [ "$side" = LEFT ] || side=RIGHT
  title="$(printf '%s' "$finding" | jq -r '.title')"
  # WHITELISTED, not sanitized, and for a stronger reason than `title` is.
  #
  # `severity` is spliced into `<!-- ai-review-severity:$severity -->`, and that
  # marker is what check-resolved.sh reads to decide which threads BLOCK MERGE
  # and what check-dispositions.sh reads to decide which ones need a written
  # disposition. A value carrying a newline could forge a second marker line, so
  # a Major would post carrying `<!-- ai-review-severity:nit -->` and its
  # unresolved thread would stop blocking anything.
  #
  # Sanitizing it the way `title` is sanitized (collapse newlines, break up
  # `<!--`) would leave a mangled string in a field with exactly three legal
  # values, so the whitelist is both simpler and stricter: nothing outside the
  # three can reach the marker at all.
  #
  # Anything else becomes Major, failing closed, matching review-engine.sh's own
  # rule that an unrecognized severity is the most severe rather than the least
  # visible. The engine already normalizes this, so nothing it produces can trip
  # the fallback; the guard is here because this script also runs against
  # findings produced elsewhere, exactly as the `line` guard above is, and
  # criterion 35's union.sh is about to make "produced elsewhere" routine.
  severity="$(printf '%s' "$finding" | jq -r '.severity')"
  case "$severity" in
  Major | Minor | nit) ;;
  *)
    echo "::warning::post-findings.sh: finding for $file carried an unusable severity; treating it as Major." >&2
    severity="Major"
    ;;
  esac
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
  #
  # RESISTANCE TO REPHRASING IS SUPPLIED UPSTREAM, not here, and this is the
  # answer to the obvious objection that a reworded title mints a new key.
  # It does, and no key computable from a finding could avoid it: measured on
  # PR #38, one CODEOWNERS finding arrived across five passes at four
  # different lines, under two different severities, and in five wordings, so
  # line, severity and title all vary and only the file does not. Keying on
  # the file alone would collapse two genuinely distinct findings in one file
  # into one thread and silently drop the second, which is the one thing this
  # script must never do.
  #
  # So the wording is pinned before it reaches here: handled-from-threads.sh
  # sends the OPEN threads' titles to the engine, and review-engine.sh's
  # prompt requires a still-present open finding to be re-reported under its
  # tracked title verbatim. The model is what produces the variance, so the
  # model is where it is removed. This key is then an exact, deterministic
  # idempotence primitive over stable text, which is also what criterion 35's
  # union.sh needs it to be.
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
    # The anchoring note, if this thread was posted through the cascade,
    # carried forward onto the new body so an update cannot erase where the
    # finding actually is.
    note="$(carry_fallback_note "$old_body")"
    new_body="$body"
    if [ -n "$note" ]; then
      new_body="$body

$note"
    fi

    if [ "$old_body" != "$new_body" ]; then
      # The severity and/or title text changed since this thread was last
      # posted; update the comment so both check-resolved.sh (which reads
      # the severity marker) and a human reading the thread see the current
      # assessment, not a stale one.
      if ! update_comment "$comment_id" "$new_body"; then
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

  if ! post_comment "$file" "$line" "$side" "$body"; then
    echo "::error::could not post a comment for $file:$line (\"$title\"); this finding cannot be tracked as a resolvable thread." >&2
    failed=1
  fi
done < <(jq -c '.[]' "$FINDINGS")

if [ "$failed" = 1 ]; then
  echo "::error::one or more ai-review findings could not be posted; failing so this is never silently merged." >&2
  exit 1
fi
