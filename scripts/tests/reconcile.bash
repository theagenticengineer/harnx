#!/usr/bin/env bash
# Standalone test for scripts/ai-review/reconcile.sh.
# Run: bash scripts/tests/reconcile.bash
#
# WHAT THIS PROTECTS. reconcile.sh decides what the merged findings MEAN
# against the pull request that already exists, and the interesting decision is
# the third state.
#
# A finding matching a RESOLVED thread is a REGRESSION, and it must survive.
# The obvious reading of "HANDLED findings must not resurface" is to drop it,
# and dropping would delete the recurrence detection post-findings.sh provides:
# a finding somebody answered and closed, which the diff still exhibits, would
# vanish instead of reopening its thread. Suppression by MEANING already
# happened one layer up, in the engine's HANDLED memory, so anything reaching
# here has survived that filter and is a claimed regression.
#
# The other direction matters too: a finding that already has an OPEN thread
# must be marked tracked, not new, or the pull request grows a second thread
# for one problem on every pass.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/reconcile.sh"
# shellcheck source=scripts/ai-review/finding-key.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/ai-review/finding-key.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
findings="$work/findings.json"
threads="$work/threads.json"
out="$work/out.json"
log="$work/log.txt"

# A thread carrying the marker post-findings.sh writes for this finding.
thread_for() {
  local file="$1" title="$2" resolved="$3"
  jq -cn --arg m "<!-- ai-review-key:$(finding_key "$file" "$title") -->" \
    --argjson r "$resolved" --arg p "$file" \
    '{id: "T", isResolved: $r, path: $p,
      comments: {nodes: [{databaseId: 1, body: ($m + "\n<!-- ai-review-severity:Major -->\n**[Major]** x")}]}}'
}
put_findings() { printf '%s' "$1" >"$findings"; }
put_threads() { printf '%s\n' "$@" | jq -sc '.' >"$threads"; }

run() {
  local status
  set +e
  env FINDINGS="$findings" THREADS="${1:-$threads}" OUTPUT="$out" bash "$script" >"$log" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}
state_of() { jq -r --arg t "$1" '[.[] | select(.title == $t)][0].state' "$out"; }

f_unset='{"file":"a.sh","line":1,"side":"RIGHT","title":"the token is unset","severity":"Major","reviewer":"claude"}'
f_other='{"file":"b.sh","line":2,"side":"RIGHT","title":"a different problem","severity":"Minor","reviewer":"claude"}'

# --- a finding with no thread is NEW -----------------------------------------
put_findings "[$f_unset]"
put_threads
if [ "$(run)" = "0" ] && [ "$(state_of 'the token is unset')" = "new" ]; then ok; else
  fail_case "a finding with no thread must be new: $(cat "$log")"
fi

# --- a finding with an OPEN thread is TRACKED --------------------------------
# Marked rather than dropped, so post-findings.sh updates that thread instead
# of opening a second one for the same problem.
put_findings "[$f_unset]"
put_threads "$(thread_for a.sh 'the token is unset' false)"
if [ "$(run)" = "0" ] && [ "$(state_of 'the token is unset')" = "tracked" ]; then ok; else
  fail_case "a finding with an open thread must be tracked, got $(state_of 'the token is unset')"
fi

# --- THE ONE THAT MATTERS: a resolved thread is a REGRESSION, and it survives -
put_findings "[$f_unset]"
put_threads "$(thread_for a.sh 'the token is unset' true)"
if [ "$(run)" = "0" ] && [ "$(state_of 'the token is unset')" = "regression" ]; then ok; else
  fail_case "a finding matching a resolved thread must be a regression, got $(state_of 'the token is unset')"
fi
if [ "$(jq -r 'length' "$out")" = "1" ]; then ok; else
  fail_case "a regression must NOT be dropped; dropping deletes the recurrence detection"
