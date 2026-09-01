#!/usr/bin/env bash
# post-ci-status.sh — maintains ONE pull-request comment reporting the state
# of the CI AI review: this pass's findings by severity, how many Major
# threads are open versus resolved, and the gate verdict.
#
# Upserted, never appended: the comment is found by a hidden marker and
# PATCHed in place, created only when absent. The same marker idiom
# post-findings.sh uses for threads, for the same reason: a review that posts
# a fresh status comment per push buries the PR under a running commentary
# nobody reads, and leaves several contradictory "current" states visible at
# once.
#
# The convergence table mirrors the local runner's
# (scripts/mise/ai-review-local.sh): one row per pass, so a trend is visible
# without cross-referencing past workflow logs, which expire. Its per-pass
# history lives in a hidden JSON payload inside the comment body itself,
# because CI has no persistent scratch space between runs and the local
# runner's .harnx/ai-review-pass-log.jsonl is a gitignored, local-only file
# by design. That history is display-only: it feeds no gate, so a
# hand-edited or missing payload costs a row in a table and nothing else.
#
# Unlike the local table, severity cells are plain counts, not
# accepted/raw pairs: locally, "raw" is what the model reported and
# "accepted" is what survives ledger filtering, whereas a CI pass's findings
# have already been filtered upstream (the model receives the resolved
# threads as HANDLED memory, see handled-from-threads.sh), so the two numbers
# would always be equal here.
#
# Runs in the post-findings job, which already holds the write-scoped App
# token, and AFTER post-findings.sh, so the thread counts and verdict below
# include the threads this pass just posted and match what the
# ai-review-resolved gate will independently compute.
#
# Env:
#   GH_TOKEN        required; a token with pull-requests: write.
#   OWNER           required; repo owner login.
#   REPO_NAME       required; repo name.
#   PR_NUMBER       required; the pull request number.
#   FINDINGS        required; path to this pass's findings JSON array
#                   ({file, line, side, title, severity, reviewer}).
#   APP_LOGIN       required; the login the review App comments under, e.g.
#                   "harnx-ai-review[bot]". See the author filter below: the
#                   marker alone is not proof of authorship.
#   HEAD_SHA        optional; the reviewed head commit SHA.
#   REVIEW_SECONDS  optional; how long the engine took, in seconds.
#   RUN_URL         optional; link to this workflow run.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${FINDINGS:?FINDINGS is required}"
: "${APP_LOGIN:?APP_LOGIN is required}"
export GH_TOKEN

marker="<!-- ai-review-ci-status -->"
log_marker="<!-- ai-review-ci-log:"
# Rows rendered, newest passes last. The hidden payload keeps every pass; only
# the rendered table is capped, so a long-running PR cannot grow the comment
# past GitHub's body-size limit.
max_rows=15

if ! jq -e 'type == "array"' "$FINDINGS" >/dev/null 2>&1; then
  echo "::error::post-ci-status.sh: $FINDINGS is not a JSON findings array; refusing to report a review state derived from it." >&2
  exit 1
fi
majors="$(jq '[.[] | select(.severity == "Major")] | length' "$FINDINGS")"
minors="$(jq '[.[] | select(.severity == "Minor")] | length' "$FINDINGS")"
nits="$(jq '[.[] | select(.severity == "nit")] | length' "$FINDINGS")"

# REVIEW_SECONDS crosses a trust boundary: it is produced by the job that
# executes the PR's own review engine, reaches this job as artifact content,
# and is interpolated into a comment body here. Digits only, or dropped: a
# strict whitelist, not an escape attempt, since the only legitimate value is
# a small integer.
seconds="${REVIEW_SECONDS:-}"
case "$seconds" in
'' | *[!0-9]*) seconds="" ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
threads="$(mktemp)"
trap 'rm -f "$threads"' EXIT
THREADS_OUTPUT="$threads" bash "$script_dir/fetch-review-threads.sh"

# Reads the SAME severity marker check-resolved.sh gates on, so the verdict
# printed here cannot drift from the verdict that actually blocks merge.
major_open="$(jq '[.[] | select(.isResolved == false) | select(.comments.nodes[0].body // "" | test("<!-- ai-review-severity:Major -->"))] | length' "$threads")"
major_resolved="$(jq '[.[] | select(.isResolved == true) | select(.comments.nodes[0].body // "" | test("<!-- ai-review-severity:Major -->"))] | length' "$threads")"

# Every issue comment on the PR, cursor-paginated: gh api --paginate emits one
# JSON array per page, and `jq -s add` folds them into a single array (an
# empty result set yields no pages at all, hence `// []`). Missing the
# existing status comment on a busy PR would post a second one, exactly the
# duplication this script exists to avoid.
comments="$(mktemp)"
trap 'rm -f "$threads" "$comments"' EXIT
gh api --paginate "repos/$OWNER/$REPO_NAME/issues/$PR_NUMBER/comments" |
  jq -s 'add // []' >"$comments"
