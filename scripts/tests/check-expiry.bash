#!/usr/bin/env bash
# Standalone test for scripts/ai-review/check-expiry.sh.
# Run: bash scripts/tests/check-expiry.bash
#
# WHAT THIS PROTECTS. The warning and the hard failure are a pair. Under the
# registry's rule a named reviewer whose credential has lapsed FAILS its leg
# and the gate goes red, which is honest and also a nasty surprise: the person
# who reads that failure, on their own unrelated pull request, is never the
# person who can fix it. This is what makes the failure arrive expected.
#
# So the interesting cases are the ones where it says nothing when it should
# speak, or speaks when it should be silent. A warning nobody can act on is the
# noise this repository refuses elsewhere; a missing warning is the surprise it
# exists to prevent.
#
# TODAY is injectable, so the arithmetic is asserted against fixed dates rather
# than against whenever the suite happens to run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/check-expiry.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/out.txt"

one='[{"slug":"claude","expires":"AI_REVIEW_TOKEN_EXPIRES_CLAUDE"}]'
two='[{"slug":"claude","expires":"AI_REVIEW_TOKEN_EXPIRES_CLAUDE"},
      {"slug":"code-rabbit","expires":"AI_REVIEW_TOKEN_EXPIRES_CODE_RABBIT"}]'

# $1 the vars JSON, $2 the reviewers JSON, rest: extra environment.
run() {
  local vars="$1" reviewers="$2"
  shift 2
  local status
  set +e
  env VARS="$vars" REVIEWERS="$reviewers" TODAY=2026-08-31 "$@" bash "$script" >"$out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}
v() { jq -cn --arg v "$1" '{AI_REVIEW_TOKEN_EXPIRES_CLAUDE: $v}'; }

# --- silence is the default ---------------------------------------------------
# A reviewer with no expiry variable is silent: plenty of credentials do not
# expire, and warning about every one of them trains readers to skip the
# warnings that matter.
if [ "$(run '{}' "$one")" = "0" ] && grep -q 'no reviewer credential is near expiry' "$out"; then ok; else
  fail_case "a reviewer with no expiry set must be silent: $(cat "$out")"
fi
if ! grep -q '::warning::' "$out"; then ok; else
  fail_case "an unset expiry must not warn"
fi
# A date comfortably away is silent too.
run "$(v 2027-01-01)" "$one" >/dev/null
if ! grep -q '::warning::' "$out"; then ok; else
  fail_case "an expiry months away must not warn: $(cat "$out")"
fi

# --- the seven-day window -----------------------------------------------------
# Asserted at both edges, because an off-by-one here either warns a day late,
# which is the surprise this exists to prevent, or warns forever.
run "$(v 2026-09-07)" "$one" >/dev/null
if grep -q '::warning::' "$out" && grep -q '7 day' "$out"; then ok; else
  fail_case "exactly seven days out must warn: $(cat "$out")"
fi
run "$(v 2026-09-08)" "$one" >/dev/null
if ! grep -q '::warning::' "$out"; then ok; else
  fail_case "eight days out must NOT warn: $(cat "$out")"
fi
run "$(v 2026-09-01)" "$one" >/dev/null
if grep -q '1 day' "$out"; then ok; else
  fail_case "one day out must say one day: $(cat "$out")"
fi
run "$(v 2026-08-31)" "$one" >/dev/null
if grep -q '::warning::' "$out" && grep -q '0 day' "$out"; then ok; else
  fail_case "expiring today must warn: $(cat "$out")"
fi
# The window is configurable, and the default is not the only value that works.
run "$(v 2026-09-20)" "$one" WARN_DAYS=30 >/dev/null
if grep -q '::warning::' "$out"; then ok; else
  fail_case "a wider window must warn earlier: $(cat "$out")"
fi

# --- already lapsed reads differently from about to lapse --------------------
# They need different actions, so they must not share a sentence.
run "$(v 2026-08-01)" "$one" >/dev/null
if grep -q 'EXPIRED' "$out"; then ok; else
  fail_case "a date in the past must say EXPIRED, not 'expiring in -30 days': $(cat "$out")"
fi
if ! grep -q 'day(s)' "$out"; then ok; else
  fail_case "a lapsed credential must not be reported as a countdown"
fi
# It must say what the consequence already is, since the leg is failing now.
if grep -q 'leg fails' "$out"; then ok; else
  fail_case "the expired warning must say the leg is already failing: $(cat "$out")"
fi

# --- a malformed value warns and is skipped, never crashes -------------------
# The value is repository state somebody typed. A typo must cost a message, not
# a red gate on a pull request that has nothing to do with it.
for bad in 'next tuesday' '2026/09/04' '' '2026-13-01' '2026-02-30' '2027-02-29' '2026-01-00' '26-09-04'; do
  case "$bad" in
  '') continue ;;
  esac
  if [ "$(run "$(v "$bad")" "$one")" = "0" ]; then ok; else
    fail_case "a malformed expiry ('$bad') must not fail the step: $(cat "$out")"
  fi
  if grep -q 'not an ISO date' "$out"; then ok; else
    fail_case "a malformed expiry ('$bad') must be reported: $(cat "$out")"
  fi
