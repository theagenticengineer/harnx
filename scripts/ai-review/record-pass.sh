#!/usr/bin/env bash
# record-pass.sh — write one row to .harnx/loop/passes.jsonl for the pass that
# just finished, and write .harnx/loop/last-failure.txt when it did not pass.
#
# THE HARNESS WRITES BOTH FILES. THE WORKER WRITES NEITHER. If the worker wrote
# its own account of its failure, the loop would feed back the worker's
# narrative of what went wrong instead of the gate's verdict, and a worker that
# misunderstood a failure would be handed its own misunderstanding as the
# authoritative record of it. The gate's output is the input to the next pass.
#
# A NEW FILE, NOT A MIGRATION OF .harnx/ai-review-pass-log.jsonl. That log's
# existing rows carry no model, no prompt hash and no gate hash, so they cannot
# be compared with rows written now: they were produced under a regime nobody
# recorded. Folding them in would produce one series that looks continuous and
# is not, which is worse than two series that are honestly separate. The old log
# is untouched and still renders the convergence table.
#
# THE REGIME FINGERPRINT is why a row is worth keeping at all. "Pass 12 found
# three Majors" means nothing on its own; it means something next to which
# prompt, which model, which CLI and which gate produced it. A row carries:
#
#   prompt_sha         the ENGINE's review instruction, hashed before the nonce
#                      is substituted (from the usage sidecar)
#   drafter_prompt_sha the LOOP's prompt for this pass (from the snapshot)
#   mode               plan or build; different regimes, never averaged
#   mode_at            when that mode was issued, because it can be stale
#   model_resolved     what actually ran, not the alias asked for
#   cli_version        what actually ran, not what mise.toml pins
#   gate_sha           over the files that DEFINE what the gate enforces
#
# Env:
#   RECORD_PASS_OUTCOME   required; one of accepted|open|crashed|refused.
#   RECORD_PASS_OPEN      optional; path to the ACCEPTED findings array (after
#                         the dismissal ledger has been applied).
#   RECORD_PASS_RAW       optional; path to the RAW findings array, before it.
#   RECORD_PASS_SIDECAR   optional; path to the engine's usage sidecar.
#   RECORD_PASS_SECONDS   optional; wall-clock seconds for the pass.
#   RECORD_PASS_TREE      optional; the reviewed tree hash. Required to accept.
#   RECORD_PASS_NARROWED  optional; non-empty if the pass reviewed one file.
#   RECORD_PASS_GATE_TAIL optional; path to gate output; its tail becomes the
#                         body of last-failure.txt.
set -euo pipefail

: "${RECORD_PASS_OUTCOME:?RECORD_PASS_OUTCOME is required}"
case "$RECORD_PASS_OUTCOME" in
accepted | open | crashed | refused) ;;
*)
  echo "record-pass: RECORD_PASS_OUTCOME must be accepted|open|crashed|refused, got '$RECORD_PASS_OUTCOME'." >&2
  exit 2
  ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

loop_dir=".harnx/loop"
mkdir -p "$loop_dir"
log="$loop_dir/passes.jsonl"

# THE FILES THAT DEFINE WHAT THE GATE ENFORCES, in ONE named array so there is a
# single place to look and a single place to change. A result produced under one
# gate is not comparable with a result produced under another, and the whole
# point of recording a hash is that the incomparability is visible rather than
# inferred later from a commit log.
#
# The list is of DEFINITIONS, not of everything the review touches: the hooks
# that run, the tasks that run them, the engine that asks the questions, the
# script that decides the verdict, the gate that blocks the push, and the
# contract a human reads. A script that merely helps (pagination, diff
# extraction) can change without changing what passes.
# THE RULE FOR MEMBERSHIP, so the next addition is a decision rather than a
# guess: a file belongs here if changing it can change WHETHER A PASS IS
# ACCEPTED or WHETHER A PUSH IS ALLOWED. That is what makes two results
# comparable or not, which is the only question gate_sha exists to answer.
#
# record-pass.sh is on the list, and its own presence is not vanity: it decides
# what counts as an acceptance, and an acceptance is what resets the round cap.
# Weakening the refusals in this very file would silently change the meaning of
# every row it writes, and a fingerprint blind to that is worth little.
#
# TWO ENTRIES ARE HERE BECAUSE THE RULE PUT THEM HERE, not because they looked
# like gates. ai-review-local.sh writes the reviewed-tree marker the push gate
# reads and chooses the outcome this script records, so it decides both halves
# of the rule at once. ci-head-shas.sh produces the number the round cap
# subtracts, so changing it changes how many rounds a branch has left. Neither
# is a "check" by name, and both were missed on the first pass for exactly that
# reason; the rule caught them where a list of things-called-checks would not.
GATE_FILES=(
  .pre-commit-config.yaml
  mise.toml
  docs/ai-review.md
  scripts/ai-review/review-engine.sh
  scripts/ai-review/evaluate-gate.sh
  scripts/ai-review/check-locally-reviewed.sh
  scripts/ai-review/check-round-cap.sh
  scripts/ai-review/ci-head-shas.sh
  scripts/ai-review/record-pass.sh
  scripts/mise/ai-review-local.sh
  scripts/check-paired-tests.sh
)

