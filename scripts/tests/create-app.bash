#!/usr/bin/env bash
# Standalone test for scripts/ai-review/create-app.sh.
# Run: bash scripts/tests/create-app.bash
#
# A live run of this script CREATES A REAL GITHUB APP, which is not something a
# test suite may do, and the browser confirmation in the middle of it cannot be
# automated at all (that is the point of GitHub's manifest flow). So what is
# tested here is the part that can be: the manifest it renders.
#
# That is not a consolation prize. The manifest is where every durable property
# of the App is decided, and a mistake in it is invisible until the pipeline
# fails months later:
#
#   - `pull_requests: write` present, so the pipeline can post threads at all.
#   - NOTHING BUT that permission, because the minted token's scope is the
#     blast radius if it ever leaks.
#   - `public: false` and webhooks off, so the App is not exposed or noisy.
#   - The redirect pointed at loopback, so the manifest code comes back to the
#     operator's own machine and not to some third party.
#
# The browser-confirmation and code-exchange half of the script stays
# unexercised by any automated test, deliberately and by necessity.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/create-app.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log="$work/out.txt"

# `gh` is stubbed to prove the dry run never calls it: a dry run that created
# an App would be a catastrophic bug in a script whose live effect is
# irreversible.
cat >"$work/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub: create-app called gh during a dry run: $*" >&2
exit 91
STUB
chmod +x "$work/gh"

run() {
  env PATH="$work:$PATH" GITHUB_REPOSITORY=owner/harnx DRY_RUN=1 "$@" \
    bash "$script"
}

if run >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a dry run must succeed without calling gh: $(cat "$log")"
fi

# The rendered manifest is the block of pretty-printed JSON the script prints;
# `jq -s` over the whole log would choke on the surrounding prose, so the
# object is sliced out by its own braces at column zero.
manifest="$work/manifest.json"
sed -n '/^{$/,/^}$/p' "$log" >"$manifest"

if jq -e . "$manifest" >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  fail_case "the script must print a parseable manifest: $(cat "$log")"
fi

expect() {
  local desc="$1" filter="$2"
  if jq -e "$filter" "$manifest" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail_case "$desc"
  fi
}

expect "the manifest must request pull_requests: write" \
  '.default_permissions.pull_requests == "write"'
expect "pull_requests must be the ONLY permission requested" \
  '(.default_permissions | keys | length) == 1'
expect "the App must not be public" '.public == false'
expect "webhooks must be inactive" '.hook_attributes.active == false'
expect "the App must subscribe to no events" \
  '(.default_events | length) == 0'
expect "the redirect must come back to loopback, never to a third party" \
  '(.redirect_url | startswith("http://127.0.0.1:"))'
expect "the App name must be derived from the repository" \
  '.name == "harnx-ai-review"'

# --- the name is overridable, since App names are globally unique ------------
if run APP_NAME=some-other-name >"$log" 2>&1; then
  sed -n '/^{$/,/^}$/p' "$log" >"$manifest"
  if [ "$(jq -r '.name' "$manifest")" = "some-other-name" ]; then
    pass=$((pass + 1))
  else
    fail_case "APP_NAME must override the derived name"
  fi
else
  fail_case "a dry run with APP_NAME must succeed: $(cat "$log")"
fi

# --- an organisation-owned App targets the org creation URL ------------------
if run ORG=theagenticengineer >"$log" 2>&1 &&
  grep -q 'https://github.com/organizations/theagenticengineer/settings/apps/new' "$log"; then
  pass=$((pass + 1))
else
  fail_case "ORG must switch the creation URL to the organisation's: $(cat "$log")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
