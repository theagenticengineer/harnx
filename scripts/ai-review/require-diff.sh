#!/usr/bin/env bash
# require-diff.sh: the guard that stops the ai-review gate reporting a verdict
# on a review that had nothing to read.
#
# WHY IT IS A SCRIPT AND NOT AN INLINE `run:` BLOCK. This is the single
# fail-open the whole gate is built to not have, and an inline block in
# .github/workflows/ai-review-trunk.yml is unreachable from
# scripts/tests/*.bash, so nothing could pin its behaviour. It lived inline and
# it was wrong (see below) for exactly as long as it was untestable. Its paired
# test is scripts/tests/require-diff.bash.
#
# WHAT IT GUARDS. review-engine.sh short-circuits on `[ ! -s ]`: an absent OR
# empty diff makes it write `[]` and exit 0. Zero findings then flow through
# post-findings.sh (nothing to post), through check-resolved.sh (no unresolved
# Major threads) and check-dispositions.sh (no resolved ones either), and the
# ai-review-resolved required check goes GREEN over a pull request no reviewer,
# human or model, ever looked at.
#
# So the two cases have to be separated here, upstream of the engine, because
# the engine itself cannot tell them apart:
#
#   - ABSENT diff.txt: the pipeline broke. extract-diff.sh did not produce the
#     file it is contracted to produce, or failed closed before writing it
#     (a head that is no longer the commit this run is a verdict about).
#   - EMPTY diff.txt: extract-diff.sh ran and the reviewed range is genuinely
#     empty.
#
# The subject used to be an ARTIFACT uploaded by the pull request's own
# workflow. It is now the diff the trunk computes for itself, which makes this
# guard stronger rather than redundant: "empty" used to mean "the artifact
# arrived intact and was hollow", including a hollow one the author wrote on
# purpose, and now means the range itself is empty.
#
# Both fail. The empty case is a DELIBERATE fail-closed and it is the half that
# was missing: the earlier guard tested `[ ! -f ]`, existence only, so a
# zero-byte diff.txt sailed past it into the engine's short-circuit. A pull
# request whose changes are already contained in its base does produce a
# genuinely empty diff, and that pull request will now be blocked by a red
# ai-review-resolved until it has something to review. That cost is accepted on
# purpose: a gate that cannot distinguish "reviewed, nothing found" from "never
# reviewed" is worth nothing, and blocking a no-op pull request is the cheaper
# of the two failure modes by a wide margin.
#
# Env:
#   DIFF_FILE  required; path to the diff the review is about to read.
set -euo pipefail

: "${DIFF_FILE:?DIFF_FILE is required}"

if [ ! -f "$DIFF_FILE" ]; then
  echo "::error::require-diff: extract-diff.sh produced no $(basename "$DIFF_FILE"); refusing to report a review of nothing. Read the extraction step: it fails closed rather than reviewing the wrong commit." >&2
  exit 1
fi

# `-s`, the half the inline guard was missing. Kept as its own branch rather
# than folded into the test above so the failure says WHICH of the two
# happened: "the extraction did not run to completion" and "the extraction ran
# and there is nothing to review" send whoever reads the log to completely
# different places.
if [ ! -s "$DIFF_FILE" ]; then
  echo "::error::require-diff: $DIFF_FILE is present but empty, so the review engine would report zero findings without reviewing anything. Refusing to report a review of nothing." >&2
  exit 1
fi

echo "require-diff: $DIFF_FILE carries $(wc -c <"$DIFF_FILE" | tr -d ' ') bytes to review."
