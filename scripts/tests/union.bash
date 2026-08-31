#!/usr/bin/env bash
# Standalone test for scripts/ai-review/union.sh.
# Run: bash scripts/tests/union.bash
#
# WHAT THIS PROTECTS. With more than one reviewer on the same diff, the union
# is what stops a second opinion becoming a second copy of every finding. Both
# of its failure directions are bad in different ways:
#
#   under-merging  every reviewer's take on the same problem becomes its own
#                  thread, and the contributor pays for the extra reviewer in
#                  noise until they stop reading the threads at all.
#   over-merging   two genuinely different findings collapse and one is never
#                  posted, which is the silent drop this whole pipeline is
#                  built to avoid.
#
# And one failure mode that is neither: an EMPTY fan-out. A matrix that
# produced no jobs is indistinguishable downstream from a matrix whose jobs all
# passed, so "no findings" would be reported for a pull request nobody read.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/union.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/out.json"
log="$work/log.txt"

setup() {
  rm -rf "$work/in"
  mkdir -p "$work/in"
}
# $1 reviewer name, rest: compact JSON findings array
# Named <reviewer>.<pass>.json, matching the fan-out: three passes per
# reviewer, each its own leg and its own artifact.
put() { printf '%s' "$2" >"$work/in/$1.${3:-code}.json"; }

run() {
  local status
  set +e
  env UNION_INPUTS="${1:-$work/in}" AI_REVIEW_OUTPUT="$out" bash "$script" >"$log" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# --- one reviewer passes through unchanged -----------------------------------
setup
put claude '[{"file":"a.sh","line":3,"side":"RIGHT","title":"t","severity":"Minor","reviewer":"claude"}]'
if [ "$(run)" = "0" ] && [ "$(jq -r 'length' "$out")" = "1" ]; then ok; else
  fail_case "a single reviewer's findings must pass through: $(cat "$log")"
fi
if [ "$(jq -r '.[0].reviewer' "$out")" = "claude" ]; then ok; else
  fail_case "attribution must survive a single-reviewer union"
fi

# --- THE POINT: two reviewers, one problem, one thread -----------------------
setup
put claude '[{"file":"a.sh","line":3,"side":"RIGHT","title":"The token is unset","severity":"Minor","reviewer":"claude"}]'
put gemini '[{"file":"a.sh","line":4,"side":"RIGHT","title":"the token is unset.","severity":"Major","reviewer":"gemini"}]'
if [ "$(run)" = "0" ] && [ "$(jq -r 'length' "$out")" = "1" ]; then ok; else
  fail_case "two reviewers reporting one problem must produce one finding, got $(jq -r 'length' "$out")"
fi
# Merged on the SHARED key, so case, punctuation and the differing line all
# fall away exactly as they do for the poster's own threading.
if [ "$(jq -r '.[0].reviewer' "$out")" = "claude,gemini" ]; then ok; else
  fail_case "a merged finding must name every reviewer that raised it, got $(jq -r '.[0].reviewer' "$out")"
fi
# MOST SEVERE WINS. Two reviewers disagreeing about whether something blocks
# merge is not a tie to average: the gate exists to stop a real Major.
if [ "$(jq -r '.[0].severity' "$out")" = "Major" ]; then ok; else
  fail_case "a merge must take the most severe rating, got $(jq -r '.[0].severity' "$out")"
fi
# The reverse order must give the same answer, or the result depends on which
# reviewer's file the shell happened to glob first.
setup
put aaa '[{"file":"a.sh","line":3,"side":"RIGHT","title":"the token is unset.","severity":"Major","reviewer":"aaa"}]'
put zzz '[{"file":"a.sh","line":4,"side":"RIGHT","title":"The token is unset","severity":"nit","reviewer":"zzz"}]'
run >/dev/null
if [ "$(jq -r '.[0].severity' "$out")" = "Major" ]; then ok; else
  fail_case "most-severe-wins must not depend on file order"
fi

# --- distinct findings must NOT be merged ------------------------------------
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"the token is unset","severity":"Major","reviewer":"claude"},
             {"file":"a.sh","line":9,"side":"RIGHT","title":"the token is unread","severity":"Minor","reviewer":"claude"}]'
