#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/check-git-identity.sh.
# Run: bash scripts/tests/check-git-identity.bash
#
# The gate has exactly three states, and the FIRST of them is the one this
# suite exists to hold in place:
#
#   UNARMED -> FAILS. An earlier version of this gate treated an un-filled
#              config as a dormant state that passed, and this suite asserted
#              that pass ("dormant-with-identity-ok ... 0"). The result was
#              that the repo authored its entire genesis history as
#              "Host Identity <leak@host.dev>" while the gate reported Passed
#              on every commit. The test encoded the defect, so the defect was
#              invisible. Those assertions are now inverted, deliberately.
#   PUBLIC  -> any REAL author email; presence still required.
#   PRIVATE -> only allowed_authors may commit.
#
# Under both armed policies a known PLACEHOLDER address is rejected, because
# "leak@host.dev" is non-empty and a presence-only check therefore accepted it.
set -euo pipefail

# Isolate from the tester's global/system git config so an inherited
# user.name / user.email cannot mask the "identity unset" cases below.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/check-git-identity.sh"

cgi_out="$(mktemp)"
trap 'rm -f "$cgi_out"' EXIT

pass=0
fail=0

fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# $5 (config body) is written verbatim, so a case can supply a multi-line
# array, a missing key, or no file at all (empty body plus $6=nofile).
check() {
  local label="$1" expect="$2" uname="$3" uemail="$4" cfg="$5" nofile="${6:-}"
  local gha="${7:-}"
  local sandbox status
  sandbox="$(mktemp -d)"
  git -C "$sandbox" init -q -b main
  if [[ -z "$nofile" ]]; then
    mkdir -p "$sandbox/.harnx"
    printf '%s\n' "$cfg" >"$sandbox/.harnx/instance-config.toml"
  fi
  [[ -n "$uname" ]] && git -C "$sandbox" config user.name "$uname"
  [[ -n "$uemail" ]] && git -C "$sandbox" config user.email "$uemail"
  set +e
  if [[ -n "$gha" ]]; then
    (cd "$sandbox" && env -u CI GITHUB_ACTIONS=true bash "$hook") >"$cgi_out" 2>&1
  else
    (cd "$sandbox" && env -u CI -u GITHUB_ACTIONS bash "$hook") >"$cgi_out" 2>&1
  fi
  status=$?
  set -e
  rm -rf "$sandbox"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected exit $expect, got $status: $(cat "$cgi_out")"
  fi
}

# --- state 1: UNARMED always fails ------------------------------------------
# Every one of these once passed. Each is a way a repo could run indefinitely
# with the author check switched off and nothing ever saying so.
check "unarmed-sentinel-fails" 1 "Dev" "dev@acme.org" 'identity_policy = "CHANGE_ME"'
check "unarmed-missing-key-fails" 1 "Dev" "dev@acme.org" 'company_name = "X"'
check "unarmed-empty-policy-fails" 1 "Dev" "dev@acme.org" 'identity_policy = ""'
check "unarmed-missing-config-fails" 1 "Dev" "dev@acme.org" "" nofile
# A typo must not fall back to a permissive default; that would let a
# one-character slip silently disable the gate.
check "unarmed-unrecognised-policy-fails" 1 "Dev" "dev@acme.org" 'identity_policy = "publik"'
# "private" with nothing to match against cannot admit any author, so it is a
# mistake rather than a policy.
check "unarmed-private-empty-list-fails" 1 "Dev" "dev@acme.org" 'identity_policy = "private"
allowed_authors = []'
check "unarmed-private-missing-list-fails" 1 "Dev" "dev@acme.org" 'identity_policy = "private"'
# The arming check reads a TRACKED FILE, so unlike the author checks it is
# meaningful on a runner and must NOT be skipped there. If it were, "it fails
# when un-armed" would depend on a contributor having installed the hooks.
check "unarmed-fails-on-ci-too" 1 "Dev" "dev@acme.org" 'identity_policy = "CHANGE_ME"' "" gha

# --- state 2: PUBLIC accepts any author, but not an absent one ---------------
check "public-any-author-ok" 0 "Dev" "random@gmail.com" 'identity_policy = "public"'
check "public-no-email-blocks" 1 "Dev" "" 'identity_policy = "public"'
check "public-no-name-blocks" 1 "" "dev@acme.org" 'identity_policy = "public"'
check "public-no-identity-blocks" 1 "" "" 'identity_policy = "public"'
check "public-ok-on-ci" 0 "" "" 'identity_policy = "public"' "" gha

