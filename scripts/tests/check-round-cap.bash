#!/usr/bin/env bash
# Standalone test for scripts/ai-review/check-round-cap.sh.
# Run: bash scripts/tests/check-round-cap.bash
#
# The cap is the loop's only stop. Everything else in this machinery makes a
# pass cheaper and better recorded, which makes it easier to run one more pass
# on a problem that is not going to be solved by one more pass.
#
# THE ARITHMETIC IS THE POINT, and three of its properties are the ones that
# would fail silently:
#
#   - counting SINCE THE LAST ACCEPTANCE rather than for the branch's lifetime.
#     A lifetime counter has one exit: after the first breach every push tolls
#     forever, a green result restores nothing, and the only way forward is to
#     bypass the gate.
#   - the BASELINE, without which a branch with history installs pre-spent while
#     a fresh branch doing identical work starts at zero.
#   - the CI term OMITTED rather than guessed when either end is unknown. A
#     guess moves the stop condition by a number nobody can check.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/check-round-cap.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

bin="$work/bin"
mkdir -p "$bin"
for tool in bash git jq sed sort wc tr cat printf head tail date awk shasum grep mkdir; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$bin/$tool"
done

repo="$work/repo"
mkdir -p "$repo/scripts/ai-review" "$repo/.harnx/loop"
cp "$script" "$repo/scripts/ai-review/check-round-cap.sh"
# COPIED IN, because without it the CI term would be omitted for the wrong
# reason and every fallback assertion below would pass while never exercising
# the path it names.
cp "$repo_root/scripts/ai-review/ci-head-shas.sh" "$repo/scripts/ai-review/"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'one\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the first commit here'
git -C "$repo" branch -M feat-9-a-rung

loop="$repo/.harnx/loop"
log="$loop/passes.jsonl"
handoff="$loop/handoff.md"

# `[ "$n" -gt 0 ]` GUARDS THE LOOP, and it is not defensive padding: BSD `seq`,
# which is what macOS ships, COUNTS DOWN when the first argument exceeds the
# second, so `seq 1 0` prints "1 0" rather than nothing. Without the guard,
# gh_returns 0 emitted two SHAs, and the cap case below read 17 rounds where it
# had set up 15. GNU seq prints nothing, so this would have passed in CI and
# failed only on a developer machine.
gh_returns() {
  local n="$1" i
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$n" -gt 0 ]; then
      for i in $(seq 1 "$n"); do printf 'printf "sha%%s\\\\n" %s\n' "$i"; done
    fi
  } >"$bin/gh"
  chmod +x "$bin/gh"
}
gh_fails() {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/gh"
  chmod +x "$bin/gh"
}

rows() { : >"$log"; }
add_pass() {
  local n="${1:-1}" i
  # Same BSD `seq` guard as above; `add_pass 0` would otherwise add two rows.
  [ "$n" -gt 0 ] || return 0
  for i in $(seq 1 "$n"); do
    printf '%s\n' '{"type":"pass","rung":"feat-9-a-rung","outcome":"open"}' >>"$log"
  done
}
add_baseline() { printf '{"type":"baseline","rung":"feat-9-a-rung","ci_head_shas":%s}\n' "$1" >>"$log"; }
add_acceptance() { printf '{"type":"acceptance","rung":"feat-9-a-rung","tree":"t","ci_head_shas":%s}\n' "$1" >>"$log"; }

run() { (cd "$repo" && env PATH="$bin" "$@" bash scripts/ai-review/check-round-cap.sh >"$work/out" 2>&1); }

# --- 1. no log is not a breach -----------------------------------------------
# A contributor who has never run the loop has spent no rounds. Refusing their
# push would make this gate the first thing anybody turns off.
gh_returns 3
rm -f "$log"
if run; then ok; else
  fail_case "a missing log must not block, got: $(cat "$work/out")"
fi

# --- 2. under the cap, it passes and reports the count ------------------------
rows
add_baseline 3
add_pass 4
if run && grep -q '4/15' "$work/out"; then ok; else
  fail_case "under the cap it must pass and name the count, got: $(cat "$work/out")"
fi

# --- 3. THE BASELINE IS SUBTRACTED -------------------------------------------
# CI is at 3 and the baseline recorded 3, so CI has contributed nothing. Without
# the baseline this branch would install pre-spent at 3.
rows
add_baseline 3
if run && grep -q '0/15' "$work/out"; then ok; else
  fail_case "the baseline must be subtracted, got: $(cat "$work/out")"
fi