done
# A valid leap day must NOT be rejected by the calendar check.
run "$(v 2028-02-29)" "$one" >/dev/null
if ! grep -q 'not an ISO date' "$out"; then ok; else
  fail_case "2028-02-29 is a real date and must be accepted"
fi
# The malformed message names the variable, or the operator cannot find it.
run "$(v 'next tuesday')" "$one" >/dev/null
if grep -q 'AI_REVIEW_TOKEN_EXPIRES_CLAUDE' "$out"; then ok; else
  fail_case "the malformed warning must name the variable to fix"
fi

# --- per reviewer -------------------------------------------------------------
# One reviewer expiring must not implicate another, and a warning has to say
# whose credential it is or a repository with three reviewers cannot act on it.
vars_two="$(jq -cn '{AI_REVIEW_TOKEN_EXPIRES_CLAUDE: "2026-09-02",
                     AI_REVIEW_TOKEN_EXPIRES_CODE_RABBIT: "2027-01-01"}')"
run "$vars_two" "$two" >/dev/null
if grep -q "reviewer 'claude'" "$out"; then ok; else
  fail_case "the warning must name the reviewer: $(cat "$out")"
fi
if ! grep -q "reviewer 'code-rabbit'" "$out"; then ok; else
  fail_case "a reviewer that is not expiring must not be warned about"
fi
# Both expiring means both reported, not just the first.
vars_both="$(jq -cn '{AI_REVIEW_TOKEN_EXPIRES_CLAUDE: "2026-09-02",
                      AI_REVIEW_TOKEN_EXPIRES_CODE_RABBIT: "2026-09-03"}')"
run "$vars_both" "$two" >/dev/null
if grep -q "reviewer 'claude'" "$out" && grep -q "reviewer 'code-rabbit'" "$out"; then ok; else
  fail_case "every expiring reviewer must be reported: $(cat "$out")"
fi

# --- nothing armed ------------------------------------------------------------
if [ "$(run "$(v 2026-09-01)" '[]')" = "0" ] && ! grep -q '::warning::' "$out"; then ok; else
  fail_case "with no reviewers armed there is nothing to warn about"
fi
# A corrupt vars payload must not crash the step either: it is read for a
# warning, and a warning must never be the reason a gate cannot report.
if [ "$(run 'not json' "$one")" = "0" ]; then ok; else
  fail_case "an unreadable vars payload must not fail the step"
fi

# --- required inputs ----------------------------------------------------------
for missing in REVIEWERS VARS; do
  set +e
  (env VARS='{}' REVIEWERS="$one" TODAY=2026-08-31 "$missing=" bash "$script") >"$out" 2>&1
  st=$?
  set -e
  if [ "$st" -ne 0 ]; then ok; else fail_case "$missing must be required"; fi
done

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
