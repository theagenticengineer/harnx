#!/usr/bin/env bash
# author-policy.sh — single source of truth for "may this address author a
# commit in this repo?", sourced by BOTH gates that need to answer it:
#
#   check-git-identity.sh    local pre-commit, reads `git config user.email`,
#                            so it validates INTENT going forward.
#   check-commit-authors.sh  CI, reads the commit range's own metadata, so it
#                            validates WHAT IS ACTUALLY IN THE BRANCH.
#
# Both are needed, and the second is the one that matters. The first can only
# ever check the machine that is about to commit: it is skipped on CI (no
# meaningful `git config` there), it does nothing at all if a contributor never
# ran `pre-commit install`, and it cannot see a single commit that already
# exists. This repo authored its entire genesis history as
# "Host Identity <leak@host.dev>" with that gate reporting Passed every time.
# A rule that only governs future commits lets CI go green while the branch
# carries the offending ones.
#
# Sourced, not executed, so the rules cannot drift between the two callers.
# Follows the pattern parse-commit-header.sh already establishes for the
# commit-header regex.
#
# Provides:
#   author_policy_load [config-path]
#       Reads the instance config into AP_POLICY / AP_ALLOWED / AP_DENIED /
#       AP_CONFIG. Prints the arming diagnosis and returns 1 when the repo is
#       UNARMED; returns 0 otherwise.
#   author_policy_reject <email>
#       Prints a human-readable reason and returns 1 if the address may not
#       author here; prints nothing and returns 0 if it may.

# shellcheck shell=bash

AP_CONFIG=""
AP_POLICY=""
AP_ALLOWED=""
AP_DENIED=""

_ap_toml_string() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$AP_CONFIG" | head -1
}

# Reads a TOML array of strings, single-line or multi-line: the whole
# `key = [ ... ]` region is buffered before the quoted entries are pulled out,
# so a list broken across lines (which is how a long one gets formatted) is not
# silently read as empty.
#
# The trailing `|| true` is load-bearing, not defensive noise. An ABSENT key is
# a legitimate, common case (identity_policy = "public" carries no
# allowed_authors at all), and `grep -o` exits 1 when it matches nothing. Under
# `set -euo pipefail` that failed the pipeline, which failed the command
# substitution at the call site, which aborted the caller with exit 1 and NO
# message: the gate rejected every "public" repo while printing nothing.
_ap_toml_array() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { inside = 1 }
    inside { buf = buf $0 }
    inside && /\]/ { print buf; exit }
  ' "$AP_CONFIG" | grep -o '"[^"]*"' | tr -d '"' || true
}

# Matches one address against one allowed_authors/denied_authors entry. An
# entry containing "@" is an exact address; anything else is a bare domain
# matching every address on it. The "@" is what tells them apart, so a single
# list can mix both without a second key to keep in sync. The "@" anchor on the
# domain arm is what stops "acme.org" from admitting "dev@evil-acme.org".
_ap_matches() {
  local email="$1" entry="$2"
  entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
  if [[ "$entry" == *@* ]]; then
    [[ "$email" == "$entry" ]]
  else
    [[ "$email" == *"@$entry" ]]
  fi
}

author_policy_load() {
  AP_CONFIG="${1:-}"
  if [[ -z "$AP_CONFIG" ]]; then
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    AP_CONFIG="${repo_root:+$repo_root/}.harnx/instance-config.toml"
  fi

  AP_POLICY=""
  AP_ALLOWED=""
  AP_DENIED=""
  if [[ -f "$AP_CONFIG" ]]; then
    AP_POLICY="$(_ap_toml_string identity_policy)"
    AP_ALLOWED="$(_ap_toml_array allowed_authors)"
    AP_DENIED="$(_ap_toml_array denied_authors)"
  fi

  if [[ ! -f "$AP_CONFIG" ]]; then
    echo "ERROR: the git-identity gate is NOT ARMED: no $AP_CONFIG." >&2
  elif [[ -z "$AP_POLICY" ]]; then
    echo "ERROR: the git-identity gate is NOT ARMED: $AP_CONFIG declares no identity_policy." >&2
  elif [[ "$AP_POLICY" == *CHANGE_ME* ]]; then
    echo "ERROR: the git-identity gate is NOT ARMED: $AP_CONFIG still has the" >&2
    echo "       un-filled sentinel identity_policy = \"$AP_POLICY\"." >&2
  elif [[ "$AP_POLICY" != "public" && "$AP_POLICY" != "private" ]]; then
    echo "ERROR: the git-identity gate is NOT ARMED: identity_policy = \"$AP_POLICY\" is not" >&2
    echo "       a recognised policy. An unrecognised value fails rather than" >&2
    echo "       falling back to a permissive default, which would let a typo" >&2
    echo "       silently disable the gate." >&2
  elif [[ "$AP_POLICY" == "private" && -z "$AP_ALLOWED" ]]; then
    echo "ERROR: the git-identity gate is NOT ARMED: identity_policy = \"private\" but" >&2
    echo "       $AP_CONFIG lists no allowed_authors, so no author could ever" >&2
    echo "       match. An empty restriction is a mistake, not a policy." >&2
  else
    return 0
  fi

  echo "       An un-armed gate reports success while checking nothing, so this" >&2
  echo "       fails instead of passing quietly. Declare the policy in" >&2
  echo "       $AP_CONFIG:" >&2
  echo "         identity_policy = \"public\"    # anyone may contribute" >&2
  echo "       or" >&2
  echo "         identity_policy = \"private\"" >&2
  echo "         allowed_authors = [\"your-company.com\", \"someone@example.org\"]" >&2
  echo "       See AGENTS.md, \"Setup\"." >&2
  return 1
}