# --- 4. CI PUSHES SINCE THE RESET COUNT --------------------------------------
gh_returns 10
rows
add_baseline 3
add_pass 2
if run && grep -q '9/15' "$work/out"; then ok; else
  fail_case "rounds must be local passes plus CI pushes since the reset, got: $(cat "$work/out")"
fi

# --- 5. ACCEPTANCE IS THE RESET ----------------------------------------------
# The property that keeps this a cap rather than a wall. The rows before the
# acceptance are far past the cap; after it, the count starts again.
rows
add_baseline 0
add_pass 30
add_acceptance 10
add_pass 1
if run && grep -q '1/15' "$work/out"; then ok; else
  fail_case "an acceptance must reset the count, got: $(cat "$work/out")"
fi
if grep -q 'since the last acceptance' "$work/out"; then ok; else
  fail_case "it must say what it counted from, got: $(cat "$work/out")"
fi

# --- 6. THE LATEST acceptance wins -------------------------------------------
rows
add_baseline 0
add_acceptance 5
add_pass 20
add_acceptance 10
add_pass 2
if run && grep -q '2/15' "$work/out"; then ok; else
  fail_case "the most recent acceptance must be the reset point, got: $(cat "$work/out")"
fi

# --- 7. ANOTHER RUNG'S ROWS ARE NOT COUNTED ----------------------------------
rows
add_baseline 10
printf '%s\n' '{"type":"pass","rung":"feat-99-elsewhere","outcome":"open"}' >>"$log"
printf '%s\n' '{"type":"pass","rung":"feat-99-elsewhere","outcome":"open"}' >>"$log"
add_pass 1
if run && grep -q '1/15' "$work/out"; then ok; else
  fail_case "another branch's passes must not count, got: $(cat "$work/out")"
fi

# --- 8. THE PUSHED REF, NOT HEAD ---------------------------------------------
# Keying off HEAD would let a capped branch push a different one from the same
# checkout and escape its own count.
rows
add_baseline 10
add_pass 20
printf '{"type":"baseline","rung":"feat-77-other","ci_head_shas":10}\n' >>"$log"
if run PRE_COMMIT_LOCAL_BRANCH=feat-77-other && grep -q '0/15' "$work/out"; then ok; else
  fail_case "the count must key off the pushed ref, got: $(cat "$work/out")"
fi
if run; then
  fail_case "with no override, the current branch is over the cap and must block"
else ok; fi

# --- 9. THE CI TERM IS OMITTED, NOT GUESSED ----------------------------------
# Both directions: gh unreadable, and a reset point that recorded no count.
gh_fails
rows
add_baseline 3
add_pass 4
if run && grep -q '4/15' "$work/out" && grep -q 'CI could not be read' "$work/out"; then ok; else
  fail_case "an unreadable CI must count 0 and say so, got: $(cat "$work/out")"
fi
gh_returns 10
rows
printf '{"type":"baseline","rung":"feat-9-a-rung","ci_head_shas":null}\n' >>"$log"
add_pass 4
if run && grep -q '4/15' "$work/out" && grep -q 'recorded no CI count' "$work/out"; then ok; else
  fail_case "a null baseline count must omit the CI term and say so, got: $(cat "$work/out")"
fi

# --- 10. A BACKWARDS CI COUNT CANNOT BUY BACK ROUNDS -------------------------
# Deleted runs or a renamed branch. Allowed to subtract, it would silently
# refund rounds that were spent.
gh_returns 2
rows
add_baseline 10
add_pass 14
if run && grep -q '14/15' "$work/out" && grep -q 'went backwards' "$work/out"; then ok; else
  fail_case "a backwards CI count must clamp to 0 and say so, got: $(cat "$work/out")"
fi

# --- 11. AT THE CAP, IT BLOCKS -----------------------------------------------
gh_returns 0
rows
add_baseline 0
add_pass 15
if run; then
  fail_case "at the cap it must block"
else ok; fi
if grep -q '15 of 15' "$work/out"; then ok; else
  fail_case "the refusal must name the count, got: $(cat "$work/out")"
fi
# It must point at the exit rather than only at the wall.
if grep -q 'ai-review:local' "$work/out"; then ok; else
  fail_case "the refusal must name the way out, got: $(cat "$work/out")"
fi

# --- 12. THE RELEASE IS A REPORT ---------------------------------------------
# Every cheap release mechanism is a mechanism for not writing the report.
printf 'rung: feat-9-a-rung\nrounds: 15\n\nTried X and Y. Z is still unknown.\n' >"$handoff"
if run; then ok; else
  fail_case "a complete handoff must release the cap, got: $(cat "$work/out")"
