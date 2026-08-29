#!/usr/bin/env bash
# Standalone test for scripts/ai-review/fetch-review-threads.sh.
# Run: bash scripts/tests/fetch-review-threads.bash
#
# WHAT THIS PROTECTS. Two consumers draw conclusions from this array that a
# truncated read gets silently wrong in the dangerous direction:
# handled-from-threads.sh decides which findings the model may stop reporting,
# and post-ci-status.sh publishes how many Major threads are open. A page-one
# read on a busy pull request drops threads off the end, so a finding that is
# still open reads as absent.
#
# Pagination is the whole subject, so the stub serves a MULTI-PAGE response and
# the cursor discipline is asserted rather than assumed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/fetch-review-threads.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
argv_log="$stub_dir/argv.log"
out="$stub_dir/threads.json"

# Serves page 1 then page 2, keyed on whether an `after` cursor was sent, and
# records every argument list so the cursor's flag can be checked.
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# One physical LINE per call: the GraphQL query is a multi-line argument, so a
# raw dump would make every per-call assertion below count lines of the query
# instead of calls.
printf '%s' "$*" | tr '\n' ' ' >>"$GH_STUB_ARGV"
printf '\n' >>"$GH_STUB_ARGV"
if printf '%s' "$*" | grep -q 'after=CURSOR1'; then
  # A SUCCESSFUL but unparseable second page, which is what an API error page
  # or a truncated response looks like from here. Used by the temp-file case at
  # the bottom, which needs a failure BETWEEN the temp file's creation and its
  # `mv`; a `gh` that merely exits non-zero never enters that window.
  if [ -n "${GH_STUB_BAD2:-}" ]; then
    printf 'not json at all'
    exit 0
  fi
  printf '%s' "$GH_STUB_PAGE2"
else
  printf '%s' "$GH_STUB_PAGE1"
fi
STUB
chmod +x "$stub_dir/gh"

page1="$(jq -cn '
  { pageInfo: { hasNextPage: true, endCursor: "CURSOR1" },
    nodes: [ { id: "T1", isResolved: false, path: "a.sh",
               comments: { nodes: [ { databaseId: 1, body: "first" } ] } } ] }')"
page2="$(jq -cn '
  { pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [ { id: "T2", isResolved: true, path: "b.sh",
               comments: { nodes: [ { databaseId: 2, body: "second" } ] } } ] }')"

run() {
  : >"$argv_log"
  rm -f "$out"
  env PATH="$stub_dir:$PATH" \
    GH_STUB_ARGV="$argv_log" GH_STUB_PAGE1="$page1" GH_STUB_PAGE2="$page2" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 THREADS_OUTPUT="$out" \
    "$@" bash "$script" >/dev/null 2>&1
}

run || fail_case "a normal fetch must exit 0"

# --- every page reaches the output ------------------------------------------
if [ "$(jq -r 'length' "$out")" = "2" ]; then ok; else
  fail_case "both pages must be concatenated, got $(jq -c . "$out")"
fi
if [ "$(jq -r '[.[].id] | join(",")' "$out")" = "T1,T2" ]; then ok; else
  fail_case "page order must be preserved, got $(jq -c '[.[].id]' "$out")"
fi

# --- the output shape its consumers destructure ------------------------------
# handled-from-threads.sh reads .path and .comments.nodes[0].body;
# post-ci-status.sh reads .isResolved. A missing field there is a silent
# miscount, not a crash, so the shape is pinned here.
if jq -e 'all(.[]; has("id") and has("isResolved") and has("path")
  and (.comments.nodes[0] | has("databaseId") and has("body")))' "$out" >/dev/null; then ok; else
  fail_case "each node must carry id, isResolved, path and its first comment"
fi

# --- the cursor flag discipline ----------------------------------------------
# The first request sends `-F after=null`, which gh converts to a GraphQL null
# meaning "from the first page". Every later request must use `-f`, a raw
# string: `-F` type-coerces a purely numeric value into a JSON number, and a
# String! argument rejects that. GitHub's cursors are opaque and not guaranteed
# to avoid looking numeric.
if head -n1 "$argv_log" | grep -q -- '-F after=null'; then ok; else
  fail_case "the first page must be requested with -F after=null"
fi
if sed -n '2p' "$argv_log" | grep -q -- '-f after=CURSOR1'; then ok; else
  fail_case "a cursor must be sent with -f, not -F: $(sed -n '2p' "$argv_log")"
fi
if [ "$(wc -l <"$argv_log")" -eq 2 ]; then ok; else
  fail_case "pagination must stop when hasNextPage is false, made $(wc -l <"$argv_log") calls"
fi

# --- a single page is not paginated further ----------------------------------
page1_single="$page2"
if env PATH="$stub_dir:$PATH" GH_STUB_ARGV="$argv_log" \
  GH_STUB_PAGE1="$page1_single" GH_STUB_PAGE2="$page2" \
  GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 THREADS_OUTPUT="$out" \
  bash "$script" >/dev/null 2>&1 && [ "$(jq -r 'length' "$out")" = "1" ]; then ok; else
  fail_case "a single-page response must yield exactly its own nodes"
fi

# --- required inputs ---------------------------------------------------------
# THREADS_OUTPUT is deliberately not named OUTPUT: callers set their own OUTPUT
# for their own result file, and a child inheriting that name would overwrite
# it. That only holds if the name is actually required rather than defaulted.
for missing in GH_TOKEN OWNER REPO_NAME PR_NUMBER THREADS_OUTPUT; do
  if run "$missing="; then
    fail_case "$missing must be required"
  else ok; fi
done

# --- A MID-LOOP FAILURE LEAVES NO TEMP FILE BEHIND ----------------------------
# Same leak, same fix and same reasoning as check-resolved.bash, which carries
# the long version of the note. `mktemp` is stubbed rather than given a private
# TMPDIR because BSD mktemp ignores TMPDIR for a template-less call, so the
# TMPDIR form passes whether or not the leak exists.
leak_dir="$(mktemp -d)"
cat >"$stub_dir/mktemp" <<'MKSTUB'
#!/usr/bin/env bash
f="$MKTEMP_STUB_DIR/t$$-$RANDOM"
: >"$f"
printf '%s\n' "$f"
MKSTUB
chmod +x "$stub_dir/mktemp"

if run MKTEMP_STUB_DIR="$leak_dir" GH_STUB_BAD2=1; then
  fail_case "an unparseable second page must fail the script, or the leak window is never entered"
else ok; fi
leaked="$(find "$leak_dir" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$leaked" = "0" ]; then ok; else
  fail_case "the pagination loop leaked $leaked temp file(s) on a mid-loop failure"
fi
rm -f "$stub_dir/mktemp"
rm -rf "$leak_dir"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
