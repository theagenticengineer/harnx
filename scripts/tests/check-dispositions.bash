#!/usr/bin/env bash
# Standalone test for scripts/ai-review/check-dispositions.sh.
# Run: bash scripts/tests/check-dispositions.bash
#
# The gate this covers exists because resolving a thread is what clears
# `ai-review-resolved`, so the action that unblocks a merge is also the action
# that hides the finding. These cases pin the three honest dispositions and,
# more importantly, the one that can actually be verified: a deferred finding
# must name an issue that exists and is still open.
#
# `gh` is stubbed. Both calls the script makes are stubbed from one file: the
# GraphQL thread fetch and the issue-state lookup.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/ai-review/check-dispositions.sh"

stub_dir="$(mktemp -d)"
out="$(mktemp)"
trap 'rm -rf "$stub_dir" "$out"' EXIT

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# GH_STUB_THREADS holds the reviewThreads payload; GH_STUB_ISSUE_STATE holds
# the state returned for any issue lookup (empty means "does not exist").
case "$*" in
  # The per-thread comment page, matched FIRST because it is also a graphql
  # call. The script asks for it only when a thread reported
  # comments.pageInfo.hasNextPage, so a stub that never sets
  # GH_STUB_COMMENT_PAGE also never reaches this branch.
  *PullRequestReviewThread*)
    printf '%s' "${GH_STUB_COMMENT_PAGE:-}"
    ;;
  *graphql*)
    printf '%s' "${GH_STUB_THREADS}"
    ;;
  *issues/*)
    # GH_STUB_ISSUE_403 makes the stub fail the way a token without
    # `issues: read` does: non-zero exit with a 403 on stderr and nothing on
    # stdout. The gate must name that as a permission problem, not report the
    # issue as missing.
    if [ -n "${GH_STUB_ISSUE_403:-}" ]; then
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2
      exit 1
    fi
    # A whole issue payload now: the gate reads .state AND .body, because a
    # deferral is checked in both directions.
    [ -n "${GH_STUB_ISSUE_STATE:-}" ] || exit 1
    jq -cn --arg s "$GH_STUB_ISSUE_STATE" --arg b "${GH_STUB_ISSUE_BODY:-}" \
      '{state: $s, body: $b}'
    ;;
esac
STUB
chmod +x "$stub_dir/gh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Builds a one-thread payload: $1 resolved, $2 severity, $3 reply body.
threads_json() {
  jq -cn --arg sev "$2" --arg reply "$3" --argjson resolved "$1" '
    { pageInfo: { hasNextPage: false, endCursor: null },
      nodes: [ { isResolved: $resolved, path: "a.sh",
                 comments: { nodes: [
                   { databaseId: 4242,
                     body: "<!-- ai-review-key:abc -->\n<!-- ai-review-severity:\($sev) -->\n**[\($sev)]** a finding" },
                   { body: $reply } ] } } ] }'
}

check() {
  local label="$1" expect="$2" payload="$3" issue_state="${4:-}" issue_body="${5:-}"
  local status
  set +e
  (cd "$stub_dir" && env PATH="$stub_dir:$PATH" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
    GH_STUB_THREADS="$payload" GH_STUB_ISSUE_STATE="$issue_state" \
    GH_STUB_ISSUE_BODY="$issue_body" \
    GH_STUB_COMMENT_PAGE="${COMMENT_PAGE:-}" \
    bash "$hook") >"$out" 2>&1
  status=$?
  set -e
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected exit $expect, got $status: $(cat "$out")"
  fi
}

# --- the three honest dispositions --------------------------------------------
check "fixed-accepted" 0 "$(threads_json true Major 'Disposition: fixed')"
check "refuted-accepted" 0 "$(threads_json true Major 'Disposition: refuted')"
check "deferred-to-open-issue-that-links-back-accepted" 0 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] **12.** The CODEOWNERS header claims a systematically derived list and does not have one; rewrite the claim or the list. Raised at https://github.com/o/r/pull/1#discussion_r4242'
# The bare anchor fragment is enough; a full URL is not required. What is
# required is the finding alongside it.
check "deferred-back-link-as-bare-fragment-accepted" 0 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] Bound the review diff before it reaches the engine, so an oversized pull request degrades predictably instead of silently truncating. Tracked at #discussion_r4242'

# --- a link is not the work ---------------------------------------------------
# The back-link check used to be satisfied by the anchor appearing anywhere in
# the body, so pasting the URL into any open issue turned the gate green while
# recording nothing about the finding. That passes the check and defeats the
# reason the check exists.
check "deferred-back-link-pasted-bare-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  'https://github.com/o/r/pull/1#discussion_r4242'
check "deferred-back-link-with-a-couple-of-words-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- see #discussion_r4242'
# The link's own path segments must not count as the description: strip the URL
# before counting, or a long enough URL satisfies the rule by itself.
check "deferred-back-link-long-url-alone-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  'https://github.com/some/very/long/path/with/many/segments/that/looks/wordy/o/r/pull/1#discussion_r4242'
# The criterion's prose and its citation on separate lines of one list item is
# a correct deferral, not a bare paste, so the count is taken over the BLOCK.
check "deferred-back-link-across-two-lines-of-one-block-accepted" 0 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] Paginate the per-thread comment read so a disposition past the window is not read as absent.
  Raised at https://github.com/o/r/pull/1#discussion_r4242'

# --- the second direction: the issue must actually mention this finding -------
# Naming any open issue proves nothing. Pointing at a plausible-looking issue
# that has no idea the finding exists is precisely how something gets buried
# while looking tracked, so the issue has to link back.
check "deferred-to-issue-that-never-mentions-it-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] some unrelated acceptance criterion'
check "deferred-to-issue-linking-a-DIFFERENT-comment-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] carried over from https://github.com/o/r/pull/1#discussion_r9999'
# The body argument is a single pair of quotes, an actually empty string. It
# used to be written ''"''", which shell quoting concatenates into the
# two-character string '', so the case exercised a body containing two
# apostrophes rather than the empty body its name claims.
check "deferred-to-issue-with-empty-body-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open ''

# --- the case the gate exists for ---------------------------------------------
# A resolved Major with a thoughtful reply that never says what happened to it
# is exactly how ten real findings nearly evaporated from this repository.
check "resolved-with-no-disposition-fails" 1 \
  "$(threads_json true Major 'Good catch, I looked at this and it is interesting.')"
check "resolved-with-no-reply-at-all-fails" 1 \
  "$(jq -cn '{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{isResolved:true,path:"a.sh",comments:{nodes:[{body:"<!-- ai-review-severity:Major -->\n**[Major]** a finding"}]}}]}')"

# --- deferral must have somewhere real to live --------------------------------
check "deferred-to-closed-issue-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" closed \
  '- [ ] Bound the review diff before it reaches the engine, so an oversized pull request degrades predictably. Carried over from #discussion_r4242'
check "deferred-to-missing-issue-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #99999')" ""

# --- scope: only resolved Majors are governed ---------------------------------
# An UNRESOLVED Major is check-resolved.sh's business, not this gate's; failing
# it here too would report the same finding twice under two different names.
check "unresolved-major-is-not-this-gates-business" 0 \
  "$(threads_json false Major 'no disposition here')"
# Minor and nit threads may be resolved freely: a resolution is only spent on
# something that was blocking.
check "resolved-minor-needs-no-disposition" 0 \
  "$(threads_json true Minor 'no disposition here')"
check "resolved-nit-needs-no-disposition" 0 \
  "$(threads_json true nit 'no disposition here')"

# --- the marker is found wherever it sits -------------------------------------
check "marker-mid-reply-accepted" 0 \
  "$(threads_json true Major 'I looked into this at length.

Disposition: fixed

The change is in the commit above.')"
check "marker-case-insensitive" 0 "$(threads_json true Major 'disposition: FIXED')"
# A near-miss must not pass: prose about deferring is not a disposition.
check "prose-about-deferring-is-not-a-disposition" 1 \
  "$(threads_json true Major 'I am deferring this to a later issue, probably #36.')"

# --- a permission failure is not a missing issue ------------------------------
# Both leave the state empty at the call site, and reporting a 403 as "that
# issue does not exist" sends whoever reads the failure looking in exactly the
# wrong place.
check_403() {
  local status
  set +e
  (cd "$stub_dir" && env PATH="$stub_dir:$PATH" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
    GH_STUB_THREADS="$(threads_json true Major 'Disposition: deferred to #36')" \
    GH_STUB_ISSUE_403=1 \
    bash "$hook") >"$out" 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 1 ]] && grep -q 'issues: read permission' "$out"; then
    pass=$((pass + 1))
  else
    fail_case "403-reported-as-permission-problem: expected exit 1 naming 'issues: read', got $status: $(cat "$out")"
  fi
}
check_403

# --- the LAST disposition wins, not the first ---------------------------------
# Replies are joined chronologically. Taking the first would let a superseded
# disposition outrank the correction that replaced it, so a finding deferred
# and then actually fixed would still be judged on the deferral, and one whose
# fix was later withdrawn would still read as fixed.
check "last-disposition-wins-fixed-supersedes-deferred" 0 \
  "$(threads_json true Major 'Disposition: deferred to #36

On reflection this was cheap enough to do now.

Disposition: fixed')"
# The same ordering in the other direction: a fix withdrawn in favour of a
# deferral must be judged as deferred, which means the issue is verified.
check "last-disposition-wins-deferred-supersedes-fixed" 1 \
  "$(threads_json true Major 'Disposition: fixed

That fix was wrong and has been reverted.

Disposition: deferred to #36')" open '- [ ] unrelated criterion'

# --- a deferral MUST name the issue number ------------------------------------
# The issue number is the whole mechanism: "deferred" without one is a promise
# to nobody, and it is exactly what the gate exists to reject. These must fail
# as "no disposition", because a bare `deferred` does not match the contract at
# all.
check "deferred-with-no-issue-number-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred')"
check "deferred-to-a-name-not-a-number-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to the next increment')"
check "deferred-to-a-bare-number-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to 36')"

# --- a pull request with nothing resolved is not a failure --------------------
check "no-resolved-majors-passes" 0 \
  "$(jq -cn '{pageInfo:{hasNextPage:false,endCursor:null},nodes:[]}')"

# --- the back-link names THIS comment, not one whose id starts the same -------
# `discussion_r4242` is a prefix of `discussion_r42421`, and both are ordinary
# databaseIds. An unanchored substring match let an issue citing a completely
# different comment satisfy this finding's back-link, which is the same class of
# defect as pointing at a plausible-looking issue: it looks tracked and is not.
check "deferred-back-link-to-a-longer-id-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] Bound the review diff before it reaches the engine, so an oversized pull request degrades predictably. Raised at https://github.com/o/r/pull/1#discussion_r42421'
# A leading-digit difference was never the problem, so this must still fail for
# the ordinary reason rather than accidentally passing the new bound.
check "deferred-back-link-to-an-unrelated-id-fails" 1 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] Bound the review diff before it reaches the engine, so an oversized pull request degrades predictably. Raised at https://github.com/o/r/pull/1#discussion_r1234'
# The exact id, followed by end-of-line, is the common shape and must pass.
check "deferred-back-link-at-end-of-line-accepted" 0 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] Bound the review diff before it reaches the engine, so an oversized pull request degrades predictably, raised at #discussion_r4242'
# And followed by punctuation, which is how a sentence usually ends.
check "deferred-back-link-followed-by-punctuation-accepted" 0 \
  "$(threads_json true Major 'Disposition: deferred to #36')" open \
  '- [ ] Bound the review diff before it reaches the engine so an oversized pull request degrades predictably (#discussion_r4242), rather than truncating.'

# --- the disposition sits past the first page of comments ---------------------
# The comment read used to be capped, so a thread longer than the window was
# read through a fixed slice and everything after it was invisible. The
# disposition marker is written LAST, after the discussion that produced it, so
# the comment a cap is most likely to cut is the exact one this gate needs. A
# long argument ending in "Disposition: refuted" read as having no disposition
# reddens the required check on a finding that was answered properly.
capped_thread="$(jq -cn '
  { pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [ { id: "PRRT_1", isResolved: true, path: "a.sh",
               comments: {
                 pageInfo: { hasNextPage: true, endCursor: "CURSOR1" },
                 nodes: [
                   { databaseId: 4242,
                     body: "<!-- ai-review-key:abc -->\n<!-- ai-review-severity:Major -->\n**[Major]** a finding" },
                   { body: "a long argument that never says what happened" } ] } } ] }')"

COMMENT_PAGE="$(jq -cn '
  { pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [ { body: "Disposition: refuted" } ] }')" \
  check "disposition-past-the-first-comment-page-is-found" 0 "$capped_thread"

# The same thread WITHOUT the follow-up page must fail, which is what proves
# the case above passes because of the pagination rather than in spite of it.
COMMENT_PAGE="$(jq -cn '
  { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] }')" \
  check "a-capped-thread-with-nothing-past-the-page-still-fails" 1 "$capped_thread"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
