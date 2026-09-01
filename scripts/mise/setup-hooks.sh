#!/usr/bin/env bash
# setup-hooks.sh — installs this repository's git hooks, so a fresh clone or a
# fresh worktree is gated without anyone remembering a setup step.
#
# Run from mise.toml's `[hooks] postinstall`, which fires after `mise install`.
# That is the first command anybody runs here, so the gates arrive with the
# toolchain rather than in a README instruction nobody reads. A gate that
# depends on being installed by hand is a gate that is not installed.
#
# CI IS EXCLUDED, deliberately. jdx/mise-action runs `mise install` on every
# job, and git hooks do nothing there: CI never commits, and the checks the
# hooks run are the same ones the `pre-commit` job runs directly. Installing
# them would spend time on every job to arm something nothing fires.
#
# ALL FOUR HOOK TYPES ARE INSTALLED, not only the ones this branch's config
# currently uses. pre-commit is happy to install a hook type with no hooks for
# it (running it is a no-op), and the alternative is worse than the cost: the
# child branch's .pre-commit-config.yaml replaces this one wholesale at the
# same path and DOES declare commit-msg, pre-push and post-checkout hooks. A
# rebase onto that config would otherwise leave three stages silently
# uninstalled, which is a gate that reports nothing rather than one that fails.
#
# Idempotent: `pre-commit install` overwrites its own hook files and leaves
# anything it did not write alone, so re-running is free.
set -euo pipefail

# Not a git work tree: nothing to install into. `mise install` is a legitimate
# thing to run in an unpacked tarball, so this is a quiet exit rather than an
# error.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

if [ -n "${CI:-}" ]; then
  echo "setup-hooks: CI detected; skipping git hook installation."
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [ ! -f .pre-commit-config.yaml ]; then
  echo "setup-hooks: no .pre-commit-config.yaml here; nothing to install." >&2
  exit 0
fi

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "setup-hooks: pre-commit is not on PATH. It is pinned in mise.toml, so 'mise install' should have provided it; the hooks are NOT installed." >&2
  exit 1
fi

# EVERY STAGE .pre-commit-config.yaml DECLARES, and the list has to be kept in
# step with it. A hook declared for a stage nobody installed never runs, and
# nothing reports that: pre-commit is silent about a stage it was not asked to
# install, and the hook simply does not fire. That is a gate shipping dormant,
# which is the failure this repository has already paid for once.
#
# `pre-merge-commit` is here for the no-merge-commit gate. It fires when git is
# about to create a merge commit; the same hook is also declared for
# `commit-msg`, which is the path a human takes when completing a CONFLICTED
# merge by hand, and which pre-merge-commit never sees.
pre-commit install \
  --hook-type pre-commit \
  --hook-type commit-msg \
  --hook-type pre-push \
  --hook-type post-checkout \
  --hook-type pre-merge-commit \
  --overwrite

echo "setup-hooks: git hooks installed for pre-commit, commit-msg, pre-push, post-checkout and pre-merge-commit."
