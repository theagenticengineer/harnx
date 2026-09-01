#!/usr/bin/env bash
# Standalone test for scripts/ai-review/probe.sh.
# Run: bash scripts/tests/probe.bash
#
# WHAT THIS PROTECTS. The probe decides whether a review happens at all. Every
# way it can be wrong is a way the required check goes green over a pull
# request nobody read:
#
#   dormant when it should be armed   no reviewer runs, no findings, no
#                                     threads, green gate.
#   configured with an empty list     the matrix fans out to zero jobs, which
#                                     downstream is indistinguishable from a
#                                     matrix whose jobs all passed. This is why
#                                     `configured` and `reviewers` are ONE
#                                     decision and are asserted together here.
#   armed on a fork                   the credential hard-fail then fires on a
#                                     contributor with no way to fix it, on
#                                     every fork pull request, forever.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/probe.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh_out="$work/out"
log="$work/log.txt"

# $1 AI_REVIEWERS, $2 head repository. REPOSITORY is always this repo.
# `$#`, not `${2:-o/r}`: a deleted fork leaves head_repository EMPTY, and a
# default would have silently substituted this repository's name and tested the
# wrong branch entirely.
run() {
  local head="o/r"
  [ "$#" -lt 2 ] || head="$2"
  : >"$gh_out"
  set +e
  env AI_REVIEWERS="$1" HEAD_REPOSITORY="$head" REPOSITORY=o/r \
    GITHUB_OUTPUT="$gh_out" bash "$script" >"$log" 2>&1
  local status=$?
  set -e
  printf '%s' "$status"
}
out_of() { sed -n "s/^$1=//p" "$gh_out"; }

# Every case asserts BOTH outputs. They are one decision, and the state that
# would fan out to zero jobs is exactly "configured=true with an empty list".
# The reviewers output is objects, so slugs are compared as a compact list and
# the richer fields are asserted separately below.
slugs_of() { out_of reviewers | jq -c '[.[].slug]' 2>/dev/null || printf 'UNPARSEABLE'; }
expect() {
  local label="$1" want_cfg="$2" want_rev="$3"
  if [ "$(out_of configured)" = "$want_cfg" ] && [ "$(slugs_of)" = "$want_rev" ]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected configured=$want_cfg slugs=$want_rev, got configured=$(out_of configured) slugs=$(slugs_of)"
  fi
}

# --- armed ---------------------------------------------------------------
if [ "$(run '["claude"]')" = "0" ]; then ok; else fail_case "an armed probe must exit 0: $(cat "$log")"; fi
expect "one reviewer" true '["claude"]'
run '["claude","gemini"]' >/dev/null
expect "two reviewers" true '["claude","gemini"]'
# Sorted and deduplicated, so the matrix is stable across runs and a repeated
# slug does not run the same reviewer twice.
run '["gemini","claude","gemini"]' >/dev/null
expect "sorted and deduplicated" true '["claude","gemini"]'

# --- dormant, and never a hard failure ---------------------------------------
# An unarmed repository must not carry a red required check it cannot clear.
# Each of these is a legitimate state, so each exits 0.
for spec in 'empty-string:' 'empty-array:[]' 'malformed:not json' 'object:{"a":1}' 'all-bad-slugs:["Claude","9x","x_y"]'; do
  label="${spec%%:*}"
  value="${spec#*:}"
  if [ "$(run "$value")" = "0" ]; then ok; else fail_case "$label must exit 0, not fail: $(cat "$log")"; fi
  expect "$label" false '[]'
done

# TRULY UNSET, which is a different code path from an empty string and is the
# one an unarmed repository actually takes: `vars.AI_REVIEWERS` interpolates to
# nothing and the variable is absent, not empty. The case above was labelled
# "unset" and tested an empty value, because `run()` always passes
# `AI_REVIEWERS=`, so the path this repository is in before the registry is
# armed was never exercised at all.
: >"$gh_out"
set +e
env -u AI_REVIEWERS HEAD_REPOSITORY=o/r REPOSITORY=o/r GITHUB_OUTPUT="$gh_out" \
  bash "$script" >"$log" 2>&1
unset_status=$?
set -e
if [ "$unset_status" = "0" ]; then ok; else
  fail_case "an absent AI_REVIEWERS must exit 0, not fail: $(cat "$log")"
fi
expect "absent variable" false '[]'
if grep -q '::notice::' "$log"; then ok; else
  fail_case "an absent registry is the ordinary unarmed state and must say so: $(cat "$log")"
fi
# A malformed value is a typo somebody made while trying to arm a reviewer, so
# it warns rather than passing in silence.
run 'not json' >/dev/null
if grep -q '::warning::' "$log"; then ok; else
  fail_case "a malformed registry must warn: $(cat "$log")"
fi
# And the warning must show the value, or the operator cannot see their typo.
if grep -q 'not json' "$log"; then ok; else
  fail_case "the malformed warning must quote the offending value"
fi
# An UNSET registry is the ordinary unarmed state, so a notice rather than a
# warning: nobody made a mistake.
run '' >/dev/null
if grep -q '::notice::' "$log" && ! grep -q '::warning::' "$log"; then ok; else
  fail_case "an unset registry is a notice, not a warning: $(cat "$log")"
