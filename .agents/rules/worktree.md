# Worktrees

Where a branch is checked out, and why it is never the primary clone.

## The rule

- **Every branch is worked on in a git worktree**, under `.worktrees/<branch>`.
- **The primary clone stays on `main`**, always. It is not a place to do work.
- `git stack <branch> <parent>` creates the worktree, so this is one command
  rather than a procedure to remember.

`check-worktree-path.sh` enforces it at `post-checkout`, and
`validate-branch-name.sh` enforces the naming the path is built from.

## Why not just check out a branch in the clone

Three reasons, and the third is the one that actually bites.

**Rungs are worked on together.** A stack is several branches open at once, and
propagating a base change upward means visiting each in turn. With one checkout
that is a sequence of stashes and switches; with worktrees each rung is a
directory that stays where you left it.

**A tool that resolves the repository root gets a stable answer.** `mise`,
`pre-commit` and every script here compute paths from the worktree they are run
in. One checkout switching branches underneath them means the same command
means different things at different times.

**A switch mid-review invalidates state nobody thought was state.** The local
review records the tree it reviewed, and the pre-push gate compares against it.

Switching branches in place changes that tree while changing nothing the gate
can see as deliberate. The next push is then refused for a reason that looks
unrelated to anything you did.

## The primary clone exempts exactly one name

The hooks that enforce this exempt the literal name `main`, and nothing else.
That has a consequence worth stating, because it is surprising the first time:

**A trust-anchor branch serving as the default is still not workable in the
primary clone.** It is not `main`, so the exemption does not cover it.

Work on it through a worktree like any other branch, or through git plumbing and
the API. The exemption is about the clone's resting state, not about which
branch happens to be the default today.

## Lifecycle

Creating and using a worktree is covered above. Removing one is not automated
here, deliberately:

- `git worktree remove .worktrees/<branch>` when a rung is genuinely finished.
- **There is no `prune-merged-worktrees` and no `sync-main`**, and that is not
  an omission.
- Both are defined in terms of merges: pruning removes branches already merged
  into `main`, and syncing fast-forwards past merges.
- Nothing merges mid-epic, so both would be tools that never fire, shipped cold,
  with no occasion to prove they work. They belong to a later increment, once
  merging is something that happens.

See [the ripple](ripple.md) for what a rung is and how a change propagates
between them.