fi
if [ "$(tail -1 "$log" | jq -r '.type')" = "escalation" ] &&
  [ "$(tail -1 "$log" | jq -r '.handoff_sha256')" = "$(shasum -a 256 "$handoff" | awk '{print $1}')" ]; then ok; else
  fail_case "the release must record an escalation row with the report's hash, got $(tail -1 "$log")"
fi

# --- 13. A HOLLOW OR STALE REPORT DOES NOT RELEASE ---------------------------
# The header lines alone are the gate talking to itself.
printf 'rung: feat-9-a-rung\nrounds: 15\n\n\n' >"$handoff"
if run; then
  fail_case "a report with no body must not release the cap"
else ok; fi
if grep -q 'no body' "$work/out"; then ok; else
  fail_case "it must say the body is missing, got: $(cat "$work/out")"
fi
# A report from a different stop, with a stale count.
printf 'rung: feat-9-a-rung\nrounds: 9\n\nSomething from an earlier stop.\n' >"$handoff"
if run; then
  fail_case "a report whose round count does not match must not release the cap"
else ok; fi
# A report about a different rung.
printf 'rung: feat-77-other\nrounds: 15\n\nWrong branch entirely.\n' >"$handoff"
if run; then
  fail_case "a report naming another rung must not release the cap"
else ok; fi
rm -f "$handoff"

# --- 13b. A BRANCH NAME IS COMPARED, NOT MATCHED AS A PATTERN ----------------
# The release check used to splice `$rung` into a grep BRE, so a regex
# metacharacter in a branch name was matched AS a metacharacter. It fails both
# ways on the gate that guards the loop's only escape hatch: a handoff naming a
# slightly different rung could satisfy it, and a correctly-worded one could
# fail to match. Found by this pipeline reviewing this branch.
git -C "$repo" branch -M release-v1.2.x
# gh MUST be pinned to zero here, or the CI term carries over from the previous
# case and the count lands somewhere other than 15. The release check only runs
# once the cap is REACHED, so a wrong count means these cases pass without ever
# reaching the code they are about.
gh_returns 0
rows
# THE ROWS MUST NAME THE RENAMED RUNG. add_baseline and add_pass hardcode
# feat-9-a-rung, so writing them after a rename leaves the counter with no rows
# for the current branch, the cap is never reached, and the release check these
# cases exist to exercise is never reached either. They would pass while testing
# nothing.
printf '{"type":"baseline","rung":"release-v1.2.x","ci_head_shas":0}\n' >>"$log"
for _ in $(seq 1 15); do
  printf '%s\n' '{"type":"pass","rung":"release-v1.2.x","outcome":"open"}' >>"$log"
done
# `release-v1X2Ex` differs from `release-v1.2.x` only where the dots are, so it
# matches the old wildcard reading and must NOT satisfy the check now.
printf 'rung: release-v1X2Ex\nrounds: 15\n\nA report about a different branch.\n' >"$handoff"
if run; then
  fail_case "a rung matching only as a regex wildcard must not release the cap"
else ok; fi
# ...and the real name still does.
printf 'rung: release-v1.2.x\nrounds: 15\n\nA real report about this branch.\n' >"$handoff"
if run; then ok; else
  fail_case "the correct rung must still release the cap, got: $(cat "$work/out")"
fi
# The label may be written either case; the branch name may not.
printf 'Rung: release-v1.2.x\nRounds: 15\n\nA real report.\n' >"$handoff"
if run; then ok; else
  fail_case "the header label must stay case-insensitive, got: $(cat "$work/out")"
fi
printf 'rung: RELEASE-V1.2.X\nrounds: 15\n\nA real report.\n' >"$handoff"
if run; then
  fail_case "the branch name must be compared case-sensitively"
else ok; fi
rm -f "$handoff"
git -C "$repo" branch -M feat-9-a-rung

# --- 14. AN UNREADABLE COUNTER IS NOT AN EMPTY ONE ---------------------------
# Treating corrupt state as "nothing counted" would silently disable the stop.
printf 'not json\n' >"$log"
if run; then
  fail_case "an unreadable log must not be treated as an empty one"
else ok; fi
if grep -q 'unreadable counter' "$work/out"; then ok; else
  fail_case "it must say why it refused, got: $(cat "$work/out")"
fi

# --- 15. THE CAP HAS NO ENVIRONMENT OVERRIDE ---------------------------------
# The repository's other knobs use ${VAR:-default}. This one must not: an env
# var is a weakening path that leaves no trace, and a loop that hit the cap
# could export a bigger one and keep going.
if ! grep -qE 'CAP="?\$\{' "$script" && grep -qE '^CAP=[0-9]+$' "$script"; then ok; else
  fail_case "the cap must be a constant with no environment override"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
