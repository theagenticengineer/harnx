#!/usr/bin/env bash
# stack.sh
# Creates the next rung of the stack: a branch and its worktree, based on the
# branch below it.
#
#   git stack <branch> <parent>
#
# Reachable as `git stack` because scripts/mise/setup-git-config.sh registers
# an alias for it. The alias delegates here rather than inlining the git
# command for two reasons: the logic below is not a one-liner (it has to find
# the primary worktree, which is not the caller's cwd), and a tracked script
# can carry a paired test under scripts/tests/, which a line of .git/config
# cannot.
#
# The parent is a BRANCH NAME, and the new branch is created from origin/<parent>
# rather than the local ref. Two consequences, both deliberate:
#
#   1. The rung starts from what is actually pushed, so it can never be built
#      on a local commit nobody else can see.
#   2. git's own branch.autoSetupMerge default sets the new branch's
#      upstream-tracking ref to origin/<parent>. That tracking ref IS the
#      branch's remembered base, and every later step of the ripple depends on
#      it: with pull.rebase=true (also set by setup-git-config.sh), a plain
#      `git pull` on this branch rebases it onto its parent, with git's own
#      fork-point detection, correctly even after the parent was rewritten.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: git stack <branch> <parent>" >&2
  echo "  <branch>  the new rung, named <type>-<issue-N>-<kebab-title>" >&2
  echo "  <parent>  the branch below it, which must exist on origin" >&2
  exit 2
fi

branch="$1"
parent="$2"

# Both arguments are validated with the floor's OWN branch-name gate rather
# than a second regex written here: the hooks own that regex and it is never
# duplicated, so a change to the naming rule cannot leave this command
# accepting names the rest of the floor rejects.
#
# It is also the security check. `branch` is interpolated into the worktree
# path, so an unvalidated `../../evil` would place a worktree outside
# .worktrees/ entirely, and a leading `-` on either argument would be read by
# git as a flag rather than a value. The gate's own pattern refuses both: it
# requires <type>-<issue-N>-<kebab-title>, whose character class admits no dot
# or slash and whose anchor admits no leading dash. `main` passes, which is
# correct for a parent and harmless for a branch, since git refuses to create
# a branch that already exists.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for pair in "branch:$branch" "parent:$parent"; do
  role="${pair%%:*}"
  value="${pair#*:}"
  # Keep the validator's own message rather than discarding it. It is the
  # component that knows WHY a name failed, and replacing that with a generic
  # sentence throws away the only specific thing the caller needed.
  if ! reason="$("$script_dir/validate-branch-name.sh" "$value" 2>&1)"; then
    echo "stack: the <$role> argument '$value' is not a valid branch name." >&2
    [ -n "$reason" ] && echo "       ${reason#*: }" >&2
    echo "       Expected <type>-<issue-N>-<kebab-title>, or 'main'." >&2
    exit 2
  fi
done

# Worktrees live under the PRIMARY clone, never under whichever worktree
# happens to be the caller's cwd. Running this from inside .worktrees/feat-2
# must not create .worktrees/feat-2/.worktrees/feat-34.
#
# Two cases, because no single git command answers this correctly on its own.
#
# Comparing --git-dir with --git-common-dir tells them apart: they are equal
# in the primary worktree, and differ in a linked one (whose git dir is
# <common>/worktrees/<name>).
#
#   In the PRIMARY worktree, --show-toplevel is authoritative and stays correct
#   under --separate-git-dir, where the repository keeps a .git FILE in the
#   worktree and the real directory elsewhere.
#
#   In a LINKED worktree, --show-toplevel points at the wrong place by
#   definition, so git has to be asked which worktree is primary.
#
# Two tempting one-liners are both wrong, which is why this is spelled out.
# dirname of --git-common-dir assumes the git dir sits directly inside the
# worktree root, which --separate-git-dir breaks. And `git worktree list`
# itself reports the GIT DIR rather than the working tree as the first entry
# under --separate-git-dir (verified on git 2.51), so it cannot be trusted
# blindly either. Hence the explicit verification below rather than a guess.
git_dir="$(cd "$(git rev-parse --git-dir)" && pwd)"
common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
if [ "$git_dir" = "$common_dir" ]; then
  primary_root="$(git rev-parse --show-toplevel)"
