#!/usr/bin/env bash
# Standalone test for scripts/check-agents-index.sh.
# Run: bash scripts/tests/check-agents-index.bash
#
# The gate's whole value is that it fails in BOTH directions, so both are
# asserted here. A one-directional version would be the easy thing to write and
# would miss the failure that actually happens: a rule document added and never
# linked, which leaves an index that looks complete and is not.
#
# Runs against throwaway fixture directories, not against the repository's own
# AGENTS.md, so the suite still means something on a tree where the real index
# is momentarily wrong. The script takes its two paths from the environment for
# exactly that reason.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/check-agents-index.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

# Builds a fixture: $1 is the index body, the rest are rule filenames to create.
fixture() {
  local body="$1"
  shift
  rm -rf "$work/fx"
  mkdir -p "$work/fx/rules"
  printf '%s\n' "$body" >"$work/fx/INDEX.md"
  local f
  for f in "$@"; do printf '# %s\n' "$f" >"$work/fx/rules/$f"; done
}

# The script resolves its repo root from its own location, so it is run with
# the fixture as the working directory and the two paths passed relative to it.
# AGENTS_ROOT, not a `cd`: the script resolves its own repository root from
# BASH_SOURCE and cds there, so a caller's working directory alone does not
# reach it.
run() {
  AGENTS_ROOT="$work/fx" AGENTS_INDEX="INDEX.md" AGENTS_RULES_DIR="rules" \
    bash "$script" >"$work/out" 2>&1
}

# --- agreement in both directions passes --------------------------------------
fixture '- [One](rules/one.md)
- [Two](rules/two.md)' one.md two.md
if run; then ok; else
  fail_case "a matching index and directory must pass: $(cat "$work/out")"
fi
if grep -q '2 documents' "$work/out"; then ok; else
  fail_case "the success line must report how many documents agreed: $(cat "$work/out")"
fi

# --- A DOCUMENT NOBODY LINKS TO fails -----------------------------------------
# The quiet failure this gate exists for: the rule is written and enforced, and
# no reader is ever sent to it.
fixture '- [One](rules/one.md)' one.md orphan.md
if run; then
  fail_case "an unlinked rule document must fail"
else ok; fi
if grep -q 'orphan.md' "$work/out"; then ok; else
  fail_case "the error must name the unlinked document: $(cat "$work/out")"
fi

# --- A LINK TO NOTHING fails ---------------------------------------------------
fixture '- [One](rules/one.md)
- [Gone](rules/renamed-away.md)' one.md
if run; then
  fail_case "a link to a missing document must fail"
else ok; fi
if grep -q 'renamed-away.md' "$work/out"; then ok; else
  fail_case "the error must name the dead link: $(cat "$work/out")"
fi

# --- BOTH AT ONCE are both reported --------------------------------------------
# Reporting only the first would send somebody round the loop twice.
fixture '- [Gone](rules/renamed-away.md)' one.md
if run; then
  fail_case "both failures at once must still fail"
else ok; fi
if grep -q 'renamed-away.md' "$work/out" && grep -q 'one.md' "$work/out"; then ok; else
  fail_case "both problems must be reported in one run: $(cat "$work/out")"
fi

# --- A MENTION IS NOT A LINK ---------------------------------------------------
# The path must come from inside the parentheses. Prose that names the file, or
# a code span quoting it, is not a link and must not satisfy the index.
# shellcheck disable=SC2016  # the backticks are a markdown code span in the
# fixture's text, not a command substitution; single quotes are what keeps them
# literal, which is the whole point of this case.
fixture 'Everything lives under `rules/one.md`, which is not a link.' one.md
if run; then
  fail_case "a bare mention must not count as linking the document"
else ok; fi

# --- AN EMPTY RULES DIRECTORY is not a failure ---------------------------------
# A floor that ships no rule documents yet is a legitimate early state; the gate
# has nothing to disagree about.
fixture '# No rules yet'
if run; then ok; else
  fail_case "an empty rules directory with no links must pass: $(cat "$work/out")"
fi

# --- A MISSING index or directory is a hard error ------------------------------
# Distinguished from "they disagree", because the cause and the fix differ.
rm -rf "$work/fx"
mkdir -p "$work/fx/rules"
if run; then
  fail_case "a missing index must fail"
else ok; fi
if grep -q 'does not exist' "$work/out"; then ok; else
  fail_case "a missing index must say so plainly: $(cat "$work/out")"
fi

rm -rf "$work/fx"
mkdir -p "$work/fx"
printf '# index\n' >"$work/fx/INDEX.md"
if run; then
  fail_case "a missing rules directory must fail"
else ok; fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
