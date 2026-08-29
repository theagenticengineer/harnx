# Reproducibility and Harness

Two invariants govern how work runs in this repo. They are not preferences; a
gate enforces them. Do not weaken, bypass, or route around them.

## Use mise (reproducibility)

- mise pins the language versions, tools, and scripts. Every application or
  project runtime runs under mise-pinned tooling, never a bare system
  interpreter. For Python apps that means `mise exec -- uv run <console-script>`.
- Bare `python3` / `python`, ad-hoc virtualenvs, or system-installed tools for
  application code are forbidden: they make runs depend on whatever is on `PATH`
  and are not reproducible.
- Every JSON parse in this repo's own scripts already goes through
  mise-pinned `jq`, never a bare-interpreter one-liner; that is the pattern to
  extend, not a carve-out to invoke around it.

## Respect the harness

- The pre-commit hooks, CI required checks, branch protection, the worktree
  flow, and the rules in AGENTS.md and `.agents/rules/` are guardrails. A
  blocking gate is the system working, not an obstacle.
- Never bypass (`--no-verify`), weaken, or delete a gate to make a change
  land; see AGENTS.md's "Git discipline" section (branch protection is
  inviolable).
- New application runtime that introduces a way to break an invariant carries
  its own gate, landed in the same PR as the runtime.
- For example, a tool that can shell out to a bare interpreter ships a check
  that fails the build when the bare interpreter is used.
- This floor ships no such runtime yet. When one lands, its gate lands with it.
