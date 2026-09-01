# The local review loop

The AI review runs in two places on the same engine, with deliberately
different trust properties: here, against your working tree, and in CI against
the pull request. This document is the local half. The CI half is
[ai-review-ci.md](ai-review-ci.md), and `docs/ai-review-setup.md` is the
standalone operator's guide to provisioning it.

## Run it before you push, over the whole diff

- `mise run ai-review:local` sends the working diff to a review model and
  reports findings by severity (Major, Minor, nit).
- It reads the engine token from **`AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN`**, not
  from `CLAUDE_CODE_OAUTH_TOKEN`.
- That second name is the variable the Claude Code CLI itself authenticates
  with. Exporting it in a shell profile silently replaces your saved Claude
  Code login in every session started from that shell.
- Run `claude setup-token` and export the value under the `AI_REVIEW_` name.
  There is deliberately no fallback to the old name, and the script warns if it
  finds one set.
- It diffs against the remote's **default branch**, resolved live, unless
  `BASE` says otherwise, so on a STACKED branch always
  pass `BASE=origin/<the branch below this one>`.
- Without it the diff carries every inherited, already-reviewed change too. The
  model burns tokens re-reviewing them, reports findings on code this branch
  never touched, and the pre-push gate records the inflated tree as reviewed.
- A Major finding blocks the push, through the pre-push hook
  `scripts/ai-review/check-locally-reviewed.sh`, until it is fixed or recorded
  as dismissed in `.harnx/ai-review-dismissed.json`, which is gitignored and
  local-only.
- That ledger is also passed to the review model as HANDLED memory, in
  `scripts/ai-review/review-engine.sh`, so a re-review does not re-report a
  finding that already has a disposition.
- The match is by MEANING, not exact text, which is what survives the model
  rewording its own finding on a later pass. It is the same model producing the
  variance, so it is the one best placed to recognise it.
- A local-only, exact-match filter in `mise run ai-review:local` backstops that
  in case the model does not comply.

## When a pass will not converge, narrow it

`AI_REVIEW_FILE=<path> mise run ai-review:local` reviews one file instead of the
whole diff.

- Reach for it when successive whole-diff passes return findings whose count
  does not shrink. One file at a time is small enough to converge, and small
  enough to read.
- **A narrowed pass cannot satisfy the push gate**, and says so twice: when it
  starts and when it finishes clean. The gate records "this tree was reviewed",
  and a pass that saw one file has not reviewed the tree. Recording it would be
  the same failure as recording a review that never ran.
- So narrowing is a way to make findings tractable, never a way to reach a
  green push. Finish with a full pass.

## Drain locally, so CI is a confirmation and not a conversation

The CI review is metered and slow. The local one is neither. Running the full
review to a clean pass before pushing turns CI into a check on work that has
already converged, rather than the place where convergence happens one round
trip at a time.

Run the FULL review, not a per-file one. A finding about how two files fit
together cannot be raised by a pass that was shown only one of them, so a
sequence of clean per-file runs says nothing about the diff as a whole.