# --- placeholders are rejected under BOTH policies ---------------------------
# "public" means any PERSON may contribute, not that a commit may be authored
# by a stand-in identity nobody owns. A presence-only check waved
# "leak@host.dev" through on every commit of this repo's genesis history,
# because the field was non-empty; non-empty is not the same as real.
check "rfc2606-example-com-blocked" 1 "Dev" "you@example.com" 'identity_policy = "public"'
check "rfc2606-example-org-blocked" 1 "Dev" "dev@example.org" 'identity_policy = "public"'
# RFC 2606 reserves the second-level names INCLUDING everything beneath them.
# An exact-only match let this through, which is the shape a copied tutorial
# snippet most often takes.
check "rfc2606-subdomain-blocked" 1 "Dev" "dev@mail.example.com" 'identity_policy = "public"'
check "rfc6761-localhost-blocked" 1 "Dev" "root@localhost" 'identity_policy = "public"'
check "rfc6761-invalid-blocked" 1 "Dev" "dev@something.invalid" 'identity_policy = "public"'
check "rfc6761-test-blocked" 1 "Dev" "dev@box.test" 'identity_policy = "public"'
# This is what GIT ITSELF generates as username@hostname when no identity is
# configured, so it is the single most likely un-configured value to reach a
# commit. It also leaks the machine's hostname.
check "rfc6762-mdns-local-blocked" 1 "Dev" "fabio@Fabios-MacBook-Pro.local" 'identity_policy = "public"'
check "icann-internal-blocked" 1 "Dev" "dev@box.internal" 'identity_policy = "public"'
check "rfc8375-home-arpa-blocked" 1 "Dev" "dev@nas.home.arpa" 'identity_policy = "public"'
check "localdomain-blocked" 1 "Dev" "dev@vm.localdomain" 'identity_policy = "public"'
# ICANN prohibits dotless domains and SMTP cannot route them, so a container
# whose hostname is its own id can never produce a deliverable address.
check "dotless-container-hostname-blocked" 1 "Dev" "root@a1b2c3d4e5f6" 'identity_policy = "public"'
# Shape. For a string with no "@" both parameter expansions yield the WHOLE
# string, so without an explicit check "nonsense" would be tested as though
# its domain were "nonsense".
check "malformed-no-at-blocked" 1 "Dev" "nonsense" 'identity_policy = "public"'
check "malformed-double-at-blocked" 1 "Dev" "a@@b" 'identity_policy = "public"'
check "malformed-empty-local-blocked" 1 "Dev" "@acme.org" 'identity_policy = "public"'
check "malformed-empty-domain-blocked" 1 "Dev" "dev@" 'identity_policy = "public"'
# These sit on ordinary, registrable domains, so no structural rule can catch
# them; only the local-part list does.
check "placeholder-local-part-test-blocked" 1 "Dev" "test@acme.org" 'identity_policy = "public"'
check "placeholder-local-part-changeme-blocked" 1 "Dev" "changeme@acme.org" 'identity_policy = "public"'
check "placeholder-local-part-root-blocked" 1 "Dev" "root@acme.org" 'identity_policy = "public"'
# Exact-match, never substring: real surnames and words contain these.
check "surname-testa-not-blocked" 0 "Dev" "testa@acme.org" 'identity_policy = "public"'
check "word-protest-not-blocked" 0 "Dev" "protest@acme.org" 'identity_policy = "public"'
check "surname-rooth-not-blocked" 0 "Dev" "rooth@acme.org" 'identity_policy = "public"'

# --- per-repo denied_authors, NOT a floor rule -------------------------------
# A site-local canary has no external meaning and usually sits on a domain the
# shop does not own, so it belongs to the repo, not to the shipped gate.
# "leak@host.dev" is exactly that: a tripwire identity, invented locally, with
# zero public existence, on a domain registered to a third party. The floor
# alone must NOT reject it.
check "site-canary-not-a-floor-rule" 0 "Dev" "leak@host.dev" 'identity_policy = "public"'
check "site-canary-blocked-when-listed" 1 "Dev" "leak@host.dev" 'identity_policy = "public"
denied_authors = ["leak@host.dev"]'
check "denied-authors-accepts-a-bare-domain" 1 "Dev" "anyone@retired.example-corp.com" 'identity_policy = "public"
denied_authors = ["retired.example-corp.com"]'
# denied_authors is checked under private too, before allowed_authors, so a
# banned address cannot be re-admitted by also appearing on the allow list.
check "denied-beats-allowed" 1 "Dev" "leak@host.dev" 'identity_policy = "private"
allowed_authors = ["host.dev"]
denied_authors = ["leak@host.dev"]'
# The one that must NOT be blocked: it looks like a placeholder but is
# GitHub's real, owned, per-account privacy address. Blocking it would lock
# out contributors doing exactly the right thing.
check "github-noreply-is-not-a-placeholder" 0 "Dev" "12345+octocat@users.noreply.github.com" 'identity_policy = "public"'