put gemini '[{"file":"b.sh","line":1,"side":"RIGHT","title":"the token is unset","severity":"Major","reviewer":"gemini"}]'
if [ "$(run)" = "0" ] && [ "$(jq -r 'length' "$out")" = "3" ]; then ok; else
  fail_case "three distinct findings must survive as three, got $(jq -r 'length' "$out")"
fi
# Same title in a DIFFERENT file is a different finding, because the key is
# file plus title.
if [ "$(jq -r '[.[] | select(.title == "the token is unset")] | length' "$out")" = "2" ]; then ok; else
  fail_case "the same title in two files must stay two findings"
fi

# --- AN EMPTY FAN-OUT IS A FAILURE, NOT AN EMPTY REVIEW ----------------------
# A matrix that produced no jobs looks exactly like a matrix whose jobs all
# passed. This is the only place that difference can still be seen.
setup
if [ "$(run)" != "0" ]; then ok; else
  fail_case "an empty input directory must fail, not report zero findings"
fi
if grep -q 'no jobs' "$log"; then ok; else
  fail_case "the empty-fan-out failure must explain itself: $(cat "$log")"
fi
if [ "$(run "$work/nonexistent")" != "0" ]; then ok; else
  fail_case "a missing input directory must fail too"
fi

# --- THE REGISTRY IS COUNTED AGAINST THE RESULTS -----------------------------
# A matrix that fans out to fewer legs than the registry named is invisible
# downstream: the legs that ran all passed, and a reviewer that never ran
# produces no findings, which reads exactly like a reviewer that found nothing.
# Job status cannot tell those apart; a count can.
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"Major","reviewer":"claude"}]'
if [ "$(
  env EXPECTED_REVIEWERS='["claude","gemini"]' UNION_INPUTS="$work/in" AI_REVIEW_OUTPUT="$out" bash "$script" >"$log" 2>&1
  echo $?
)" != "0" ]; then ok; else
  fail_case "a reviewer named in the registry that produced no file must fail the union"
fi
if grep -q 'gemini' "$log"; then ok; else
  fail_case "the failure must name the reviewer that produced nothing: $(cat "$log")"
fi
# Every named reviewer present is a clean union, so the count is a count and
# not a blanket refusal.
setup
put claude '[]'
put gemini '[]'
if [ "$(
  env EXPECTED_REVIEWERS='["claude","gemini"]' UNION_INPUTS="$work/in" AI_REVIEW_OUTPUT="$out" bash "$script" >"$log" 2>&1
  echo $?
)" = "0" ]; then ok; else
  fail_case "every named reviewer producing a file must pass: $(cat "$log")"
fi
# A reviewer that produced a file but is NOT in the registry does not fail the
# count. The registry is the floor, not the ceiling, and a stale artifact is
# not a missing review.
setup
put claude '[]'
put extra '[]'
if [ "$(
  env EXPECTED_REVIEWERS='["claude"]' UNION_INPUTS="$work/in" AI_REVIEW_OUTPUT="$out" bash "$script" >"$log" 2>&1
  echo $?
)" = "0" ]; then ok; else
  fail_case "an unexpected extra reviewer file must not fail the count"
fi
# Without the registry the count is skipped, so the script stays usable on its
# own and the empty-directory guard is still the backstop.
setup
put claude '[]'
if [ "$(run)" = "0" ]; then ok; else
  fail_case "an absent registry must skip the count rather than fail"
fi

# --- a FAILED leg must not suppress the reviewers that worked ----------------
# `fail-fast: false` exists so one reviewer's expired token does not cost the
# contributor every other reviewer's findings. Refusing the union when a leg
# failed would undo that: the leg is already reported by itself and by the
# gate, and discarding the rest reports nothing at all.
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"Major","reviewer":"claude"}]'
if [ "$(
  env EXPECTED_REVIEWERS='["claude","gemini"]' EXPECTED_STRICT=false \
    UNION_INPUTS="$work/in" AI_REVIEW_OUTPUT="$out" bash "$script" >"$log" 2>&1
  echo $?
)" = "0" ]; then ok; else
  fail_case "a failed leg must not suppress the reviewers that worked: $(cat "$log")"
