# harnx: trust anchor branch

**You are looking at this repository's default branch, and it is not the
project.** It carries only the security core of the AI-review pipeline, and
nothing else. The project's actual floor lives on the child branch
immediately above this one.

This is temporary. It lasts for the duration of one epic, after which the
default branch returns to `main`.

## Why a branch like this exists

The AI review runs in CI and holds live credentials: an API key for the review
model, and a GitHub App key that lets it post review comments. CI runs the code
in a pull request before any human has looked at it, so any credential within
reach of that code is a credential a pull request can take.

The fix is to split the pipeline in two, and it turns on one behaviour of
GitHub Actions:

- a `pull_request` workflow reads its own YAML, and every script it calls, from
  the **pull request's branch**, so its author controls what it runs;
- a `workflow_run` workflow always reads them from the repository's **default
  branch**, so the pull request gets no say.

All the credentials therefore live in the `workflow_run` half, which resolves
from the default branch. And a `workflow_run` workflow only fires if it already
exists on the default branch, which is why the pull request that introduces one
cannot exercise it, and why this branch has to be the default branch for the
mechanism to run at all.

`docs/ai-review-setup.md` in this branch explains the whole architecture from
scratch, for any repository, with no reference to harnx.

## Two things here are deliberately not what they look like

**`ci.yml` and `git.yml` here are mostly placeholders.** Branch protection
requires eight status contexts that those two workflows produce. GitHub reads
workflow files from a pull request's head branch, so a pull request whose head
is *this* branch would otherwise report none of them.

It would then sit blocked forever on checks that can never arrive. The
placeholder jobs exist to report those contexts and do nothing else. Each one
emits a warning saying so, and both files say it in capitals at the top.

Two jobs are real. `ci.yml`'s `shell-tests` runs `mise run test` over
`scripts/tests/*.bash`, which covers every script this branch owns, and
`pre-commit` runs `mise run lint` over the same tree. `actionlint` and
`gitleaks` are the placeholders.

The real `ci.yml` and `git.yml`, which run the linters, formatters, secret
scanning, shell tests and git-discipline gates for real, are on the child
branch and replace these at the same paths. Every working branch in the epic
stacks on that child branch, so this version only ever runs for a pull request
whose head is this branch.

**`mise.toml` here is a deliberate subset**, pinning only the toolchain the
credentialed workflow actually executes. Do not reconcile it with the child
branch's copy; they are meant to differ.

## A change here does nothing until it reaches this branch

**Every script the credentialed workflow runs is resolved from the `DEFAULT`
branch, so editing one anywhere else changes nothing.** That is the security
guarantee working exactly as designed, and it is also the single easiest thing
to forget while working on the epic.

`.github/workflows/ai-review-trunk.yml` is `workflow_run`-triggered. GitHub
resolves its YAML, and everything `actions/checkout` fetches inside it, from
the default branch.

So a fix to `scripts/ai-review/post-findings.sh` committed on the child branch
is not a fix to anything yet. The pipeline that posts findings on that child
branch's own pull request is still running this branch's copy.

The symptom is a pull request whose review behaves exactly as it did before
the fix, with a green commit sitting in the branch that supposedly contains
it.

Other descriptions of this mechanism say the edit sits inert "until a human
merges it". That is true of an ordinary repository, and misleading here: this
epic never merges, its branches stack.

The rule that always holds is the one above. **A trunk-executed change belongs
on this branch**, and the child branch inherits it by rebasing, not the other
way round.

Trunk-executed, and therefore in scope for this branch:

- `.github/workflows/ai-review-trunk.yml`
- every script under `scripts/ai-review/` that workflow invokes

Not trunk-executed, and therefore in scope for the child branch:

- `.github/workflows/ai-review.yml`, which runs from the pull request's own
  branch and is what the pull request author controls
- the hygiene floor, and everything the child branch's `ci.yml` runs

### "Trunk-executed" is not the only test, and it was never sufficient

The rule above answers *where does this run*, which is the right question for
anything holding a credential. It is the wrong question for deciding what the
branch is **about**, and reading it as the only test produced two visible
errors.

It said `scripts/tests/` belongs to the child branch. This branch has thirty
test files. They are here because criterion 24 requires the anchor to verify
its own scripts, and a test executes on a runner and on a laptop rather than in
the trunk workflow, so *trunk-executed* excludes every one of them.

And it kept the local review runner off this branch. `scripts/mise/ai-review-local.sh`
runs the review engine, and `scripts/ai-review/check-locally-reviewed.sh`
refuses a push whose tree that review has not cleared. Neither is invoked by
the trunk workflow, so *trunk-executed* said child branch. By subject both are
the AI review, and the engine they drive exists only here. While they sat one
branch up, this branch, the default branch every `workflow_run` in the stack
resolves from, was the only branch in the stack whose pushes no review gated.

**So there are two tests, and both apply.** A file is in scope here if the
trunk executes it, **or** if it is part of the AI review itself. The first is
about credentials. The second is about cohesion, and it is why
`review-engine.sh` and the two files that drive it now live on one branch
rather than two.

## If you are building the repository generator

**The floor a generated repository receives is emitted from the child branch's
tree, never from this branch's.**

A generated repository gets the complete floor at its root in its first commit,
with real workflows, and it never needs a trust anchor: its own default branch
carries the `workflow_run` listener from the start, so the bootstrap problem
this branch solves does not exist there.

Defining "the floor" as "whatever is on the default branch" would ship the
placeholder workflows above into every generated repository, which would then
report eight green checks that verified nothing. That is the single way these
files can cause harm beyond this branch, and it is why the constraint is
written down here rather than left to be rediscovered.
