#!/usr/bin/env bash
# check-branch-rebased.sh — a pre-push gate: refuse to push a branch that does
# not contain the current tip of its own base.
#
# WHY THIS IS A GATE AND NOT ADVICE. A stacked branch whose base has moved is
# not merely out of date; it is a branch whose pull request shows a diff nobody
# asked for. Every commit the base gained since the branch left appears in that
# pull request as though this branch introduced it, the AI review pays to review
# code it already reviewed one rung down, and a human reviewing the diff cannot
# tell which half is the change under review.
#
# THE BASE COMES FROM resolve-base.sh, so this and the chain gate and
# base-relative CI all mean the same thing by "base". A gate inventing its own
# answer is how two gates come to disagree while each looks correct.
#
# WHY THIS ONE HAS NO CI MIRROR, unlike no-merge-commit and no-forward-refs.
# Its mirror already exists and is not a job: branch protection sets
# `required_status_checks.strict = true` (scripts/configure-protection.sh), which
# is GitHub refusing to merge a branch that is behind its base. That check runs
# server-side, at merge time, against the live base, which is strictly stronger
# than anything a job could assert at push time against a ref it fetched
# earlier. A job would be a second voice saying the same thing, later and less
# authoritatively.
#
# The other two gates have no such equivalent. GitHub has no setting for "this
# range contains no merge commit" or "no commit references a file it does not
# contain", so those genuinely need a mirror of our own.
#
# BASE_NO_NETWORK IS SET, deliberately. This runs on every push, and a `gh api`
# call there is a per-push network dependency that fails offline, fails without
# a token, and fails under a rate limit. Tier 1 (an explicit declaration, which
# `git stack` writes) and tier 3 (the fallback) are both local and free.
#
# Env:
#   BRANCH   optional; defaults to the current branch.
#   BASE     optional; skips resolution entirely. For the paired test, and for
#            a contributor who knows better than the resolver.
#   REMOTE   optional; defaults to `origin`.
set -euo pipefail

remote="${REMOTE:-origin}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# THE POLICY IS CONSULTED FIRST, through the shared fragment. This gate is
# stacking machinery too, and an earlier version wired the policy into two of
# the three consumers and not this one, so `HARNX_STACKING=off` left this gate
# still acting and "inert" was not true.
# shellcheck source=scripts/git-discipline/stacking-policy.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/stacking-policy.sh"
if ! stacking_enabled; then
  echo "check-branch-rebased: stacking is off ($HARNX_POLICY_FILE); nothing to check."
  exit 0
fi

branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  echo "::error::check-branch-rebased: cannot determine the current branch (detached HEAD?)." >&2
  exit 1
fi

base="${BASE:-}"
if [ -z "$base" ]; then
  base="$(BRANCH="$branch" BASE_NO_NETWORK=1 bash "$script_dir/resolve-base.sh" 2>/dev/null || true)"
fi
if [ -z "$base" ]; then
  echo "::error::check-branch-rebased: could not resolve a base for '$branch'." >&2
  exit 1
fi

# THE BASE NAME IS VALIDATED BEFORE IT REACHES GIT, and passed after `--`.
# It can arrive from the BASE environment variable, which this script documents
# as a supported override, and git reads a leading dash as an option wherever it
# can: `--upload-pack=...` as a base would become a transport option rather than
# a ref. check-stack-chain.sh and stack.sh both guard the identical input at the
# identical boundary, and a gate that walks branch names should not be the one
# place that does not.
case "$base" in
-* | *' '* | *'..'*)
  echo "::error::check-branch-rebased: '$base' is not a usable branch name. A leading dash, a space or a '..' cannot be a ref, and git would read the first of those as an option." >&2
  exit 1
  ;;
esac

# A branch that IS its own base has nothing to be behind. This is the ordinary
# state of the stack's bottom when the fallback answers, and it must not be
# reported as a failure.
if [ "$branch" = "$base" ]; then
  echo "check-branch-rebased: '$branch' is its own base; nothing to check."
  exit 0
fi

# THE REMOTE'S TIP, not a local copy of it. A local ref can be arbitrarily
# stale, and a gate that compares against a stale copy passes exactly when the
# branch is most out of date. Fetched, not assumed.
if ! git fetch --no-tags --quiet "$remote" -- "$base" 2>/dev/null; then
  # A base that does not exist on the remote is not this gate's subject: the
  # chain-integrity gate reports that, with the whole chain for context. Here it
  # would be a confusing second voice, so this says what it could not do and
  # stops rather than guessing.
  echo "::error::check-branch-rebased: could not fetch '$base' from '$remote'. If that branch does not exist, the stack-chain-integrity gate reports it with the rest of the chain." >&2
  exit 1
fi

base_tip="$(git rev-parse FETCH_HEAD)"

if git merge-base --is-ancestor "$base_tip" HEAD; then
  echo "check-branch-rebased: '$branch' contains '$base' at $(git rev-parse --short "$base_tip")."
  exit 0
fi

behind="$(git rev-list --count "HEAD..$base_tip" 2>/dev/null || echo '?')"
echo "::error::check-branch-rebased: '$branch' does not contain the current tip of '$base' ($behind commit(s) behind)." >&2
echo "       Its pull request would show those commits as though this branch introduced them: the review pays to re-read code it already read one rung down, and a human cannot tell which half is the change under review." >&2
echo "       Rebase onto it, which for this repository means: git pull (pull.rebase is set by scripts/mise/setup-git-config.sh)." >&2
exit 1
