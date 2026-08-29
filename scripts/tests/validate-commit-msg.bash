#!/usr/bin/env bash
# Standalone table-driven test for scripts/git-discipline/validate-commit-msg.sh.
# Run: bash scripts/tests/validate-commit-msg.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/git-discipline/validate-commit-msg.sh"

pass=0
fail=0

fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# check <expected-exit> <description> <<'MSG' ... MSG
# COMMIT_MSG_BRANCH=main pins every format-only case to the exempt branch, so
# these never depend on whatever branch this test suite happens to run on.
check() {
  local expect="$1" desc="$2" msgfile status
  msgfile="$(mktemp)"
  cat >"$msgfile"
  set +e
  COMMIT_MSG_BRANCH=main bash "$hook" "$msgfile" >/dev/null 2>&1
  status=$?
  set -e
  rm -f "$msgfile"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "'$desc' expected exit $expect, got $status"
  fi
}

check 0 "well-formed message" <<'MSG'
fix(#6): a valid enough title

body paragraph here.
MSG

check 0 "build/ci/perf types accepted" <<'MSG'
perf(#9): speed up the hot path

body paragraph here.
MSG

check 0 "revert type accepted, properly issue-scoped" <<'MSG'
revert(#9): revert the bad change from earlier

body paragraph here.
MSG

check 1 "unknown type rejected" <<'MSG'
style(#9): formatting only change

body paragraph here.
MSG

check 1 "title shorter than 10 chars rejected" <<'MSG'
fix(#6): too short

body paragraph here.
MSG

check 1 "trailing whitespace on the header rejected" \
  < <(printf 'fix(#6): a valid enough title \n\nbody paragraph here.\n')

check 1 "missing blank separator line rejected" <<'MSG'
fix(#6): a valid enough title
body paragraph here.
MSG

check 1 "missing body rejected" <<'MSG'
fix(#6): a valid enough title

MSG

check 0 "body after an extra blank line accepted" <<'MSG'
fix(#6): a valid enough title


body paragraph on line four.
MSG

check 1 "missing issue number rejected" <<'MSG'
fix: a valid enough title

body paragraph here.
MSG

check 0 "fixup! header accepted (bodyless, autosquash)" <<'MSG'
fixup! fix(#6): a valid enough title
MSG

check 0 "squash! header accepted (autosquash)" <<'MSG'
squash! fix(#6): a valid enough title
MSG

check 0 "amend! header accepted (autosquash)" <<'MSG'
amend! fix(#6): a valid enough title
MSG

check 0 "stacked fixup! headers accepted" <<'MSG'
fixup! fixup! fix(#6): a valid enough title
MSG

check 1 "fixup! without the delimiting space is not exempt" <<'MSG'
fixup!fix(#6): missing the space

body paragraph here.
MSG

check 1 "header + only git comment lines is not a body" <<'MSG'
feat(#6): a valid header line

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
MSG

# A body line starting with "#" immediately followed by a non-space
# character (no "# " prefix) is real content, e.g. an issue reference, not
# one of git's own template comment lines, and must not be stripped into a
# false "empty body" rejection.
check 0 "body line starting with a bare issue reference (#123) accepted" <<'MSG'
fix(#6): a valid enough title

#123 relates to an old ticket.
MSG

# A bare "#" line (no trailing space, no content), as git's own template
# uses for blank separator lines between sections, is still recognized and
# stripped like the "# " prefixed lines around it.
check 1 "header + git template with a bare # separator line is not a body" <<'MSG'
feat(#6): a valid header line

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch main
MSG

# --- issue-number cross-check against COMMIT_MSG_BRANCH ---
check_branch() {
  local branch="$1" expect="$2" desc="$3" msgfile status
  msgfile="$(mktemp)"
  cat >"$msgfile"
  set +e
  COMMIT_MSG_BRANCH="$branch" bash "$hook" "$msgfile" >/dev/null 2>&1
  status=$?
  set -e
  rm -f "$msgfile"
  if [[ "$status" -eq "$expect" ]]; then
    pass=$((pass + 1))
  else
    fail_case "'$desc' expected exit $expect, got $status"
  fi
}

check_branch "feat-6-a-title" 0 "header issue matches branch issue" <<'MSG'
fix(#6): a valid enough title

body paragraph here.
MSG

check_branch "feat-7-a-title" 1 "header issue does not match branch issue" <<'MSG'
fix(#6): a valid enough title

body paragraph here.
MSG

check_branch "main" 0 "main branch is exempt from the cross-check" <<'MSG'
fix(#6): a valid enough title

body paragraph here.
MSG

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
