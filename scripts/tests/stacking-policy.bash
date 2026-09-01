#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/stacking-policy.sh.
# Run: bash scripts/tests/stacking-policy.bash
#
# The fragment is one function, which is exactly why it needs a test of its own:
# three scripts source it, and the whole point of making it a fragment is that
# they cannot come to disagree. That is not hypothetical. The policy conditional
# was written inline in two of the three consumers, the third kept acting with
# stacking turned off, and `off` therefore did not mean inert.
#
# `scripts/tests/stack-inertness.bash` covers what each consumer DOES with the
# answer. This covers what the answer IS.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fragment="$repo_root/scripts/git-discipline/stacking-policy.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

repo="$work/repo"
mkdir -p "$repo/.harnx/custom-hooks/git-discipline"
git -C "$repo" init -q -b main 2>/dev/null || git init -q -b main "$repo"
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'x\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the fixture base commit'

slot="$repo/.harnx/custom-hooks/git-discipline/policy.sh"
out="$work/out"

# Each case runs in a FRESH shell. The fragment sources the slot, which sets a
# variable in the caller's environment; reusing one shell would let an earlier
# case's `HARNX_STACKING` leak into a later one and make it pass or fail for the
# wrong reason.
ask() {
  # shellcheck disable=SC2016  # the single quotes are deliberate: this is the
  # body of a FRESH shell, and `$1`, `$HARNX_POLICY_FILE` and
  # `$HARNX_PROBE_VALUE` must be expanded by THAT shell, not by this one.
  (cd "$repo" && env -u HARNX_STACKING bash -c '
    . "$1"
    if stacking_enabled; then echo on; else echo off; fi
    printf "%s\n" "$HARNX_POLICY_FILE"
  ' _ "$fragment") >"$out" 2>&1
}
answer() { head -1 "$out"; }

# --- ABSENT means the floor's default, which is on ---------------------------
rm -f "$slot"
ask || true
if [ "$(answer)" = "on" ]; then ok; else
  fail_case "an absent policy must mean stacking is on, got '$(answer)'"
fi

# --- EMPTY also means the default ---------------------------------------------
# THE CASE THAT MATTERS MOST. If an empty file meant `off`, the slot would be a
# way to break a repository by touching a file, and "absent" and "off" would be
# indistinguishable to anybody reading the directory.
: >"$slot"
ask || true
if [ "$(answer)" = "on" ]; then ok; else
  fail_case "an EMPTY policy must mean stacking is on, got '$(answer)'"
fi

# --- ONLY an explicit `off` disables it ---------------------------------------
printf 'HARNX_STACKING=off\n' >"$slot"
ask || true
if [ "$(answer)" = "off" ]; then ok; else
  fail_case "an explicit off must disable stacking, got '$(answer)'"
fi

printf 'HARNX_STACKING=on\n' >"$slot"
ask || true
if [ "$(answer)" = "on" ]; then ok; else
  fail_case "an explicit on must enable stacking, got '$(answer)'"
fi

# A value that is neither means ON, not off. A typo must not silently disable
# the machinery: the failure mode of guessing wrong here is a repository whose
# stacking gates quietly stopped running.
printf 'HARNX_STACKING=maybe\n' >"$slot"
ask || true
if [ "$(answer)" = "on" ]; then ok; else
  fail_case "an unrecognised value must NOT disable stacking, got '$(answer)'"
fi

# --- THE SLOT IS SOURCED, so it can set more than the one flag ---------------
# Deliberate: enumerating in advance every knob a project might want is how a
# seam becomes a second, worse configuration language.
printf 'HARNX_STACKING=on\nHARNX_PROBE_VALUE=reached\n' >"$slot"
# shellcheck disable=SC2016  # single-quoted deliberately; see `ask` above.
(cd "$repo" && env -u HARNX_STACKING bash -c '
  . "$1"
  stacking_enabled || true
  printf "%s\n" "${HARNX_PROBE_VALUE:-unset}"
' _ "$fragment") >"$out" 2>&1 || true
if [ "$(head -1 "$out")" = "reached" ]; then ok; else
  fail_case "the slot must be sourced, so it can set anything the callers read; got '$(head -1 "$out")'"
fi

# --- THE PATH IS REPORTED, so a caller's message can name it -----------------
printf 'HARNX_STACKING=off\n' >"$slot"
ask || true
# Compared by RESOLVED path. The fragment builds the path from
# `git rev-parse --show-toplevel`, which resolves symlinks, and on macOS the
# per-user temp directory is a symlink (`/var` to `/private/var`). Comparing the
# raw strings fails on a difference that has nothing to do with the behaviour
# under test.
reported="$(cd "$(dirname "$(tail -1 "$out")")" && pwd -P)/$(basename "$(tail -1 "$out")")"
expected="$(cd "$(dirname "$slot")" && pwd -P)/$(basename "$slot")"
if [ "$reported" = "$expected" ]; then ok; else
  fail_case "HARNX_POLICY_FILE must name the slot consulted, got '$reported' want '$expected'"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
