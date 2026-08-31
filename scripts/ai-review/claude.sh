#!/usr/bin/env bash
# claude.sh — the `claude` reviewer's engine.
#
# THE REGISTRY RESOLVES scripts/ai-review/<slug>.sh, so this file IS how the
# slug `claude` becomes something that runs. That resolution rule is the
# contract, which is why the dispatch is a file per reviewer rather than a
# mapping inside review-engine.sh: a mapping would mean the registry no longer
# says what it claims to say, and a second reviewer would be a patch to shared
# code instead of a new file.
#
# It is deliberately thin. Everything about HOW a review is conducted lives in
# review-engine.sh, so a second provider is a shim like this one plus its own
# secret, not a fork of the engine.
#
# A NAMED REVIEWER THAT CANNOT RUN FAILS. It does not go dormant, and this is
# the sharpest rule in the registry.
#
# The unconfigured case is already handled one layer up: probe.sh makes the
# whole pipeline dormant when no reviewer is armed, and on a fork's pull
# request. So this script is only ever reached when somebody DELIBERATELY named
# this reviewer. At that point a missing credential is a misconfiguration to
# report, not a fresh repository to be gentle with, and a `::notice::` plus
# exit 0 would be the silent omission the notice pretends to prevent.
#
# This repository has already paid for the alternative once. The git-identity
# gate shipped dormant, its own genesis commit was authored under a leaked host
# identity while the gate reported `Passed`, and its paired test asserted that
# pass. Dormancy hides inside the test, which is why scripts/tests/claude.bash
# asserts the failure in both directions rather than only the success.
#
# Env:
#   AI_REVIEW_ENGINE_TOKEN  required; this reviewer's credential, mapped by the
#                           workflow from the secret AI_REVIEW_ENGINE_TOKEN_CLAUDE.
#                           Absent is a hard failure naming that secret.
#   Everything else is passed through to review-engine.sh unchanged.
set -euo pipefail

reviewer="claude"
secret="AI_REVIEW_ENGINE_TOKEN_$(printf '%s' "$reviewer" | tr '[:lower:]-' '[:upper:]_')"

if [ -z "${AI_REVIEW_ENGINE_TOKEN:-}" ]; then
  echo "::error::ai-review reviewer '$reviewer' is named in AI_REVIEWERS but has no credential. Set the repository secret $secret on the ai-review environment, or remove '$reviewer' from AI_REVIEWERS. This fails rather than skipping: a reviewer somebody asked for and that never ran is exactly the silent omission this gate exists to prevent." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The reviewer name is stamped by the SHELL, never by the model: attribution is
# a property of which engine ran, and union.sh joins these to say who raised a
# finding.
AI_REVIEW_REVIEWER="$reviewer" exec bash "$script_dir/review-engine.sh"
