#!/usr/bin/env bash
# check-commit-authors.sh — CI gate: every commit in the pull request's range
# must be AUTHORED by an address this repo accepts.
#
# WHY THIS EXISTS, and why check-git-identity.sh is not enough. That hook reads
# `git config user.email`, so it can only ever govern the machine that is about
# to commit:
#   - it is skipped on a runner, where `git config` carries no meaning;
#   - it does nothing at all if a contributor never ran `pre-commit install`;
#   - and it cannot see a commit that already exists.
# The result is a gate that constrains future commits while CI reports green
# over a branch that already carries the offending ones. That is not a
# hypothetical: this repo's entire genesis history is authored
# "Host Identity <leak@host.dev>", and the local hook reported Passed on every
# one of those commits.
#
# This script closes that by reading the commits themselves. Commit metadata is
# just as available on a runner as locally, so unlike the local hook this one
# cannot be skipped, cannot be un-installed, and applies to work that was
# already done.
#
# AUTHOR and COMMITTER are both checked, with one carve-out: GitHub stamps
# `noreply@github.com` as the COMMITTER of commits made through its web editor
# and of its own merge commits. That is real, attributable machine
# provenance rather than a stand-in, and rejecting it would fail commits a
# contributor made correctly through the GitHub UI. It is never accepted as an
# AUTHOR.
#
# Env:
#   BASE_SHA          required; the pull request base commit SHA.
#   HEAD_SHA          required; the pull request head commit SHA.
#   INSTANCE_CONFIG   optional; path to the instance config, for tests.
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-discipline/author-policy.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/author-policy.sh"

# The arming check runs here too, so a repo that never declared its policy
# fails in CI rather than only on a developer machine that happened to have the
# hooks installed.
author_policy_load "${INSTANCE_CONFIG:-}" || exit 1

# GitHub's web-flow committer. Accepted as a COMMITTER only, never as an author.
webflow_committer="noreply@github.com"

fail=0
checked=0

# Process substitution, not a pipe: a `git log | while read` loop runs the body
# in a subshell, so `fail` set inside it would be lost the moment the pipeline
# exits, silently turning every rejection into a pass. This is the same trap
# post-findings.sh documents.
while IFS=$'\t' read -r sha author_email committer_email; do
  [[ -n "$sha" ]] || continue
  checked=$((checked + 1))

  if reason="$(author_policy_reject "$author_email")"; then
    :
  else
    echo "::error::commit $sha is authored by '$author_email', which is $reason." >&2
    fail=1
  fi

  # Lowercased before comparing, matching what author_policy_reject does to
  # every address it evaluates. Without it a differently-cased noreply address
  # would miss this carve-out and be rejected by the generic no-reply rule,
  # failing a commit somebody made correctly through GitHub's web editor.
  if [[ "$(printf '%s' "$committer_email" | tr '[:upper:]' '[:lower:]')" != "$webflow_committer" ]]; then
    if reason="$(author_policy_reject "$committer_email")"; then
      :
    else
      echo "::error::commit $sha is committed by '$committer_email', which is $reason." >&2
      fail=1
    fi
  fi
done < <(git log --format='%H%x09%ae%x09%ce' "${BASE_SHA}..${HEAD_SHA}")

if [[ "$fail" -ne 0 ]]; then
  echo "::error::one or more commits carry an identity this repo does not accept. Rewrite them (git rebase -i, or 'git commit --amend --reset-author' for the tip) after fixing 'git config user.email'; the branch cannot carry them." >&2
  exit 1
fi

# A range of zero commits FAILS rather than passing silently. It means the base
# and head resolved to the same commit, which for a pull request is a broken
# invocation, not a clean result: the gate would report green having validated
# nothing, which is the exact failure mode this whole script exists to remove.
# Fail-closed here costs a clear error on a malformed range; passing would cost
# a green check that means nothing.
if [[ "$checked" -eq 0 ]]; then
  echo "::error::check-commit-authors: the range ${BASE_SHA}..${HEAD_SHA} contains no commits, so nothing was validated. Refusing to report success for a check that examined nothing." >&2
  exit 1
fi

echo "check-commit-authors: $checked commit(s) in ${BASE_SHA}..${HEAD_SHA} carry an accepted identity."
