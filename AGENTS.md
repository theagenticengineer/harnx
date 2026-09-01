# AGENTS.md: how to work in this repo

Read this first in any session opened in this repo. It is an INDEX, not a
manual: every rule lives in its own document under `.agents/rules/`, and this
file exists to tell you which one you need.

That split is deliberate. A single file carrying every rule is read once, at
the top, and then skimmed. The rule you actually needed was in the middle of a
section about something else.

One concern per document means a link can point at the rule rather than at the
file that happens to contain it, and a document can grow without making its
neighbours harder to find.

`scripts/check-agents-index.sh` fails if this index and `.agents/rules/` ever
disagree, so a rule document that nothing links to cannot quietly exist and a
link here cannot point at a document that does not.

## Start here

- [Setup and author identity](.agents/rules/setup-and-identity.md): what to run
  after cloning, and the identity policy that is deliberately not optional. The
  repository refuses to work until a human states it.
- [Git discipline](.agents/rules/git-discipline.md): branch names, commit
  headers, the one-commit-per-push cadence, and why nothing bypasses a hook.
- [Task runner](.agents/rules/task-runner.md): `mise` as the single entry point
  for tools and commands, and which file owns the list of gates.

## The AI review

- [The local review loop](.agents/rules/local-review-loop.md): `mise run
  ai-review:local`, which token variable to export, and why a stacked branch
  must pass `BASE`.
- [The AI review in CI](.agents/rules/ai-review-ci.md): resolvable finding
  threads, the disposition a resolved Major owes, and the split-pipeline
  security model.
- [The review's credentials](.agents/rules/ai-review-credentials.md): which
  secrets exist, why they sit on a GitHub Environment rather than on the
  repository, and what provisions them.
- [Review-adjacent protections](.agents/rules/review-adjacent-protections.md):
  the CODEOWNERS requirement and stale-review dismissal that keep a required
  check from being weakened by the pull request it checks.

`docs/ai-review-setup.md` is separate from all of these: it is the standalone
operator's guide to standing this pipeline up in ANY repository, written with
no reference to harnx.

## How this repository is built

- [Paired-test homing](.agents/rules/tests-homing.md): a test lands in the same
  commit as the code it tests.
- [Ignore scoping](.agents/rules/gitignore-scoping.md): an ignore rule lives
  next to what it ignores, and what the root `.gitignore` is for.
- [Reproducibility and harness](.agents/rules/reproducibility-and-harness.md):
  pinned tools, and what a gate has to do to count as one.
