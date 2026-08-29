#!/usr/bin/env bash
# extract-diff.sh — computes the diff under review ON THE TRUSTED SIDE, from
# GitHub's own refs, and writes it to DIFF_FILE.
#
# WHY THIS EXISTS, and it is a security control rather than a refactor.
#
# The diff used to be produced by `.github/workflows/ai-review.yml`, which is
# `pull_request`-triggered and therefore read from the pull request's own
# branch. That workflow's header states the property plainly: the pull request
# author controls every line of it. It uploaded `diff.txt` as an artifact and
# the credentialed trunk workflow reviewed whatever bytes arrived.
#
# So the review input was attacker-authored. Replacing one line of that
# workflow with `echo "benign" >ai-review-input/diff.txt` produced a pull
# request whose review was of the word "benign":
#
#   - the artifact NAME was unchanged, so the download succeeded;
#   - `if-no-files-found: error` matched a file, so it did not fire;
#   - `require-diff.sh` tests for present and non-empty, and "benign" is both;
#   - the per-run nonce protects the untrusted region's FENCE, and nothing in a
#     fabricated diff needs to forge a fence.
#
# The engine then reported no findings, no threads were posted, no Major was
# left unresolved, and `ai-review-resolved`, a REQUIRED context, went green
# over a pull request nothing had read. That is a merge-past-review primitive,
# not a missed finding. It is the same objective as the prompt injection the
# nonce closed, by a blunter route: do not defeat the reviewer's reading of the
# diff, replace the diff.
#
# The fix is not to validate the artifact. It is to stop consuming it. This
# script runs in the trunk workflow, from the default branch's tree, and asks
# GitHub for the refs directly. There is no second copy to compare, and nothing
# a pull request writes reaches the review input except through the commits it
# actually pushed.
#
# WHY NOT COMPARE A HASH AGAINST THE ARTIFACT. Because the base branch can
# advance between the pull request run and the trunk run, so two diffs computed
# at different moments legitimately differ, and the comparison would fail
# innocent pull requests on a race. The tamper is caught anyway: the attacker's
# edit to ai-review.yml is IN the diff this script now computes.
#
# THE HEAD IS ASSERTED, NOT ASSUMED. `refs/pull/<n>/head` tracks the pull
# request's current tip, and the trunk run is a verdict about ONE commit,
# `workflow_run.head_sha`, which is what post-findings.sh anchors its comments
# to and what post-check-run.sh publishes the gate against. If the author
# pushed again while this run was starting, the ref has already moved on, and
# reviewing the newer commit while reporting against the older one would
# publish a verdict about code nobody looked at. It fails closed instead; the
# superseded run is being cancelled anyway, and the newer push has its own.
#
# THREE-DOT, matching what CI has always reviewed: `base...head` is
# merge-base(base, head)..head, so an unrelated commit landing on the base
# branch does not appear in the pull request's review as though the author
# wrote it.
#
# Env:
#   OWNER      required; repo owner login.
#   REPO_NAME  required; repo name.
#   PR_NUMBER  required; the pull request number, from resolve-pr-context.sh.
#   BASE_REF   required; the pull request's base BRANCH NAME, from the same
#              place. Never from the artifact, and never from the pull
#              request: a base the author could name could be their own head,
#              which diffs to nothing and reviews nothing.
#   HEAD_SHA   required; the reviewed commit (workflow_run.head_sha).
#   DIFF_FILE  required; path to write the diff to. Under RUNNER_TEMP in the
#              workflow, not the workspace, so pull-request-authored content
#              never lands beside the trusted scripts.
set -euo pipefail

: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${BASE_REF:?BASE_REF is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${DIFF_FILE:?DIFF_FILE is required}"

# Digits only. This is spliced into a ref path, and a value carrying `../` or a
# glob would fetch something other than the pull request under review.
case "$PR_NUMBER" in
'' | *[!0-9]*)
  echo "::error::extract-diff.sh: PR_NUMBER must be digits, got '$PR_NUMBER'." >&2
  exit 1
  ;;
esac
# A branch name, not a refspec. `git fetch` accepts a lot more than a name in
# this position, and BASE_REF crosses from an API payload, so anything outside
# the character set GitHub allows in a branch name is refused rather than
# passed through.
case "$BASE_REF" in
'' | *[!A-Za-z0-9._/-]* | -* | */ | *..*)
  echo "::error::extract-diff.sh: BASE_REF is not a plain branch name, got '$BASE_REF'." >&2
  exit 1
  ;;
esac

# Fetched into names under refs/ai-review/, not into FETCH_HEAD or a local
# branch: FETCH_HEAD holds only the last fetch's result, and a local branch
# name could collide with a real one in the checkout.
git fetch --no-tags --quiet origin \
  "+refs/pull/$PR_NUMBER/head:refs/ai-review/head" \
  "+refs/heads/$BASE_REF:refs/ai-review/base"

fetched_head="$(git rev-parse refs/ai-review/head)"
if [ "$fetched_head" != "$HEAD_SHA" ]; then
  echo "::error::extract-diff.sh: pull request #$PR_NUMBER's head is now $fetched_head, but this run is a verdict about $HEAD_SHA. Refusing to review one commit and report against another; the push that moved the head has its own run." >&2
  exit 1
fi

git diff refs/ai-review/base...refs/ai-review/head >"$DIFF_FILE"
echo "extract-diff.sh: $(wc -c <"$DIFF_FILE") bytes, #$PR_NUMBER $BASE_REF...$HEAD_SHA."