# A MISSING FILE IS RECORDED AS MISSING, not skipped. Skipping it would make a
# tree that lost a gate hash identically to a tree that never had one, which is
# the single most important difference this hash exists to show. Each entry is
# "path:hash" or "path:ABSENT", so the position of every file is fixed and
# adding one to the array changes the hash deliberately rather than by accident.
gate_sha() {
  local f h
  for f in "${GATE_FILES[@]}"; do
    if [ -f "$f" ]; then
      h="$(shasum -a 256 "$f" | awk '{print $1}')"
    else
      h=ABSENT
    fi
    printf '%s:%s\n' "$f" "$h"
  done | shasum -a 256 | awk '{print $1}'
}

snapshot="$loop_dir/.pass-snapshot"
snap_field() {
  [ -f "$snapshot" ] || return 0
  sed -n "s/^$1=//p" "$snapshot" | head -1
}

sidecar="${RECORD_PASS_SIDECAR:-}"
sidecar_json='{}'
if [ -n "$sidecar" ] && [ -f "$sidecar" ] &&
  jq -e 'type == "object"' "$sidecar" >/dev/null 2>&1; then
  sidecar_json="$(jq -c '.' "$sidecar")"
fi

count_sev() {
  local path="$1" sev="$2"
  if [ -n "$path" ] && [ -f "$path" ] && jq -e 'type == "array"' "$path" >/dev/null 2>&1; then
    jq --arg s "$sev" '[.[] | select(.severity == $s)] | length' "$path"
  else
    printf '0'
  fi
}

open_path="${RECORD_PASS_OPEN:-}"
raw_path="${RECORD_PASS_RAW:-}"
majors="$(count_sev "$open_path" Major)"

# A NARROWED PASS CANNOT BE AN ACCEPTANCE, and it is refused BY NAME rather than
# quietly downgraded. Acceptance means "this tree was reviewed"; a pass that saw
# one file has not reviewed the tree, and recording it as one would mark
# unreviewed code reviewed with nothing afterwards to say otherwise. The same
# rule ai-review-local.sh already applies to the push gate.
outcome="$RECORD_PASS_OUTCOME"
if [ "$outcome" = accepted ] && [ -n "${RECORD_PASS_NARROWED:-}" ]; then
  echo "record-pass: REFUSING to record an acceptance for a narrowed pass; it reviewed one file, not the tree." >&2
  outcome=open
fi
if [ "$outcome" = accepted ] && [ "$majors" -gt 0 ]; then
  echo "record-pass: REFUSING to record an acceptance with $majors accepted Major finding(s)." >&2
  outcome=open
fi
if [ "$outcome" = accepted ] && [ -z "${RECORD_PASS_TREE:-}" ]; then
  echo "record-pass: REFUSING to record an acceptance with no reviewed-tree hash; acceptance is content-addressed." >&2
  outcome=open
fi

