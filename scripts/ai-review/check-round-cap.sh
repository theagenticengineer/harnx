#!/usr/bin/env bash
# check-round-cap.sh — the loop's stop condition, at pre-push.
#
# A LOOP WITHOUT A STOP IS NOT A LOOP, IT IS A LEAK. Every other part of this
# machinery makes a pass cheaper, more repeatable and better recorded, and all
# of that makes it easier to run one more pass on a problem the loop is not
# going to solve. The cap is the only piece that says no.
#
# ROUNDS ARE COUNTED SINCE THE LAST ACCEPTED TREE, NOT FOR THE BRANCH'S
# LIFETIME, and this is the difference between a cap and a wall. A lifetime
# counter has exactly one exit: after the first breach every future push tolls
# forever and a green result restores nothing, so the success exit disappears
# and the only way forward is to bypass the gate. Counting since the last
# acceptance gives back the exit the loop is supposed to be aiming at.
#
#   rounds = local passes recorded since the last acceptance
#          + (CI head SHAs now - the count recorded in that acceptance)
#
# ACCEPTANCE IS THE RESET, AND THERE IS NO RESET VERB. Nothing here clears a
# counter. The reset is an event the harness records when a full non-narrowed
# review converges to zero accepted Majors, content-addressed by the reviewed
# tree, and record-pass.sh refuses to write one that was not earned. There is
# therefore nothing for anybody to forge, forget, or be tempted to run "just to
# get unblocked".
#
# WITH NO ACCEPTANCE YET, the baseline row is the reset point. Without it the
# counter would mix epochs: passes.jsonl starts empty while CI already counts a
# branch's whole history, so a branch with 40 pushes behind it would install
# pre-spent against a cap of 15 while a fresh branch doing identical work would
# start at zero.
#
# THE CAP IS A CONSTANT WITH NO ENVIRONMENT OVERRIDE, which is a deliberate
# departure from this repository's `${VAR:-default}` idiom. Those knobs tune
# BEHAVIOUR. This one tunes the STOP, and an environment variable is a weakening
# path that leaves no trace: a loop that hit the cap could export a bigger one
# and keep going, and nothing afterwards would show it happened. `scripts/` is
# CODEOWNERS-protected, so raising it means a tracked edit needing a review its
# author cannot self-grant. Fifteen, not forty: since-acceptance scoping makes a
# much smaller number defensible, and the acceptance rows will calibrate it with
# real data.
#
# WHAT IT DOES NOT DO, stated because a gate whose limits are unstated gets
# trusted for things it never did: `git push --no-verify` skips it entirely, and
# there is no server-side backstop BY CONSTRUCTION. Making one would mean a
# required check that reads this branch's gitignored local state, which the
# state cannot provide and CI has no way to verify. This is a stop for a loop
# that wants to stop correctly, not a defence against an operator who does not.
set -euo pipefail

CAP=15

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# THE PUSHED REF, not HEAD. pre-commit sets PRE_COMMIT_LOCAL_BRANCH for pre-push
# hooks, and it is the branch actually being pushed. Keying off HEAD would let a
# capped branch push a different one from the same checkout and escape its own
# count. Falls back to HEAD when invoked by hand, which is the only case where
# there is no pushed ref to speak of.
rung="${PRE_COMMIT_LOCAL_BRANCH:-}"
[ -n "$rung" ] || rung="$(git rev-parse --abbrev-ref HEAD)"

loop_dir=".harnx/loop"
log="$loop_dir/passes.jsonl"
handoff="$loop_dir/handoff.md"

# NO LOG IS NOT A BREACH. A contributor who has never run the loop has spent no
# rounds, and refusing their push would make this gate the first thing anybody
# turns off.
if [ ! -f "$log" ]; then
  echo "check-round-cap: no $log for '$rung'; nothing has been counted."
  exit 0
fi

