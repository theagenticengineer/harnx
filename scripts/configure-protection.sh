#!/usr/bin/env bash
# configure-protection.sh — arm the repository's default branch's protection
# with the floor's required status checks.
#
# The check set is produced by floor_required_checks (a computed function, not
# an inline literal spliced into the API call), so a later increment can
# extend this same seam to add more checks to the floor set without touching
# the call site.
#
# The target branch is read from the live repo (GET /repos/{owner}/{repo}'s
# default_branch), never hardcoded to "main": a user who renamed their default
# branch (dev, develop, trunk) gets the same protection on their actual
# default, not a protection rule silently written to a branch named "main"
# that may not even exist. This also means re-running the script after the
# live repo's default-branch setting changes re-targets protection to
# whatever is default now, without editing this script.
#
# EACH REQUIRED CHECK NAMES THE APP THAT MAY REPORT IT. The payload uses
# `required_status_checks.checks`, the current API, rather than the
# closing-down `contexts` list, and every entry carries an explicit `app_id`.
# The two forms are not equivalent: with `contexts`, GitHub back-fills each
# check's app from whichever app most recently REPORTED that context, so in a
# freshly generated repository, where nothing has reported anything yet, all
# nine required checks are satisfiable by ANY app. Naming the app removes the
# dependency on reporting history entirely. `ai-review-resolved` is the one
# that makes this concrete: post-check-run.sh publishes it deliberately on
# github.token so it is attributed to GitHub Actions, and pinning the app id
# is what makes a green check run from some other app unable to stand in for
# it.
#
# The id is RESOLVED AT RUNTIME from /apps/github-actions rather than
# hardcoded. It is a stable, public, GitHub-wide value (15368 on
# github.com), but a hardcoded constant would be silently wrong on GitHub
# Enterprise Server, where app ids are per-instance.
#
# Idempotent: a PUT applies the full desired protection state, so re-running
# converges to it rather than accreting. DRY_RUN=1 prints the payload without
# calling GitHub. Requires a token with admin on the repo.
set -euo pipefail

floor_required_checks() {
  printf '%s\n' \
    pre-commit \
    gitleaks \
    actionlint \
    shell-tests \
    commitlint \
    branch-name \
    pr-title \
    pr-body \
    ai-review-resolved
}

