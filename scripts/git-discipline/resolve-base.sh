#!/usr/bin/env bash
# resolve-base.sh — answers "what is this branch stacked on?", in priority
# order, first match wins.
#
# Three consumers need that answer and none of them may invent its own:
# `branch-rebased`, the stack chain-integrity gate, and base-relative CI. If
# each resolved it differently, a branch could satisfy one gate and fail
# another for reasons neither reports.
#
# THE ORDER, and why it is this order:
#
#   1. `git config branch.<branch>.base`. An explicit local declaration. First
#      because it is the only tier a human sets deliberately, so it must be able
#      to override the two guesses below.
#   2. The open pull request's base, read from the API. Authoritative about what
#      the branch is actually stacked on, because that is what a merge would
#      target, but it costs a network call and only exists once a PR is open.
#   3. `main`. The floor. Correct for the first rung of any stack and for a
#      repository that never stacks at all.
#
# THE UPSTREAM-TRACKING REF IS DELIBERATELY NOT A TIER, and this needs saying
# because `git stack` sets one. `git worktree add --track` points the new branch
# at its parent, which makes the tracking ref look like a fourth answer. It is
# not: tracking is about where `git push` and `git pull` go, a contributor can
# repoint it with one command for unrelated reasons, and it is set by tooling
# rather than declared. Tier 1 exists precisely so an explicit declaration has a
# home that tracking cannot silently overwrite.
#
# THE NETWORK TIER IS SKIPPABLE, and a pre-push hook should skip it. Tier 2 runs
# a `gh api` call, which on every push is a real cost and a real failure mode
# (offline, rate limited, no token). `BASE_NO_NETWORK=1` drops straight from
# tier 1 to tier 3, so a hook can stay local while CI, which already has a token
# and a network, uses all three.
#
# Env:
#   BRANCH           optional; the branch to resolve for. Defaults to the
#                    current one.
#   BASE_NO_NETWORK  optional; when non-empty, tier 2 is skipped entirely.
#   BASE_FALLBACK    optional; tier 3's value. Defaults to `main`. Set it to the
#                    EMPTY string to disable tier 3 entirely, which is how a
#                    caller asks "was a base actually declared?" rather than
#                    "what should I assume it is". Also lets the paired test
#                    assert the fallback without depending on what this
#                    repository's default branch happens to be.
#
# Writes the resolved base to stdout, and the tier it came from to stderr, so a
# caller's log says WHICH answer it got rather than only what it was.
set -euo pipefail

branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  echo "::error::resolve-base: cannot determine the current branch (detached HEAD?). Pass BRANCH explicitly." >&2
  exit 1
fi

# THE BRANCH NAME IS VALIDATED HERE, at the source, not only in the consumers.
# `BRANCH` is a documented override AND is passed by check-stack-chain.sh from a
# name it read out of the API while walking, so it reaches this script from
# outside. It is then interpolated into a `git config` key and handed to `gh` as
# a positional argument, and a leading dash is read as an option wherever it can
# be.
#
# check-branch-rebased.sh and check-stack-chain.sh both guard the base name they
# produce; guarding here as well is what stops the resolver from being the hole
# under all three of them.
case "$branch" in
-* | *' '* | *'..'* | *'~'* | *'^'* | *':'*)
  echo "::error::resolve-base: '$branch' is not a usable branch name. A leading dash, a space, or any of '..', '~', '^', ':' cannot be a ref, and git or gh would read the first of those as an option." >&2
  exit 1
  ;;
esac

# --- tier 1: an explicit local declaration -----------------------------------
declared="$(git config --get "branch.${branch}.base" 2>/dev/null || true)"
if [ -n "$declared" ]; then
  echo "resolve-base: $branch -> $declared (declared in branch.${branch}.base)" >&2
  printf '%s\n' "$declared"
  exit 0
fi

# --- tier 2: the open pull request's base ------------------------------------
if [ -z "${BASE_NO_NETWORK:-}" ] && command -v gh >/dev/null 2>&1; then
  # `|| true` on the whole pipeline: no PR, no token, no network and a rate
  # limit all land here, and none of them is an error for this script. They mean
  # "tier 2 has no answer", which is what tier 3 is for. A hard failure would
  # make every gate that calls this fail offline.
  pr_base="$(gh pr view "$branch" --json baseRefName -q .baseRefName 2>/dev/null || true)"
  if [ -n "$pr_base" ]; then
    echo "resolve-base: $branch -> $pr_base (the open pull request's base)" >&2
    printf '%s\n' "$pr_base"
    exit 0
  fi
fi

# --- tier 3: the floor -------------------------------------------------------
# `-`, NOT `:-`. An explicitly EMPTY BASE_FALLBACK means "there is no tier 3",
# which a caller needs when it wants to know whether a base was actually
# DECLARED rather than guessed: check-stack-chain.sh compares the remembered
# base against the pull request's, and a fallback of `main` would make every
# branch that declares nothing look like it disagrees. With `:-` the empty value
# was substituted away and that is exactly what happened, on the first live run.
fallback="${BASE_FALLBACK-main}"
echo "resolve-base: $branch -> $fallback (fallback; no declaration and no open pull request)" >&2
printf '%s\n' "$fallback"
