#!/usr/bin/env bash
# check-dispositions.sh — every RESOLVED Major ai-review finding must carry a
# written disposition, and a deferred one must name an issue that actually
# exists and is still open.
#
# WHY THIS GATE EXISTS. Resolving a thread is what clears `ai-review-resolved`,
# so the single action that unblocks a merge is also the action that hides the
# finding. That is an incentive, not an accident: the cheapest way to go green
# is to resolve everything and move on, and nothing afterwards remembers what
# was in those threads. It happened on this repository's own genesis pull
# requests, where ten real findings were triaged, answered, resolved, and would
# have evaporated with the threads had a human not asked where they went.
#
# check-resolved.sh asks "is anything still open?". This asks the question that
# actually protects the backlog: "for everything that was closed, what
# happened to it?".
#
# THE CONTRACT. A reply in the thread must carry one line of exactly this
# shape, case-insensitive on the keyword:
#
#   Disposition: fixed
#   Disposition: refuted
#   Disposition: deferred to #123
#
# Three, because there are exactly three honest things to do with a finding.
# It was fixed. It was wrong, and the reply says why. Or it is real and is not
# being done now, in which case it needs a home, and "a home" means an issue a
# human can find later, not a sentence in a thread nobody will reopen.
#
# A DEFERRAL IS CHECKED IN BOTH DIRECTIONS, and this is the part that does the
# real work:
#
#   comment -> issue   the reply names an explicit issue number, and that issue
#                      exists and is OPEN.
#   issue -> comment   that issue's body links BACK to this exact review
#                      comment, by its `#discussion_r<id>` anchor.
#
# One direction alone is worth little. A reply can name any open issue in the
# repository, so "deferred to #36" proves nothing about whether #36 has any
# idea this finding exists: pointing at a plausible issue is exactly how a
# finding gets buried while looking tracked. Requiring the issue to link back
# means somebody actually wrote the finding down where it will be worked, and
# the two halves cannot drift apart, because deleting the acceptance criterion
# from the issue turns this gate red again.
#
# WHAT IS AND IS NOT VERIFIED, stated plainly so nobody mistakes this for more
# than it is. For `deferred`, both directions above are enforced. For `fixed`
# and `refuted` the marker is taken at its word: no gate can confirm that a fix
# is real or that a refutation is sound. This makes burying a finding a
# deliberate, written lie rather than an omission, which is the most a
# mechanical check can do here.
#
# Scoped to MAJOR findings only. Those are what block merge, so those are what
# a resolution is spent on. Minor and nit threads may be resolved freely.
#
# Env:
#   GH_TOKEN   required; a token with pull-requests: read AND issues: read. The
#              second is not optional: a deferral names a real ISSUE, and the
#              Issues API is not covered by the pull-requests scope.
#   OWNER      required; repo owner login.
#   REPO_NAME  required; repo name.
#   PR_NUMBER  required; the pull request number.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
export GH_TOKEN

# ONE HANDLER OWNS EVERY TEMP FILE THIS SCRIPT CREATES, which is the claim
# criterion 28's fifth repair made for post-findings.sh and which this script
# did not honour. Both pagination loops below build a `merged` file and `mv` it
# into place; a `gh api graphql` failure between those two steps exits under
# `set -e` and left it behind. Declared up front and reset after each move, so
# the trap covers the window and nothing survives a mid-loop failure.
threads="$(mktemp)"
merged=""
trap 'rm -f "$threads" "$merged"' EXIT
printf '[]' >"$threads"

# Every comment in each thread, not just the first: the disposition lives in a
# REPLY, so a first-comment-only read (which is all the other scripts need)
# would find nothing and fail every thread.
cursor=""
while :; do
  if [ -z "$cursor" ]; then
    after_field=(-F after=null)
  else
    after_field=(-f after="$cursor")
  fi
  # shellcheck disable=SC2016  # single-quoted deliberately: GraphQL variables.
  page="$(gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$after:String) {
      repository(owner:$owner, name:$repo) {
        pullRequest(number:$pr) {
          reviewThreads(first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              path
              comments(first: 100) {
                pageInfo { hasNextPage endCursor }
                nodes { databaseId body }
              }
            }
          }
        }
      }
    }' -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" "${after_field[@]}" \
    -q '.data.repository.pullRequest.reviewThreads')"

  merged="$(mktemp)"
  jq -s '.[0] + .[1].nodes' "$threads" <(printf '%s' "$page") >"$merged"
  mv "$merged" "$threads"
  merged=""

  [ "$(printf '%s' "$page" | jq -r '.pageInfo.hasNextPage')" = "true" ] || break
  cursor="$(printf '%s' "$page" | jq -r '.pageInfo.endCursor')"
done