else
  primary_root="$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')"
fi

# Verify rather than assume, and refuse loudly instead of creating a worktree
# somewhere surprising. A real worktree root always carries a .git entry, file
# or directory; the misreported path above carries neither.
if [ -z "$primary_root" ] || [ ! -e "$primary_root/.git" ]; then
  echo "stack: could not resolve the primary worktree (got '${primary_root:-<empty>}')." >&2
  echo "       This repository's layout is one 'git worktree list' misreports," >&2
  echo "       most likely a --separate-git-dir clone used from a linked worktree." >&2
  echo "       Run 'git stack' from the primary clone instead." >&2
  exit 1
fi

# Fetch first: origin/<parent> has to exist and be current, or the new rung is
# based on a stale idea of its parent. --prune keeps deleted remote branches
# from lingering as plausible-looking bases.
git -C "$primary_root" fetch origin --prune

if ! git -C "$primary_root" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
  echo "stack: 'origin/$parent' does not exist." >&2
  echo "       The parent rung must be pushed before a rung can be stacked on it." >&2
  exit 1
fi

# --track is explicit rather than left to git's branch.autoSetupMerge default.
# The default does set the tracking ref today, but it is a CONFIG, and a
# developer with branch.autoSetupMerge=false in their global config would get a
# branch with no upstream and no error: every later `git pull` would then have
# nothing to rebase onto, which is the one failure this whole protocol cannot
# absorb. Asking for it explicitly costs nothing and removes the dependency.
git -C "$primary_root" worktree add --track -b "$branch" -- ".worktrees/$branch" "origin/$parent"

# Verify rather than assume. --track is a request; this asserts it took effect,
# so a future git or a config nobody remembers setting fails here, loudly, at
# creation time, instead of silently at the first ripple.
worktree="$primary_root/.worktrees/$branch"
upstream="$(git -C "$worktree" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
if [ "$upstream" != "origin/$parent" ]; then
  echo "stack: '$branch' was created but its upstream is '${upstream:-<none>}', not 'origin/$parent'." >&2
  echo "       That tracking ref is the branch's remembered base; without it a plain" >&2
  echo "       'git pull' has nothing to rebase onto and the ripple breaks silently." >&2
  # Roll back rather than leave a half-configured rung lying around. It is
  # seconds old and provably empty (nothing has been checked out into it but
  # the parent's own tree), so nothing can be lost, and the alternative is
  # worse than an error: a worktree that looks ready, is not, and fails later
  # at the first ripple instead of here. Same invariant the missing-parent
  # path already holds, which is that a refused rung leaves nothing behind.
  echo "       Rolling back the partially created rung..." >&2
  git -C "$primary_root" worktree remove --force ".worktrees/$branch" 2>/dev/null || true
  git -C "$primary_root" branch -D "$branch" >/dev/null 2>&1 || true

  # Verify the rollback instead of announcing it. Both calls above swallow
  # their errors deliberately, since either can legitimately have nothing to
  # do, which also means neither can be trusted to report a real failure. So
  # check the end state. A false "rolled back" is worse than no message at
  # all: it sends the reader looking for the problem somewhere it is not.
  leftover=""
  if [ -d "$primary_root/.worktrees/$branch" ]; then
    leftover="worktree"
  fi
  if git -C "$primary_root" show-ref --verify --quiet "refs/heads/$branch"; then
    leftover="${leftover:+$leftover and }branch"
  fi
  if [ -n "$leftover" ]; then
    echo "       Rollback INCOMPLETE: the $leftover could not be removed." >&2
    echo "       Clean up by hand before retrying:" >&2
    echo "         git -C '$primary_root' worktree remove --force .worktrees/$branch" >&2
    echo "         git -C '$primary_root' branch -D $branch" >&2
    exit 1
  fi

  echo "       Rolled back. Check 'git config --get branch.autoSetupMerge' and retry." >&2
  exit 1
fi

echo "stack: created '$branch' from 'origin/$parent'"
echo "       worktree: $worktree"
echo "       tracking: $upstream"