fi
if [ "$(jq -r 'length' "$out")" = "1" ]; then ok; else
  fail_case "the surviving reviewer's findings must still be merged"
fi
# Still SAID, loudly, so a reader is never left thinking every reviewer ran.
if grep -q '::warning::' "$log" && grep -q 'gemini' "$log"; then ok; else
  fail_case "a missing reviewer must still be reported even when it does not fail: $(cat "$log")"
fi
# And strict remains the default, so the leniency has to be asked for.
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"Major","reviewer":"claude"}]'
if [ "$(
  env EXPECTED_REVIEWERS='["claude","gemini"]' \
    UNION_INPUTS="$work/in" AI_REVIEW_OUTPUT="$out" bash "$script" >"$log" 2>&1
  echo $?
)" != "0" ]; then ok; else
  fail_case "strict must be the default; a missing reviewer fails unless told otherwise"
fi

# --- a corrupt reviewer file is not silently skipped -------------------------
# Skipping it drops that reviewer's whole set, and dropping is the direction
# that loses a Major.
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"Major","reviewer":"claude"}]'
put broken '{"not":"an array"}'
if [ "$(run)" != "0" ]; then ok; else
  fail_case "a corrupt reviewer file must fail the union, not be skipped"
fi
if grep -q 'broken' "$log"; then ok; else
  fail_case "the failure must name the reviewer whose file was unusable: $(cat "$log")"
fi
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"Major","reviewer":"claude"}]'
put odd '["a bare string, not a finding"]'
if [ "$(run)" != "0" ]; then ok; else
  fail_case "a non-object finding must fail the union rather than being dropped"
fi

# --- a reviewer that legitimately found nothing ------------------------------
# An empty ARRAY is a real answer ("I read it and found nothing") and is
# completely different from an absent file ("I never ran").
setup
put claude '[]'
put gemini '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"Major","reviewer":"gemini"}]'
if [ "$(run)" = "0" ] && [ "$(jq -r 'length' "$out")" = "1" ]; then ok; else
  fail_case "a reviewer reporting nothing must not fail the union: $(cat "$log")"
fi
setup
put claude '[]'
put gemini '[]'
if [ "$(run)" = "0" ] && [ "$(jq -c . "$out")" = "[]" ]; then ok; else
  fail_case "every reviewer finding nothing is a clean union, not a failure"
fi

# --- an unknown severity fails closed ----------------------------------------
# Matching review-engine.sh's rule: unrecognised is the most severe, not the
# least visible.
setup
put claude '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"catastrophic","reviewer":"claude"}]'
put gemini '[{"file":"a.sh","line":1,"side":"RIGHT","title":"t","severity":"nit","reviewer":"gemini"}]'
run >/dev/null
if [ "$(jq -r '.[0].severity' "$out")" = "Major" ]; then ok; else
  fail_case "an unrecognised severity must win as Major, got $(jq -r '.[0].severity' "$out")"
fi

# --- the merged shape is what post-findings.sh consumes ----------------------
setup
put claude '[{"file":"a.sh","line":7,"side":"LEFT","title":"t","severity":"Major","reviewer":"claude"}]'
run >/dev/null
if jq -e '.[0] | has("file") and has("line") and has("side") and has("title") and has("severity") and has("reviewer")' "$out" >/dev/null; then ok; else
  fail_case "the merged finding must carry every field post-findings.sh reads"
fi
# The grouping field must not leak into what gets posted.
if jq -e '.[0] | has("nkey") | not' "$out" >/dev/null; then ok; else
  fail_case "the internal grouping key must not survive into the output"
fi
# side survives, so a finding about removed code still anchors left.
if [ "$(jq -r '.[0].side' "$out")" = "LEFT" ]; then ok; else
  fail_case "side must survive the union"
fi

# --- required inputs ----------------------------------------------------------
for missing in UNION_INPUTS AI_REVIEW_OUTPUT; do
  set +e
  (env UNION_INPUTS="$work/in" AI_REVIEW_OUTPUT="$out" "$missing=" bash "$script") >"$log" 2>&1
  st=$?
  set -e
  if [ "$st" -ne 0 ]; then ok; else fail_case "$missing must be required"; fi
done

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
