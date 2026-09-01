#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/author-policy.sh.
# Run: bash scripts/tests/author-policy.bash
#
# The fragment answers one question, "may this address author a commit here",
# for BOTH gates that ask it: check-git-identity.sh locally and
# check-commit-authors.sh in CI. It is sourced rather than executed precisely so
# the two can never disagree, which means a change here changes what CI enforces
# with nothing else watching. That is what this suite watches.
#
# Two properties get the most attention below, because both have already been
# wrong in this repository's history:
#
#   - AN UNARMED GATE MUST FAIL. The genesis history here was authored as
#     "Host Identity <leak@host.dev>" while the identity gate reported Passed
#     every single time. Every arming diagnosis is asserted to return non-zero.
#   - DENIED BEATS ALLOWED. An address on both lists must be rejected; the
#     other order would let a denial be undone by re-listing.
#
# Every helper call that is not already inside an `if` carries `|| true`. Under
# `set -e` a bare failing call aborts the suite, and an aborted suite reports
# the assertions it reached rather than a failure, which reads as a smaller run
# rather than a broken one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/git-discipline/author-policy.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$repo_root/scripts/git-discipline/author-policy.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

# Writes a config and loads it. Returns author_policy_load's own status, so the
# arming cases can assert on it.
load_config() {
  local body="$1" cfg="$work/instance-config.toml"
  printf '%s\n' "$body" >"$cfg"
  author_policy_load "$cfg" 2>"$work/load.err"
}

accepts() {
  if author_policy_reject "$1" >"$work/why" 2>&1; then ok; else
    fail_case "must accept $1: $(cat "$work/why")"
  fi
}
rejects() {
  if author_policy_reject "$1" >"$work/why" 2>&1; then
    fail_case "must reject ($2): $1"
  else ok; fi
}

# ============================================================================
# ARMING. Every one of these must FAIL, and the message must say the gate is
# not armed rather than accepting the commit.
# ============================================================================
if load_config 'identity_policy = "public"'; then ok; else
  fail_case "a well-formed public policy must arm: $(cat "$work/load.err")"
fi

armed_check() {
  local label="$1" body="$2"
  if load_config "$body"; then
    fail_case "$label must NOT arm the gate"
  else
    ok
    if grep -q 'NOT ARMED' "$work/load.err"; then ok; else
      fail_case "$label must say the gate is not armed, said: $(cat "$work/load.err")"
    fi
  fi
}
armed_check "an empty config" ''
armed_check "a sentinel policy" 'identity_policy = "CHANGE_ME"'
armed_check "an unrecognised policy" 'identity_policy = "permissive"'
armed_check "private with no allowed_authors" 'identity_policy = "private"'

# A MISSING FILE is its own case: the others all have a file to read.
if author_policy_load "$work/does-not-exist.toml" 2>"$work/load.err"; then
  fail_case "a missing config must NOT arm the gate"
else
  ok
  if grep -q 'NOT ARMED' "$work/load.err"; then ok; else
    fail_case "a missing config must say the gate is not armed"
  fi
fi

# ============================================================================
# ADDRESS SHAPE. Everything after this assumes a clean local@domain split.
# ============================================================================
load_config 'identity_policy = "public"' || true
rejects 'nonsense' "no @ at all"
rejects '@example.dev' "empty local part"
rejects 'dev@' "empty domain"
rejects 'a@b@c.dev' "two @ signs"
accepts 'dev@acme.dev'

# ============================================================================
# RESERVED NAMESPACES, each with a SUBDOMAIN case. An exact-only match would
# let dev@mail.example.com through, which is the whole reason the arms carry
# their wildcards.
# ============================================================================
for d in example.com example.net example.org invalid test localhost home.arpa; do
  rejects "dev@$d" "reserved: $d"
  rejects "dev@mail.$d" "reserved subdomain: mail.$d"
done
rejects 'dev@machine.local' "link-local mDNS, which is what git generates as username@hostname"
rejects 'dev@corp.internal' "ICANN private-use namespace"
rejects 'dev@box.localdomain' "distro-default .localdomain"

# A DOTLESS domain can never receive mail, and is the shape a container's
# default hostname takes.
rejects 'dev@containerid' "dotless domain"

# The carve-out that must survive all of the above: GitHub's per-account
# privacy address is real and owned, and blocking it would lock out
# contributors doing exactly the right thing.
accepts '12345+someone@users.noreply.github.com'

# ============================================================================
# LOCAL PARTS that identify nobody.
# ============================================================================
for l in changeme change_me change-me placeholder youremail your_email your-email your.email; do
  rejects "$l@acme.dev" "placeholder local part: $l"
done
rejects 'test@acme.dev' "throwaway account"
rejects 'root@acme.dev' "system account"
for l in noreply no-reply donotreply do-not-reply; do
  rejects "$l@acme.dev" "no-reply address: $l"
done
# The bare no-reply rule must NOT reach the GitHub privacy address, which the
# domain carve-out accepts before this list is consulted.
accepts 'noreply@users.noreply.github.com'

# ============================================================================
# PER-REPO LISTS.
# ============================================================================
load_config 'identity_policy = "public"
denied_authors = ["bad@acme.dev", "evil.dev"]' || true
rejects 'bad@acme.dev' "exact denied entry"
rejects 'anyone@evil.dev' "denied by bare domain"
accepts 'good@acme.dev'
# The "@" anchor on the domain arm: a bare domain entry must not admit a
# lookalike that merely ends with the same letters.
accepts 'dev@not-evil.dev'

load_config 'identity_policy = "private"
allowed_authors = ["acme.dev", "one@other.dev"]' || true
accepts 'anyone@acme.dev'
accepts 'one@other.dev'
rejects 'two@other.dev' "private policy, address matches no allowed entry"
rejects 'dev@elsewhere.dev' "private policy, domain not allowed"
# The same "@" anchor, on the allow side.
rejects 'dev@evil-acme.dev' "a lookalike domain must not be admitted by the acme.dev entry"

# DENIED IS CHECKED BEFORE ALLOWED, so an address on both lists stays out. The
# other order would let a denial be undone by re-listing the address.
load_config 'identity_policy = "private"
allowed_authors = ["acme.dev"]
denied_authors = ["fired@acme.dev"]' || true
rejects 'fired@acme.dev' "on both lists: denied must win"
accepts 'current@acme.dev'

# CASE IS NOT SIGNIFICANT. Git records whatever the contributor typed.
rejects 'FIRED@ACME.DEV' "denial must hold regardless of case"
accepts 'Current@Acme.Dev'

# A MULTI-LINE ARRAY must parse. This is how a long list gets formatted, and
# reading it as empty would silently drop every entry: under a private policy
# that rejects everyone, and on the denied side it admits everyone denied.
load_config 'identity_policy = "private"
allowed_authors = [
  "acme.dev",
  "one@other.dev",
]' || true
accepts 'anyone@acme.dev'
accepts 'one@other.dev'
rejects 'dev@elsewhere.dev' "a multi-line allow list must still exclude"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
