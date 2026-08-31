#!/usr/bin/env bash
# reconcile.sh — says what the merged findings MEAN against the pull request
# that already exists.
#
# union.sh answers "what did the reviewers say, once". This answers "and what
# is that, given what is already on the pull request": which findings are new,
# which already have a thread, and which are recurrences of something a human
# already resolved.
#
# THREE STATES, and the third is the interesting one.
#
#   new         no thread carries this key. post-findings.sh opens one.
#   tracked     an OPEN thread carries it. post-findings.sh updates that thread
#               rather than opening a second one.
#   regression  a RESOLVED thread carries it. Somebody answered this finding
#               and closed it, and the reviewers are raising it again.
#
# A REGRESSION IS NOT SUPPRESSED HERE, and that is deliberate. The obvious
# reading of "HANDLED findings must not resurface" is to drop them, and it is
# wrong: dropping would delete the recurrence detection post-findings.sh exists
# to provide, which reopens the original thread instead of posting a duplicate.
#
# Suppression happens one layer up and by MEANING, not by key: review-engine.sh
# hands the model the HANDLED memory and instructs it never to resurface those
# findings unless the diff clearly still exhibits the problem. So a finding that
# reaches here matching a resolved thread has already survived that filter and
# is a claimed regression. Dropping it would overrule the only component in the
# pipeline positioned to judge whether it is one.
#
# Nothing is dropped at all, in fact. This script annotates and counts; every
# decision about what to POST stays in post-findings.sh, which is the only
# thing holding a write-scoped token.
#
# Env:
#   FINDINGS  required; the merged findings array from union.sh.
#   THREADS   required; the pull request's review threads, from
#             fetch-review-threads.sh. An absent file is treated as no threads,
#             which is the correct reading for a pull request's first pass.
#   OUTPUT    required; path to write the annotated array to.
set -euo pipefail

: "${FINDINGS:?FINDINGS is required}"
: "${THREADS:?THREADS is required}"
: "${OUTPUT:?OUTPUT is required}"

# shellcheck source=scripts/ai-review/finding-key.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/finding-key.sh"

if ! jq -e 'type == "array"' "$FINDINGS" >/dev/null 2>&1; then
  echo "::error::reconcile.sh: $FINDINGS is not a JSON findings array; refusing to classify a set it cannot read." >&2
  exit 1
fi

# An absent threads file is a legitimate state: the first pass on a pull
# request has no threads. A file that EXISTS and is corrupt is not, because
# then every finding would read as new and a pull request would grow a second
# copy of every thread it already has.
threads='[]'
if [ -f "$THREADS" ]; then
  if ! jq -e 'type == "array"' "$THREADS" >/dev/null 2>&1; then
    echo "::error::reconcile.sh: $THREADS exists but is not a JSON array. Refusing to treat a corrupt thread list as an empty one: every finding would read as new and the pull request would grow a duplicate of every thread it already has." >&2
    exit 1
  fi
  threads="$(cat "$THREADS")"
fi

staged="$(mktemp)"
annotated="$(mktemp)"
trap 'rm -f "$staged" "$annotated"' EXIT

cp "$FINDINGS" "$staged"
: >"$annotated"

count="$(jq 'length' "$staged")"
i=0
while [ "$i" -lt "$count" ]; do
  finding="$(jq -c ".[$i]" "$staged")"
  i=$((i + 1))
  file="$(printf '%s' "$finding" | jq -r '.file // ""')"
  title="$(printf '%s' "$finding" | jq -r '.title // ""')"
  key="$(finding_key "$file" "$title")"

  # The marker post-findings.sh writes into the FIRST comment of the thread it
  # opens. Read from the same place, so the two agree about which thread a
  # finding belongs to.
  state="$(printf '%s' "$threads" | jq -r --arg m "<!-- ai-review-key:$key -->" '
    [ .[] | select(.comments.nodes[0].body // "" | contains($m)) ] as $hits
    | if ($hits | length) == 0 then "new"
      elif ($hits | any(.isResolved == false)) then "tracked"
      else "regression" end')"

  printf '%s' "$finding" | jq -c --arg s "$state" --arg k "$key" '. + {state: $s, key: $k}' >>"$annotated"
done

jq -s '.' "$annotated" >"$OUTPUT"

n_new="$(jq '[.[] | select(.state == "new")] | length' "$OUTPUT")"
n_tracked="$(jq '[.[] | select(.state == "tracked")] | length' "$OUTPUT")"
n_regression="$(jq '[.[] | select(.state == "regression")] | length' "$OUTPUT")"
echo "reconcile.sh: $count finding(s): $n_new new, $n_tracked already threaded, $n_regression recurring after being resolved."
if [ "$n_regression" -gt 0 ]; then
  echo "::warning::$n_regression ai-review finding(s) recurred after being resolved. post-findings.sh reopens the original thread rather than posting a duplicate; a recurrence means the answer that closed it did not hold."
fi
