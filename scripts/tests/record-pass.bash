#!/usr/bin/env bash
# Standalone test for scripts/ai-review/record-pass.sh.
# Run: bash scripts/tests/record-pass.bash
#
# The script writes the harness's own record of a pass. Two groups of assertion
# matter more than the rest:
#
#   - ACCEPTANCE IS REFUSED unless it is earned. Acceptance resets the round cap,
#     so anything that can record one cheaply can defeat the stop condition
#     without ever touching the cap's own code. Three separate refusals are
#     tested: a narrowed pass, a pass with accepted Majors, and one with no
#     reviewed-tree hash.
#   - THE HARNESS WRITES last-failure.txt, and it is CLEARED on acceptance.
#     A stale failure handed to the next pass sends it to re-solve a solved
#     problem, which is the most expensive way for a loop to waste a pass.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/record-pass.sh"

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
for tool in bash git jq sed sort wc tr cat printf head tail date awk shasum mkdir; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$bin/$tool"
done
# gh answers, so the acceptance row's CI count is exercised rather than
# defaulting to null through an absent binary.
cat >"$bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf 'sha-a\nsha-b\nsha-b\n'
GHSTUB
chmod +x "$bin/gh"

repo="$work/repo"
mkdir -p "$repo/scripts/ai-review" "$repo/.harnx/loop" "$repo/docs"
cp "$script" "$repo/scripts/ai-review/record-pass.sh"
# THE HELPER IS COPIED IN. Without it the acceptance row's CI count would be
# null because the SCRIPT is missing, not because gh is, and the assertion below
# would pass while never exercising the path it names.
cp "$repo_root/scripts/ai-review/ci-head-shas.sh" "$repo/scripts/ai-review/"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'gate\n' >"$repo/mise.toml"
printf 'gate\n' >"$repo/.pre-commit-config.yaml"
printf 'gate\n' >"$repo/docs/ai-review.md"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the first commit here'
git -C "$repo" branch -M feat-9-a-rung

loop="$repo/.harnx/loop"
log="$loop/passes.jsonl"

printf '[{"file":"a.sh","line":3,"severity":"Major","title":"a real problem"},{"file":"b.sh","severity":"nit","title":"tiny"}]' >"$work/open-major.json"
printf '[]' >"$work/open-clean.json"
printf '{"calls":2,"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":900,"cache_creation_input_tokens":77,"total_cost_usd":0.5,"prompt_sha":"pss","cli_version":"9.9.9","model_resolved":["claude-sonnet-5"]}' >"$work/sidecar.json"
printf 'gate said no\nline two\n' >"$work/gate.txt"

run() {
  (cd "$repo" && env PATH="$bin" "$@" bash scripts/ai-review/record-pass.sh >"$work/out" 2>&1)
}
last_row() { tail -1 "$log"; }

# --- 1. the outcome is required and validated --------------------------------
if run RECORD_PASS_OUTCOME=wobble; then
  fail_case "an unrecognised outcome must be refused"
else ok; fi
if (cd "$repo" && env PATH="$bin" bash scripts/ai-review/record-pass.sh >"$work/out" 2>&1); then
  fail_case "a missing outcome must be refused"
else ok; fi

# --- 2. an ordinary failing pass -------------------------------------------
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-major.json" \
  RECORD_PASS_RAW="$work/open-major.json" RECORD_PASS_SIDECAR="$work/sidecar.json" \
  RECORD_PASS_SECONDS=12 RECORD_PASS_GATE_TAIL="$work/gate.txt" || true
if [ "$(last_row | jq -r '[.type,.outcome,(.major|tostring),(.nit|tostring)] | join(" ")')" = "pass open 1 1" ]; then ok; else
  fail_case "a failing pass must record its severities, got $(last_row)"
fi

# --- 3. THE REGIME IS ON THE ROW ---------------------------------------------
# A finding count without the regime that produced it cannot be compared with
# anything, which is the whole reason for a second log rather than the old one.
if [ "$(last_row | jq -r '[.prompt_sha,.cli_version,(.model_resolved|join(",")),(.calls|tostring),(.total_cost_usd|tostring)] | join(" ")')" = "pss 9.9.9 claude-sonnet-5 2 0.5" ]; then ok; else
  fail_case "the row must carry the regime from the sidecar, got $(last_row)"