# TWO conditions, the marker AND the author, not the marker alone.
#
# The marker is a plain HTML comment in a public pull request body, so the
# pull request's author can read it and write it. Matching on it alone meant
# the first comment carrying that string won, and a contributor who pre-posts
# a comment containing it before the pipeline's first pass owns the canonical
# status comment from then on: every later pass PATCHes THEIRS, under the
# review App's write-scoped token, and the review's own verdict is published
# inside text somebody else controls. The pass history rides in the same body,
# so they can rewrite that too.
#
# The author is not forgeable: `user.login` is GitHub's own record of who
# created the comment, and only the App's token can create one under the App's
# login. So the marker still says WHICH comment this is, and the author says
# whether the pipeline is allowed to treat it as its own. A marker-carrying
# comment by anybody else is ignored, and the pipeline creates and maintains
# its own alongside it.
existing="$(jq -c --arg m "$marker" --arg login "$APP_LOGIN" \
  '[.[] | select((.body // "") | contains($m)) | select((.user.login // "") == $login)][0] // empty' "$comments")"

prev_log='[]'
existing_id=""
if [ -n "$existing" ]; then
  existing_id="$(printf '%s' "$existing" | jq -r '.id')"
  # tr -d '\r' first: a body that has been through a client that normalizes
  # line endings would otherwise leave a stray carriage return inside the
  # extracted JSON, making it unparseable for no interesting reason.
  log_line="$(printf '%s' "$existing" | jq -r '.body // ""' | tr -d '\r' |
    grep -m1 -F "$log_marker" || true)"
  if [ -n "$log_line" ]; then
    candidate="${log_line#*"$log_marker"}"
    candidate="${candidate%% -->*}"
    if printf '%s' "$candidate" | jq -e 'type == "array"' >/dev/null 2>&1; then
      prev_log="$candidate"
    else
      # Display-only history: a corrupt payload restarts the table rather
      # than failing the run, the opposite of review-engine.sh's handling of
      # corrupt HANDLED memory. Nothing here gates anything, so the
      # fail-loudly reasoning that applies to review memory does not apply.
      echo "post-ci-status.sh: WARNING: the status comment's pass history is not a JSON array; restarting it." >&2
    fi
  fi
fi

pass="$(($(printf '%s' "$prev_log" | jq 'length') + 1))"
new_log="$(printf '%s' "$prev_log" | jq -c \
  --argjson pass "$pass" --argjson major "$majors" \
  --argjson minor "$minors" --argjson nit "$nits" \
  --arg seconds "$seconds" \
  '. + [{pass: $pass, runner: "CI", major: $major, minor: $minor, nit: $nit,
         seconds: (if $seconds == "" then null else ($seconds | tonumber) end)}]')"

rows="$(printf '%s' "$new_log" | jq -r --argjson max "$max_rows" '
  (if (length > $max) then .[-$max:] else . end)
  | .[]
  | "| #\(.pass) | \(.runner) | \(.major) | \(.minor) | \(.nit) | " +
    (if (.seconds | type) == "number" then "\(.seconds)s" else "n/a" end) + " |"')"
# Rendered as a bullet in the summary list below, not as a bare line under
# the table: a paragraph wedged between the table and the list is one blank
# line away from being parsed as part of either.
truncated=""
if [ "$pass" -gt "$max_rows" ]; then
  truncated="- Showing the most recent $max_rows of $pass passes.
"
fi

if [ "$major_open" -gt 0 ]; then
  verdict="BLOCKED: $major_open unresolved Major finding(s). Resolve each thread on this PR, or push a fix, before merging."
else
  verdict="PASS: no unresolved Major finding."
fi

context=""
[ -n "${HEAD_SHA:-}" ] && context="
- Reviewed head: \`${HEAD_SHA}\`"
[ -n "${RUN_URL:-}" ] && context="$context
- Workflow run: ${RUN_URL}"

body="$marker
${log_marker}${new_log} -->
### AI review (CI)

| Pass | Runner | Major | Minor | Nit | Review Time |
|---|---|---|---|---|---|
$rows

$truncated- This pass reported: $majors Major, $minors Minor, $nits nit.
- Major threads on this PR: $major_open open, $major_resolved resolved.
- \`ai-review-resolved\` gate: $verdict$context

Each finding is its own resolvable review thread; this comment is updated in
place on every pass, never re-posted."

if [ -n "$existing_id" ]; then
  gh api -X PATCH "repos/$OWNER/$REPO_NAME/issues/comments/$existing_id" \
    -f body="$body" >/dev/null
  echo "post-ci-status.sh: updated status comment $existing_id (pass #$pass)."
else
  gh api "repos/$OWNER/$REPO_NAME/issues/$PR_NUMBER/comments" \
    -f body="$body" >/dev/null
  echo "post-ci-status.sh: created the status comment (pass #$pass)."
fi