author_policy_reject() {
  local email="$1" lower local_part domain_part entry
  lower="$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')"

  # Shape first. Everything below assumes local@domain split cleanly, and for a
  # string with no "@" the two parameter expansions yield the WHOLE string, so
  # an address like "nonsense" would otherwise be tested as though its domain
  # were "nonsense".
  domain_part="${lower##*@}"
  local_part="${lower%@*}"
  if [[ "$lower" != *@* || -z "$local_part" || -z "$domain_part" || "$local_part" == *@* ]]; then
    echo "not a well-formed address (expected exactly one \"@\", with text on both sides)"
    return 1
  fi

  # users.noreply.github.com is deliberately NOT rejected: it looks like a
  # placeholder but is GitHub's real, owned, per-account privacy address, and
  # blocking it would lock out contributors doing exactly the right thing.
  # Checked before the reserved-namespace rules so no later rule can catch it.
  if [[ "$domain_part" == "users.noreply.github.com" ]]; then
    return 0
  fi

  # Reserved namespaces. Matched on the domain AND its subdomains: RFC 2606
  # reserves the second-level names including everything beneath them, so an
  # exact-only match would let "dev@mail.example.com" through.
  case "$domain_part" in
  example.com | example.net | example.org | *.example.com | *.example.net | *.example.org)
    echo "on a reserved documentation domain (RFC 2606), which nobody can own"
    return 1
    ;;
  example | *.example | invalid | *.invalid | test | *.test | localhost | *.localhost)
    echo "on a reserved special-use domain (RFC 6761), which nobody can own"
    return 1
    ;;
  *.local)
    echo "on the link-local mDNS namespace (RFC 6762), which is also what git generates as username@hostname when no identity is configured"
    return 1
    ;;
  internal | *.internal | local | localdomain | *.localdomain)
    echo "on a private-use namespace (ICANN .internal, or a distro-default .localdomain), not routable off the host"
    return 1
    ;;
  home.arpa | *.home.arpa)
    echo "on the residential home-network namespace (RFC 8375)"
    return 1
    ;;
  esac

  # A domain with no dot at all. ICANN prohibits dotless domain names and SMTP
  # requires a fully-qualified one, so these can never receive mail. This is the
  # shape a container default takes: the hostname is the container id.
  #
  # This rule already covers every BARE reserved name in the arms above
  # ("internal", "local", "invalid", "test", "localhost"), which is exactly why
  # they are still spelled out there: a reader comparing the arms should not
  # have to derive that dotless coverage is what makes the list complete, and a
  # reviewer should not have to rediscover it. The redundancy is deliberate.
  if [[ "$domain_part" != *.* ]]; then
    echo "on a dotless domain, which ICANN prohibits and SMTP cannot route (the shape a container's default hostname takes)"
    return 1
  fi

  case "$local_part" in
  changeme | change_me | change-me | placeholder | youremail | your_email | your-email | your.email)
    echo "a placeholder local part"
    return 1
    ;;
  test | root)
    echo "a system or throwaway account, not a person"
    return 1
    ;;
  noreply | no-reply | donotreply | do-not-reply)
    # Non-attributable by construction. This does NOT catch
    # "<id>+<user>@users.noreply.github.com": that address is returned as
    # accepted by the DOMAIN carve-out above, before this list is reached,
    # because it is a real, owned, per-account privacy address. This arm is
    # for the bare "noreply@github.com" form, which GitHub stamps as the
    # COMMITTER of web-editor and merge commits. That is legitimate machine
    # provenance in the committer position, and check-commit-authors.sh
    # exempts it there and only there; as an AUTHOR it identifies nobody.
    echo "a no-reply address, which identifies nobody"
    return 1
    ;;
  esac

  # Per-repo denials, checked BEFORE the allow list so an address cannot be
  # re-admitted by appearing on both.
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if _ap_matches "$lower" "$entry"; then
      echo "listed in denied_authors in $AP_CONFIG"
      return 1
    fi
  done <<EOF
$AP_DENIED
EOF

  if [[ "$AP_POLICY" == "private" ]]; then
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      if _ap_matches "$lower" "$entry"; then
        return 0
      fi
    done <<EOF
$AP_ALLOWED
EOF
    echo "not an allowed author: identity_policy is \"private\" and this address matches no allowed_authors entry in $AP_CONFIG"
    return 1
  fi

  return 0
}
