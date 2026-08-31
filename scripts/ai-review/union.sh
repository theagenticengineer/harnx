#!/usr/bin/env bash
# union.sh — merges every reviewer's findings into one deduplicated set.
#
# With more than one reviewer on the same diff, two of them finding the same
# problem must produce ONE review thread, not one per reviewer. Without that, a
# second opinion is not a second opinion; it is a second copy of every finding,
# and the contributor pays for the extra reviewer in noise.
#
# DEDUPLICATED ON THE SAME KEY post-findings.sh threads on, read from the
# shared fragment rather than recomputed here. That is the whole reason the
# fragment exists: a union that grouped differently from the poster would merge
# two findings into one entry and then post it under a key matching neither, or
# split one finding the poster would have threaded together.
#
# WHAT A MERGE KEEPS, when two reviewers report the same finding:
#
#   file, title   the first reviewer's, since the key already says they agree
#   line, side    the first reviewer's; they anchor to the same problem
#   severity      the MOST severe of them. Two reviewers disagreeing about
#                 whether something blocks merge is not a tie to average; the
#                 gate exists to stop a real Major, so the answer that fails
#                 closed is the only safe one.
#   reviewer      all of them, comma-joined and sorted, so a thread says who
#                 raised it. A finding two independent reviewers agree on is
#                 worth more than one only a single reviewer saw, and that is
#                 information the reader should not have to dig for.
#
# AN EMPTY FAN-OUT IS A FAILURE, NOT AN EMPTY REVIEW. If no input files exist
# at all, the matrix produced no jobs, and a matrix that produced no jobs is
# indistinguishable downstream from a matrix whose jobs all passed: zero
# findings, no threads, no unresolved Major, and a green required check over a
# pull request nothing reviewed. That is the same fail-open require-diff.sh
# catches one stage earlier, so it fails here rather than being reported as a
# clean pass.
#
# Env:
#   UNION_INPUTS      required; a directory holding one findings JSON array per
#                     reviewer, named <slug>.json. Empty or absent is a
#                     failure, see above.
#   EXPECTED_REVIEWERS optional; the registry's JSON array, from the probe.
#                     When set, EVERY named reviewer must have produced a file.
#                     See the count below: this is the only place a matrix that
#                     fanned out to fewer jobs than the registry named can
#                     still be seen.
#   EXPECTED_STRICT   optional, default true. When "false", a missing reviewer
#                     WARNS instead of failing, because its leg already failed
#                     and reported itself. See the count.
#   AI_REVIEW_OUTPUT  required; path to write the merged array to.
set -euo pipefail

: "${UNION_INPUTS:?UNION_INPUTS is required}"
: "${AI_REVIEW_OUTPUT:?AI_REVIEW_OUTPUT is required}"

# shellcheck source=scripts/ai-review/finding-key.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/finding-key.sh"

if [ ! -d "$UNION_INPUTS" ]; then
  echo "::error::union.sh: $UNION_INPUTS does not exist, so the reviewer fan-out produced nothing. Refusing to report a clean review of a pull request no reviewer read." >&2
  exit 1
fi

