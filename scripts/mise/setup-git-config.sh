#!/usr/bin/env bash
# setup-git-config.sh
# Writes the repo-local git configuration the stacking protocol depends on.
#
# Run from mise's `postinstall` hook, so it fires on every `mise install` and a
# fresh clone never depends on anyone remembering a setup step. It is
# idempotent by construction: `git config` overwrites a key rather than
# appending, so running it a hundred times leaves the same three values.
#
# Everything here is --local, written to the clone's own .git/config. Nothing
# touches the developer's --global config: a harness may configure the
# repository it ships with, never the machine it is checked out on.
#
# Note that .git/config is shared by every worktree of the same clone (a linked
# worktree's config lives there too, absent extensions.worktreeConfig), so this
# runs once per clone in effect, not once per worktree, even though a new
# worktree will happily re-run it.
set -euo pipefail

# mise runs a postinstall hook from wherever mise was invoked, which is not
# guaranteed to be inside this repository: a global `mise install` from $HOME
# is enough to land somewhere else entirely. Deriving the target from the cwd
# would then write this repo's stacking config into an unrelated repository
# that happens to enclose the caller. Derive it from THIS FILE's own location
# instead, which is by definition inside the repo the config belongs to.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "setup-git-config: not inside a git repository; nothing to configure." >&2
  exit 0
fi

# pull.rebase=true is what makes a plain `git pull` the correct and only ripple
# command upstack. It rebases the branch onto its remembered base (the
# upstream-tracking ref stack.sh sets at creation), using git's own fork-point
# detection, which stays correct even after the base was rewritten by a
# --force-with-lease push. Without it, `git pull` MERGES, which both violates
# the no-merge-commit gate and corrupts the next ripple's "what is uniquely
# mine" calculation.
git -C "$repo_root" config --local pull.rebase true

# push.default=current means `git push` and `git push --force-with-lease` need
# no branch arguments to reach the right place. That matters less for
# convenience than for correctness: the ripple's downstack step is a
# force-push, and a force-push that has to be told its target by hand is a
# force-push that can be told the wrong one.
git -C "$repo_root" config --local push.default current

# `git stack <branch> <parent>` creates the next rung. The alias resolves the
# script through the caller's own worktree top level, so it works identically
# from the primary clone and from any linked worktree; stack.sh then finds the
# primary clone itself, which is where the new worktree has to be created.
# shellcheck disable=SC2016  # the $(...) must stay LITERAL: it is stored in
# .git/config and evaluated by git each time the alias runs, from whichever
# worktree the caller is in. Expanding it here would bake in this one path.
git -C "$repo_root" config --local alias.stack \
  '!bash "$(git rev-parse --show-toplevel)"/scripts/git-discipline/stack.sh'

echo "setup-git-config: configured pull.rebase, push.default and alias.stack in $repo_root"
