#!/usr/bin/env bash
# stacking-policy.sh — loads the repository's git-discipline policy, if it has
# one, and answers "is stacking on here?".
#
# Sourced, not executed, by every script that must honour the policy:
# setup-git-config.sh, check-stack-chain.sh and check-branch-rebased.sh. It is a
# fragment for the same reason finding-key.sh is one: three callers have to
# agree, and three copies of a conditional is how they come to disagree. That is
# not hypothetical here. The policy was wired into two of the three, and the
# third kept acting with stacking turned off, so `off` did not mean inert.
#
# Provides:
#   stacking_enabled   returns 0 when stacking is on, 1 when the policy turns it
#                      off. Loads the slot on first call.
#   HARNX_POLICY_FILE  the path consulted, so a caller's message can name it.
#
# ABSENT, EMPTY AND `off` ARE THREE DIFFERENT THINGS. Absent or empty means this
# floor's default, which is that stacking is on; only an explicit
# `HARNX_STACKING=off` disables it. Treating an empty file as `off` would make
# the slot a way to break a repository by touching a file.

# shellcheck shell=bash

stacking_enabled() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
  HARNX_POLICY_FILE="$root/.harnx/custom-hooks/git-discipline/policy.sh"

  if [ -f "$HARNX_POLICY_FILE" ]; then
    # SOURCED, so the slot can set anything these scripts read rather than only
    # the one flag. Enumerating in advance every knob a project might want is
    # how a seam becomes a second, worse configuration language.
    # shellcheck source=/dev/null
    . "$HARNX_POLICY_FILE"
  fi

  [ "${HARNX_STACKING:-on}" != "off" ]
}
