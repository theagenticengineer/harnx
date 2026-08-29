# The AI review in CI

The same review that runs locally runs again in CI on every push, and posts
each finding as its own resolvable pull-request comment thread. The
`ai-review-resolved` check blocks merge until every Major thread is resolved.

`docs/ai-review-setup.md` is the standalone operator's guide to standing this
up in any repository. This document is what a contributor here needs to know.

## Resolving a Major thread obliges you to say what happened to it

**Resolving a Major thread obliges you to say what happened to it.** Reply
in the thread with exactly one of:

- `Disposition: fixed`
- `Disposition: refuted`
- `Disposition: deferred to #<issue>`

**A deferral is checked in both directions**, and both are required:

- **comment to issue**: the reply names an explicit issue number, and that
  issue exists and is OPEN.
- **issue to comment**: that issue's body links BACK to this exact review
  comment, by its `#discussion_r<id>` anchor.

One direction alone is worth little. A reply can name any open issue in the
repository, so "deferred to #36" on its own proves nothing about whether #36
has any idea the finding exists. Pointing at a plausible-looking issue is
exactly how something gets buried while looking tracked.

Requiring the issue to link back means somebody actually wrote the finding down
where it will be worked. The two halves cannot drift apart either, because
deleting the acceptance criterion turns the gate red again.

So: before resolving, add an acceptance criterion to the target issue citing
the comment's permalink. "Deferred to a later increment" is not a disposition;
it is a promise to nobody. If no issue is the right home, file one, or ask for
one to be filed.

This is enforced, not merely asked for: `check-dispositions.sh` runs inside
the `ai-review-resolved` gate and fails on a resolved Major finding with no
disposition, or one deferred to an issue that is missing, closed, or silent

## Why it is a rule at all

The reason it is a rule at all: resolving a thread is what clears the merge
gate, so the single action that unblocks a merge is also the action that hides
the finding. The cheapest path to green is to resolve everything and move on,
and nothing afterwards remembers what those threads said.

That is not hypothetical here. Ten real findings on this repository's own
genesis pull requests were triaged, answered, resolved, and would have
evaporated with the threads if a human had not asked where they had gone. They
are now acceptance criteria on #36.

`fixed` and `refuted` are taken at their word, since no gate
can confirm a fix is real or a refutation sound, but a deferral is checkable
and is therefore checked.

## The pipeline is split in two, and the split is the security model

CI runs it as a SPLIT pipeline, because CI executes the pull request's code
before anyone has reviewed it, and the review needs live credentials:

- `.github/workflows/ai-review.yml`, the PR workflow (`pull_request`), runs on
  the pull request's own branch. It holds no credential of any kind, and it is
  ONLY a trigger. It produces nothing the trusted side consumes.
- `.github/workflows/ai-review-trunk.yml`, the trunk workflow
  (`workflow_run`), holds every credential. GitHub always resolves a
  `workflow_run` workflow's YAML, and everything it checks out, from the
  repository's DEFAULT branch, never from the pull request that triggered it.
  So a pull request may rewrite any review script freely and the edit changes
  nothing about the run.
- The trusted side computes the diff ITSELF, from GitHub's own refs, in
  `scripts/ai-review/extract-diff.sh`.

## Why the PR side no longer produces the diff

It used to run `git diff` and upload the result as an artifact, and the
credentialed workflow reviewed whatever bytes arrived. Because the pull request
author controls that file, the review's INPUT was attacker-authored: replacing
one line with `echo "benign" >diff.txt` produced a pull request whose review was
of the word "benign", and the required `ai-review-resolved` check went green
over code nothing had read.

The trusted side now fetches `refs/pull/<n>/head` and the base branch itself,
and refuses to continue if the head it fetched is not the commit the run is a
verdict about.

A note on wording you may find elsewhere. Descriptions of this mechanism often
say a pull request's edit to a trusted script "sits inert until a human merges
it". That is true of an ordinary repository and misleading in a stacked epic,
which never merges.

The rule that always holds is that the trusted side resolves from the default
branch. An edit anywhere else changes nothing until it reaches that branch, by
whatever route.

Two rules keep that true, and both are easy to undo by accident:

- No `ref:` on any checkout in the trunk workflow. It defaults to the default
  branch; `ref: ${{ github.event.workflow_run.head_sha }}` silently checks
  out the pull request's code instead, with every credential present.
- The pull request number and head SHA come from the `workflow_run` payload,
  never from the artifact. Letting pull-request-authored content name them
  would let one pull request post its review, under the App's identity, onto
  another.
