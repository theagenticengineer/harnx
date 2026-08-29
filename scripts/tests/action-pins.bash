#!/usr/bin/env bash
# Standalone test for GitHub Action pinning across .github/workflows/.
# Run: bash scripts/tests/action-pins.bash
#
# WHY THIS EXISTS. Every `uses:` in this repo is pinned to a full commit SHA
# rather than a tag, because a tag is MUTABLE: whoever controls the action's
# repository can repoint `v4` at new code, and every workflow that referenced
# it executes that code on the next run, with whatever secrets the job holds.
# The credentialed trunk workflow holds the review engine's token and the App
# private key, so this is the difference between pinning a dependency and
# trusting a third party indefinitely.
#
# Until now that was maintained by discipline alone: 26 of 26 `uses:` were
# SHA-pinned and nothing checked it. A single tag-pinned line added later would
# go green and unpin the supply chain silently, which is precisely the class of
# regression a floor is supposed to make impossible. harnx GENERATES
# repositories, so an unpinned action here becomes an unpinned action in every
# repository it produces.
#
# The version comment is asserted for a second, practical reason: a bare
# 40-character SHA is unreadable, so without `# vX.Y.Z` nobody can tell what is
# pinned, whether it is current, or what a bump would move. That comment is
# what makes a pin auditable rather than merely fixed.
#
# NOT asserted: that any pin is up to date, or which Node runtime it targets.
# Both need the network, and a test that reaches GitHub is neither hermetic nor
# runnable offline. Freshness is a review-time and Dependabot-time question.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow_dir="$repo_root/.github/workflows"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

if [ ! -d "$workflow_dir" ]; then
  echo "FAIL: no .github/workflows directory at $workflow_dir" >&2
  exit 1
fi

total=0
for wf in "$workflow_dir"/*.yml "$workflow_dir"/*.yaml; do
  [ -f "$wf" ] || continue
  name="$(basename "$wf")"
  # Only real step `uses:` lines. A `uses:` inside a comment is not a step, and
  # neither is the word appearing in prose, so the match is anchored to the
  # YAML shape: optional list dash, then `uses:`.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    ref="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*//; s/[[:space:]]*#.*$//')"

    # A local composite action (./path) is this repository's own code, already
    # covered by every other gate here, and has no SHA to pin.
    case "$ref" in
    ./*)
      pass=$((pass + 1))
      continue
      ;;
    esac

    if ! printf '%s' "$ref" | grep -qE '^[^@]+@[0-9a-f]{40}$'; then
      fail_case "$name: '$ref' is not pinned to a full 40-character commit SHA. A tag or branch is mutable: whoever owns that action can repoint it at new code, which then runs with this job's secrets."
      continue
    fi
    pass=$((pass + 1))

    # The trailing comment is what makes the pin readable. Without it the SHA
    # is an opaque 40 characters nobody can audit or bump with confidence.
    if printf '%s' "$line" | grep -qE '#[[:space:]]*v[0-9]+\.[0-9]+(\.[0-9]+)?'; then
      pass=$((pass + 1))
    else
      fail_case "$name: '$ref' has no '# vX.Y.Z' comment, so nothing records which release that SHA is"
    fi
  done < <(grep -E '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*[^[:space:]]' "$wf" || true)
done

# A guard on the guard: if the parse silently matched nothing, every assertion
# above would vacuously pass and this suite would report green while checking
# no workflow at all. That is the same failure shape ci-validate-commits.sh
# refuses for an empty commit range.
if [ "$total" -gt 0 ]; then
  pass=$((pass + 1))
else
  fail_case "found no 'uses:' lines in $workflow_dir at all; the parse is broken, and reporting success here would mean this suite checked nothing"
fi

echo "RESULT: $pass passed, $fail failed ($total uses: lines checked)"
[[ "$fail" -eq 0 ]]