# The reset point and the local term, in one pass over the file. Rows are
# append-only, so "since the reset" is a position in the file and not a
# timestamp comparison, which would be at the mercy of a clock.
counts="$(jq -s --arg r "$rung" '
  [.[] | select(.rung == $r)] as $rows
  | ([range(0; ($rows | length)) as $i | select($rows[$i].type == "acceptance") | $i] | last) as $acc
  | ([range(0; ($rows | length)) as $i | select($rows[$i].type == "baseline") | $i] | last) as $base
  | (if $acc != null then $acc elif $base != null then $base else -1 end) as $reset
  | {
      reset_type: (if $reset >= 0 then $rows[$reset].type else "none" end),
      ci_then: (if $reset >= 0 then ($rows[$reset].ci_head_shas // null) else null end),
      local: ([$rows[($reset + 1):][] | select(.type == "pass")] | length)
    }
' "$log" 2>/dev/null)" || {
  echo "check-round-cap: $log could not be read as JSON." >&2
  echo "  Refusing to treat an unreadable counter as an empty one: that would silently disable the stop condition." >&2
  exit 1
}

local_term="$(printf '%s' "$counts" | jq -r '.local')"
ci_then="$(printf '%s' "$counts" | jq -r '.ci_then')"
reset_type="$(printf '%s' "$counts" | jq -r '.reset_type')"

# THE CI TERM IS OMITTED, NOT GUESSED, when either end is unknown. A guess here
# is a number nobody can check that moves the stop condition. Omitting it makes
# the cap fire LATER, which is the safe direction for a gate whose purpose is to
# stop a runaway loop rather than to police an honest one, and the fallback is
# announced so a reader never mistakes a partial count for a whole one.
ci_term=0
ci_note=""
if [ "$ci_then" = null ]; then
  ci_note="the reset point recorded no CI count"
else
  ci_now="$(bash scripts/ai-review/ci-head-shas.sh "$rung" 2>/dev/null || true)"
  if [ -z "$ci_now" ]; then
    ci_note="CI could not be read"
  else
    ci_term=$((ci_now - ci_then))
    # NEGATIVE MEANS THE HISTORY MOVED UNDER US, most often a deleted run or a
    # renamed branch. Clamped to zero rather than allowed to subtract from the
    # local term, where it would silently buy back rounds that were spent.
    if [ "$ci_term" -lt 0 ]; then
      ci_note="the CI count went backwards ($ci_now < $ci_then); counting 0 for it"
      ci_term=0
    fi
  fi
fi

rounds=$((local_term + ci_term))

if [ "$rounds" -lt "$CAP" ]; then
  msg="check-round-cap: $rounds/$CAP rounds on '$rung' since the last $reset_type."
  [ -z "$ci_note" ] || msg="$msg ($ci_note)"
  echo "$msg"
  exit 0
fi

# --- the cap is reached ------------------------------------------------------
# THE RELEASE IS A REPORT, NOT A FLAG. Something has to let a stopped loop hand
# over to a human, and every cheap mechanism for that (an env var, a touch-file,
# a --force) is a mechanism for not writing the report. Requiring the report
# itself means the escape hatch and the deliverable are the same artifact.
#
# It is FRICTION, NOT ENFORCEMENT, and the distinction is stated here rather
# than implied: the refusal below names the exact round count a forger would
# need to write. That is deliberate. A person who reads this message and writes
# a real handoff is who the gate is for; a person who fabricates one has made a
# recorded, deliberate choice, which is all a local gate can ever achieve.
# THE HEADER VALUES ARE EXTRACTED AND COMPARED AS STRINGS, never interpolated
# into a pattern. The previous form spliced `$rung` straight into a grep BRE
# (`^rung: *$rung *$`), so any regex metacharacter in a branch name was matched
# as a metacharacter: a `.` in a release-style branch name becomes "any
# character". That fails in BOTH directions on a check that gates the loop's
# only escape hatch. A handoff naming a slightly different rung could satisfy
# it, and a correctly-worded handoff could fail to match. Found by this
# pipeline reviewing this branch.
#
# `-i` on the keyword is preserved by lowercasing the matched name rather than
# the value: the label may be written `Rung:` or `rung:`, but the branch name
# itself is case-sensitive and must be compared exactly.
# The label is matched case-insensitively by lowercasing THE LINE, and the value
# is returned untouched. `$key` is a literal word chosen by this script, never
# user input, so it is safe in a case pattern; the branch name never reaches a
# pattern at all.
header_value() {
  local key="$1" line lc
  while IFS= read -r line; do
    lc="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    lc="${lc#"${lc%%[![:space:]]*}"}"
    case "$lc" in
    "$key:"*)
      printf '%s' "${line#*:}" | tr -d '[:space:]'
      return 0
      ;;
    esac
  done <"$handoff"
}

release_ok=1
release_why=""
if [ ! -s "$handoff" ]; then
  release_ok=0
  release_why="$handoff is empty or missing"
elif [ "$(header_value rung)" != "$rung" ]; then
  release_ok=0
  release_why="$handoff does not carry a line 'rung: $rung'"
elif [ "$(header_value rounds)" != "$rounds" ]; then
  release_ok=0
  release_why="$handoff does not carry a line 'rounds: $rounds'"
else
  # A NON-EMPTY BODY, not just the two header lines. A report that says only
  # what the gate asked it to say is the gate talking to itself.
  body="$(grep -viE '^(rung|rounds):' "$handoff" | tr -d '[:space:]')"
  if [ -z "$body" ]; then
    release_ok=0
    release_why="$handoff has the required lines but no body: say what was tried, what is known, and what the next person must decide"
  fi
fi

if [ "$release_ok" = 0 ]; then
  echo "::error::check-round-cap: the loop has spent $rounds of $CAP rounds on '$rung' since the last $reset_type, and is stopping." >&2
  echo "" >&2
  echo "  $release_why" >&2
  echo "" >&2
  echo "  This is the stop condition, not a bug. $rounds rounds without an accepted tree means the" >&2
  echo "  loop is not converging, and the next pass is very unlikely to be the one that does." >&2
  echo "" >&2
  echo "  TO PROCEED, write $handoff with:" >&2
  echo "" >&2
  echo "      rung: $rung" >&2
  echo "      rounds: $rounds" >&2
  echo "" >&2
  echo "      <what was tried, what is known, and what the next person has to decide>" >&2
  echo "" >&2
  echo "  A clean full local review resets this counter to zero, which is the exit this" >&2
  echo "  cap exists to push you towards. Run 'mise run ai-review:local' and converge." >&2
  exit 1
fi

# THE ESCALATION ROW RECORDS THE REPORT'S HASH, so a report reused across two
# different stops, or one padded to satisfy the body check, is visible in the
# harness record afterwards. It does not prevent either; nothing local can.
jq -cn --arg rung "$rung" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson rounds "$rounds" --argjson cap "$CAP" \
  --arg sha "$(shasum -a 256 "$handoff" | awk '{print $1}')" \
  '{type:"escalation", rung:$rung, at:$at, rounds:$rounds, cap:$cap, handoff_sha256:$sha}' >>"$log"

echo "check-round-cap: cap reached at $rounds/$CAP on '$rung', and $handoff reports it. Allowing the push."
