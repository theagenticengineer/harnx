#!/usr/bin/env bash
# validate-pr-body.sh — CI-only: a PR's body must carry `Closes #N` for the
# issue it delivers, N matching the branch's own issue number, the same
# cross-check validate-pr-title.sh performs for the title. Positional args,
# not an env var: same reasoning as validate-pr-title.sh, a PR body has no
# local hook equivalent to also serve.
set -euo pipefail
body="$1"
branch="${2:-}"

# Only meaningful on a real feature branch; skip silently otherwise (same as
# validate-pr-title.sh does for main/detached HEAD, and validate-commit-msg.sh
# for commits).
if [[ "$branch" =~ ^[a-z]+-([0-9]+)-[a-z0-9-]+$ ]]; then
  branch_n="${BASH_REMATCH[1]}"
  # A plain substring match ("Closes #$branch_n" anywhere in $body) would let
  # "Closes #67" satisfy a required "Closes #6": #6 is a substring of #67,
  # and GitHub would actually close issue #67 on merge, not #6. Requiring the
  # number to be followed by a non-digit (or end of string) closes that gap.
  if [[ ! "$body" =~ Closes\ \#${branch_n}([^0-9]|$) ]]; then
    echo "PR body must contain 'Closes #$branch_n' for the issue this branch delivers" >&2
    exit 1
  fi
fi
