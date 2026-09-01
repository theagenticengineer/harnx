# harnx

A monorepo generator. Repositories it creates get strong linters, formatters,
secret scanning, git discipline and a converging AI code review armed from
their first commit, rather than bolted on later.

This is the v2 rebuild, in progress. See `AGENTS.md` for how to work in this
repository, and the epic in issue #1 for the build order.

## Where things are

- `AGENTS.md`: setup, the rules every contributor and agent follows, and how
  the review pipeline works.
- `.agents/rules/`: standalone rule documents, one concern each.
- `docs/ai-review-setup.md`: how to stand up the AI review pipeline in any
  repository, written to stand on its own with no reference to harnx.
- `scripts/`: the gates themselves, grouped by concern. Every one of them is
  wired into a hook, a CI job, or both.

## A note on this repository's default branch

For the duration of the current epic the default branch is not `main`. It is a
trust anchor carrying only the AI review's security core.

The reason is that a `workflow_run` workflow only fires if it already exists on
the default branch, so the pull request that introduces one cannot exercise it.

That branch has its own README explaining the arrangement, including which of
its checks are real and which are deliberate placeholders that verify nothing.

This branch is the real floor. The workflows here are the ones that run.