# PER-THREAD COMMENT PAGINATION, and it is the thread level that was capped,
# not the query overall. Threads were already cursor-paginated; their comments
# were not, so a thread was read through a fixed window and everything past it
# was invisible to this gate.
#
# The window used to be 50. This gate reads a thread looking for ONE line, the
# disposition marker, which by construction is written LAST, after the
# discussion that produced it. So the one comment it must not miss is the one
# a cap is most likely to cut. A long argument on a Major finding, ending in
# "Disposition: refuted", read as having no disposition at all, fails the
# required check on a finding that was answered properly. The window is now
# 100 and, more importantly, the remainder is fetched rather than dropped.
#
# One follow-up query per over-long thread, addressed by the thread's node id.
# Threads that fit in the first page (all of them, on any normal pull request)
# cost nothing.
# shellcheck disable=SC2016  # single-quoted deliberately: GraphQL variables.
comment_page_query='
  query($id:ID!,$after:String) {
    node(id: $id) {
      ... on PullRequestReviewThread {
        comments(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { databaseId body }
        }
      }
    }
  }'
while read -r thread_id; do
  [ -n "$thread_id" ] || continue
  ccursor="$(jq -r --arg id "$thread_id" \
    '[.[] | select(.id == $id)][0].comments.pageInfo.endCursor // ""' "$threads")"
  while [ -n "$ccursor" ]; do
    cpage="$(gh api graphql -f query="$comment_page_query" \
      -f id="$thread_id" -f after="$ccursor" -q '.data.node.comments')"
    merged="$(mktemp)"
    jq --arg id "$thread_id" --argjson page "$cpage" \
      'map(if .id == $id
           then .comments.nodes = (.comments.nodes + $page.nodes)
           else . end)' "$threads" >"$merged"
    mv "$merged" "$threads"
    merged=""
    [ "$(printf '%s' "$cpage" | jq -r '.pageInfo.hasNextPage')" = "true" ] || break
    ccursor="$(printf '%s' "$cpage" | jq -r '.pageInfo.endCursor')"
  done
done < <(jq -r '.[] | select(.comments.pageInfo.hasNextPage == true) | .id' "$threads")

