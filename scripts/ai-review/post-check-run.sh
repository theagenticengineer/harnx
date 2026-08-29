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
#   SUMMARY      optional; a ONE-LINE cause, shown as the check run's summary
#                and, on a failure, promoted to its TITLE. See the title
#                comment below for why the title is the field that matters.
#   TEXT         optional; the full detail behind SUMMARY, shown in the check
#                run's expandable body. Omitted entirely when empty, never
#                sent as an empty string.
#
#                Both are BOUNDED before they are sent; see the clamp below.
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
#
# THE FAILURE TITLE CARRIES THE CAUSE. The title is the only part of a check
# run GitHub renders in the pull request's merge box, so it is the one string
# a reader sees without clicking through. It used to be the fixed sentence
# "The ai-review gate is red.", which is the one thing already obvious from
# the red mark next to it. A dead engine token and a disposition backlog are
# completely different problems with completely different fixes, and both
# rendered as that identical string, so every red gate cost a trip into the
# workflow logs to learn which had happened.
#
# So a failure's title is SUMMARY, the one-line cause the caller computed,
# and the fixed sentence survives only as the fallback for a caller that
# passed nothing.
case "$CONCLUSION" in
success) title="No unresolved Major ai-review findings." ;;
failure) title="${SUMMARY:-The ai-review gate is red.}" ;;
*)
  echo "post-check-run.sh: CONCLUSION must be 'success' or 'failure', got '$CONCLUSION'." >&2
  exit 1
  ;;
esac

# The API rejects a title over 255 characters, and a cause assembled from a
# check's own error output has no guaranteed length. Truncating here keeps a
# long cause from turning into a failed publish, which would leave the
# required context unreported and the pull request blocked on nothing: a
# strictly worse outcome than a clipped sentence.
if [ "${#title}" -gt 255 ]; then
  title="${title:0:252}..."
fi

summary="${SUMMARY:-}"
if [ -z "$summary" ]; then
  summary="Published by the ai-review trunk workflow, which runs the default branch's copy of the review scripts. See the run linked under Details for the findings this verdict is based on."
fi

# EVERY CAPPED FIELD IS BOUNDED BEFORE IT IS SENT. The Checks API rejects the
# whole request when output.summary or output.text exceeds 65535 characters,
# and a rejected publish leaves the required ai-review-resolved context
# unreported, which blocks the pull request on nothing at all. That outcome is
# strictly worse than a clipped sentence, which is the same trade the caller's
# own title clamp is built on. Neither field has a guaranteed length: both are
# assembled from a failing check's own output, and a runaway linter or a long
# findings list is exactly the case where the check run matters most.
#
# The marker is appended INSIDE the budget, not after it, so the clamped
# result is always at most the limit, and it is visible text rather than a
# silent cut: a reader must be able to tell "this is the whole detail" from
# "this is as much of it as fitted".
clamp_output() {
  local value="$1" marker
  # 65535 is GitHub's documented maximum for both fields.
  local limit=65535
  marker="

... truncated here: this field exceeded the GitHub Checks API limit of $limit characters. See the run linked under Details for the full output."
  if [ "${#value}" -le "$limit" ]; then
    printf '%s' "$value"
    return 0
  fi
  printf '%s%s' "${value:0:$((limit - ${#marker}))}" "$marker"
}

summary="$(clamp_output "$summary")"
# TEXT is the field most likely to blow the limit in practice: it carries the
# gate's captured detail, which is a check's raw output rather than a sentence
# somebody wrote. Clamped through the same function, and still omitted from
# the payload entirely when empty (see the jq below).
text="$(clamp_output "${TEXT:-}")"

# Built with jq and sent via --input, not assembled from `gh api -f` flags:
# the check run's `output` is a NESTED object, which the flat -f key=value
# form cannot express.
payload="$(jq -cn \
  --arg name "$CHECK_NAME" \
  --arg sha "$HEAD_SHA" \
  --arg conclusion "$CONCLUSION" \
  --arg title "$title" \
  --arg summary "$summary" \
  --arg text "$text" \
  --arg url "${DETAILS_URL:-}" '
  {
    name: $name,
    head_sha: $sha,
    status: "completed",
    conclusion: $conclusion,
    # `text` is ADDED when non-empty rather than always sent and left blank,
    # the same shape `details_url` already used below. It is the expandable
    # body of the check run, and an empty string renders as an empty section
    # rather than as no section, so "no detail to show" and "a detail that is
    # blank" would look identical to whoever opens it.
    output: ({ title: $title, summary: $summary }
             + (if $text == "" then {} else { text: $text } end))
  }
  + (if $url == "" then {} else { details_url: $url } end)')"

if ! printf '%s' "$payload" |
  gh api -X POST "repos/$OWNER/$REPO_NAME/check-runs" \
    -H "Accept: application/vnd.github+json" --input - >/dev/null; then
  echo "::error::post-check-run.sh: could not publish the '$CHECK_NAME' check run for $HEAD_SHA; the required check will stay unreported and the pull request will stay blocked." >&2
  exit 1
fi

echo "post-check-run.sh: published '$CHECK_NAME' as $CONCLUSION for $HEAD_SHA."