fi
if [ -n "$(last_row | jq -r '.gate_sha')" ] && [ "$(last_row | jq -r '.gate_sha')" != null ]; then ok; else
  fail_case "the row must carry a gate hash"
fi
# CACHE CREATION IS ON THE ROW TOO. Cache writes are billed at a premium over
# ordinary input, so a row without them cannot reconstruct its own cost from its
# own parts, and the sidecar has carried the number all along.
if [ "$(last_row | jq -r '.cache_creation_input_tokens')" = "77" ]; then ok; else
  fail_case "the row must carry cache creation tokens, got $(last_row | jq -r '.cache_creation_input_tokens')"
fi

# --- 4. THE GATE HASH MOVES WHEN A GATE-DEFINING FILE MOVES ------------------
# The point of the hash is that a result produced under one gate is visibly not
# comparable with one produced under another.
before="$(last_row | jq -r '.gate_sha')"
printf 'gate CHANGED\n' >"$repo/mise.toml"
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '.gate_sha')" != "$before" ]; then ok; else
  fail_case "changing a gate-defining file must change gate_sha"
fi
# ...and a DELETED one is recorded as absent rather than skipped, or a tree that
# lost a gate would hash identically to one that never had it.
after_change="$(last_row | jq -r '.gate_sha')"
rm -f "$repo/docs/ai-review.md"
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '.gate_sha')" != "$after_change" ]; then ok; else
  fail_case "deleting a gate-defining file must change gate_sha, not be skipped"
fi
printf 'gate\n' >"$repo/docs/ai-review.md"

# THE FINGERPRINT COVERS THIS SCRIPT ITSELF, which is not vanity: record-pass.sh
# decides what counts as an acceptance, and an acceptance resets the round cap.
# Weakening the refusals in it would change the meaning of every row it writes,
# and a fingerprint blind to that is worth little.
before_self="$(last_row | jq -r '.gate_sha')"
printf '\n# a change to this script\n' >>"$repo/scripts/ai-review/record-pass.sh"
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '.gate_sha')" != "$before_self" ]; then ok; else
  fail_case "changing record-pass.sh must change gate_sha; it defines what acceptance means"
fi
# Restored, so later cases are not run against a mutated copy.
cp "$script" "$repo/scripts/ai-review/record-pass.sh"

# --- 5. last-failure.txt IS WRITTEN BY THE HARNESS ---------------------------
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-major.json" \
  RECORD_PASS_GATE_TAIL="$work/gate.txt" || true
if grep -q 'a real problem' "$loop/last-failure.txt" &&
  grep -q 'gate said no' "$loop/last-failure.txt"; then ok; else
  fail_case "last-failure must carry the Major titles and the gate output, got: $(cat "$loop/last-failure.txt")"
fi
# Only Majors. A nit in the failure file competes for attention with the thing
# that actually blocked the pass.
if ! grep -q 'tiny' "$loop/last-failure.txt"; then ok; else
  fail_case "last-failure must not list nits"
fi

# --- 6. ACCEPTANCE IS REFUSED UNLESS EARNED ----------------------------------
# Each of these would otherwise reset the round cap, defeating the stop
# condition without touching the cap's own code.
run RECORD_PASS_OUTCOME=accepted RECORD_PASS_OPEN="$work/open-clean.json" \
  RECORD_PASS_TREE=treehash RECORD_PASS_NARROWED=one-file.sh || true
if [ "$(last_row | jq -r '.outcome')" = "open" ] && grep -q 'narrowed' "$work/out"; then ok; else
  fail_case "a narrowed pass must be refused acceptance by name, got $(last_row)"
fi
run RECORD_PASS_OUTCOME=accepted RECORD_PASS_OPEN="$work/open-major.json" \
  RECORD_PASS_TREE=treehash || true
if [ "$(last_row | jq -r '.outcome')" = "open" ] && grep -q 'accepted Major' "$work/out"; then ok; else
  fail_case "acceptance with open Majors must be refused, got $(last_row)"
fi
run RECORD_PASS_OUTCOME=accepted RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '.outcome')" = "open" ] && grep -q 'content-addressed' "$work/out"; then ok; else
  fail_case "acceptance with no tree hash must be refused, got $(last_row)"
fi
# None of the three may have written an acceptance row.
if [ "$(jq -s '[.[] | select(.type == "acceptance")] | length' "$log")" = "0" ]; then ok; else
  fail_case "a refused acceptance must not write an acceptance row"
