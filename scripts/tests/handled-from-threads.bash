#!/usr/bin/env bash
# Standalone test for scripts/ai-review/handled-from-threads.sh.
# Run: bash scripts/tests/handled-from-threads.bash
#
# WHAT THIS PROTECTS. This script builds the review engine's memory, and its
# two halves pull in OPPOSITE directions, so getting either wrong is a
# different, silent defect:
#
#   HANDLED (resolved)    tells the model never to resurface a finding. Put an
#                         UNRESOLVED thread in here and a finding nobody has
#                         addressed is muted by the wording of the pass that
#                         first raised it.
#   OPEN (unresolved)     tells the model to re-report a still-present finding
#                         under its EXISTING title. Put a RESOLVED thread in
#                         here and a dispositioned finding is asked to come
#                         back. Leave the array out and a reworded re-report
#                         opens a second thread for one problem, which is how
#                         one CODEOWNERS finding reached five threads on this
#                         repository's own PR #38.
#
# So the membership of each array is the subject, and both are asserted in both
# directions.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/handled-from-threads.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
handled_out="$stub_dir/handled.json"
open_out="$stub_dir/open.json"
log="$stub_dir/log.txt"

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${GH_STUB_PAGE:-}"
STUB
chmod +x "$stub_dir/gh"

# $1 id, $2 resolved, $3 path, $4 title, $5 optional body override.
thread() {
  jq -cn --arg id "$1" --argjson resolved "$2" --arg path "$3" --arg title "$4" \
    --arg override "${5:-}" '
    { id: $id, isResolved: $resolved, path: $path,
      comments: { nodes: [ { databaseId: 1,
        body: (if $override != "" then $override
               else "<!-- ai-review-key:k -->\n<!-- ai-review-severity:Major -->\n**[Major]** \($title)"
               end) } ] } }'
}
page() { printf '%s\n' "$@" | jq -sc '{pageInfo:{hasNextPage:false,endCursor:null},nodes:.}'; }

run() {
  rm -f "$handled_out" "$open_out"
  env PATH="$stub_dir:$PATH" GH_STUB_PAGE="$1" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
    OUTPUT="$handled_out" OPEN_OUTPUT="$open_out" \
    bash "$script" >"$log" 2>&1
}

# --- the split ----------------------------------------------------------------
mixed="$(page \
  "$(thread T1 true a.sh 'a dispositioned finding')" \
  "$(thread T2 false b.sh 'a finding still waiting')")"
run "$mixed" || fail_case "a normal build must exit 0: $(cat "$log")"

if [ "$(jq -r '[.[].title] | join(",")' "$handled_out")" = "a dispositioned finding" ]; then ok; else
  fail_case "HANDLED must hold the resolved thread only, got $(jq -c . "$handled_out")"
fi
if [ "$(jq -r '[.[].title] | join(",")' "$open_out")" = "a finding still waiting" ]; then ok; else
  fail_case "OPEN must hold the unresolved thread only, got $(jq -c . "$open_out")"
fi
# The direction that mutes an unaddressed finding.
if ! jq -e 'any(.[]; .title == "a finding still waiting")' "$handled_out" >/dev/null; then ok; else
  fail_case "an unresolved finding must never reach HANDLED memory"
fi
# The direction that asks a dispositioned finding to come back.
if ! jq -e 'any(.[]; .title == "a dispositioned finding")' "$open_out" >/dev/null; then ok; else
  fail_case "a resolved finding must never reach OPEN memory"
fi

# --- the shape review-engine.sh filters to ------------------------------------
# Exactly {file, title}. The thread id is used internally for the error message
# below and must not leak into what the model is shown.
if jq -e 'all(.[]; (keys | sort) == ["file","title"])' "$handled_out" >/dev/null &&
  jq -e 'all(.[]; (keys | sort) == ["file","title"])' "$open_out" >/dev/null; then ok; else
  fail_case "both memories must be exactly {file, title}"
fi
if [ "$(jq -r '.[0].file' "$open_out")" = "b.sh" ]; then ok; else
  fail_case "the file comes from the THREAD's path, not from the comment body"
fi

# --- only ai-review threads count ---------------------------------------------
# Ordinary human review threads share the type. Feeding one to the engine as
# memory would tell the model to suppress, or to re-report verbatim, something
# that was never a finding.
human="$(page "$(thread T3 true a.sh '' 'Nice work, merging this.')" \
  "$(thread T4 false a.sh '' 'Could you rename this?')")"
run "$human" || fail_case "a pull request with only human threads must exit 0: $(cat "$log")"
if [ "$(jq -r 'length' "$handled_out")" = "0" ] &&
  [ "$(jq -r 'length' "$open_out")" = "0" ]; then ok; else
  fail_case "a thread with no ai-review key marker is not a finding"
fi

# --- both arrays empty is a legitimate state ----------------------------------
run "$(page)" || fail_case "a pull request with no threads must exit 0"
if [ "$(jq -c . "$handled_out")" = "[]" ] && [ "$(jq -c . "$open_out")" = "[]" ]; then ok; else
  fail_case "no threads must produce two empty arrays, not a missing file"
fi

# --- a marker-carrying thread that cannot be parsed FAILS ---------------------
# Dropping it is the dangerous direction: a forgotten entry is re-derived by
# the model, reworded, and posted as a new thread, which restores the
# unconvergeable gate this script exists to prevent. The failure means
# post-findings.sh's body format and this parser have drifted.
broken="$(page "$(thread T5 true a.sh '' '<!-- ai-review-key:k -->
no title line here')")"
if run "$broken"; then
  fail_case "an unparseable resolved finding must fail, not be dropped"
else ok; fi
if grep -q 'T5' "$log"; then ok; else
  fail_case "the failure must name the thread it could not parse: $(cat "$log")"
fi
# The same rule applies to the OPEN half: a thread whose title cannot be read
# cannot have its wording pinned, and the pin is what stops the duplicate.
broken_open="$(page "$(thread T6 false a.sh '' '<!-- ai-review-key:k -->
no title line here')")"
if run "$broken_open"; then
  fail_case "an unparseable unresolved finding must fail too"
else ok; fi
if grep -q 'T6' "$log"; then ok; else
  fail_case "the failure must name the unresolved thread it could not parse"
fi

# --- both destinations are required -------------------------------------------
# OPEN_OUTPUT defaulting to somewhere would silently drop the wording pin and
# leave the duplicate-thread bug in place with nothing to show for it.
for missing in GH_TOKEN OWNER REPO_NAME PR_NUMBER OUTPUT OPEN_OUTPUT; do
  set +e
  env PATH="$stub_dir:$PATH" GH_STUB_PAGE="$(page)" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
    OUTPUT="$handled_out" OPEN_OUTPUT="$open_out" "$missing=" \
    bash "$script" >"$log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then ok; else fail_case "$missing must be required"; fi
done

# --- the log says what was passed to the engine -------------------------------
run "$mixed"
if grep -q '1 resolved' "$log" && grep -q '1 unresolved' "$log"; then ok; else
  fail_case "the run must report both counts: $(cat "$log")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
