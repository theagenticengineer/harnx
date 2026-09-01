#!/usr/bin/env bash
# forbid-merge-commit.sh
# Refuses to create a merge commit locally.
#
# The stack moves in one direction only: downstack `git push --force-with-lease`,
# upstack `git pull` (which rebases, because setup-git-config.sh sets
# pull.rebase). A merge commit means a pull that merged instead of rebasing, or
# a manual `git merge`. `main` advances solely through squash-merged pull
# requests.
#
# This is not a style rule. A merge commit inside a stacked branch corrupts
# `git pull --rebase`'s "what is uniquely mine" calculation: on the next
# ripple, the base's own commits are silently DUPLICATED into the branch's
# history rather than the pull failing loudly. That has actually happened, and
# it is why this gate sits with the ripple rather than with the formatting
# checks.
#
# Wired at TWO stages, because either alone is bypassable by accident:
#   pre-merge-commit  blocks the automatic merge commit git makes when a merge
#                     applies cleanly.
#   commit-msg        blocks COMPLETING a paused merge with `git commit`, which
#                     is what happens after a conflicted merge is resolved by
#                     hand. pre-merge-commit never fires on that path.
#
# The MERGE_HEAD test is what makes the commit-msg wiring a no-op for every
# ordinary commit: git only writes that ref while a merge is in progress.
set -euo pipefail

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  exit 0
fi

echo "harnx: local merge commit refused." >&2
echo "" >&2
echo "A merge commit here means a 'git pull' that merged instead of rebasing," >&2
echo "or a manual 'git merge'. Neither belongs in a stacked branch: on the next" >&2
echo "ripple it silently duplicates the base's own commits into this branch." >&2
echo "" >&2
echo "The stack moves one direction:" >&2
echo "  downstack:  git push --force-with-lease" >&2
echo "  upstack:    git pull        (rebases, because pull.rebase is set)" >&2
echo "" >&2
echo "If a pull tried to merge, pull.rebase is not set on this clone. Run" >&2
echo "'mise install' to restore it, then clear this half-done merge:" >&2
echo "  git merge --abort" >&2
exit 1
