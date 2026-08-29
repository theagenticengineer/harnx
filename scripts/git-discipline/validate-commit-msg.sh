#!/usr/bin/env bash
set -euo pipefail
header="$(sed -n '1p' "$1")"

# fixup!/squash!/amend! commits are transient: `git rebase --autosquash` melds
# them into their target, so they never reach final history. Both checks
# below exempt them.
autosquash_re='^(fixup|squash|amend)! '
if [[ "$header" =~ $autosquash_re ]]; then
  exit 0
fi

line2="$(sed -n '2p' "$1")"
# Any non-blank content from line 3 onward is a body: a message may separate
# the header from its body with more than one blank line, so inspecting only
# line 3 would reject a valid body that starts on line 4. Drop git's own
# comment lines before the emptiness check: the commit-msg hook runs BEFORE
# git's cleanup pass, so an interactively-authored commit with no real body
# still carries the "# Please enter the commit message..." template lines
# here, which would otherwise make `body` look non-empty.
#
# Only lines matching git's own template convention, "# " (hash-space) or a
# bare "#", are dropped, NOT every line starting with "#": a legitimate body
# line referencing an issue, e.g. "#123 relates to an old ticket" (hash
# directly followed by a digit, no space), is real content and must not be
# silently stripped into a false "empty body" rejection.
#
# Two separate `-e` patterns, not one with `\|` alternation: BSD sed (macOS
# default /usr/bin/sed) does not support GNU sed's `\|` extension in basic
# regex, verified live, it silently fails to match, letting template lines
# through uncaught (a different BSD-vs-GNU sed incompatibility than the
# `-e '1{...}'` brace-addressing one already hit and fixed in
# scripts/ai-review/review-engine.sh's fence-strip logic, same broad category).
body="$(sed -n '3,$p' "$1" | sed -e '/^# /d' -e '/^#$/d' | tr -d '[:space:]')"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-discipline/parse-commit-header.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/parse-commit-header.sh"

[[ "$header" =~ $COMMIT_HEADER_RE ]] || {
  echo "header must match 'type(#N): title' (title >=10 chars, no trailing whitespace)" >&2
  exit 1
}
[[ -z "$line2" ]] || {
  echo "line 2 must be blank (header/body separator)" >&2
  exit 1
}
[[ -n "$body" ]] || {
  echo "a body paragraph is required after the blank line" >&2
  exit 1
}

# Cross-check the header's issue number against the current branch's, so the
# two can never drift apart. COMMIT_MSG_BRANCH lets a caller (the CI
# commitlint job, which checks out a detached merge ref) supply the real
# branch name explicitly; falls back to git HEAD for the local hook, where the
# real branch is actually checked out. Only meaningful on a real feature
# branch; "main" and a detached HEAD carry no issue number to check against.
branch="${COMMIT_MSG_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)}"
if [[ "$branch" != "main" && "$branch" != "HEAD" ]]; then
  if [[ "$branch" =~ ^[a-z]+-([0-9]+)-[a-z0-9-]+$ ]]; then
    branch_n="${BASH_REMATCH[1]}"
    if [[ "$header" =~ \(#([0-9]+)\): ]]; then
      header_n="${BASH_REMATCH[1]}"
      if [[ "$header_n" != "$branch_n" ]]; then
        echo "header issue #$header_n does not match branch '$branch' issue #$branch_n" >&2
        exit 1
      fi
    fi
  fi
fi
