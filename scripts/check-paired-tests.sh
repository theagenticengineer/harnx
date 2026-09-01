#!/usr/bin/env bash
# check-paired-tests.sh — every shell script this branch ships must have a
# paired test, and this is what makes that mechanical.
#
# WHY IT EXISTS. `.agents/rules/tests-homing.md` says where a paired test goes:
# "directly in scripts/tests/, as a .bash file, in the same commit as the code
# it tests". Nothing failed when a script had none, and a rule nothing enforces
# is a preference. Six scripts reached the default branch untested that way,
# including review-engine.sh, the one script that runs holding a live engine
# token while reading a diff written by whoever opened the pull request.
#
# HOOK OR CI JOB: BOTH, and that is the answer to the question criterion 27 left
# open. It is a `local` hook in .pre-commit-config.yaml, so an author learns at
# commit time rather than after a push; and the trunk's `pre-commit` CI job runs
# `pre-commit run --all-files`, so the same gate is a required check that a
# skipped hook cannot bypass. Neither alone is enough: a hook is advisory to
# anyone who passes --no-verify, and a CI-only gate spends a round trip
# teaching what a hook teaches in a second.
#
# THE DIRECTION IS ONE WAY, deliberately. A script with no test fails. A TEST
# with no script does not: scripts/tests/action-pins.bash,
# trunk-toolchain.bash and workflow-job-names.bash are suites over the
# workflows and the toolchain, which are not scripts and have no basename to
# pair with. Requiring the reverse would either delete those or force three
# empty scripts into existence to satisfy a checker.
#
# Scanned from `git ls-files`, not from the filesystem: an untracked scratch
# script in a worktree is nobody's business, and a NEWLY ADDED script is in the
# index by the time a pre-commit hook runs, so this fires on the commit that
# introduces it rather than one commit later.
#
# `scripts/*.sh` IS RECURSIVE HERE, and it is worth stating because it reads
# like it is not. A git pathspec is not a shell glob: git matches with fnmatch
# WITHOUT FNM_PATHNAME, so `*` crosses `/` and this pattern reaches
# scripts/ai-review/ and scripts/mise/ as well as the top level. A reader
# carrying shell-glob intuition concludes the opposite, that the gate exempts
# exactly the credentialed scripts it exists to protect, which would be a
# serious defect if it were true.
#
# Measured rather than argued: `git ls-files 'scripts/*.sh'` returns 18 paths,
# and `git ls-files scripts/ | grep '\.sh$'`, which has no pathspec subtlety at
# all, returns the same 18. scripts/tests/check-paired-tests.bash pins the
# behaviour with a nested fixture, so a future change to this line that broke
# recursion would fail rather than silently narrow the gate.
set -euo pipefail

# Repo-root-relative regardless of where it is invoked from: pre-commit runs
# hooks from the repository root, but `mise run` and a human do not have to.
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

missing=""
seen=""
collisions=""
count=0
while read -r script; do
  [ -n "$script" ] || continue
  count=$((count + 1))
  base="$(basename "$script" .sh)"

  # A BASENAME COLLISION IS REFUSED, not paired. scripts/tests/ is flat, so
  # pairing by basename means scripts/ai-review/x.sh and scripts/mise/x.sh
  # would BOTH be satisfied by one scripts/tests/x.bash, and one of them would
  # be untested while this gate reported green. That is the fail-open the gate
  # exists to close, reintroduced by its own matching rule.
  #
  # Refused rather than resolved by pairing on the full path, because a flat
  # scripts/tests/ has no room for two x.bash files: making the pairing
  # path-aware would only move the failure to "the test you need cannot be
  # named". Two scripts in one repository sharing a basename is confusing on
  # its own terms; renaming one is the fix.
  if printf '%s\n' "$seen" | grep -Fxq "$base"; then
    collisions="$collisions  $base: $(git ls-files "scripts/*/$base.sh" "scripts/$base.sh" | tr '\n' ' ')
"
  fi
  seen="$seen
$base"

  if [ ! -f "scripts/tests/$base.bash" ]; then
    missing="$missing  $script -> scripts/tests/$base.bash
"
  fi
done <<EOF
$(git ls-files 'scripts/*.sh')
EOF

if [ -n "$collisions" ]; then
  echo "::error::check-paired-tests: two or more scripts share a basename. scripts/tests/ is flat, so they cannot each have their own paired test and one would be silently untested. Rename one." >&2
  printf '%s' "$collisions" >&2
  exit 1
fi

if [ -n "$missing" ]; then
  echo "::error::check-paired-tests: these scripts have no paired test. Write one in the SAME commit as the code it tests; see .agents/rules/tests-homing.md." >&2
  printf '%s' "$missing" >&2
  exit 1
fi

echo "check-paired-tests: $count script(s), each with a paired test in scripts/tests/."
