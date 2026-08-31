#!/usr/bin/env bash
# finding-key.sh — the identity of a review finding, defined once.
#
# SOURCED, never executed. It defines two functions and does nothing else, the
# same shape scripts/git-discipline/parse-commit-header.sh uses for the commit
# header regex and for the same reason: two scripts that must agree about a
# value should read one definition rather than each carry a copy.
#
# WHO AGREES ABOUT WHAT. post-findings.sh keys a review thread on this, so the
# key decides whether a finding updates an existing thread or opens a new one.
# union.sh dedups a multi-reviewer fan-out on it, so the key decides whether
# two reviewers reporting the same problem produce one thread or two. Those two
# have to be the SAME key. Computed separately they would drift on the first
# edit to either, and the failure is silent: a pull request quietly grows two
# threads for one finding, which is the exact defect criterion 28 repaired.
#
# WHAT THE KEY IS, and what it deliberately is not:
#
#   file + normalized title. Not the line, because an unrelated edit earlier in
#   the same file shifts the reported line for the same underlying finding
#   between runs. Not the severity, because a model re-assesses it and a
#   severity change must read as an update to one thread rather than as a new
#   finding.
#
# Resistance to REPHRASING is supplied upstream, not here: review-engine.sh
# sends the open threads' titles to the model and requires a still-present
# finding to be re-reported under its tracked title verbatim. This key is an
# exact, deterministic primitive over text that has already been stabilised.

# Lowercase, every run of non-alphanumeric characters collapsed to one space,
# runs of spaces squeezed, and then TRIMMED at both ends. Deliberately NOT
# truncated to a fixed word count: an earlier version cut to the first eight
# words, which let two genuinely different findings sharing an opening phrase
# collapse onto one key, so the second was silently skipped as "already
# tracked" instead of posted.
#
# The trim is a repair, and it was found by writing this file's paired test
# against what the normalisation obviously ought to do. Without it a title
# ending in punctuation kept a trailing space, so "the token is unset" and
# "The token is unset." produced DIFFERENT keys and therefore two threads for
# one finding. A trailing full stop is exactly the kind of variation a model
# introduces between runs, so this was the rephrasing defect in miniature,
# sitting inside the function meant to absorb it.
#
# Trimming cannot over-collapse: it removes only whitespace that carries no
# meaning, so two titles it merges differ by punctuation and spacing alone.
normalize_title() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:] ' ' ' |
    tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# The key itself. sha256 of "file:normalized-title", so it is fixed-width and
# safe to embed in an HTML comment marker inside a review comment body.
finding_key() {
  printf '%s:%s' "$1" "$(normalize_title "$2")" | sha256sum | cut -d' ' -f1
}
