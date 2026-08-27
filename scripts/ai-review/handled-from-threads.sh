#!/usr/bin/env bash
# handled-from-threads.sh — builds the CI-side HANDLED memory for the review
# engine out of the pull request's OWN review threads.
#
# Why this exists: the local runner passes the dismissal ledger
# (.harnx/ai-review-dismissed.json) into the model as HANDLED memory, so a
# re-review does not re-derive an already-dispositioned finding. CI had no
# memory at all, so every push re-derived every finding from scratch, and
# because post-findings.sh dedups on file plus NORMALIZED TITLE, a finding
# the model reworded between passes hashed to a different key and posted as a
# brand new thread. Observed live: one deferred finding accumulated four
# threads under four wordings, and the ai-review-resolved gate could never
# converge (resolve, push, re-posted reworded, red again).
#
# Why the ledger is NOT the CI memory source: it is gitignored on purpose. A
# committed, CI-read ledger would be author-controlled content inside the
# very pull request under review, a self-service mute button on the blocking
# gate. The safe memory source is the PR's own review threads and their
# resolution state, which is authority-neutral: resolving a Major thread is
# ALREADY the only way the gate is cleared (check-resolved.sh reads exactly
# that state), so replaying it as memory grants the author no power they did
# not already have. It only stops redundant re-derivation.
#
# RESOLVED THREADS ONLY, deliberately. An unresolved thread is a finding
# nobody has dispositioned yet: suppressing it would let the first pass's
# wording permanently silence a finding that was never addressed, and the
# author would lose the signal that it still applies to the current diff.
# Unresolved threads also cannot cause the convergence failure this script
# fixes, since they are already open, so the gate is already red for them,
# and a reworded re-post of one is cosmetic noise rather than a gate that can
# never go green. Resolved threads are the opposite on both counts: they are
# exactly the ones already dispositioned (fixed, or justified as deferred or
# refuted in a reply), and re-posting one reworded is precisely what makes
# the gate unconvergeable.
#
# The engine's prompt still allows re-raising a HANDLED item when the diff
# CLEARLY still exhibits that exact problem, so a genuine regression is not
# permanently muted by having once been resolved; post-findings.sh reopens
# the existing thread in that case rather than posting a duplicate.
#
# Env:
#   GH_TOKEN   required; a token with pull-requests: read is sufficient
#              (this script never writes), so it runs safely in the
#              read-only, PR-code-executing ai-review job.
#   OWNER      required; repo owner login.
#   REPO_NAME  required; repo name.
#   PR_NUMBER  required; the pull request number.
#   OUTPUT     required; path to write the HANDLED JSON array
#              ([{file, title}], the shape review-engine.sh filters to).
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${OUTPUT:?OUTPUT is required}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
threads="$(mktemp)"
trap 'rm -f "$threads"' EXIT
THREADS_OUTPUT="$threads" bash "$script_dir/fetch-review-threads.sh"

# post-findings.sh is the authority on the body format parsed back out here.
# It writes exactly three lines, in this order:
#   <!-- ai-review-key:<sha256> -->
#   <!-- ai-review-severity:<Major|Minor|nit> -->
#   **[<severity>]** <title>
# plus, on the line-1 fallback path only, a trailing blank line and an
# "(originally reported at line N; ...)" paragraph. Splitting on newlines and
# taking the single "**[...]** " line is therefore stable against that
# fallback suffix, and against the key and severity marker lines themselves.
#
# Only the thread's FIRST comment is read (fetch-review-threads.sh requests
# comments(first: 1)), matching post-findings.sh and check-resolved.sh: the
# human replies below it are justifications, not findings, and must never be
# mistaken for one.
handled="$(jq -c '
  def title_of:
    split("\n")
    | map(select(test("^\\*\\*\\[[^]]*\\]\\*\\* .")))
    | (.[0] // "")
    | sub("^\\*\\*\\[[^]]*\\]\\*\\* "; "");
  [ .[]
    | select(.isResolved == true)
    | { id, file: (.path // ""), body: (.comments.nodes[0].body // "") }
    | select(.body | test("<!-- ai-review-key:"))
    | { id, file, title: (.body | title_of) }
  ]' "$threads")"

# Fails loudly on a marker-carrying thread whose file and title cannot be
# parsed, rather than dropping it from memory. Dropping is the dangerous
# direction: a forgotten entry is re-derived by the model, reworded, and
# posted as a new thread, silently restoring the unconvergeable-gate bug this
# script exists to fix. A non-zero exit says post-findings.sh's comment body
# format and this parser have drifted apart, which is a real defect in the
# pipeline and belongs in the run's error annotations, not swallowed.
#
# Exiting here writes NO output file, and the workflow step that calls this
# script is deliberately continue-on-error: the review then runs with no
# memory at all, which is how every CI pass ran before this script existed.
# That is the safe direction for a mechanism whose only job is to SUPPRESS
# findings: losing it means the model reports more, never fewer, so a broken
# memory build can cost duplicate threads but can never hide a Major.
unparsed="$(printf '%s' "$handled" | jq -r '[.[] | select(.file == "" or .title == "") | .id] | join(", ")')"
if [ -n "$unparsed" ]; then
  echo "::error::handled-from-threads.sh: could not parse a file path and title out of ai-review thread(s): $unparsed. post-findings.sh's comment body format and this parser have drifted; refusing to review with incomplete memory." >&2
  exit 1
fi

# Written via a temp file and moved into place, never streamed straight into
# $OUTPUT: a jq failure part-way through a direct redirect would leave a
# truncated, invalid JSON file behind, and review-engine.sh (correctly)
# refuses to run at all on corrupt handled-memory rather than ignoring it.
# An absent file is a documented, harmless state there; a half-written one
# would take the whole review down.
staged="$(mktemp)"
printf '%s' "$handled" | jq '[.[] | {file, title}]' >"$staged"
mv "$staged" "$OUTPUT"
count="$(jq 'length' "$OUTPUT")"
# A count of 0 is a legitimate, common state (a first push, or a PR where
# nothing has been resolved yet), not an error: review-engine.sh documents
# absent or empty HANDLED memory as "no memory", which simply reviews the
# diff from scratch the way every CI pass already did.
echo "handled-from-threads.sh: $count resolved ai-review finding(s) passed to the engine as HANDLED memory."
