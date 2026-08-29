# The AI review's credentials in CI

Where the review's live credentials are held, why they are held there, and what
provisions them.

Three secrets, all of them on the `ai-review` GitHub ENVIRONMENT rather than on
the repository:

- `AI_REVIEW_ENGINE_TOKEN_CLAUDE`, a Claude Code OAuth token from
  `claude setup-token`;
- `AI_REVIEW_APP_CLIENT_ID` and `AI_REVIEW_APP_KEY`, for a GitHub App scoped to
  Pull requests: write only, installed on this repository.

The CLIENT id, not the app id. The trunk workflow's token-minting step reads
`secrets.AI_REVIEW_APP_CLIENT_ID`, so renaming it here without renaming it
there leaves that step reading an empty value.

## Why an environment and not the repository

- The environment's deployment branch policy names the trust-anchor branches
  explicitly.
- GitHub checks the ref a job runs on against that policy, server side, before
  releasing any value. That check is independent of the workflow's YAML, of
  what triggered the job, and of CODEOWNERS.
- A repository secret, by contrast, is available to ANY job in the repository.
  A pull request could otherwise add a brand-new job that simply names one.
- Engine tokens follow `AI_REVIEW_ENGINE_TOKEN_<ENGINE>`, so more than one
  can be held at once; the trunk workflow maps whichever one it selects into
  the engine-agnostic `AI_REVIEW_ENGINE_TOKEN` that `review-engine.sh`
  actually reads. Do not collapse the suffix away.
- `scripts/ai-review/create-app.sh` and
  `scripts/ai-review/configure-environment.sh` provision all of the above,
  in that order: the first creates the App and emits an app id plus a `.pem`,
  the second creates the environment, sets the branch policy, stores those
  two, and stops for a human to supply the engine token. Both are idempotent
  and `DRY_RUN`-capable.

### In CI: what the trunk workflow does per pass

- Builds HANDLED memory from the pull request's own RESOLVED review threads,
  in `scripts/ai-review/handled-from-threads.sh`.
- The gitignored local ledger is deliberately NOT that source. A committed,
  CI-read ledger would be author-controlled content inside the pull request
  under review, so it would work as a self-service mute button on a blocking
  gate.
- Resolution state is authority-neutral instead. Resolving a Major thread is
  already the only way the gate is cleared, so replaying it as memory grants no
  new power.
- What it does buy is that the same finding is not re-derived and re-posted
  under new wording on every push. Four threads for one finding, observed live.
  Unresolved
  threads are deliberately excluded: they are still open, so the gate is
  still red for them, and nothing about them needs suppressing.
- Runs the engine, then posts findings from a SEPARATE job that mints the
  App token. Separate jobs are separate runners, so nothing the
  content-processing job's execution touches can reach the job holding the
  write-scoped token.
- Upserts ONE status comment on the pull request
  (`scripts/ai-review/post-ci-status.sh`): a convergence table with one row
  per pass, mirroring the local runner's, plus the open-versus-resolved
  Major thread counts and the gate verdict. Updated in place, never
  re-posted, so there is exactly one current state on the pull request at any
  time.
- Publishes the verdict as an explicit `ai-review-resolved` check run against
  the pull request's head SHA, in `scripts/ai-review/post-check-run.sh`.
- That explicit check run is required because a `workflow_run` job does not
  surface as a status on the pull request the way a `pull_request` job does.
  Without it the required check sits permanently "Expected" and nothing merges.
- It is created with `github.token`, not the App's token, because branch
  protection pins each required context to the app that reports it.
- On a red gate the check run's TITLE states the CAUSE, not the fact that it is
  red. `scripts/ai-review/evaluate-gate.sh` captures why the gate failed and
  passes it through.
- So "the review pipeline did not complete" and "12 resolved Major findings
  have no disposition" read differently in the merge box, and the full output
  of both sub-checks sits in the check run's body.
