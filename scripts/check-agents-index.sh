#!/usr/bin/env bash
# check-agents-index.sh — AGENTS.md and .agents/rules/ must agree, in both
# directions.
#
# AGENTS.md is an index. An index is only worth reading if it is complete, and
# an incomplete one is worse than none: a reader who finds four of five rules
# there concludes there are four rules. The two failure modes are opposite and
# both silent, so both are checked:
#
#   - a rule document nothing links to. It was written, it is enforced, and
#     nobody will ever be sent to it.
#   - a link to a document that does not exist. Usually a rename, and the
#     reader gets a dead link for a rule that is still in force.
#
# Deliberately NOT a link checker. It says nothing about links to files outside
# .agents/rules/, or about external URLs; lychee covers those. Its whole
# question is whether the index matches the directory.
set -euo pipefail

# The root is resolved from this script's own location, so the gate checks THIS
# repository however it was invoked, from a hook, from CI, or from a
# subdirectory. AGENTS_ROOT overrides it, and the two path variables below
# override the names, so the paired test can point the whole gate at a fixture
# instead of asserting against the repository's own index. A suite that read the
# real AGENTS.md would stop meaning anything on the day that file is wrong,
# which is the day it matters most.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${AGENTS_ROOT:-$repo_root}"

index="${AGENTS_INDEX:-AGENTS.md}"
rules_dir="${AGENTS_RULES_DIR:-.agents/rules}"

if [ ! -f "$index" ]; then
  echo "::error::check-agents-index: $index does not exist." >&2
  exit 1
fi
if [ ! -d "$rules_dir" ]; then
  echo "::error::check-agents-index: $rules_dir does not exist." >&2
  exit 1
fi

# Every markdown link in the index that points into the rules directory. The
# path is taken from inside the parentheses, so a link whose TEXT mentions the
# directory does not count as one.
# The directory is ESCAPED before it goes into the ERE. Interpolated raw, the
# dot in `.agents/rules` is a wildcard, so `Xagents/rules/foo.md` would count as
# a link into it. Harmless in practice and wrong in principle, and a pattern
# built from a variable that nobody escaped is the kind of thing that stops
# being harmless when the variable changes.
# shellcheck disable=SC2016  # the `$` and `&` are sed syntax, not shell
# expansions; single quotes are what keeps them literal.
rules_dir_re="$(printf '%s' "$rules_dir" | sed 's/[.[\*^$()+?{|]/\\&/g')"
linked="$(grep -oE "\]\($rules_dir_re/[A-Za-z0-9._-]+\.md\)" "$index" |
  sed -e 's/^](//' -e 's/)$//' | sort -u || true)"

present="$(find "$rules_dir" -maxdepth 1 -name '*.md' | sort -u)"

status=0

missing_link=""
while IFS= read -r doc; do
  [ -n "$doc" ] || continue
  printf '%s\n' "$linked" | grep -Fxq "$doc" || missing_link="$missing_link $doc"
done <<RULES_PRESENT
$present
RULES_PRESENT
if [ -n "$missing_link" ]; then
  echo "::error::check-agents-index: these rule documents are not linked from $index, so nobody will be sent to them:$missing_link" >&2
  status=1
fi

broken=""
while IFS= read -r link; do
  [ -n "$link" ] || continue
  [ -f "$link" ] || broken="$broken $link"
done <<RULES_LINKED
$linked
RULES_LINKED
if [ -n "$broken" ]; then
  echo "::error::check-agents-index: $index links to these documents, which do not exist:$broken" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "check-agents-index: $index and $rules_dir agree ($(printf '%s\n' "$present" | grep -c .) documents)."
fi
exit "$status"
