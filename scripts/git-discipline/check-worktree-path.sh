#!/usr/bin/env bash
# check-worktree-path.sh
# Asserts that any feature branch is checked out inside a git worktree, not in
# the primary clone: root stays on `main`, every other branch lives in its own
# `.worktrees/<branch>/`.
set -euo pipefail

# git's post-checkout hook passes prev-HEAD, new-HEAD, and a flag that is 1 for
# a branch/ref checkout and 0 for a plain file checkout (`git checkout --
# path`). pre-commit's post-checkout stage does NOT forward these as raw
# positional args to the hook command (it parses them itself and exposes the
# third one as $PRE_COMMIT_CHECKOUT_TYPE instead), so $3 is only ever set when
# this script is invoked directly (as the test suite does); prefer it when
# present, fall back to the env var pre-commit actually sets, then default to
# 1 (run the check) when neither is available. A file checkout changes no
# ref, so skip the worktree assertion entirely in that case.
checkout_type="${3:-${PRE_COMMIT_CHECKOUT_TYPE:-1}}"
if [[ "$checkout_type" != 1 ]]; then
  exit 0
fi

branch="$(git rev-parse --abbrev-ref HEAD)"

# main and detached HEAD are exempt. This check also terminates the
# recursion below: the self-heal checks out "main", which re-triggers this
# same post-checkout hook (git does not suppress hooks for a checkout run
# from inside another hook), and that second, recursive invocation exits
# right here on this branch, bounded to exactly one extra level, never
# infinite.
if [[ "$branch" == "main" || "$branch" == "HEAD" ]]; then
  exit 0
fi

# git worktree list --porcelain outputs one stanza per worktree. The primary
# worktree is the first entry listed. Compare it to the current working
# directory to tell a linked worktree apart from the primary clone.
primary_path="$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')"
current_path="$(git rev-parse --show-toplevel)"

if [[ "$current_path" == "$primary_path" ]]; then
  echo "ERROR: branch '$branch' must be checked out in a git worktree," >&2
  echo "       not in the primary clone at '$primary_path'." >&2
  echo "       Create it with: git worktree add .worktrees/$branch $branch" >&2
  # Never auto-switch a dirty tree: git carries non-conflicting uncommitted
  # changes across the checkout, landing them on main in the very clone this
  # hook keeps clean. Refuse and let the human resolve rather than silently
  # move them.
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "       The primary clone has UNCOMMITTED changes; not auto-reverting" >&2
    echo "       to 'main' (that would carry them onto main). Commit or stash" >&2
    echo "       them, then move this work into a worktree." >&2
    exit 1
  fi
  echo "       Reverting the primary clone back to 'main'..." >&2
  git checkout main
  exit 1
fi
