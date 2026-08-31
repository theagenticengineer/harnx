# Resolving an ai-review finding

`ai-review-resolved` is a required check. It is red when the AI review has
found something nobody has answered yet.

This page is what a red gate links to. It exists because a red
`ai-review-resolved` usually means **a decision is pending**, not that something
is broken, and those two need completely different responses.

## Table of contents

- [What turns the gate red](#what-turns-the-gate-red)
- [The three dispositions](#the-three-dispositions)
- [Resolving a thread fires no webhook](#resolving-a-thread-fires-no-webhook)
- [A rebase never clears a finding](#a-rebase-never-clears-a-finding)
- [Deferring, and the issue you may not file](#deferring-and-the-issue-you-may-not-file)
- [What the gate does not check](#what-the-gate-does-not-check)
- [A worked example](#a-worked-example)

## What turns the gate red

Two independent questions, both asked on every run.

**Is anything still open?** `check-resolved.sh` fails while any review thread
carrying a Major marker is unresolved. Minor and nit threads never block.

**For everything that was closed, what happened to it?**
`check-dispositions.sh` fails when a **resolved** Major thread carries no
written disposition.

The second exists because of an incentive. Resolving a thread is what clears the
gate, so the single cheapest way to go green is to resolve everything and move
on.

That is not hypothetical. Ten real findings on this repository's own genesis
pull requests were triaged, answered, resolved, and would have evaporated with
the threads had a human not asked where they went.

## The three dispositions

Reply on the thread with one line of exactly this shape, then resolve the
thread. The keyword is case-insensitive.

```text
Disposition: fixed
Disposition: refuted
Disposition: deferred to #123
```

Three, because there are exactly three honest things to do with a finding.

- **fixed.** You changed the code. Say what you changed.
- **refuted.** The finding is wrong. Say why, with a reproduction rather than
  an opinion.
- **deferred to #N.** The finding is real and is not being done now, so it needs
  somewhere to live.

The **last** disposition in a thread wins. Replies are read in order, so a
finding deferred and then actually fixed is judged on where it ended up, not on
where it started.

## Resolving a thread fires no webhook

This is the single most confusing thing about the gate, and it follows from how
GitHub works rather than from anything here.

Resolving a review thread emits no event, so nothing re-runs the pipeline. What
happens next therefore depends on which disposition you chose.

**fixed self-heals.** The commit that carries the fix fires `synchronize`, the
pipeline re-runs, and the gate recomputes on its own.

**refuted and deferred do not.** Neither adds a commit, so nothing fires. Re-run
the failed jobs by hand:

```sh
gh run rerun --failed
```

Without that, the gate stays red forever on a finding that was already answered
properly.

## A rebase never clears a finding

A rebase moves the code a thread is anchored to. GitHub marks the thread
**outdated** and keeps it.

An outdated thread is still an unresolved thread, so it still blocks. Rebasing
to make a finding go away does not work, and it costs a run to discover.

Answer the finding instead. An outdated thread whose code genuinely no longer
exists is a legitimate `Disposition: refuted`, with the reason being that the
code it describes is gone.

## Deferring, and the issue you may not file

A deferral is checked in **both directions**, and one direction alone is worth
very little.

**Reply to issue.** The reply names an explicit issue number, and that issue
exists and is open.

**Issue to reply.** That issue's body links back to this exact review comment,
by its `#discussion_r<id>` anchor, and carries the finding written out in the
issue's own words.

Requiring only the first would let a reply name any open issue in the
repository. Pointing at a plausible-looking issue is exactly how a finding gets
buried while looking tracked.

Requiring the second means somebody wrote the finding down where it will be
worked. The two halves cannot drift apart either, because deleting that
criterion from the issue turns the gate red again.

**The pasted link is not enough.** The block containing the anchor must carry
at least twelve words of its own. A bare URL records where a finding was
raised, never what has to be done about it.

### An agent never files the issue

`#N` must name an issue that **already exists**. There are exactly two
permitted moves.

- Add the finding to an issue that is already open, with its reasoning, as a new
  acceptance criterion citing the anchor.
- Stop, and design the issue with a human.

Filing an issue to satisfy a gate is how a backlog fills with tickets nobody
scoped and nobody will do. The finding is the cheap part; deciding it deserves
its own issue is the part that needs judgement.

## What the gate does not check

Stated plainly, so nobody mistakes this for more than it is.

For `deferred`, both directions above are enforced mechanically.

For `fixed` and `refuted`, the marker is taken at its word. No mechanical check
can confirm that a fix is real or that a refutation is sound.

That is deliberate rather than a gap. It makes burying a finding a written,
deliberate lie instead of a silent omission, which is the most a gate can do.

**Who created `#N` is not checked.** A deferral pointing at an issue the review
App itself opened would pass. Enforcing that is a decision for a human to make
rather than an agent to assume; the payload the gate already fetches carries
`user.login`, so it is available if somebody wants it.

## A worked example

A Major finding says a temporary file leaks on one path.

You read the code and the claim is wrong: the removal is there, inside a
condition that is easy to read past. Reply on the thread:

```text
Disposition: refuted

The removal runs in the `elif` condition, as the left operand of `&&`, so it
happens before the test that sends control to the `else` branch. Reproduced
with state=open: the else branch is reached and no temp file survives.
```

Resolve the thread. No commit was made, so nothing fires: run
`gh run rerun --failed`. The gate recomputes, finds one resolved Major with a
written disposition, and goes green.
