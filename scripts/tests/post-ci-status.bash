#!/usr/bin/env bash
# Standalone test for scripts/ai-review/post-ci-status.sh.
# Run: bash scripts/tests/post-ci-status.bash
#
# WHAT THIS PROTECTS. This script runs in the one job holding the write-scoped
# App token, and it PATCHes a comment it identifies by a marker that is plain
# text in a public pull request body. Whoever opened the pull request can read
# that marker and write it, so WHICH comment this script decides is "its own"
# is a security question, not a formatting one: the answer decides whose text
# the App's token rewrites.
#
# The rest of the file pins the upsert contract, because the alternative to one
# updated comment is a new one per push, which is how a pull request ends up
# with several contradictory "current" states visible at once.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/post-ci-status.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
calls="$stub_dir/calls.log"
bodies="$stub_dir/bodies.log"
findings="$stub_dir/findings.json"
log="$stub_dir/log.txt"
app_login='harnx-ai-review[bot]'

# One stub for three calls: the GraphQL thread fetch (made by
# fetch-review-threads.sh, which this script shells out to), the issue-comment
# list, and the create-or-update write.
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$*" | tr '\n' ' ' >>"$GH_STUB_CALLS"
printf '\n' >>"$GH_STUB_CALLS"
case "$*" in
*graphql*)
  printf '%s' "${GH_STUB_THREADS:-}"
  exit 0
  ;;
esac
# The write path. Record the body so the rendered comment can be inspected.
case "$*" in
*"-X PATCH"* | *"-f body="*)
  prev=""
  for a in "$@"; do
    case "$prev" in -f) printf '%s\n' "${a#body=}" >>"$GH_STUB_BODIES" ;; esac
    prev="$a"
  done
  exit 0
  ;;
esac
# Anything else is the comment listing.
printf '%s' "${GH_STUB_COMMENTS:-[]}"
STUB
chmod +x "$stub_dir/gh"

threads_payload() {
  # $1 = number of unresolved Major threads, $2 = number of resolved ones
  jq -cn --argjson open "$1" --argjson res "$2" '
    def t(r): { isResolved: r, comments: { nodes: [
      { body: "<!-- ai-review-severity:Major -->\n**[Major]** f" } ] } };
    { pageInfo: { hasNextPage: false, endCursor: null },
      nodes: ([range($open) | t(false)] + [range($res) | t(true)]) }'
}

run() {
  : >"$calls"
  : >"$bodies"
  env PATH="$stub_dir:$PATH" \
    GH_STUB_CALLS="$calls" GH_STUB_BODIES="$bodies" \
    GH_STUB_THREADS="${THREADS:-$(threads_payload 0 0)}" \
    GH_STUB_COMMENTS="${COMMENTS:-[]}" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
    APP_LOGIN="$app_login" FINDINGS="$findings" \
    "$@" bash "$script" >"$log" 2>&1
}

jq -cn '[{file:"a.sh",line:1,side:"RIGHT",title:"t",severity:"Major",reviewer:"claude"},
         {file:"a.sh",line:2,side:"RIGHT",title:"u",severity:"nit",reviewer:"claude"}]' >"$findings"

# --- with no comment yet, it creates one -------------------------------------
run || fail_case "a first pass must exit 0: $(cat "$log")"
if grep -q 'created the status comment' "$log"; then ok; else
  fail_case "with no existing comment the script must create one: $(cat "$log")"
fi
if grep -q 'issues/1/comments' "$calls" && ! grep -q -- '-X PATCH' "$calls"; then ok; else
  fail_case "creation must POST to the pull request, not PATCH something"
fi

# --- THE SECURITY CASE: the marker alone is not proof of authorship -----------
# A contributor who pre-posts a comment carrying the marker would, under a
# marker-only match, own the canonical status comment from then on: every later
# pass PATCHes THEIRS under the App's write-scoped token, so the review's own
# verdict is published inside text somebody else controls, and the pass history
# rides in the same body.
impostor="$(jq -cn '[{id: 900, user: {login: "a-contributor"},
  body: "<!-- ai-review-ci-status -->\nnothing to see here"}]')"
COMMENTS="$impostor" run
if grep -q 'created the status comment' "$log"; then ok; else
  fail_case "a marker-carrying comment by somebody else must be ignored: $(cat "$log")"
fi
if ! grep -q 'comments/900' "$calls"; then ok; else
  fail_case "the App's token must never PATCH a comment it did not write"
fi

# --- its own comment IS updated, in place ------------------------------------
mine="$(jq -cn --arg l "$app_login" '[{id: 500, user: {login: $l},
  body: "<!-- ai-review-ci-status -->\n<!-- ai-review-ci-log:[{\"pass\":1,\"runner\":\"CI\",\"major\":9,\"minor\":0,\"nit\":0,\"seconds\":11}] -->\n### AI review (CI)"}]')"
