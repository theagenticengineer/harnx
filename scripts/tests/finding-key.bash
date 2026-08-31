#!/usr/bin/env bash
# Standalone test for scripts/ai-review/finding-key.sh.
# Run: bash scripts/tests/finding-key.bash
#
# WHAT THIS PROTECTS. This key decides two things that must not disagree:
# whether a finding updates an existing review thread or opens a new one
# (post-findings.sh), and whether two reviewers reporting the same problem
# produce one thread or two (union.sh). Both source this file, so the only way
# they can drift is if this file changes underneath them, and the properties
# below are what "changes underneath them" would break.
#
# The dangerous direction is OVER-collapsing. A key that merges two genuinely
# different findings silently drops the second, which is precisely the defect
# an earlier eight-word-truncated version of this had.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# --- the same finding keys the same, whatever the formatting ----------------
# Findings are worded by a model, so case and punctuation are not stable across
# runs of the same underlying issue. Tolerating that is the whole point.
same() {
  if [ "$(finding_key "$1" "$2")" = "$(finding_key "$1" "$3")" ]; then ok; else
    fail_case "these must key alike on $1: '$2' vs '$3'"
  fi
}
same "a.sh" "A Finding" "a finding"
same "a.sh" "a finding" "a  finding"
same "a.sh" "a finding" "a, finding."
same "a.sh" "the token is unset" "The token is unset!"
same "a.sh" "uses --tools" "uses  tools"

# --- different findings must NOT collide ------------------------------------
# This is the direction that loses work: a collision means the second finding
# is skipped as "already tracked" and never posted at all.
differ() {
  if [ "$(finding_key "$1" "$2")" != "$(finding_key "$3" "$4")" ]; then ok; else
    fail_case "these must NOT key alike: $1/'$2' vs $3/'$4'"
  fi
}
differ "a.sh" "a finding" "b.sh" "a finding"
differ "a.sh" "the token is unset" "a.sh" "the token is unread"
# Two findings sharing an opening phrase. The eight-word truncation this file's
# comment records as rejected would have collapsed exactly this pair.
differ "a.sh" "the temp file is never removed on the success path" \
  "a.sh" "the temp file is never removed on the failure path"
differ "a.sh" "missing test" "a.sh" "missing tests"

# --- the fields the key deliberately EXCLUDES -------------------------------
# Line is out because an unrelated edit earlier in the same file shifts it for
# the same underlying finding. Severity is out because a model re-assesses it,
# and a severity change must read as an update to one thread rather than as a
# new finding. Neither is an input to the function, so the assertion is that
# the signature stays two arguments: a third would silently become part of the
# key for any caller that passed one.
if [ "$(finding_key "a.sh" "t")" = "$(finding_key "a.sh" "t" "extra")" ]; then ok; else
  fail_case "a third argument must not change the key; the key is file plus title"
fi

# --- shape ------------------------------------------------------------------
# Fixed width and hex, because it is embedded in an HTML comment marker inside
# a review comment body, and a key carrying a newline or a `-->` would forge or
# break that marker.
k="$(finding_key "a.sh" "a finding")"
if [ "${#k}" = "64" ]; then ok; else
  fail_case "the key must be a 64-character sha256, got ${#k}"
fi
case "$k" in
*[!0-9a-f]*) fail_case "the key must be hex only, got '$k'" ;;
*) ok ;;
esac
# A title containing marker syntax must not survive into the key.
k2="$(finding_key "a.sh" "a <!-- ai-review-key:deadbeef --> finding")"
case "$k2" in
*[!0-9a-f]*) fail_case "marker syntax in a title must not reach the key" ;;
*) ok ;;
esac

# --- deterministic ----------------------------------------------------------
# Across processes, not just within one: post-findings.sh and union.sh run in
# different jobs and must reach the same answer.
a="$(finding_key "a.sh" "a finding")"
b="$(bash -c ". '$repo_root/scripts/ai-review/finding-key.sh'; finding_key 'a.sh' 'a finding'")"
if [ "$a" = "$b" ]; then ok; else
  fail_case "the key must be stable across processes"
fi

# --- sourcing is SILENT and side-effect free --------------------------------
# It is sourced by scripts that then talk to the GitHub API. A file that did
# anything on load would do it inside those.
out="$(bash -c ". '$repo_root/scripts/ai-review/finding-key.sh'" 2>&1)"
if [ -z "$out" ]; then ok; else
  fail_case "sourcing must produce no output, got: $out"
fi

# --- post-findings.sh actually uses THIS definition -------------------------
# The whole reason the fragment exists. A copy left behind in the consumer
# would keep working until one of the two was edited.
if grep -q 'finding-key.sh' "$repo_root/scripts/ai-review/post-findings.sh" &&
  ! grep -q '^normalize_title()' "$repo_root/scripts/ai-review/post-findings.sh"; then ok; else
  fail_case "post-findings.sh must source the shared key rather than define its own"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
