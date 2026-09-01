# Task runner

`mise.toml` is the single entry point for tool versions and commands, so every
floor command runs through the pinned toolchain, never the developer machine's
tools. List tasks with `mise tasks`; run one with `mise run <name>`.

- `mise run lint` runs every floor gate over the whole tree, by way of
  `pre-commit run --all-files`. It does not invoke the linters itself.
- `mise run test` runs the shell-test suite (`scripts/tests/*.bash`), the same
  set the `shell-tests` CI job runs.
- `mise run ai-review:local` runs the local AI review against the working tree.
  See [local-review-loop.md](local-review-loop.md).

## There is one list of gates, and `mise.toml` is not it

`.pre-commit-config.yaml` says WHAT the floor checks. `mise.toml` says WHICH
VERSION runs. One axis each, and neither file answers the other's question.

It was briefly both. Five `lint:<type>` tasks each ran a tool over
`git ls-files`, while `.pre-commit-config.yaml` declared the same tools again
as hooks, with their own separately pinned versions. Two lists, and nothing
made them agree: a gate added to one was absent from the other, and the git
hook and CI could enforce different rules while both reported success.

Losing the per-tool tasks costs nothing. `pre-commit run <hook-id> --all-files`
runs one gate, from the list that is now the only one. A convenience wrapper
added to `mise.toml` must delegate to pre-commit rather than name a tool, or
the second list is reborn.
