#!/usr/bin/env bash
# probe.sh — decides whether a review happens at all, and by whom.
#
# It publishes two outputs, `configured` and `reviewers`, as ONE decision. They
# are never computed separately, because "configured with an empty reviewer
# list" is the state that fans out to zero jobs and reports success.
#
# IT RUNS ON THE TRUSTED SIDE, and that is the whole design.
#
# Epic #1's sketch and this repository's earlier notes both put the probe in
# the pull-request workflow. That is a self-service mute button. A pull request
# controls that file completely, so publishing `reviewers: []` from it makes the
# pipeline dormant, `ai-review-resolved` goes green, and nothing was reviewed.
# It is the same shape as the diff substitution extract-diff.sh closed, and
# worse: that one reviewed the wrong thing, this one reviews nothing.
#
# Credential-need was the wrong test for where it belongs. The probe needs no
# secret, true, but AUTHORSHIP is what matters: the probe decides whether the
# review happens, so it must not be authored by the thing under review.
# `AI_REVIEWERS` is repository state that only an admin can write, and the trunk
# reads it directly. (`workflow_run` does not carry the triggering run's job
# outputs anyway, so consuming a pull-request-side probe would need the very
# artifact channel that was removed.)
#
# THE REGISTRY. `AI_REVIEWERS` is a JSON array of slugs. A slug matches
# ^[a-z][a-z0-9-]*$, uppercases into its secret name
# AI_REVIEW_ENGINE_TOKEN_<ENGINE>, and resolves scripts/ai-review/<slug>.sh as
# its engine.
#
# THE `reviewers` OUTPUT CARRIES ALL THREE, as objects, and that is not
# decoration. GitHub Actions expressions have no uppercase function, so a
# matrix leg cannot turn `claude` into `AI_REVIEW_ENGINE_TOKEN_CLAUDE` by
# itself. The alternative is reading `${{ toJSON(secrets) }}` in the leg and
# picking the key out with jq, which is what the donor floor does, and it means
# materialising EVERY secret the job can see, the App's private key included,
# into one string inside the job that runs the review engine. Doing the
# uppercase here, where `tr` exists, keeps the leg naming exactly the one
# secret it needs. A malformed value DEGRADES to no reviewers rather than failing:
# an unarmed repository must not carry a red required check it cannot clear,
# and the hard failures elsewhere are reserved for a reviewer somebody
# deliberately named.
#
# THE FORK CARVE-OUT. A pull request from a fork is dormant, with a notice.
#
# Worth stating precisely, because the reason usually given for this is wrong:
# under `workflow_run` the secrets are NOT structurally unavailable on a fork's
# pull request. The trunk workflow resolves from the default branch, and the
# environment's deployment branch policy checks the ref the job runs on, which
# IS the default branch, so the secrets would be released. The carve-out
# survives on different grounds: spending the review engine's token and the
# App's private key on drive-by fork content is a choice, not an obligation.
#
# It is decided HERE rather than inside each reviewer's job, and the ordering
# is load-bearing. Dormant before any matrix exists means no leg runs, so the
# missing-credential hard failure can never fire on a fork contributor who has
# no way to fix it.
#
# Env:
#   AI_REVIEWERS     optional; the registry's raw value. Absent, empty or
#                    malformed all mean "no reviewer armed".
#   HEAD_REPOSITORY  required; github.event.workflow_run.head_repository.full_name.
#   REPOSITORY       required; github.repository.
#   GITHUB_OUTPUT    required; the step-output file Actions provides.
set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

emit() {
  printf 'configured=%s\n' "$1" >>"$GITHUB_OUTPUT"
  printf 'reviewers=%s\n' "$2" >>"$GITHUB_OUTPUT"
}

# A deleted fork leaves head_repository null, which reads as "not this
# repository" and lands on dormant. That is the safe direction.
head_repo="${HEAD_REPOSITORY:-}"
if [ "$head_repo" != "$REPOSITORY" ]; then
  echo "::notice::ai-review is dormant on this pull request: it comes from ${head_repo:-a fork}, and this repository does not spend its review credentials on fork content."
  emit false '[]'
  exit 0
fi

raw="${AI_REVIEWERS:-}"
if [ -z "$raw" ]; then
  echo "::notice::ai-review is dormant: the AI_REVIEWERS repository variable is not set, so no reviewer is armed."
  emit false '[]'
  exit 0
fi

# Malformed degrades, and says so. A repository that meant to arm a reviewer
# and typed the value wrongly gets a visible warning rather than a red gate it
# cannot diagnose.
if ! slugs="$(printf '%s' "$raw" | jq -ce '
  if type == "array"
  then [ .[] | select(type == "string") | select(test("^[a-z][a-z0-9-]*$")) ] | unique
  else error("not an array") end' 2>/dev/null)"; then
  echo "::warning::AI_REVIEWERS is not a JSON array of slugs, so no reviewer is armed. Expected something like [\"claude\"]; got: $raw"
  emit false '[]'
  exit 0
fi

count="$(printf '%s' "$slugs" | jq 'length')"
if [ "$count" -eq 0 ]; then
  echo "::warning::AI_REVIEWERS named no usable reviewer, so no reviewer is armed. A slug must match ^[a-z][a-z0-9-]*\$; got: $raw"
  emit false '[]'
  exit 0
fi

# From here the pipeline is ARMED, and every later failure is a hard one. This
# is what makes that safe: past this point somebody deliberately named a
# reviewer, so a reviewer that cannot run is a misconfiguration to report, not
# a fresh repository to be gentle with.
# One object per reviewer: the slug, the secret that carries its credential,
# and the engine the registry resolves. The uppercase mapping is `tr`'s, and
# `-` becomes `_` so a slug like `code-rabbit` names a legal secret.
reviewers="[]"
while read -r slug; do
  [ -n "$slug" ] || continue
  secret="AI_REVIEW_ENGINE_TOKEN_$(printf '%s' "$slug" | tr '[:lower:]-' '[:upper:]_')"
  # The expiry variable's name is derived HERE too, by the same mapping, so the
  # uppercase rule lives in exactly one place. A second copy of it in the
  # expiry check would drift on the first slug that needed a hyphen.
  expires="AI_REVIEW_TOKEN_EXPIRES_$(printf '%s' "$slug" | tr '[:lower:]-' '[:upper:]_')"
  reviewers="$(printf '%s' "$reviewers" | jq -c \
    --arg slug "$slug" --arg secret "$secret" --arg expires "$expires" \
    '. + [{slug: $slug, secret: $secret, expires: $expires,
           engine: ("scripts/ai-review/" + $slug + ".sh")}]')"
done <<EOF
$(printf '%s' "$slugs" | jq -r '.[]')
EOF

emit true "$reviewers"
names="$(printf '%s' "$slugs" | jq -r 'join(", ")')"
echo "probe.sh: $count reviewer(s) armed: $names."
