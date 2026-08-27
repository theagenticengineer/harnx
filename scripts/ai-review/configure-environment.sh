#!/usr/bin/env bash
# configure-environment.sh — stands up the GitHub Environment the ai-review
# trunk workflow draws its credentials from, and scopes that environment to
# the branches allowed to obtain them.
#
# This is the second half of the ai-review setup pipeline. create-app.sh runs
# first and emits an app id and a private key file; this script consumes both.
# docs/ai-review-setup.md is the operator's guide and explains, from scratch
# and without reference to either script, what all of this is for.
#
# WHAT IT CONFIGURES, and why each piece matters:
#
#   - The environment itself. An environment is the only place GitHub lets a
#     secret be scoped to something narrower than "any job in this
#     repository".
#   - Its deployment branch policy, as EXACT BRANCH NAMES, not patterns.
#     GitHub checks the ref a job is running on against this list, server
#     side, before releasing any of the environment's secrets. That check is
#     independent of the workflow's YAML, of what triggered the job, and of
#     CODEOWNERS, which is what makes it hold against a pull request that adds
#     a brand-new job naming the secret directly.
#   - AI_REVIEW_APP_ID and AI_REVIEW_APP_KEY, the two halves of the App
#     identity the pipeline mints its write-scoped token from.
#
# WHAT IT DELIBERATELY DOES NOT DO: set the engine token. Its plaintext exists
# only in a human's hands, so the script stops and prints the exact command
# for the operator to run instead of inventing a way to route a secret it was
# never given through a script.
#
# HANDLING OF SECRET MATERIAL: the private key is PIPED from its file straight
# into `gh secret set`'s stdin. It is never read into a variable, never passed
# as an argument, and never printed. Only the app id, a public value, appears
# on a command line. An existing secret is left alone rather than rewritten,
# so a re-run genuinely changes nothing (see FORCE_SECRETS to override that
# when rotating a key).
#
# Idempotent: re-running converges to the same state and reports what was
# already right. DRY_RUN=1 prints every change it would make, and calls no
# mutating API.
#
# Env:
#   APP_ID           required; the GitHub App's id (public).
#   APP_KEY_PATH     required; path to the App's .pem private key.
#   ENV_NAME         optional; environment name, default "ai-review".
#   ALLOWED_BRANCHES optional; space- or comma-separated EXACT branch names
#                    allowed to obtain the secrets. Default "main". Pass the
#                    trust-anchor branch explicitly whenever it is not the
#                    default branch: this list is the whole Pattern 1
#                    mitigation, so it is deliberately not guessed.
#   ENGINE           optional; the review engine's suffix, default "CLAUDE".
#                    Names the engine-token secret this script tells the
#                    operator to set: AI_REVIEW_ENGINE_TOKEN_<ENGINE>.
#   FORCE_SECRETS    optional; set to 1 to overwrite AI_REVIEW_APP_ID and
#                    AI_REVIEW_APP_KEY even when they already exist. Needed
#                    when rotating the App's private key; off by default so
#                    the ordinary re-run is a true no-op.
#   PRUNE_BRANCHES   optional; set to 0 to leave branch policies this script
#                    did not ask for in place. Default is to remove them, so
#                    the allow-list on the environment is exactly
#                    ALLOWED_BRANCHES and nothing has quietly widened it.
#   DRY_RUN          optional; set to 1 to print without calling GitHub.
#   GITHUB_REPOSITORY optional; owner/repo, otherwise read from `gh`.
#
# Requires a token with admin on the repository.
set -euo pipefail

: "${APP_ID:?APP_ID is required (create-app.sh prints it)}"
: "${APP_KEY_PATH:?APP_KEY_PATH is required (path to the App private key .pem)}"
env_name="${ENV_NAME:-ai-review}"
allowed_branches="${ALLOWED_BRANCHES:-main}"
engine="${ENGINE:-CLAUDE}"
engine_secret="AI_REVIEW_ENGINE_TOKEN_${engine}"
dry_run="${DRY_RUN:-}"
prune="${PRUNE_BRANCHES:-1}"