fi
# It must be visible in the run, since a recurrence means the answer that
# closed the thread did not hold.
if grep -q 'recurred after being resolved' "$log"; then ok; else
  fail_case "a regression must be reported in the run output: $(cat "$log")"
fi

# --- the key tolerates rephrasing exactly as the poster's does ---------------
# Same shared function, so a title differing only in case and punctuation still
# matches its thread rather than opening a second one.
put_findings '[{"file":"a.sh","line":9,"side":"RIGHT","title":"The token is unset.","severity":"Major","reviewer":"gemini"}]'
put_threads "$(thread_for a.sh 'the token is unset' false)"
if [ "$(run)" = "0" ] && [ "$(state_of 'The token is unset.')" = "tracked" ]; then ok; else
  fail_case "a reworded finding must match its existing thread, got $(state_of 'The token is unset.')"
fi
# And a genuinely different finding in the same file must NOT match it.
put_findings "[$f_unset,$f_other]"
put_threads "$(thread_for a.sh 'the token is unset' false)"
run >/dev/null
if [ "$(state_of 'a different problem')" = "new" ]; then ok; else
  fail_case "a different finding must not inherit another's thread"
fi
if [ "$(state_of 'the token is unset')" = "tracked" ]; then ok; else
  fail_case "the matching finding must still be tracked alongside it"
fi

# --- mixed states are counted, and the counts are the point ------------------
put_findings "[$f_unset,$f_other]"
put_threads "$(thread_for a.sh 'the token is unset' true)"
run >/dev/null
if grep -q '1 new' "$log" && grep -q '1 recurring' "$log"; then ok; else
  fail_case "the summary must count each state: $(cat "$log")"
fi

# --- the key is carried out, so post-findings.sh need not recompute it -------
put_findings "[$f_unset]"
put_threads
run >/dev/null
if [ "$(jq -r '.[0].key' "$out")" = "$(finding_key a.sh 'the token is unset')" ]; then ok; else
  fail_case "the computed key must be carried on the output"
fi
# Every field post-findings.sh reads survives the annotation.
if jq -e '.[0] | has("file") and has("line") and has("side") and has("title") and has("severity") and has("reviewer")' "$out" >/dev/null; then ok; else
  fail_case "annotation must not drop fields post-findings.sh reads"
fi

# --- an absent threads file is the FIRST PASS, not an error ------------------
put_findings "[$f_unset]"
if [ "$(run "$work/nope.json")" = "0" ] && [ "$(state_of 'the token is unset')" = "new" ]; then ok; else
  fail_case "a pull request with no threads yet must classify everything as new"
fi

# --- a CORRUPT threads file is an error --------------------------------------
# Treating it as empty would mark every finding new and grow a duplicate of
# every thread the pull request already has.
put_findings "[$f_unset]"
printf '{"not":"an array"}' >"$threads"
if [ "$(run)" != "0" ]; then ok; else
  fail_case "a corrupt threads file must fail, not be read as no threads"
fi
if grep -q 'duplicate of every thread' "$log"; then ok; else
  fail_case "the corrupt-threads failure must say what it is protecting against"
fi

# --- a corrupt findings file is an error too ---------------------------------
put_findings '{"not":"an array"}'
put_threads
if [ "$(run)" != "0" ]; then ok; else
  fail_case "a corrupt findings file must fail"
fi

# --- nothing to classify is a clean pass -------------------------------------
put_findings '[]'
put_threads
if [ "$(run)" = "0" ] && [ "$(jq -c . "$out")" = "[]" ]; then ok; else
  fail_case "no findings is a clean reconcile, not a failure"
fi

# --- required inputs ----------------------------------------------------------
put_findings "[$f_unset]"
put_threads
for missing in FINDINGS THREADS OUTPUT; do
  set +e
  (env FINDINGS="$findings" THREADS="$threads" OUTPUT="$out" "$missing=" bash "$script") >"$log" 2>&1
  st=$?
  set -e
  if [ "$st" -ne 0 ]; then ok; else fail_case "$missing must be required"; fi
done

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
