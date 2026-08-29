#!/usr/bin/env bash
# Git-identity gate, LOCAL half: validates the identity this machine is about
# to commit with, before it writes a commit.
#
# Its CI counterpart is check-commit-authors.sh, which reads the commits
# themselves. Both are needed and they answer different questions: this one
# stops a bad identity being written, that one stops a branch CARRYING one.
# The rules they apply are identical because both source author-policy.sh; the
# rules live there, not here.
#
# The repo's author policy has exactly THREE states, declared in
# .harnx/instance-config.toml. There is no fourth, and no default:
#
#   1. UNARMED   -> FAILS. No identity_policy, an unrecognised one, the
#                   CHANGE_ME sentinel, or "private" with no allowed_authors.
#   2. PUBLIC    -> any REAL author email. Presence, and a non-placeholder
#                   address, are still required.
#   3. PRIVATE   -> only authors matching allowed_authors may commit.
#
# WHY UNARMED IS A FAILURE, rather than the dormant state this gate used to
# implement. A floor that ships with a check switched off, and says nothing
# about it, verifies nothing while looking like it does. That is strictly worse
# than having no check at all: a green tick is a claim, and an un-armed gate
# makes the claim false. This repo learned it the hard way, having authored its
# entire genesis history as "Host Identity <leak@host.dev>" while this very
# gate reported Passed on every single commit.
#
# The consequence is deliberate and is the whole point: a repository generated
# from this floor REFUSES TO COMMIT until a human states its policy. Setup is
# not optional, and forgetting it is loud instead of silent. Choosing "public"
# is a decision the repo records, not an absence of one.
#
# WHY THE ARMING CHECK IS NOT SKIPPED ON CI, when the author checks are. The
# author checks read `git config`, which is meaningless on a runner (the author
# is already in the commit metadata), so they would falsely fail there. The
# arming check reads a TRACKED FILE, which is exactly as meaningful on CI as it
# is locally.
#
# Usage: check-git-identity.sh [instance-config-path]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-discipline/author-policy.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/author-policy.sh"

author_policy_load "${1:-}" || exit 1

# Skipped on a GitHub Actions runner, keyed off the runner-only
# GITHUB_ACTIONS=true signal, NOT the generic CI var: CI=1 is set by many
# devcontainers and unrelated tools, and keying the skip off it would silently
# disable the presence check on a real local commit.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  exit 0
fi

fail=0
name=$(git config user.name || true)
email=$(git config user.email || true)

# Presence: required under BOTH policies. "public" means any person may
# contribute, not that a commit may be authored by nobody.
if [[ -z "$name" ]]; then
  echo "ERROR: git user.name is not set." >&2
  echo "       Run: git config user.name \"Your Name\"" >&2
  fail=1
fi
if [[ -z "$email" ]]; then
  echo "ERROR: git user.email is not set." >&2
  echo "       Run: git config user.email \"you@your.real.domain\"" >&2
  fail=1
fi

if [[ -n "$email" ]]; then
  if ! reason="$(author_policy_reject "$email")"; then
    echo "ERROR: git user.email '$email' is $reason." >&2
    echo "       A commit must be attributable to a real person, and this branch" >&2
    echo "       must not carry one that is not: the same rule runs in CI over" >&2
    echo "       every commit in the pull request (check-commit-authors.sh), so" >&2
    echo "       committing anyway only moves the failure later." >&2
    echo "       Set a real address: git config user.email \"you@your.real.domain\"" >&2
    echo "       Your global ~/.gitconfig may be supplying this value; a per-repo" >&2
    echo "       'git config user.email' overrides it." >&2
    fail=1
  fi
fi

exit "$fail"