case "$APP_ID" in
'' | *[!0-9]*)
  echo "configure-environment: APP_ID must be the App's numeric id, got '$APP_ID'." >&2
  exit 1
  ;;
esac

if [ ! -f "$APP_KEY_PATH" ]; then
  echo "configure-environment: no private key at '$APP_KEY_PATH'." >&2
  exit 1
fi
# grep, not a read into a variable: this confirms the file is a PEM private
# key without ever holding its contents anywhere the shell could echo them.
# Catching a wrong path here is worth the check, because the failure it
# prevents (a secret set to the contents of some unrelated file) shows up much
# later as an unexplained token-minting error in CI.
if ! grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$APP_KEY_PATH"; then
  echo "configure-environment: '$APP_KEY_PATH' does not look like a PEM private key." >&2
  exit 1
fi

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [ -z "$repo" ]; then
  echo "configure-environment: cannot determine the repository; set GITHUB_REPOSITORY or authenticate gh." >&2
  exit 1
fi

# Accepts either separator so the value reads naturally however it is written,
# in a shell, in a CI matrix, or pasted from the docs.
branches="$(printf '%s' "$allowed_branches" | tr ',' ' ' | tr -s ' ')"
# shellcheck disable=SC2086  # deliberate word splitting: $branches is a list.
set -- $branches
if [ "$#" -eq 0 ]; then
  echo "configure-environment: ALLOWED_BRANCHES is empty; an environment with no allowed branch can never release its secrets." >&2
  exit 1
fi
desired_branches="$*"

echo "configure-environment: repo=$repo environment=$env_name"
echo "configure-environment: allowed branches: $desired_branches"

# protected_branches: false with custom_branch_policies: true is what makes
# the allow-list an explicit list of names. The alternative
# (protected_branches: true) would allow ANY protected branch, which quietly
# widens the allow-list every time a new branch gets protection.
env_payload='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'

if [ -n "$dry_run" ]; then
  echo "configure-environment: DRY_RUN, would PUT repos/$repo/environments/$env_name:"
  printf '%s\n' "$env_payload" | jq .
else
  if ! printf '%s' "$env_payload" |
    gh api -X PUT "repos/$repo/environments/$env_name" \
      -H "Accept: application/vnd.github+json" --input - >/dev/null; then
    echo "configure-environment: could not create or update the '$env_name' environment; a token with admin on $repo is required." >&2
    exit 1
  fi
  echo "configure-environment: environment '$env_name' present, custom branch policies enabled."
fi

# ---------------------------------------------------------------- branches --
# Read live even under DRY_RUN: a preview built against an assumed-empty
# environment would tell the operator it is about to add policies that are
# already there, and would never surface the removals, which are the part of a
# converging run worth previewing.
current_policies="$(gh api "repos/$repo/environments/$env_name/deployment-branch-policies" 2>/dev/null || echo '{"branch_policies":[]}')"
current_names="$(printf '%s' "$current_policies" | jq -r '.branch_policies[]?.name')"

for want in $desired_branches; do
  if printf '%s\n' "$current_names" | grep -Fxq "$want"; then
    echo "configure-environment: branch policy '$want' already present."
    continue
  fi
  if [ -n "$dry_run" ]; then
    echo "configure-environment: DRY_RUN, would add branch policy '$want'."
    continue
  fi
  # A branch policy is a NAME evaluated when a job requests the environment,
  # not a reference resolved now, so adding one for a branch that does not
  # exist yet is legitimate and expected during bootstrap. GitHub has
  # nonetheless rejected such a request in the past, so this warns and
  # continues rather than aborting a run whose other branches configured
  # fine: a half-configured allow-list that is missing a not-yet-created
  # branch is recoverable, an aborted run that never set the existing
  # branches is not.
  if gh api -X POST "repos/$repo/environments/$env_name/deployment-branch-policies" \
    -H "Accept: application/vnd.github+json" \
    -f name="$want" -f type=branch >/dev/null 2>&1; then
    echo "configure-environment: added branch policy '$want'."
  else
    echo "configure-environment: WARNING: GitHub rejected the branch policy for '$want' (it may not exist yet). Re-run this script once that branch exists." >&2
  fi
