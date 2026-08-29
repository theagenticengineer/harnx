#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/check-commit-authors.sh.
# Run: bash scripts/tests/check-commit-authors.bash
#
# This is the gate that closes the hole the local hook could never cover: the
# local hook validates the identity a machine is ABOUT to commit with, so it
# says nothing about commits that already exist, does nothing on a machine
# where the hooks were never installed, and is skipped entirely on CI. The
# repo's genesis history was authored "Host Identity <leak@host.dev>" with the
# local hook reporting Passed on every one of those commits.
#
# So the cases below are all about what a BRANCH carries, not what a config
# says. Each builds a real repository with real commits and runs the gate over
# a real range.
set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/check-commit-authors.sh"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Builds a repo with one base commit plus one commit per "Name|email" pair,
# then runs the gate over base..HEAD.
#
# $3 is the instance-config body; $4.. are the authors of the commits under
# test. The base commit is always authored by an accepted identity, so a
# failure can only come from the range itself.
run_range() {
  local label="$1" expect="$2" cfg="$3"
  shift 3
  local sb base status i=0
  sb="$(mktemp -d)"
  git -C "$sb" init -q -b main
  mkdir -p "$sb/.harnx"
  printf '%s\n' "$cfg" >"$sb/.harnx/instance-config.toml"
  git -C "$sb" config user.name "Base"
  git -C "$sb" config user.email "base@acme.org"
  git -C "$sb" commit -q --allow-empty -m "base"
  base="$(git -C "$sb" rev-parse HEAD)"
  local spec name email
  for spec in "$@"; do
    name="${spec%%|*}"
    email="${spec#*|}"
    i=$((i + 1))
    GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
      GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
      git -C "$sb" commit -q --allow-empty -m "c$i"
  done
  set +e
  (cd "$sb" && env BASE_SHA="$base" HEAD_SHA=HEAD bash "$hook") >"$out" 2>&1
  status=$?
  set -e
  rm -rf "$sb"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected exit $expect, got $status: $(cat "$out")"
  fi
}

PRIVATE='identity_policy = "private"
allowed_authors = ["acme.org"]'
PUBLIC='identity_policy = "public"'
CANARY='identity_policy = "public"
denied_authors = ["leak@host.dev"]'

# --- the case this gate exists for ------------------------------------------
# A branch carrying a placeholder-authored commit must fail, no matter what the
# committing machine's config says now. This is precisely the situation the
# local hook cannot detect.
# The historical value verbatim, with no second "@". An earlier version of this
# case used "leak@host.dev@x.local", which is rejected by the malformed-address
# rule rather than by the placeholder rule, so it passed while testing
# something other than what its name claims. Under the floor's rules alone
# "leak@host.dev" is a perfectly well-formed address on a real domain, which is
# exactly why it needs the per-repo denied_authors entry the CANARY case below
# exercises. This case therefore asserts the mDNS-namespace rule instead, using
# the value git itself generates when no identity is configured.
run_range "carried-mdns-hostname-commit-fails" 1 "$PUBLIC" "Host Identity|host@Fabios-MacBook-Pro.local"
run_range "carried-mdns-local-commit-fails" 1 "$PUBLIC" "Dev|dev@box.local"
run_range "carried-dotless-commit-fails" 1 "$PUBLIC" "Dev|root@a1b2c3d4e5f6"
run_range "carried-site-canary-fails-when-denied" 1 "$CANARY" "Host Identity|leak@host.dev"
# ... and the same address passes when the repo has not denied it, proving the
# canary is a per-repo rule and not a floor one.
run_range "site-canary-passes-when-not-denied" 0 "$PUBLIC" "Host Identity|leak@host.dev"

# --- one bad commit among good ones still fails the range --------------------
# The loop must not stop at the first commit, and must not lose the failure:
# `git log | while read` runs the body in a subshell, so a flag set inside it
# would be discarded when the pipeline exits, turning every rejection into a
# pass.
run_range "one-bad-among-many-fails" 1 "$PUBLIC" \
  "Dev|dev@acme.org" "Dev|dev@example.com" "Dev|other@acme.org"
run_range "all-good-passes" 0 "$PUBLIC" \
  "Dev|dev@acme.org" "Dev|other@acme.org" "Dev|third@acme.co.uk"

# --- private policy applies to every commit in the range ---------------------
run_range "private-allows-listed-domain" 0 "$PRIVATE" "Dev|dev@acme.org"
run_range "private-rejects-outside-domain" 1 "$PRIVATE" "Dev|dev@other.com"
run_range "private-rejects-outsider-mid-range" 1 "$PRIVATE" \
  "Dev|dev@acme.org" "Outsider|someone@gmail.com"

# --- unarmed fails here too, on CI, where it cannot be skipped ---------------
run_range "unarmed-fails" 1 'identity_policy = "CHANGE_ME"' "Dev|dev@acme.org"
run_range "unarmed-missing-config-fails" 1 '' "Dev|dev@acme.org"

# --- an empty range fails rather than reporting a green check ------------------
# base == head means the range resolved to nothing. Reporting success there is
# a green check that examined nothing, which is the exact failure mode this
# script exists to remove.
run_range "empty-range-fails" 1 "$PUBLIC"

# --- GitHub's web-flow committer is accepted as COMMITTER, never as AUTHOR ---
# GitHub stamps noreply@github.com as the committer of commits made through its
# web editor. Rejecting it would fail commits a contributor made correctly.
check_webflow() {
  local label="$1" expect="$2" a_email="$3" c_email="$4"
  local sb base status
  sb="$(mktemp -d)"
  git -C "$sb" init -q -b main
  mkdir -p "$sb/.harnx"
  printf '%s\n' 'identity_policy = "public"' >"$sb/.harnx/instance-config.toml"
  git -C "$sb" config user.name Base
  git -C "$sb" config user.email base@acme.org
  git -C "$sb" commit -q --allow-empty -m base
  base="$(git -C "$sb" rev-parse HEAD)"
  GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL="$a_email" \
    GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL="$c_email" \
    git -C "$sb" commit -q --allow-empty -m webflow
  set +e
  (cd "$sb" && env BASE_SHA="$base" HEAD_SHA=HEAD bash "$hook") >"$out" 2>&1
  status=$?
  set -e
  rm -rf "$sb"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "$label: expected exit $expect, got $status: $(cat "$out")"
  fi
}
check_webflow "webflow-committer-accepted" 0 "dev@acme.org" "noreply@github.com"
# The carve-out is case-insensitive, matching how every other address in the
# policy is evaluated; otherwise a differently-cased noreply address would fall
# through to the generic no-reply rule and fail a legitimate web-edited commit.
check_webflow "webflow-committer-accepted-mixed-case" 0 "dev@acme.org" "NoReply@GitHub.com"
# The carve-out is committer-only: the same address as an AUTHOR is a
# non-attributable stand-in and must still be rejected.
check_webflow "webflow-address-rejected-as-author" 1 "noreply@github.com" "dev@acme.org"
# A genuinely bad committer is still caught.
check_webflow "bad-committer-rejected" 1 "dev@acme.org" "root@a1b2c3d4e5f6"
# GitHub's per-account privacy address is real and must pass as either.
check_webflow "github-noreply-privacy-address-ok" 0 \
  "12345+octocat@users.noreply.github.com" "12345+octocat@users.noreply.github.com"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