# --- state 3: PRIVATE restricts to allowed_authors ---------------------------
check "private-domain-match-ok" 0 "Dev" "dev@acme.org" 'identity_policy = "private"
allowed_authors = ["acme.org"]'
check "private-wrong-domain-blocks" 1 "Dev" "dev@other.com" 'identity_policy = "private"
allowed_authors = ["acme.org"]'
# An entry containing "@" is an exact address, not a domain, so one list can
# mix both without a second key to keep in sync.
check "private-exact-address-ok" 0 "Dev" "contractor@gmail.com" 'identity_policy = "private"
allowed_authors = ["acme.org", "contractor@gmail.com"]'
check "private-exact-address-is-not-a-domain" 1 "Dev" "someone@gmail.com" 'identity_policy = "private"
allowed_authors = ["contractor@gmail.com"]'
# A suffix match must not admit a lookalike domain: "evil-acme.org" ends with
# "acme.org" as a plain string, and only the "@" anchor rejects it.
check "private-lookalike-domain-blocks" 1 "Dev" "dev@evil-acme.org" 'identity_policy = "private"
allowed_authors = ["acme.org"]'
# A long list gets formatted across lines; reading only the first line would
# silently drop every entry after it.
check "private-multiline-list-ok" 0 "Dev" "dev@acme.org" 'identity_policy = "private"
allowed_authors = [
  "acme.org",
  "contractor@gmail.com",
]'
check "private-missing-name-blocks" 1 "" "dev@acme.org" 'identity_policy = "private"
allowed_authors = ["acme.org"]'
# The AUTHOR half reads `git config`, which is meaningless on a runner, so it
# is skipped there even for an author the policy would reject locally.
check "private-author-check-skipped-on-ci" 0 "Dev" "dev@other.com" 'identity_policy = "private"
allowed_authors = ["acme.org"]' "" gha
# CI=1 is set by many devcontainers and unrelated tools; only the runner-only
# GITHUB_ACTIONS signal may skip the author checks.
check_bare_ci() {
  local sandbox status
  sandbox="$(mktemp -d)"
  git -C "$sandbox" init -q -b main
  mkdir -p "$sandbox/.harnx"
  printf '%s\n' 'identity_policy = "private"
allowed_authors = ["acme.org"]' >"$sandbox/.harnx/instance-config.toml"
  git -C "$sandbox" config user.name "Dev"
  git -C "$sandbox" config user.email "dev@other.com"
  set +e
  (cd "$sandbox" && env -u GITHUB_ACTIONS CI=true bash "$hook") >"$cgi_out" 2>&1
  status=$?
  set -e
  rm -rf "$sandbox"
  if [[ "$status" -eq 1 ]]; then
    pass=$((pass + 1))
  else
    fail_case "bare-CI-still-enforces: expected exit 1, got $status: $(cat "$cgi_out")"
  fi
}
check_bare_ci

# --- the config is found from a subdirectory ---------------------------------
# Now that a missing config FAILS, resolving it against the cwd instead of the
# repo root would turn any hook invoked from a subdirectory into a false
# "not armed".
check_subdir() {
  local sandbox status
  sandbox="$(mktemp -d)"
  git -C "$sandbox" init -q -b main
  mkdir -p "$sandbox/.harnx" "$sandbox/deep/nested"
  printf '%s\n' 'identity_policy = "public"' >"$sandbox/.harnx/instance-config.toml"
  git -C "$sandbox" config user.name "Dev"
  git -C "$sandbox" config user.email "dev@acme.org"
  set +e
  (cd "$sandbox/deep/nested" && env -u CI -u GITHUB_ACTIONS bash "$hook") >"$cgi_out" 2>&1
  status=$?
  set -e
  rm -rf "$sandbox"
  if [[ "$status" -eq 0 ]]; then
    pass=$((pass + 1))
  else
    fail_case "config-found-from-subdirectory: expected exit 0, got $status: $(cat "$cgi_out")"
  fi
}
check_subdir

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