done

if [ "$prune" = "1" ]; then
  while read -r have; do
    [ -n "$have" ] || continue
    case " $desired_branches " in
    *" $have "*) continue ;;
    esac
    if [ -n "$dry_run" ]; then
      echo "configure-environment: DRY_RUN, would REMOVE unlisted branch policy '$have'."
      continue
    fi
    policy_id="$(printf '%s' "$current_policies" |
      jq -r --arg n "$have" '.branch_policies[] | select(.name == $n) | .id' | head -n1)"
    gh api -X DELETE "repos/$repo/environments/$env_name/deployment-branch-policies/$policy_id" >/dev/null
    echo "configure-environment: removed unlisted branch policy '$have'."
  done <<EOF
$current_names
EOF
fi

# ----------------------------------------------------------------- secrets --
# The REST endpoint, not `gh secret list`: it returns names only (a secret's
# value is not readable through any API), its JSON shape is stable across gh
# releases, and it is a plain GET, so it runs under DRY_RUN too. A run that
# could not read the list (a brand-new environment answers 404 until it
# exists) simply treats every secret as absent, which is the correct reading.
existing_secrets="$(gh api "repos/$repo/environments/$env_name/secrets" -q '.secrets[]?.name' 2>/dev/null || true)"
secret_exists() { printf '%s\n' "$existing_secrets" | grep -Fxq "$1"; }

set_public_secret() {
  local name="$1" value="$2"
  if secret_exists "$name" && [ "${FORCE_SECRETS:-}" != "1" ]; then
    echo "configure-environment: secret $name already set; leaving it as is (FORCE_SECRETS=1 to overwrite)."
    return 0
  fi
  if [ -n "$dry_run" ]; then
    echo "configure-environment: DRY_RUN, would set $name (public value: $value)."
    return 0
  fi
  gh secret set "$name" --env "$env_name" --repo "$repo" --body "$value"
  echo "configure-environment: set $name."
}

set_piped_secret() {
  local name="$1" path="$2"
  if secret_exists "$name" && [ "${FORCE_SECRETS:-}" != "1" ]; then
    echo "configure-environment: secret $name already set; leaving it as is (FORCE_SECRETS=1 to overwrite, which is how a rotated key is deployed)."
    return 0
  fi
  if [ -n "$dry_run" ]; then
    echo "configure-environment: DRY_RUN, would set $name from $path (contents never printed)."
    return 0
  fi
  # Redirected from the file, never `cat`-ed into a variable or an argument:
  # the plaintext goes file -> gh's stdin and touches nothing else. Note that
  # even the shell's own `-x` trace would show only the redirection here, not
  # the key.
  gh secret set "$name" --env "$env_name" --repo "$repo" <"$path"
  echo "configure-environment: set $name (from $path)."
}

# Public, so passing it as an argument is fine: the app id is visible on the
# App's own settings page and in every installation event. It lives in the
# environment alongside the key purely so both halves of the App identity are
# released under the same branch policy.
set_public_secret AI_REVIEW_APP_ID "$APP_ID"
set_piped_secret AI_REVIEW_APP_KEY "$APP_KEY_PATH"

# ------------------------------------------------------------- the handoff --
if [ -n "$dry_run" ]; then
  echo
  echo "configure-environment: DRY_RUN complete; nothing was changed."
  exit 0
fi

if secret_exists "$engine_secret"; then
  echo
  echo "configure-environment: $engine_secret is already set on '$env_name'."
  echo "configure-environment: converged; nothing left to do."
  exit 0
fi

cat <<BANNER

configure-environment: ONE STEP REMAINS, and it is yours, not this script's.

  $engine_secret is the review engine's API credential. Its plaintext
  exists only in your hands, so nothing here ever sees it. Run this in a
  normal terminal (it prompts on stdin, so the value never lands in your
  shell history, in a transcript, or in this script's arguments):

    gh secret set $engine_secret --env $env_name --repo $repo

  Then re-run this script to confirm the environment has converged.
BANNER
