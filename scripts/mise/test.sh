#!/usr/bin/env bash
# test.sh — runs every shell-test suite and fails if any of them fails.
#
# This is what `mise run test` and ci.yml's `shell-tests` job execute, so its
# exit status IS the required check. Two properties matter and both are pinned
# by scripts/tests/test.bash:
#
#   - a failing suite must fail the run. `bash "$t" || status=1` records the
#     failure without aborting, so EVERY suite still runs and one push reports
#     every broken suite rather than one per round.
#   - an EMPTY suite directory must fail, loudly. Reporting green because
#     nothing was looking is the placeholder pattern this branch's ci.yml
#     header spends thirty lines apologising for, and it is the exact shape of
#     the tamper CODEOWNERS exists to catch ("redefining mise.toml's test task
#     to a no-op"). Left to the bare glob it failed by accident, through
#     `bash` being handed a literal `scripts/tests/*.bash` that does not
#     exist, with an error message about a missing file rather than about a
#     missing suite. Deliberate and legible instead.
set -euo pipefail

shopt -s nullglob
suites=(scripts/tests/*.bash)
if [ "${#suites[@]}" -eq 0 ]; then
  echo "test.sh: no suites found under scripts/tests/. Refusing to report a green test run that verified nothing." >&2
  exit 1
fi

status=0
for t in "${suites[@]}"; do
  echo "== $t"
  bash "$t" || status=1
done
exit "$status"