fi

# --- 7. AN EARNED ACCEPTANCE ------------------------------------------------
run RECORD_PASS_OUTCOME=accepted RECORD_PASS_OPEN="$work/open-clean.json" \
  RECORD_PASS_SIDECAR="$work/sidecar.json" RECORD_PASS_TREE=abc123 || true
if [ "$(last_row | jq -r '[.type,.tree,(.ci_head_shas|tostring)] | join(" ")')" = "acceptance abc123 2" ]; then ok; else
  fail_case "an earned acceptance must record the tree and the CI count, got $(last_row)"
fi
# The pass row is written too, so a reader sees both what happened and that it
# was accepted.
if [ "$(tail -2 "$log" | head -1 | jq -r '.type')" = "pass" ]; then ok; else
  fail_case "an acceptance must still be preceded by its pass row"
fi
# CLEARED. A failure that has since been fixed must not be handed to the next
# pass.
if [ ! -s "$loop/last-failure.txt" ]; then ok; else
  fail_case "acceptance must clear last-failure.txt, got: $(cat "$loop/last-failure.txt")"
fi

# --- 8. the drafter's prompt and mode come from the snapshot -----------------
printf 'mode=build\nprompt_sha=drafter-sha\nat=2026-01-02T03:04:05Z\n' >"$loop/.pass-snapshot"
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '[.mode,.drafter_prompt_sha] | join(" ")')" = "build drafter-sha" ]; then ok; else
  fail_case "the row must carry the mode and the drafter prompt hash, got $(last_row)"
fi
# THE MODE CAN BE STALE, so when it was issued is carried beside it. The
# snapshot records the last `loop:prompt` invocation rather than a property of
# the review being recorded, so a review run outside any loop pass inherits
# whichever mode was asked for last. Observed on this branch: a full local
# review, run after a manual `loop:prompt plan`, recorded itself as a plan pass.
# The timestamp is what lets a reader see a mode that predates its own pass.
if [ "$(last_row | jq -r '.mode_at')" = "2026-01-02T03:04:05Z" ]; then ok; else
  fail_case "the row must carry when the mode was issued, got $(last_row | jq -r '.mode_at')"
fi
# A snapshot written before that field existed must give null, not a guess.
printf 'mode=build\nprompt_sha=drafter-sha\n' >"$loop/.pass-snapshot"
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '.mode_at')" = null ]; then ok; else
  fail_case "a snapshot with no timestamp must give mode_at null, got $(last_row | jq -r '.mode_at')"
fi
# A plan pass and a build pass are different regimes; the field exists so they
# are never averaged.
rm -f "$loop/.pass-snapshot"
run RECORD_PASS_OUTCOME=open RECORD_PASS_OPEN="$work/open-clean.json" || true
if [ "$(last_row | jq -r '.mode')" = null ]; then ok; else
  fail_case "with no snapshot the mode must be null, not guessed"
fi

# --- 9. a missing or corrupt sidecar is survivable ---------------------------
# The engine writes one on every exit, but a caller that did not pass its path
# must still produce a row rather than crash the pass that already happened.
run RECORD_PASS_OUTCOME=crashed RECORD_PASS_OPEN="$work/open-clean.json" \
  RECORD_PASS_SIDECAR="$work/nonexistent.json" || true
if [ "$(last_row | jq -r '[.outcome,(.calls|tostring)] | join(" ")')" = "crashed 0" ]; then ok; else
  fail_case "a missing sidecar must give zeros, not a crash, got $(last_row)"
fi
printf 'not json at all' >"$work/bad.json"
run RECORD_PASS_OUTCOME=crashed RECORD_PASS_OPEN="$work/open-clean.json" \
  RECORD_PASS_SIDECAR="$work/bad.json" || true
if [ "$(last_row | jq -r '.calls')" = "0" ]; then ok; else
  fail_case "a corrupt sidecar must give zeros, not a crash"
fi

# --- 10. every row is valid JSON ---------------------------------------------
# The file is appended to by more than one script and read by the round cap; one
# malformed line would make the cap unreadable rather than merely wrong.
if jq -s -e 'length > 0 and all(.type != null)' "$log" >/dev/null; then ok; else
  fail_case "every row must be valid JSON with a type"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