shopt -s nullglob
inputs=("$UNION_INPUTS"/*.json)
if [ "${#inputs[@]}" -eq 0 ]; then
  echo "::error::union.sh: no reviewer produced a findings file in $UNION_INPUTS. A fan-out with no jobs looks exactly like a fan-out whose jobs all passed, so this fails rather than reporting zero findings." >&2
  exit 1
fi

# THE REGISTRY IS COUNTED AGAINST THE RESULTS, and this is the only place that
# comparison can be made.
#
# A matrix that fans out to fewer jobs than the registry named is invisible to
# every downstream check: the jobs that did run all passed, so the job status is
# success, and a reviewer that never ran produces no findings, which reads
# exactly like a reviewer that found nothing. Job status cannot tell them apart.
# A COUNT can.
#
# It lives here rather than in the gate because this is where the per-reviewer
# outputs are. Putting it in the gate would mean giving that job `actions: read`
# to re-download the artifact, and that scope was deliberately removed when the
# diff stopped travelling as one; re-adding it to the job that publishes the
# required check, to re-read data another job already holds, is the wrong trade.
if [ -n "${EXPECTED_REVIEWERS:-}" ]; then
  # A reviewer's files are named <slug>.<pass>.json, one per pass, so the test
  # is "did this reviewer produce ANY output" rather than "is there a file with
  # exactly this name". A reviewer whose every pass failed produced none.
  missing=""
  while read -r slug; do
    [ -n "$slug" ] || continue
    # An ARRAY and its length, not `set --` with `[ -e "$1" ]`: nullglob is on,
    # so an unmatched pattern expands to nothing at all, and `$1` is then
    # unbound under `set -u`. `${#arr[@]}` is safe on an empty array; `$1` and
    # `${arr[0]}` are not.
    produced=("$UNION_INPUTS/$slug".*.json)
    [ "${#produced[@]}" -gt 0 ] || missing="$missing $slug"
  done <<EOF
$(printf '%s' "$EXPECTED_REVIEWERS" | jq -r '.[]?' 2>/dev/null || true)
EOF
  if [ -n "$missing" ]; then
    # STRICT when every leg reported success, which is the case with no other
    # reporter: a reviewer that "succeeded" and produced nothing would
    # otherwise contribute silence indistinguishable from a clean review.
    #
    # Not strict when a leg FAILED. That reviewer has already been reported by
    # its own leg and by the gate, and refusing here as well would suppress the
    # findings the other reviewers did produce, which is exactly what
    # `fail-fast: false` exists to prevent.
    if [ "${EXPECTED_STRICT:-true}" = "false" ]; then
      echo "::warning::union.sh: reviewer(s) produced no findings file:$missing. Their legs failed and are reported separately; merging what the other reviewers did produce rather than discarding it too." >&2
    else
      echo "::error::union.sh: AI_REVIEWERS names reviewer(s) that produced no findings file:$missing, and every reviewer's leg reported success. A leg that never ran is indistinguishable from one that found nothing, so this is counted rather than inferred from job status." >&2
      exit 1
    fi
  fi
fi

# Each input is validated BEFORE anything is merged. A corrupt file is a
# reviewer whose findings would be silently dropped, and dropping is the
# direction that loses a Major.
for f in "${inputs[@]}"; do
  if ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then
    echo "::error::union.sh: $(basename "$f") is not a JSON findings array. Refusing to merge a set with a reviewer missing from it." >&2
    exit 1
  fi
done

# The normalized title is computed by the SHARED function, once per finding,
# and attached as a grouping field. One subprocess per finding is the cost of
# not having a second copy of the normalisation living in a jq expression; a
# review producing enough findings for that to matter has a larger problem than
# its runtime.
staged="$(mktemp)"
keyed="$(mktemp)"
trap 'rm -f "$staged" "$keyed"' EXIT

jq -s 'add // []' "${inputs[@]}" >"$staged"
: >"$keyed"
count="$(jq 'length' "$staged")"
i=0
while [ "$i" -lt "$count" ]; do
  finding="$(jq -c ".[$i]" "$staged")"
  i=$((i + 1))
  # A non-object element cannot be keyed and must not be dropped in silence.
  if [ "$(printf '%s' "$finding" | jq -r 'type')" != "object" ]; then
    echo "::error::union.sh: a reviewer emitted a non-object finding; refusing to merge a malformed set: $finding" >&2
    exit 1
  fi
  file="$(printf '%s' "$finding" | jq -r '.file // ""')"
  title="$(printf '%s' "$finding" | jq -r '.title // ""')"
  printf '%s' "$finding" |
    jq -c --arg nkey "$(printf '%s:%s' "$file" "$(normalize_title "$title")")" '. + {nkey: $nkey}' >>"$keyed"
done

# Severity ranks so "most severe wins" is expressible. Anything unrecognised
# ranks highest, matching review-engine.sh's rule that an unknown severity is
# treated as the most severe rather than the least visible.
jq -s '
  def rank: if . == "Major" then 3 elif . == "Minor" then 2 elif . == "nit" then 1 else 4 end;
  def unrank: if . == 3 then "Major" elif . == 2 then "Minor" elif . == 1 then "nit" else "Major" end;
  group_by(.nkey)
  | map(
      .[0]
      + { severity: ([.[] | .severity | rank] | max | unrank),
          reviewer: ([.[] | .reviewer // "unknown"] | unique | join(",")) }
      | del(.nkey)
    )
' "$keyed" >"$AI_REVIEW_OUTPUT"

merged="$(jq 'length' "$AI_REVIEW_OUTPUT")"
echo "union.sh: ${#inputs[@]} reviewer file(s), $count finding(s) in, $merged after deduplication."
