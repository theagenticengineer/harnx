#!/usr/bin/env bash
# check-no-forward-refs.sh — a spine file may gain a reference to a script or
# document only in the SAME commit that adds that script or document. Never
# before.
#
# THE DEFECT THIS EXISTS FOR, which is not hypothetical: it corrupted an earlier
# rebuild of this repository. That attempt's first commit declared all seven
# local pre-commit hooks before their scripts existed, had `mise.toml` call the
# review engine five commits before the engine existed, and indexed ten rule
# documents that landed across the four commits after it. Checking out any of
# those commits and running `pre-commit run --all-files` failed on a missing
# script.
#
# Nothing caught it, and the reason generalises: CI only ever checks the TIP.
# Every intermediate commit was broken and every one of them reported green,
# because no run ever existed for them. What it cost was bisectability,
# per-commit review, and any possibility of per-commit CI.
#
# WHAT COUNTS AS A SPINE FILE. Three, because these are the files that make a
# claim about something else existing:
#
#   .pre-commit-config.yaml   `entry: scripts/...` names a script the hook runs
#   mise.toml                 a task or hook body naming a repo script
#   AGENTS.md                 markdown links into .agents/rules/
#
# A `mise exec -- <tool>` entry is deliberately NOT a reference: the tool comes
# from mise.toml's [tools], not from this repository, and scripts/tests/
# hook-stages.bash already checks that every one of those is pinned.
#
# THE TREE IS READ THROUGH GIT, never from the working directory. The question
# is whether the reference resolves IN THAT COMMIT, and a file present on disk
# but not in the commit is exactly the case that must fail. Reading from disk
# would make the check pass for the wrong reason on every uncommitted file.
#
# Env / args:
#   $1  optional commit-ish. Given one, that commit is checked. Given none, the
#       INDEX is checked, which is the commit about to be made and is what the
#       pre-commit hook needs.
set -euo pipefail

# `<sha>:` or `:` — the prefix that makes `git show` and `git cat-file` read the
# same tree in both modes, so there is one code path rather than two.
if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
  ref="$1:"
  label="commit $(git rev-parse --short "$1")"
else
  ref=":"
  label="the staged tree"
fi

# Reads a spine file out of the tree under test. A spine file that does not
# exist there is not an error: a repository need not have all three.
spine() { git show "$ref$1" 2>/dev/null || true; }

refs_file="$(mktemp)"
trap 'rm -f "$refs_file"' EXIT
: >"$refs_file"

# .pre-commit-config.yaml: only `entry:` values that name a path in this repo.
spine .pre-commit-config.yaml |
  grep -oE '^ *entry: (scripts/[A-Za-z0-9._/-]+)' |
  awk '{print ".pre-commit-config.yaml\t" $NF}' >>"$refs_file" || true

# mise.toml: any repo script named by a task body or a hook. FULL-LINE COMMENTS
# ARE DROPPED FIRST. This file's comments name scripts constantly, to explain
# what a hook runs and why, and a comment is not a reference: nothing executes
# it, so a comment mentioning a script that no longer exists is stale prose
# rather than a broken commit. Scanning them would make this gate fail on the
# documentation that exists to explain it, which is the same reason AGENTS.md's
# links are taken from inside the parentheses rather than from any mention of a
# path.
#
# The strip is QUOTE-AWARE, not a full-line test. A trailing comment is just as
# much a comment as a whole-line one (`run = "..."  # see scripts/foo.sh`), and
# dropping only full lines left that case scanned. It cannot be a plain `sed
# s/#.*//` either: a `#` inside a quoted value is data, not a comment, so the
# scan walks each line tracking quote state and cuts at the first `#` outside
# quotes. Ten lines of awk, and the alternative is a gate that either misses a
# comment or eats a real reference.
spine mise.toml |
  awk '{
    out = ""
    inq = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (inq == "") {
        if (c == "#") break
        if (c == "\"" || c == "'"'"'") inq = c
      } else if (c == inq) {
        inq = ""
      }
      out = out c
    }
    print out
  }' |
  grep -oE 'scripts/[A-Za-z0-9._/-]+\.sh' |
  awk '{print "mise.toml\t" $0}' >>"$refs_file" || true

# AGENTS.md: markdown links into the rules directory. Taken from inside the
# parentheses, so prose naming a document is not a reference.
spine AGENTS.md |
  grep -oE '\]\(\.agents/rules/[A-Za-z0-9._-]+\.md\)' |
  sed -e 's/^](//' -e 's/)$//' |
  awk '{print "AGENTS.md\t" $0}' >>"$refs_file" || true

missing=""
while IFS="$(printf '\t')" read -r from path; do
  [ -n "$path" ] || continue
  git cat-file -e "$ref$path" 2>/dev/null || missing="$missing
  $from references $path, which does not exist in $label"
done <"$refs_file"

if [ -n "$missing" ]; then
  echo "::error::check-no-forward-refs: a spine file references something $label does not contain.$missing" >&2
  echo "       A spine file may gain a reference to a script or document only in the SAME commit that adds it." >&2
  echo "       Otherwise every commit in between is broken: checking one out and running the gates fails on a" >&2
  echo "       missing file, and no CI run exists for it to say so." >&2
  exit 1
fi

count="$(grep -c . "$refs_file" || true)"
echo "check-no-forward-refs: $count spine reference(s) all resolve in $label."
