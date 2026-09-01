#!/usr/bin/env bash
# check-stack-chain.sh — walks a pull request's base chain link by link and
# fails if any link is broken, ambiguous, or disagrees with itself.
#
# WHY A WALK RATHER THAN A SINGLE COMPARISON. An earlier draft of this gate
# asked "does this pull request's base equal `main`?". That is right for exactly
# one pull request in a stack, the bottom one. Every rung above it bases on the
# branch below, so the check would have failed every pull request it was meant
# to protect. Walking the chain is correct at any depth, including depth one.
#
# THE THREE FAILURES, and they are different problems:
#
#   broken     a link names a base branch that does not exist on the remote.
#              The chain has a hole: nothing can rebase onto a branch that is
#              not there, and the pull request's own merge target is fictional.
#   ambiguous  a branch in the chain has more than one open pull request, so
#              "its base" has no single answer. Whichever one a tool picked
#              would be a guess, and the guess would differ between tools.
#   mismatched the branch's declared GitHub base and its own remembered base
#              disagree. Both are claims about the same thing, made in two
#              places, and a stack where they differ will rebase onto one and
#              merge into the other.
#
# THE WALK IS BOUNDED. A chain is finite, but a misconfiguration can make it
# circular (two branches each declaring the other as base), and a gate that
# hangs is worse than one that fails. Every branch visited is remembered, and a
# repeat is reported as a cycle rather than followed.
#
# Env:
#   HEAD_BRANCH  required; the branch whose chain is walked.
#   MAX_DEPTH    optional; the walk's ceiling. Default 20, far above any real
#                stack, and a backstop rather than a limit anybody should meet.
#   STOP_AT      optional; the branch the chain is expected to terminate at.
#               Defaults to the repository's default branch. Reaching it is
#               success; the walk also stops at any branch with no open pull
#               request, which is the normal state of the stack's bottom.
set -euo pipefail

: "${HEAD_BRANCH:?HEAD_BRANCH is required}"

max_depth="${MAX_DEPTH:-20}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# THE POLICY IS CONSULTED BEFORE ANYTHING ELSE, including before the
# default-branch lookup below. "Inert" means taking no action, and a network
# call is an action: a repository that has turned stacking off must not have
# this gate reaching for the API, which would also make it fail offline for a
# project that never asked for any of this.
# THE POLICY IS CONSULTED FIRST, through the shared fragment. Whether a
# repository stacks at all is a property of the project, not of the harness, and
# "inert" must mean taking no action and failing nothing.
# shellcheck source=scripts/git-discipline/stacking-policy.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/stacking-policy.sh"
if ! stacking_enabled; then
  echo "check-stack-chain: stacking is off ($HARNX_POLICY_FILE); nothing to walk."
  exit 0
fi

gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT

# THE TERMINUS IS RESOLVED OR THE RUN FAILS. `|| echo main` was the same
# fail-open this script rejects below for `gh pr list`: an auth failure, a
# network failure and a rate limit would all silently make the terminus the
# literal `main`, and during an epic that promotes a trust anchor `main` is NOT
# the default branch. The walk would then stop at a branch that is not the top
# of the stack, or never reach one and be cut off by MAX_DEPTH, and either way
# it can report "the chain is intact" having verified something other than the
# chain.
#
# STOP_AT stays an explicit override, because a caller naming the terminus needs
# no lookup at all. Only the DEFAULT resolution is fatal.
stop_at="${STOP_AT:-}"
if [ -z "$stop_at" ]; then
  if ! stop_at="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>"$gh_err")"; then
    echo "::error::check-stack-chain: could not read the repository's default branch: $(tr '\n' ' ' <"$gh_err")" >&2
    echo "       This is a pipeline failure, not an answer. Refusing to assume 'main': during an epic that promotes a trust anchor the default branch is not main, and a walk that terminates at the wrong branch can report a chain intact having verified something else. Pass STOP_AT to name the terminus explicitly." >&2
    exit 1
  fi
  if [ -z "$stop_at" ]; then
    echo "::error::check-stack-chain: the repository reported an empty default branch name." >&2
    exit 1
  fi
fi

branch="$HEAD_BRANCH"
visited=""
depth=0
status=0

echo "check-stack-chain: walking from $branch, expecting to reach $stop_at."

