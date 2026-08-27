# harnx: trust anchor branch

**You are looking at this repository's default branch, and it is not the
project.** It carries 18 files: the security core of the AI-review pipeline,
and nothing else. The project's actual floor lives on the child branch
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

**`ci.yml` and `git.yml` here are placeholders that verify nothing.** Branch
protection requires eight status contexts that those two workflows produce.
GitHub reads workflow files from a pull request's head branch, so a pull
request whose head is *this* branch would otherwise report none of them and sit
blocked forever on checks that can never arrive. The files here exist to report
those contexts and do nothing else. Every job emits a warning saying so, and
both files say it in capitals at the top.

The real `ci.yml` and `git.yml`, which run the linters, formatters, secret
scanning, shell tests and git-discipline gates for real, are on the child
branch and replace these at the same paths. Every working branch in the epic
stacks on that child branch, so this version only ever runs for a pull request
whose head is this branch.

**`mise.toml` here is a deliberate subset**, pinning only the toolchain the
credentialed workflow actually executes. Do not reconcile it with the child
branch's copy; they are meant to differ.

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
