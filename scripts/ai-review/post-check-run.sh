#!/usr/bin/env bash
# post-check-run.sh — publishes the ai-review gate's verdict onto the pull
# request as a Check Run anchored to the reviewed head commit.
#
# Why this exists at all: a workflow_run-triggered job does NOT surface as a
# status on the pull request whose completion triggered it, the way a
# pull_request-triggered job does. The ai-review-resolved context is a
# REQUIRED check in branch protection, so without an explicit Check Run it
# would sit permanently "Expected, waiting for status" and no pull request
# could ever merge. Splitting the pipeline is what created that gap; this
# script is what closes it.
#
# WHICH TOKEN, and why it matters more than it looks: this must run on
# github.token, NOT on the review App's installation token. Branch protection
# stores each required context alongside the app that most recently reported
# it (`required_status_checks.checks[].app_id`), and every other check in this
# floor is reported by GitHub Actions, app id 15368. A Check Run created with
# the App's token is attributed to the App instead, so protection would keep
# waiting for an ai-review-resolved from Actions that never arrives, while a
# green one from another app sits next to it. github.token with `checks:
# write` produces a check run attributed to GitHub Actions, which is exactly
# what the required context already expects.
#
# The name is likewise not free-form: it must match, byte for byte, the
# `ai-review-resolved` literal that scripts/configure-protection.sh puts in
# required_status_checks.contexts.
#
# Env:
#   GH_TOKEN     required; a token with checks: write.
#   OWNER        required; repo owner login.
#   REPO_NAME    required; repo name.
#   HEAD_SHA     required; the commit to anchor the check run to. Must be
#                GitHub's own record of the reviewed head
#                (github.event.workflow_run.head_sha), never a value carried
#                across from the pull request's artifact.
#   CHECK_NAME   required; the check run's name, matching the protected
#                context exactly.
#   CONCLUSION   required; "success" or "failure".
#   SUMMARY      optional; markdown shown on the check run.
#   DETAILS_URL  optional; a link shown as "Details" on the check run.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${REPO_NAME:?REPO_NAME is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
: "${CHECK_NAME:?CHECK_NAME is required}"
: "${CONCLUSION:?CONCLUSION is required}"
export GH_TOKEN

# Whitelisted, not passed through: CONCLUSION is computed from a step outcome
# in the workflow, and a typo there would otherwise be rejected by the API
# with a message that says nothing about which of this repo's checks broke.
case "$CONCLUSION" in
success) title="No unresolved Major ai-review findings." ;;
failure) title="The ai-review gate is red." ;;
*)
  echo "post-check-run.sh: CONCLUSION must be 'success' or 'failure', got '$CONCLUSION'." >&2
  exit 1
  ;;
esac

summary="${SUMMARY:-}"
if [ -z "$summary" ]; then
  summary="Published by the ai-review trunk workflow, which runs the default branch's copy of the review scripts. See the run linked under Details for the findings this verdict is based on."
fi

# Built with jq and sent via --input, not assembled from `gh api -f` flags:
# the check run's `output` is a NESTED object, which the flat -f key=value
# form cannot express.
payload="$(jq -cn \
  --arg name "$CHECK_NAME" \
  --arg sha "$HEAD_SHA" \
  --arg conclusion "$CONCLUSION" \
  --arg title "$title" \
  --arg summary "$summary" \
  --arg url "${DETAILS_URL:-}" '
  {
    name: $name,
    head_sha: $sha,
    status: "completed",
    conclusion: $conclusion,
    output: { title: $title, summary: $summary }
  }
  + (if $url == "" then {} else { details_url: $url } end)')"

if ! printf '%s' "$payload" |
  gh api -X POST "repos/$OWNER/$REPO_NAME/check-runs" \
    -H "Accept: application/vnd.github+json" --input - >/dev/null; then
  echo "::error::post-check-run.sh: could not publish the '$CHECK_NAME' check run for $HEAD_SHA; the required check will stay unreported and the pull request will stay blocked." >&2
  exit 1
fi

echo "post-check-run.sh: published '$CHECK_NAME' as $CONCLUSION for $HEAD_SHA."