# One record per resolved Major thread: its file, its title, and every reply
# body joined, so the marker can be looked for across all of them.
#
# The title is taken from the "**[Major]** ..." line post-findings.sh writes,
# the same parse handled-from-threads.sh performs, so an operator reading a
# failure sees the finding rather than a thread id.
records="$(jq -c '
  def title_of:
    split("\n")
    | map(select(test("^\\*\\*\\[[^]]*\\]\\*\\* .")))
    | (.[0] // "")
    | sub("^\\*\\*\\[[^]]*\\]\\*\\* "; "");
  [ .[]
    | select(.isResolved == true)
    | select(.comments.nodes[0].body // "" | test("<!-- ai-review-severity:Major -->"))
    | { file: (.path // "?"),
        title: (.comments.nodes[0].body // "" | title_of),
        anchor: (.comments.nodes[0].databaseId // 0),
        replies: ([.comments.nodes[1:][]?.body] | join("\n")) }
  ]' "$threads")"

total="$(printf '%s' "$records" | jq 'length')"
if [ "$total" -eq 0 ]; then
  echo "check-dispositions: no resolved Major findings on this pull request."
  exit 0
fi

# HOW MUCH TEXT COUNTS AS "written down". The back-link check used to be
# satisfied by the anchor appearing ANYWHERE in the issue body, so pasting the
# URL into any open issue turned the gate green while recording nothing about
# what the finding was or what would be done. That passes the check and defeats
# the reason the check exists.
#
# So the anchor has to arrive with the finding. Measured over the BLOCK that
# contains it, meaning the run of non-blank lines around it, which is the unit
# a Markdown list item or paragraph occupies. A block, not a line, because a
# real acceptance criterion often puts the prose on one line and the citation
# on the next, and that is a correct deferral, not a bare paste.
#
# URLs are removed before counting, so the link's own path segments cannot
# masquerade as the description of the work.
min_context_words=12

anchor_context_words() {
  local body="$1" anchor="$2"
  # Same bounded match as the check above, for the same reason: a block that
  # only mentions discussion_r9990 must not be counted as context for anchor
  # 999. `$` inside this dynamically-built pattern anchors to the end of the
  # BLOCK being tested, which is what is wanted, since a citation at the very
  # end of a paragraph carries no trailing character.
  printf '%s\n' "$body" | tr -d '\r' | awk -v anchor="discussion_r$anchor([^0-9]|\$)" '
    function flush() {
      if (block != "" && block ~ anchor) {
        text = block
        gsub(/https?:\/\/[^ \t]*/, " ", text)
        gsub(/#discussion_r[0-9]+/, " ", text)
        gsub(/[^A-Za-z0-9]+/, " ", text)
        n = split(text, words, " ")
        count = 0
        for (i = 1; i <= n; i++) if (words[i] != "") count++
        if (count > best) best = count
      }
      block = ""
    }
    /^[[:space:]]*$/ { flush(); next }
    { block = block " " $0 }
    END { flush(); print best + 0 }'
}

fail=0
deferred=0
while read -r rec; do
  [ -n "$rec" ] || continue
  file="$(printf '%s' "$rec" | jq -r '.file')"
  title="$(printf '%s' "$rec" | jq -r '.title')"
  anchor="$(printf '%s' "$rec" | jq -r '.anchor')"
  replies="$(printf '%s' "$rec" | jq -r '.replies')"

  # grep -io, not a bash regex: the marker may sit anywhere in a multi-line
  # reply, and only the matched keyword is wanted, not the whole line.
  # tail -n1, not head: the LAST disposition in the thread wins. Replies are
  # joined chronologically, so taking the first would let a superseded
  # disposition outrank the correction that replaced it. A finding deferred and
  # then actually fixed, or fixed and then found to need deferring after all,
  # must be judged on where it ended up, not where it started.
  marker="$(printf '%s' "$replies" |
    grep -ioE 'Disposition:[[:space:]]*(fixed|refuted|deferred to #[0-9]+)' | tail -n1 || true)"

  if [ -z "$marker" ]; then
    echo "::error::resolved Major finding has no disposition: $file (\"$title\"). Reply in the thread with one of: 'Disposition: fixed', 'Disposition: refuted', or 'Disposition: deferred to #<issue>'." >&2
    fail=1
    continue
  fi

  case "$(printf '%s' "$marker" | tr '[:upper:]' '[:lower:]')" in
  *deferred*)
    deferred=$((deferred + 1))
    issue="$(printf '%s' "$marker" | grep -oE '[0-9]+$')"
    # The whole point of the gate: a deferred finding must have somewhere to
    # live. An issue that does not exist, or that is already closed, is not
    # somewhere to live.
    # stderr is CAPTURED rather than discarded. A 403 (the token lacking
    # `issues: read`) and a 404 (the issue genuinely not existing) both leave
    # `state` empty, and reporting a permission problem as "that issue does not
    # exist" sends whoever reads the failure looking in exactly the wrong
    # place.
    err="$(mktemp)"
    payload="$(gh api "repos/$OWNER/$REPO_NAME/issues/$issue" 2>"$err" || true)"
    state="$(printf '%s' "$payload" | jq -r '.state // empty' 2>/dev/null || true)"
    if [ -z "$state" ] && grep -qiE '403|forbidden|not accessible|permission' "$err"; then
      echo "::error::could not read #$issue to verify the deferral of $file (\"$title\"): the token lacks access to the Issues API. The job needs the issues: read permission. This is a pipeline misconfiguration, not a problem with the deferral." >&2
      rm -f "$err"
      fail=1
    elif [ -z "$state" ]; then
      rm -f "$err"
      echo "::error::$file (\"$title\") is deferred to #$issue, which does not exist in $OWNER/$REPO_NAME." >&2
      fail=1
    elif rm -f "$err" && [ "$state" != "open" ]; then
      echo "::error::$file (\"$title\") is deferred to #$issue, which is $state. A deferred finding needs an OPEN issue to live in, or it is buried." >&2
      fail=1
    else
      # The second direction, and the one that does the real work. The issue
      # must reference THIS comment by its own anchor, which is what proves
      # the finding was written down where it will be worked rather than
      # pointed at a plausible-looking issue. Matched as a substring so any
      # form of the link works: the bare "#discussion_rN" fragment, or a full
      # URL ending in it.
      body="$(printf '%s' "$payload" | jq -r '.body // ""' 2>/dev/null || true)"
      # BOUNDED, not a bare substring. `discussion_r999` is a prefix of
      # `discussion_r9990`, so an unanchored match let an issue citing a
      # COMPLETELY DIFFERENT comment satisfy this finding's back-link. The
      # anchor is a databaseId, so ids that are prefixes of other ids are
      # ordinary rather than contrived. Requiring a non-digit (or the end of
      # the body) after it makes the match mean the id it names.
      if ! printf '%s' "$body" | grep -qE "discussion_r${anchor}([^0-9]|\$)"; then
        echo "::error::$file (\"$title\") is deferred to #$issue, but #$issue never mentions this finding. Add an acceptance criterion there citing https://github.com/$OWNER/$REPO_NAME/pull/$PR_NUMBER#discussion_r${anchor} , so the deferral points at somewhere the work is actually recorded." >&2
        fail=1
      elif [ "$(anchor_context_words "$body" "$anchor")" -lt "$min_context_words" ]; then
        # THE ANCHOR ALONE IS NOT THE WORK. See anchor_context_words above.
        echo "::error::$file (\"$title\") is deferred to #$issue, and #$issue carries the link but not the finding: the block containing discussion_r${anchor} has fewer than $min_context_words words of its own. Write the finding down there, in the issue's own words, next to the link. A pasted anchor records where a finding was raised, not what has to be done about it." >&2
        fail=1
      fi
    fi
    ;;
  esac
done < <(printf '%s' "$records" | jq -c '.[]')

if [ "$fail" -ne 0 ]; then
  echo "::error::one or more resolved Major findings are not accounted for. Resolving a thread is what clears the merge gate, so it must not also be what hides the finding." >&2
  exit 1
fi

echo "check-dispositions: $total resolved Major finding(s) accounted for ($deferred deferred to an open issue)."