fi

# --- valid slugs are kept, invalid ones dropped ------------------------------
# The slug is what uppercases into a secret name and resolves an engine path,
# so anything outside ^[a-z][a-z0-9-]*$ cannot do either.
run '["claude","Bad","9x","code-rabbit","x_y",""]' >/dev/null
expect "only valid slugs survive" true '["claude","code-rabbit"]'
# A non-string element must not crash the parse or leak through.
run '["claude",7,null,{"a":1}]' >/dev/null
expect "non-string elements are dropped" true '["claude"]'

# --- THE FORK CARVE-OUT ------------------------------------------------------
# Decided HERE, before any matrix exists, and the ordering is the point: no leg
# runs, so the missing-credential hard failure can never fire on a fork
# contributor who has no way to fix it.
if [ "$(run '["claude"]' 'someone-else/r')" = "0" ]; then ok; else
  fail_case "a fork pull request must be dormant, not a failure: $(cat "$log")"
fi
expect "fork" false '[]'
if grep -q '::notice::' "$log" && grep -q 'someone-else/r' "$log"; then ok; else
  fail_case "the fork notice must name the fork: $(cat "$log")"
fi
# A DELETED fork leaves head_repository null. The inequality reads true and
# lands on dormant, which is the safe direction.
run '["claude"]' '' >/dev/null
expect "deleted fork" false '[]'
# The fork test must win even when the registry is perfectly valid, which is
# the whole reason it is checked first.
run '["claude","gemini"]' 'someone-else/r' >/dev/null
expect "fork beats a valid registry" false '[]'

# --- required inputs ----------------------------------------------------------
for missing in REPOSITORY GITHUB_OUTPUT; do
  set +e
  (env AI_REVIEWERS='["claude"]' HEAD_REPOSITORY=o/r REPOSITORY=o/r \
    GITHUB_OUTPUT="$gh_out" "$missing=" bash "$script") >"$log" 2>&1
  st=$?
  set -e
  if [ "$st" -ne 0 ]; then ok; else fail_case "$missing must be required"; fi
done

# --- the two outputs are never written apart ---------------------------------
# Asserted at the source: every exit path goes through one emit, so there is no
# branch that could publish configured without reviewers or the reverse.
probe_code="$(sed 's/[[:space:]]*#.*$//' "$script")"
# Exactly two writes to the step-output file, both inside one function, so
# there is no branch that could publish `configured` without `reviewers` or the
# reverse. That state, configured with an empty list, is the one that fans out
# to zero jobs and reports success.
# shellcheck disable=SC2016  # the literal text being searched for, not an expansion.
if [ "$(printf '%s' "$probe_code" | grep -c '>>"\$GITHUB_OUTPUT"')" = "2" ]; then ok; else
  fail_case "the two outputs must be written in exactly one place each, inside emit()"
fi
# And several exit paths must route through it, or the single write is single
# only because there is one branch.
if [ "$(printf '%s' "$probe_code" | grep -cE '^[[:space:]]*emit ')" -ge 4 ]; then ok; else
  fail_case "every exit path must publish through emit(); found $(printf '%s' "$probe_code" | grep -cE '^[[:space:]]*emit ')"
fi

# --- each reviewer carries its secret name and its engine path ---------------
# GitHub Actions expressions have no uppercase function, so a matrix leg cannot
# derive AI_REVIEW_ENGINE_TOKEN_CLAUDE from `claude` on its own. The only other
# way is reading `${{ toJSON(secrets) }}` in the leg and picking the key out,
# which materialises every secret the job can see, the App private key
# included, into one string inside the job that runs the review engine. Doing
# the mapping here is what keeps the leg naming exactly one secret.
run '["claude"]' >/dev/null
if [ "$(out_of reviewers | jq -r '.[0].secret')" = "AI_REVIEW_ENGINE_TOKEN_CLAUDE" ]; then ok; else
  fail_case "a reviewer must carry its secret name, got $(out_of reviewers | jq -r '.[0].secret')"
fi
if [ "$(out_of reviewers | jq -r '.[0].engine')" = "scripts/ai-review/claude.sh" ]; then ok; else
  fail_case "a reviewer must carry the engine path the registry resolves"
fi
# A hyphenated slug must name a LEGAL secret: `-` is not valid in a secret
# name, so it maps to `_`.
run '["code-rabbit"]' >/dev/null
if [ "$(out_of reviewers | jq -r '.[0].secret')" = "AI_REVIEW_ENGINE_TOKEN_CODE_RABBIT" ]; then ok; else
  fail_case "a hyphenated slug must map to a legal secret name, got $(out_of reviewers | jq -r '.[0].secret')"
fi
if [ "$(out_of reviewers | jq -r '.[0].engine')" = "scripts/ai-review/code-rabbit.sh" ]; then ok; else
  fail_case "the engine path keeps the slug verbatim, hyphen included"
fi
# Dormant states publish an empty array, never objects, so `fromJSON` in the
# matrix cannot produce a leg.
run '' >/dev/null
if [ "$(out_of reviewers)" = "[]" ]; then ok; else
  fail_case "a dormant probe must publish an empty array, got $(out_of reviewers)"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