while :; do
  if [ "$branch" = "$stop_at" ]; then
    # Guarded on `status`, so a run that already recorded a broken link does not
    # print "the chain is intact" underneath its own error. The exit code was
    # always right; the message contradicted it.
    if [ "$status" -eq 0 ]; then
      echo "check-stack-chain: reached $stop_at after $depth link(s). The chain is intact."
    fi
    break
  fi

  case " $visited " in
  *" $branch "*)
    echo "::error::check-stack-chain: the chain revisits '$branch', so it is a cycle rather than a chain. Two branches declaring each other as base cannot both rebase onto the other." >&2
    exit 1
    ;;
  esac
  visited="$visited $branch"

  # DEPTH COUNTS ESTABLISHED LINKS, and is incremented only once this branch is
  # known to have a base to walk to. Counting on entry overstated the chain by
  # one in the terminal case (a branch with no open pull request is not a link),
  # and made MAX_DEPTH trip an iteration early there.
  if [ "$depth" -ge "$max_depth" ]; then
    echo "::error::check-stack-chain: the chain is deeper than $max_depth links, which is far past any real stack. Refusing to keep walking; check for a misconfigured base." >&2
    exit 1
  fi

  # ONE API CALL, AND ITS FAILURE IS FATAL. Two calls asked the same question
  # twice and could disagree between them; worse, `|| echo 0` made an auth
  # failure, a network failure and a rate limit indistinguishable from "this
  # branch has no open pull request", which ENDS THE WALK AND REPORTS THE CHAIN
  # VERIFIED. A gate that reports success because it could not read anything is
  # the precise failure this floor exists to prevent, and it was doing it here.
  # STDERR IS CAPTURED SEPARATELY, not merged into the payload. `2>&1` folds
  # both streams together on a SUCCESSFUL call too, so any incidental notice the
  # CLI writes (an update banner, an auth warning) lands inside the JSON and the
  # parse below fails, turning a healthy chain into a false "not valid JSON"
  # failure. The trunk's review engine carries the same note for the same
  # reason. The captured text is used only to explain a real failure.
  if ! prs="$(gh pr list --head "$branch" --state open --json number,baseRefName 2>"$gh_err")"; then
    echo "::error::check-stack-chain: could not read the pull requests for '$branch': $(tr '\n' ' ' <"$gh_err")" >&2
    echo "       This is a pipeline failure, not an answer. Refusing to treat an unreadable branch as one with no pull request, which would end the walk and report the chain intact." >&2
    exit 1
  fi
  if ! open_count="$(printf '%s' "$prs" | jq 'length' 2>/dev/null)"; then
    echo "::error::check-stack-chain: the pull request list for '$branch' was not valid JSON: $prs" >&2
    echo "       Anything the CLI wrote to stderr: $(tr '\n' ' ' <"$gh_err")" >&2
    exit 1
  fi

  # AMBIGUITY IS CHECKED BEFORE THE BASE IS READ, because reading it first would
  # silently take whichever pull request the API happened to list first.
  if [ "$open_count" -gt 1 ]; then
    echo "::error::check-stack-chain: '$branch' has $open_count open pull requests, so its base is ambiguous. Close all but one before this chain can be verified." >&2
    exit 1
  fi
  if [ "$open_count" -eq 0 ]; then
    echo "check-stack-chain: '$branch' has no open pull request, so the chain ends here after $depth link(s)."
    break
  fi

  # Read from the payload already fetched, not from a second call.
  base="$(printf '%s' "$prs" | jq -r '.[0].baseRefName // empty')"
  if [ -z "$base" ]; then
    echo "::error::check-stack-chain: could not read the base of '$branch''s open pull request." >&2
    exit 1
  fi

  # THE BASE NAME IS VALIDATED AND THEN PASSED AFTER `--`. It arrives from the
  # GitHub API, so it is not attacker-authored in the usual sense, but it IS a
  # string this script hands to git as a positional argument, and git reads a
  # leading dash as an option wherever it can. A branch named
  # `--upload-pack=...` would become a transport option rather than a ref.
  # stack.sh guards its own two arguments this way, at the same `--`, and a gate
  # that walks branch names should not be the one place that does not.
  case "$base" in
  -* | *' '* | *'..'* | '')
    echo "::error::check-stack-chain: '$branch' names a base ('$base') that is not a usable branch name. A leading dash, a space or a '..' cannot be a ref, and git would read the first of those as an option." >&2
    status=1
    break
    ;;
  esac

  # BROKEN: the declared base does not exist on the remote.
  if ! git ls-remote --exit-code --heads origin -- "$base" >/dev/null 2>&1; then
    echo "::error::check-stack-chain: '$branch' is based on '$base', which does not exist on the remote. The chain has a hole: nothing can rebase onto a branch that is not there." >&2
    status=1
  fi

  # MISMATCHED: the branch's own remembered base disagrees with GitHub's.
  #
  # THIS ARM IS LOCAL-ONLY, and saying so is better than implying otherwise.
  # It reads `branch.<branch>.base`, which lives in a repository's own config
  # and is therefore absent from a fresh CI checkout by construction. In the
  # stack-chain-integrity workflow this arm never fires, and that is not a
  # defect to be worked around: a CI runner has no local declaration to
  # disagree with, so there is nothing there to check. What CI does check is
  # the broken, ambiguous and cycle cases, which are all remote facts.
  #
  # It earns its place when a contributor runs this by hand, where the
  # declaration does exist: `git stack` writes it when it creates a rung.
  # Read through resolve-base.sh so this gate and every other consumer of BASE
  # agree on what "remembered" means. The network tier is skipped deliberately:
  # that tier IS the GitHub base, and comparing it with itself would make this
  # check pass by construction.
  remembered="$(BRANCH="$branch" BASE_NO_NETWORK=1 BASE_FALLBACK="" \
    bash "$script_dir/resolve-base.sh" 2>/dev/null || true)"
  if [ -n "$remembered" ] && [ "$remembered" != "$base" ]; then
    echo "::error::check-stack-chain: '$branch' declares base '$remembered' locally but its open pull request targets '$base'. Both are claims about the same thing; a stack where they differ rebases onto one and merges into the other." >&2
    status=1
  fi

  depth=$((depth + 1))
  echo "check-stack-chain:   $branch -> $base"
  branch="$base"
done

if [ "$status" -ne 0 ]; then
  echo "::error::check-stack-chain: the chain from $HEAD_BRANCH is not intact. Each broken link is named above." >&2
  exit 1
fi
