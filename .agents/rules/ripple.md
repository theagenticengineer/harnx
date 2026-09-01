# The ripple

How a change reaches every rung above it, and what must be true before it does.

This is the rule document for the whole stacking story: why a stack exists,
what a rung is, how a change to a base propagates up, and how the chain is kept
provably intact. The gates named here are enforced; the reasoning is here so
that when one of them fails you know what it was protecting.

## Why a stack, and not one branch

Each increment is a rung. A rung stacks on the branch below it and is reviewed
on its own, so a reviewer sees one increment's diff rather than the sum of
everything since `main`.

Nothing merges mid-epic. The whole stack stays open until the cutover, which is
why several rules here refuse to reason about merges at all: a gate whose
premise is "after this merges" has no occasion to fire, and one that fires
anyway is doing something other than what it says.

## Creating a rung

`git stack <branch> <parent>` creates the worktree, sets its upstream, and
records the parent:

- the worktree lands under `.worktrees/<branch>`, never in the primary clone;
- `--track` points the branch at its parent, which is where `git push` and
  `git pull` go;
- `branch.<branch>.base` records what the rung is stacked ON, which is a
  different claim from where push and pull go.

That last one matters more than it looks. Tracking is repointable in one
command and is set by tooling; the base is a declaration. `resolve-base.sh`
reads the declaration first for exactly that reason.

## Resolving a base

Every gate that needs to know what a branch is stacked on asks
`scripts/git-discipline/resolve-base.sh`, in priority order, first match wins:

1. `git config branch.<branch>.base`, the explicit declaration above;
2. the open pull request's base, which is authoritative because it is what a
   merge would target, but costs a network call;
3. `main`.

**No gate resolves this for itself.** Three of them consume it, and if each
answered differently a branch could satisfy one and fail another for reasons
neither reports.

`BASE_NO_NETWORK=1` skips tier 2. A pre-push hook sets it, because a network
call on every push fails offline, without a token, and under a rate limit.

## The ripple: propagating a base change upward

When a rung changes, every rung above it is now behind. Propagating that is a
`git pull` per rung, bottom to top:

1. Fix at the rung that owns the problem, not at the top.
2. In the rung above, `git pull`. `pull.rebase=true` is set by
   `scripts/mise/setup-git-config.sh`, so this rebases rather than merging.
3. Resolve conflicts in favour of the BASE. The rung below has already been
   reviewed and converged; the rung above has not.
4. Re-run the local review, converge it, then push.
5. Repeat upward.

**Never merge the base into the branch.** A merge commit inside a stacked branch
corrupts `git pull --rebase`'s calculation of what is uniquely yours, and
silently duplicates the base's own commits into the branch's history on a later
pull.

Both halves are enforced: `no-merge-commit` locally, and
`ci-check-merge-commits.sh` over the pull request's commit range. The local hook
is bypassable with `--no-verify`; the commits are not.

## Keeping the chain provable

`stack-chain-integrity` walks the chain link by link and fails on three
different problems:

- **broken**: a link names a base branch that does not exist on the remote;
- **ambiguous**: a branch has more than one open pull request, so "its base"
  has no single answer;
- **mismatched**: the local declaration and the GitHub base disagree.

It walks rather than comparing against `main`, because only the bottom rung
bases on `main`. A check asking "is this pull request's base `main`?" is right
for exactly one pull request in the stack and wrong for every other.

## Converging a rung

The review runs twice, and the two are not interchangeable:

- **Locally first**, over the whole diff against the resolved base. Drain to a
  clean pass. `check-locally-reviewed.sh` is a pre-push gate: a tree that has
  not passed cannot be pushed.
- **Then CI**, which additionally reviews the issue body and the pull request
  description against what was delivered. A clean local pass is a precondition
  for pushing, not a prediction of CI.

**Stream both convergence tables live.** A run that reports only its verdict
hides whether the finding count is shrinking, which is the one thing that says
whether the loop is converging or oscillating. One table, both runners, so the
local-then-CI sequence for each commit is visible in one place.

Resolving a Major finding obliges a disposition: `fixed`, `refuted`, or
`deferred to #<issue>`. See
[the AI review in CI](ai-review-ci.md) for what each means and how a deferral is
checked in both directions.

**Halt, never merge.** When a rung is green, it stays open. The cutover is a
deliberate, human-gated step and not the end of a rung's own loop.

## Inert until the cutover

The trust anchor is the default branch for the duration of the epic, and
`ai-review-trunk.yml` is `workflow_run`-triggered, so **GitHub resolves it, and
every script it invokes, from the default branch**. That has a consequence
which is easy to state and easy to forget:

**A change to a trunk-executed path, made on a child branch, changes the local
loop immediately and changes nothing in CI until the cutover.**

The hazard is belief rather than drift. On 2026-08-29 `evaluate-gate.sh` and
`require-diff.sh` were written on a child and assumed live. They were not, and
nothing said so.

A parity check would be the wrong remedy: it would enforce a sameness the
trunk-scope policy deliberately does not want. The remedy is this list.

**Trunk-executed, so a child's copy is not what CI runs:**

- `.github/workflows/ai-review-trunk.yml`
- every script under `scripts/ai-review/` that it invokes, including
  `extract-diff.sh`, `review-engine.sh`, `probe.sh`, `union.sh`,
  `reconcile.sh`, `post-findings.sh`, `check-resolved.sh`,
  `check-dispositions.sh`, `evaluate-gate.sh`, `require-diff.sh`,
  `post-check-run.sh` and `post-ci-status.sh`
- `scripts/configure-protection.sh`, whose effect is a repository setting
  written by running it, not by merging it

**Not trunk-executed, so a child's copy IS what runs:**

- `.github/workflows/ci.yml`, `git.yml`, `stack-chain-integrity.yml` and
  `ai-review.yml`, all of which resolve from the pull request's own branch
- everything under `scripts/git-discipline/`, `scripts/mise/` and
  `scripts/tests/`
- the hygiene floor: `.pre-commit-config.yaml`, `mise.toml`, the linter configs

**The single rule.** A fix to a trunk-executed path is verified against LOCAL
behaviour and is never reported as having changed CI. Saying "CI now does X"
about such a change is false until the cutover, whoever says it.

Issue #44 owns walking this list at the cutover.
