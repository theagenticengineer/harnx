#!/usr/bin/env bash
# validate-pr-title.sh — CI-only: `main` is squash-merge-only, so a PR's title
# becomes the squash commit's subject on `main`. It must therefore match the
# exact same header format validate-commit-msg.sh already enforces, using the
# exact same regex (reused, never duplicated). Positional args, not an env
# var: unlike validate-commit-msg.sh, a PR title has no local hook equivalent
# to also serve, so there is no dual calling convention to support; this
# matches how the branch-name CI job already calls validate-branch-name.sh
# with a positional arg from an env var.
set -euo pipefail
title="$1"
branch="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-discipline/parse-commit-header.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/parse-commit-header.sh"

[[ "$title" =~ $COMMIT_HEADER_RE ]] || {
  echo "title must match 'type(#N): title' (title >=10 chars, no trailing whitespace)" >&2
  exit 1
}

# Cross-check the title's issue number against the branch's, so the two can
# never drift apart. Only meaningful on a real feature branch; skip silently
# otherwise (same as validate-commit-msg.sh does for main/detached HEAD).
if [[ "$branch" =~ ^[a-z]+-([0-9]+)-[a-z0-9-]+$ ]]; then
  branch_n="${BASH_REMATCH[1]}"
  if [[ "$title" =~ \(#([0-9]+)\): ]]; then
    title_n="${BASH_REMATCH[1]}"
    if [[ "$title_n" != "$branch_n" ]]; then
      echo "title issue #$title_n does not match branch '$branch' issue #$branch_n" >&2
      exit 1
    fi
  fi
fi