main() {
  local repo
  repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
  if [ -z "$repo" ]; then
    echo "configure-protection: cannot determine the repository; set GITHUB_REPOSITORY or authenticate gh." >&2
    exit 1
  fi

  # Read live, not hardcoded: see the header comment. Printed before any
  # write happens so a default-branch setting nobody remembers changing
  # (fat-fingered in the GitHub UI, or genuinely intentional) is visible
  # here rather than silently protecting the wrong branch.
  local branch
  branch="$(gh api "repos/${repo}" -q .default_branch)"
  if [ -z "$branch" ]; then
    echo "configure-protection: could not read ${repo}'s default branch from the API." >&2
    exit 1
  fi
  echo "configure-protection: targeting ${repo}'s default branch, '${branch}'."

  # The app every floor check is reported by. See the header for why this is
  # named explicitly instead of left to GitHub's reporting-history back-fill,
  # and why it is read live instead of hardcoded.
  local app_id
  app_id="$(gh api /apps/github-actions -q .id 2>/dev/null || true)"
  case "$app_id" in
  '' | *[!0-9]*)
    echo "configure-protection: could not resolve the GitHub Actions app id from /apps/github-actions; refusing to write a protection whose required checks any app could satisfy." >&2
    exit 1
    ;;
  esac
  echo "configure-protection: required checks will be pinned to app id ${app_id} (GitHub Actions)."

  local checks payload
  checks="$(floor_required_checks |
    jq -R --argjson app "$app_id" '{context: ., app_id: $app}' | jq -cs .)"
  payload="$(jq -cn --argjson checks "$checks" '{
    required_status_checks: { strict: true, checks: $checks },
    # false, not true. GitHub never lets a PR author approve their own PR,
    # full stop, independent of CODEOWNERS: required_approving_review_count:
    # 1 ALONE already deadlocks every PR in a single-person org (the only
    # member IS the sole author of every PR), not only ones touching a
    # CODEOWNERS-listed path. require_code_owner_reviews below narrows WHO
    # must approve on a protected path; it is not the cause of the deadlock,
    # which required_approving_review_count already creates on its own.
    # enforce_admins: true would make that deadlock permanent and
    # unbypassable by anyone, admin included. false is the standard
    # solo-maintainer pattern: a non-admin contributor still cannot merge
    # without a real approval (or, on a protected path, a real code-owner
    # approval), while the admin retains a native GitHub override ("merge
    # without waiting for requirements") for their own PRs. No new risk
    # beyond what the admin already has via existing repo access. Confirmed
    # with the user as the correct tradeoff.
    enforce_admins: false,
    required_pull_request_reviews: {
      required_approving_review_count: 1,
      # true, not false: GitHub dismisses ALL prior approvals on every new
      # push to the PR, not just pushes that touch a CODEOWNERS-listed path
      # (GitHub has no path-scoped version of this setting). Required for
      # CODEOWNERS to mean what it claims: with dismiss_stale_reviews false,
      # a contributor could get a protected path approved, then push a
      # DIFFERENT change to that same path and merge without a fresh review
      # of the actual final diff, silently defeating the tamper-evidence
      # guarantee below. The cost is real: every push to every PR needs a
      # fresh approval, not only ones touching a protected path, heavier
      # friction on top of the one-commit-per-push cadence this floor
      # already establishes. Confirmed with the user as the correct
      # tradeoff.
      dismiss_stale_reviews: true,
      # A change under a CODEOWNERS-listed path (scripts/ai-review/**,
      # .github/workflows/**) requires the listed code owner to approve,
      # never satisfiable by the PR author approving their own PR. This is
      # the tamper-evidence measure for the ai-review-resolved gate: its
      # enforcement scripts run from the PR checkout, so an edit that
      # neuters the gate must still clear human review before it can merge.
      require_code_owner_reviews: true
    },
    restrictions: null,
    allow_force_pushes: false,
    allow_deletions: false
  }')"

  if [ -n "${DRY_RUN:-}" ]; then
    echo "configure-protection: DRY_RUN, would apply to ${repo} ${branch}:"
    printf '%s\n' "$payload" | jq .
    return 0
  fi

  if ! printf '%s' "$payload" | gh api -X PUT "repos/${repo}/branches/${branch}/protection" \
    -H "Accept: application/vnd.github+json" --input - >/dev/null; then
    echo "configure-protection: failed to write ${repo} ${branch} protection; a token with admin on the repo is required." >&2
    exit 1
  fi
  echo "configure-protection: applied the floor's required checks to ${repo} ${branch}."

  # READ IT BACK. A 2xx on the PUT says GitHub accepted the request, not that
  # the protection now holds what was asked for: an unknown field is ignored
  # rather than rejected, so a future API change that renames `checks` would
  # leave this script reporting success over a branch with no required checks
  # at all. The one thing worse than an unprotected default branch is an
  # unprotected default branch that a green setup log says is protected.
  local live missing want
  live="$(gh api "repos/${repo}/branches/${branch}/protection" \
    -q '.required_status_checks.checks[]? | "\(.context)|\(.app_id)"' 2>/dev/null || true)"
  missing=""
  while read -r want; do
    [ -n "$want" ] || continue
    printf '%s\n' "$live" | grep -Fxq "${want}|${app_id}" || missing="$missing ${want}"
  done <<EOF
$(floor_required_checks)
EOF
  if [ -n "$missing" ]; then
    echo "configure-protection: the protection read back from ${repo} ${branch} is missing these required checks for app ${app_id}:${missing}" >&2
    echo "configure-protection: the branch is NOT protected the way this script just reported. Live checks were:" >&2
    printf '%s\n' "$live" >&2
    exit 1
  fi
  echo "configure-protection: verified live: $(printf '%s\n' "$live" | grep -c .) required checks, each pinned to app ${app_id}."
}

main "$@"