COMMENTS="$mine" run
if grep -q 'updated status comment 500' "$log"; then ok; else
  fail_case "its own comment must be updated in place: $(cat "$log")"
fi
# The pass history is carried forward rather than restarted, which is the whole
# reason the table shows a trend instead of a single row.
if grep -q '| #1 | CI | 9 |' "$bodies" && grep -q '| #2 | CI | 1 |' "$bodies"; then ok; else
  fail_case "the previous passes must survive the update: $(cat "$bodies")"
fi
# An impostor sitting alongside the real comment must not win.
COMMENTS="$(jq -cn --arg l "$app_login" '[
  {id: 900, user: {login: "a-contributor"}, body: "<!-- ai-review-ci-status -->\nmine now"},
  {id: 500, user: {login: $l}, body: "<!-- ai-review-ci-status -->\n### AI review (CI)"}]')" run
if grep -q 'updated status comment 500' "$log"; then ok; else
  fail_case "the App's own comment must be preferred over an impostor: $(cat "$log")"
fi

# --- the verdict must not drift from the gate that blocks merge --------------
# Both read the same severity marker, so a pull request the gate would block
# must never be reported here as passing.
THREADS="$(threads_payload 2 1)" run
if grep -q 'BLOCKED: 2 unresolved Major' "$bodies"; then ok; else
  fail_case "an open Major must be reported as BLOCKED: $(cat "$bodies")"
fi
if grep -q '2 open, 1 resolved' "$bodies"; then ok; else
  fail_case "the thread counts must be reported: $(cat "$bodies")"
fi
THREADS="$(threads_payload 0 3)" run
if grep -q 'PASS: no unresolved Major' "$bodies"; then ok; else
  fail_case "no open Major must be reported as PASS: $(cat "$bodies")"
fi

# --- REVIEW_SECONDS crosses a trust boundary ----------------------------------
# It is produced by the job that runs the pull request's own review engine,
# travels as artifact content, and is interpolated into a comment body here.
# Digits only, or dropped.
run REVIEW_SECONDS=42
if grep -q '42s' "$bodies"; then ok; else
  fail_case "a numeric review time must be rendered: $(cat "$bodies")"
fi
# THE INJECTION PAYLOAD IS A CANARY, NOT A DESTRUCTIVE COMMAND. An earlier
# version of this line used `rm -rf /`, on the reasoning that the assertion
# drops the value so the command never runs. That reasoning is backwards: the
# payload only executes in the exact case this test exists to catch, so the
# consequence of the regression it hunts was to wipe the machine running the
# suite, and this file tells a developer to run it locally.
#
# `touch <canary>` is equally metacharacter-rich and strictly stronger: the
# value is still asserted to be dropped, and the canary's absence then proves
# nothing executed. Matches the same treatment in extract-diff.bash and
# fetch-subject.bash.
canary="$stub_dir/canary-must-not-exist"
run REVIEW_SECONDS="7; touch $canary"
if grep -q 'n/a' "$bodies" && ! grep -q 'touch' "$bodies"; then ok; else
  fail_case "a non-numeric review time must be dropped, not interpolated"
fi
if [ ! -e "$canary" ]; then ok; else
  fail_case "a rejected REVIEW_SECONDS reached a shell: the canary at $canary was created"
fi

# --- a corrupt history restarts the table, it does not fail the run -----------
# This payload is display-only: it feeds no gate. That is the opposite of
# review-engine.sh's handling of corrupt memory, and deliberately so.
COMMENTS="$(jq -cn --arg l "$app_login" '[{id: 500, user: {login: $l},
  body: "<!-- ai-review-ci-status -->\n<!-- ai-review-ci-log:{\"not\":\"an array\"} -->"}]')" run
if grep -q 'restarting it' "$log"; then ok; else
  fail_case "a corrupt pass history must warn and restart: $(cat "$log")"
fi
if grep -q '| #1 | CI |' "$bodies"; then ok; else
  fail_case "a restarted table must still render this pass"
fi

# --- a findings payload that is not an array fails ----------------------------
# Reporting a review state derived from a corrupt payload would publish a
# verdict about nothing.
printf '{"not":"an array"}' >"$findings"
if run; then
  fail_case "a non-array findings payload must fail"
else ok; fi
jq -cn '[]' >"$findings"

# --- required inputs -----------------------------------------------------------
# APP_LOGIN most of all: defaulted or empty it would match no comment, so every
# pass would create another one, restoring the running-commentary this script
# exists to prevent.
for missing in GH_TOKEN OWNER REPO_NAME PR_NUMBER FINDINGS APP_LOGIN; do
  if run "$missing="; then
    fail_case "$missing must be required"
  else ok; fi
done

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