rung="$(git rev-parse --abbrev-ref HEAD)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -cn \
  --arg rung "$rung" --arg at "$now" --arg outcome "$outcome" \
  --arg mode "$(snap_field mode)" \
  --arg mode_at "$(snap_field at)" \
  --arg dsha "$(snap_field prompt_sha)" \
  --arg gsha "$(gate_sha)" \
  --arg narrowed "${RECORD_PASS_NARROWED:-}" \
  --argjson usage "$sidecar_json" \
  --argjson major "$majors" \
  --argjson minor "$(count_sev "$open_path" Minor)" \
  --argjson nit "$(count_sev "$open_path" nit)" \
  --argjson major_raw "$(count_sev "$raw_path" Major)" \
  --argjson seconds "${RECORD_PASS_SECONDS:-0}" \
  '{
    type: "pass", rung: $rung, at: $at, outcome: $outcome,
    mode: (if $mode == "" then null else $mode end),
    # WHEN THE MODE WAS ISSUED, and it is recorded because the mode can lie.
    # The snapshot holds the LAST `loop:prompt` invocation, not a property of
    # the review being recorded, so a review run outside any loop pass inherits
    # whichever mode was asked for last. Measured on this branch: a full local
    # review, run after a manual `loop:prompt plan`, recorded itself as a plan
    # pass. Nothing here can distinguish the two, so the timestamp is carried
    # and a reader comparing it with `at` can see a mode that predates its pass.
    # Recorded rather than prevented, the same treatment prompt drift gets.
    mode_at: (if $mode_at == "" then null else $mode_at end),
    narrowed: ($narrowed != ""),
    major: $major, minor: $minor, nit: $nit, major_raw: $major_raw,
    seconds: $seconds,
    prompt_sha: ($usage.prompt_sha // null),
    drafter_prompt_sha: (if $dsha == "" then null else $dsha end),
    model_resolved: ($usage.model_resolved // []),
    cli_version: ($usage.cli_version // null),
    gate_sha: $gsha,
    calls: ($usage.calls // 0),
    input_tokens: ($usage.input_tokens // 0),
    output_tokens: ($usage.output_tokens // 0),
    cache_read_input_tokens: ($usage.cache_read_input_tokens // 0),
    # CACHE CREATION IS CARRIED TOO, and its absence was a real gap rather than
    # an omission of a field nobody reads. Cache writes are billed at a premium
    # over ordinary input, so a row without them cannot reconstruct its own cost
    # from its own parts, and the sidecar this row is built from has recorded
    # the number all along.
    cache_creation_input_tokens: ($usage.cache_creation_input_tokens // 0),
    total_cost_usd: ($usage.total_cost_usd // 0)
  }' >>"$log"

failure="$loop_dir/last-failure.txt"
if [ "$outcome" = accepted ]; then
  # THE ACCEPTANCE ROW IS THE RESET for the round cap, which counts since the
  # last one. It carries the CI count at this moment so the cap can subtract it
  # later; null when gh cannot be read, and the cap says so when it falls back.
  ci="$(bash scripts/ai-review/ci-head-shas.sh "$rung" 2>/dev/null || true)"
  [ -n "$ci" ] || ci=null
  jq -cn --arg rung "$rung" --arg at "$now" --arg tree "$RECORD_PASS_TREE" \
    --argjson ci "$ci" \
    '{type:"acceptance", rung:$rung, at:$at, tree:$tree, ci_head_shas:$ci}' >>"$log"
  # CLEARED, not left in place. The next pass reads this file first; handing it
  # a failure that has since been fixed would send it to re-solve a solved
  # problem, which is the most expensive way for a loop to waste a pass.
  : >"$failure"
  echo "record-pass: acceptance recorded for tree $RECORD_PASS_TREE."
else
  {
    printf 'The last pass did not pass. Outcome: %s (rung %s, %s)\n' "$outcome" "$rung" "$now"
    printf '\n'
    if [ "$majors" -gt 0 ]; then
      printf '%s accepted Major finding(s):\n' "$majors"
      jq -r '.[] | select(.severity == "Major") | "  \(.file):\(.line // "file")  \(.title)"' "$open_path"
      printf '\n'
    fi
    if [ -n "${RECORD_PASS_GATE_TAIL:-}" ] && [ -f "$RECORD_PASS_GATE_TAIL" ]; then
      # THE TAIL, not the whole log. A gate can emit thousands of lines and the
      # actionable part is at the end; pasting all of it into the next pass's
      # context is how the file meant to focus a pass becomes the thing that
      # buries it.
      printf -- '--- gate output, last 40 lines ---\n'
      tail -40 "$RECORD_PASS_GATE_TAIL"
    fi
  } >"$failure"
  echo "record-pass: recorded a '$outcome' pass; $failure written for the next one."
fi
