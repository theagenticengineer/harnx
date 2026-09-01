#!/usr/bin/env bash
# Standalone test for scripts/mise/ai-review-local.sh's preconditions.
# Run: bash scripts/tests/ai-review-local.bash
#
# WHY ONLY THE PRECONDITIONS. Everything past them calls a review model, so it
# is not testable here. The preconditions are worth pinning on their own,
# because one of them is a hazard rather than a convenience.
#
# RUNS AGAINST A THROWAWAY REPOSITORY, not against this one. While a missing
# token aborted the script, running it here was harmless because it never got
# past the check. It no longer aborts, so the same suite would start a REAL
# review of this repository's own working tree on every `mise run test`, append
# to the real pass log, and crash. A test must not have side effects on the
# tree it is testing.
#
# THE HAZARD. This script used to read CLAUDE_CODE_OAUTH_TOKEN and tell the
# operator to export it. That is the variable the Claude Code CLI ITSELF
# authenticates with, so an export in a shell profile silently replaces the
# operator's saved login for every Claude Code session started from that shell.
# It is a review-tooling instruction that changes something else entirely, and
# harnx reproduces this floor into every repository it generates.
#
# The rename to AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN is therefore only half the
# fix. The other half is that there is NO fallback to the old name: a fallback
# would keep the hazard alive under a new spelling. That absence is a property,
# so it is asserted here rather than left to be re-added by someone being
# helpful.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

out="$(mktemp)"
prompt="$(mktemp)"

# A fingerprint of THIS repository's review state, taken before anything runs.
# `ls -l` rather than a checksum: it covers appends, truncations and new files,
# and needs no tool beyond coreutils. Missing files are a legitimate state and
# render as nothing, which compares equal to itself.
# `--git-path` RETURNS A RELATIVE PATH IN AN ORDINARY CLONE, and absolute only
# in a linked worktree. Measured both ways: from a plain `git init` repository it
# answers `.git/ai-review-reviewed-tree`, while from this branch's worktree it
# answers a full path under `.git/worktrees/`. `-C` changes git's directory, not
# the shell's, so the relative answer resolves against whatever cwd the suite was
# invoked from.
#
# Unprefixed, that made this check pass VACUOUSLY off the repository root: both
# snapshots resolve the same wrong path, `ls -l` finds nothing twice, and nothing
# compares equal to nothing. This branch develops in a worktree, so the bug was
# invisible here and would have shipped to every generated repository, which are
# ordinary clones. That is the placebo this check's own comment warns about,
# reintroduced one line below it.
own_harnx_state() {
  local state_path
  state_path="$(git -C "$repo_root" rev-parse --git-path ai-review-reviewed-tree)"
  case "$state_path" in
  /*) ;;
  *) state_path="$repo_root/$state_path" ;;
  esac
  ls -l "$repo_root/.harnx/ai-review-pass-log.jsonl" \
    "$repo_root/.harnx/ai-review-dismissed.json" \
    "$state_path" 2>/dev/null || true
}
own_harnx_before="$(own_harnx_state)"

# -u on BOTH names, always: the developer running this suite locally is very
# likely to have one of them exported, and inheriting it would make these cases
# pass or fail for reasons that have nothing to do with the script.
# A throwaway repository with a stubbed `claude`, so no token, no network and no
# model are involved, and nothing here touches the tree under test.
fixture="$(mktemp -d)"
trap 'rm -f "$out" "$prompt"; rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/scripts/ai-review" "$fixture/scripts/mise" "$fixture/.harnx"
# The stub RECORDS THE PROMPT. Asserting on the runner's own output cannot see
# what was actually sent for review: the output carries findings, and a stub
# that returns none prints nothing about the diff either way. An earlier version
# of the merge-base case asserted on the output and passed whether the diff was
# two-dot or three-dot.
cat >"$fixture/bin/claude" <<'CLAUDE_STUB'
#!/usr/bin/env bash
# `--version` IS ANSWERED BEFORE STDIN IS READ, and the order is the whole
# point. The engine probes the CLI's version to record the regime a result was
# produced under, and this stub's next act is `cat`, which blocks forever
# waiting for an EOF that a version probe never sends. That hung this suite,
# and it presented as an intermittent stall rather than a failure, because
# backgrounding the test changed whether stdin happened to be closed already.
case "${1:-}" in
--version)
  printf '9.9.9 (Claude Code Test Stub)\n'
  exit 0
  ;;
esac
cat >"$CLAUDE_STUB_PROMPT"
printf '{"result":"[]","is_error":false}'
CLAUDE_STUB
chmod +x "$fixture/bin/claude"

# `gh` IS STUBBED, AND ITS ABSENCE WAS A REAL DEFECT RATHER THAN AN OVERSIGHT.
# The runner records an acceptance, record-pass.sh asks ci-head-shas.sh for the
# branch's CI count, and that shells out to `gh run list`. With no stub the
# suite made a LIVE NETWORK CALL: its runtime depended on GitHub's latency and
# its result on whether the machine held credentials. Observed as an
# intermittent stall that pushed the whole suite past ten minutes on one run
# and finished in forty-five seconds on the next, which is the worst kind of
# flake because it looks like a hang rather than a failure.
#
# Every other suite added alongside this one already builds a PATH with no gh
# or a scripted one; this is the one that was missed.
#
# It answers, rather than failing, so the acceptance row's CI count is exercised
# instead of falling back to null for want of a binary.
cat >"$fixture/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf 'sha-one\nsha-two\nsha-two\n'
GH_STUB
chmod +x "$fixture/bin/gh"
cp "$repo_root/scripts/ai-review/review-engine.sh" "$fixture/scripts/ai-review/"
# THE SCRIPTS THE RUNNER DRIVES ARE COPIED IN, not just the engine. The runner
# calls record-pass.sh on every path out of a review, and that asks
# ci-head-shas.sh for the branch's CI count when it records an acceptance.
# Without them the calls failed, the `|| true` swallowed it, and the wiring this
# suite exists to cover was never executed while every assertion still passed.
# The same fixture-drift that made the loop-init suite green for the wrong
# reason.
cp "$repo_root/scripts/ai-review/record-pass.sh" "$fixture/scripts/ai-review/"
cp "$repo_root/scripts/ai-review/ci-head-shas.sh" "$fixture/scripts/ai-review/"
# The script under test is COPIED into the fixture and run from there, so the
# path below is the only reference to it; there is deliberately no `$script`
# variable pointing at the original, because running the original would run it
# against this repository.
cp "$repo_root/scripts/mise/ai-review-local.sh" "$fixture/scripts/mise/"
git -C "$fixture" init -q
git -C "$fixture" config user.email t@acme.dev
git -C "$fixture" config user.name Tester
printf 'base\n' >"$fixture/a.txt"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'feat(#1): the fixture base commit'
git -C "$fixture" tag base-point
printf 'changed\n' >>"$fixture/a.txt"

# -u on BOTH names, always: the developer running this suite locally is very
# likely to have one of them exported, and inheriting it would make these cases
# pass or fail for reasons that have nothing to do with the script.
run() {
  : >"$prompt"
  (cd "$fixture" && env -u CLAUDE_CODE_OAUTH_TOKEN \
    -u AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN \
    PATH="$fixture/bin:$PATH" BASE=base-point \
    CLAUDE_STUB_PROMPT="$prompt" \
    "$@" bash scripts/mise/ai-review-local.sh)
}

# --- NO TOKEN IS NOT AN ERROR --------------------------------------------------
# The `claude` CLI authenticates from ~/.claude on a developer machine, and an
# empty value is what makes it fall back to that login. Requiring a token here
# added a setup step for every contributor and every generated repository, for a
# credential they already had. CI still needs the environment-scoped secret,
# because a runner has no ~/.claude, which is why this is a difference between
# the two runners rather than a relaxation of both.
run >"$out" 2>&1 || true
if grep -q 'using the claude CLI' "$out"; then
  pass=$((pass + 1))
else
  fail_case "a run with no token must say it is falling back to the CLI login: $(cat "$out")"
fi
if grep -q 'is not set; run' "$out"; then
  fail_case "a missing token must no longer be reported as an error: $(cat "$out")"
else
  pass=$((pass + 1))
fi

# --- the old name is not a fallback -------------------------------------------
# This is the assertion that keeps the fix from being quietly undone. If the old
# name ever becomes the script's token again, the hazardous export works again,
# and nothing else would notice.
#
# The SHAPE of the assertion changed when a missing token stopped being fatal.
# It used to be "the run fails", which no longer distinguishes anything: the run
# now succeeds either way. What must still be true is that the script does not
# ADOPT the old name's value, so it must announce the CLI-login fallback rather
# than report a token of its own.
run CLAUDE_CODE_OAUTH_TOKEN=stale-token >"$out" 2>&1 || true
if grep -q 'using the claude CLI' "$out"; then
  pass=$((pass + 1))
else
  fail_case "the old variable name must not be adopted as this script's token: $(cat "$out")"
fi

# --- the old name being present is warned about, not ignored ------------------
# An operator who exported it once will otherwise never learn why their Claude
# Code sessions changed behaviour.
if grep -q 'WARNING: CLAUDE_CODE_OAUTH_TOKEN is set' "$out"; then
  pass=$((pass + 1))
else
  fail_case "an inherited CLAUDE_CODE_OAUTH_TOKEN must be warned about: $(cat "$out")"
fi
if grep -q 'overrides your saved login' "$out"; then
  pass=$((pass + 1))
else
  fail_case "the warning must say what the stray variable actually does"
fi
# Quiet when there is nothing to warn about: a warning that fires on every run
# is a warning nobody reads.
run >"$out" 2>&1 || true
if grep -q 'WARNING: CLAUDE_CODE_OAUTH_TOKEN is set' "$out"; then
  fail_case "the warning must not fire when the old variable is absent"
else
  pass=$((pass + 1))
fi

# --- the run happens in the FIXTURE, never in this repository -----------------
# The assertion that keeps this suite from acquiring side effects again. If the
# fixture were ever bypassed, the script would review this repository's own
# working tree and append to its real pass log.
if [ -f "$fixture/.harnx/ai-review-pass-log.jsonl" ]; then
  pass=$((pass + 1))
else
  fail_case "the run must have written its pass log inside the fixture"
fi
# THE REAL REPOSITORY'S STATE IS COMPARED, before against after. The first
# version of this checked for a marker file that nothing ever created, so it
# passed whether or not the suite had side effects: a placebo in the exact place
# a placebo is most expensive, since the failure it was meant to catch is the
# suite silently reviewing this repository on every `mise run test`.
if [ "$(own_harnx_state)" = "$own_harnx_before" ]; then
  pass=$((pass + 1))
else
  fail_case "the suite modified this repository's own .harnx state; it must run entirely inside the fixture"
fi

# --- THE DIFF IS THREE-DOT, FROM THE MERGE BASE -------------------------------
# CI diffs `BASE_REF...HEAD`. Two-dot compares the base's CURRENT TIP against
# this tree, so every commit that landed on the base after this branch left it
# shows up locally and not in CI. A clean local pass would then be a claim about
# a superset of what CI reviews, and the pre-push gate records that superset's
# tree as reviewed.
#
# The fixture advances the base AFTER the branch point, which is the only
# situation in which the two forms differ at all.
git -C "$fixture" checkout -q -b work base-point
printf 'work change\n' >>"$fixture/a.txt"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'feat(#1): a change on the working branch'
git -C "$fixture" checkout -q base-point
git -C "$fixture" checkout -q -B moved base-point
printf 'unrelated base change\n' >"$fixture/base-only.txt"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'feat(#1): a change only on the base'
git -C "$fixture" checkout -q work

run BASE=moved >"$out" 2>&1 || true
# The file that exists only on the advanced base must NOT appear in what was
# SENT FOR REVIEW. Asserted against the recorded prompt, not the runner's
# output: the output shows findings, and a stub returning none says nothing
# about the diff either way.
if grep -q 'base-only.txt' "$prompt"; then
  fail_case "a two-dot diff sent the base's own later commit for review"
else
  pass=$((pass + 1))
fi
# The branch's own change MUST be there, or the case above passes because
# nothing was reviewed at all.
if grep -q 'work change' "$prompt"; then
  pass=$((pass + 1))
else
  fail_case "the branch's own change must be in the reviewed diff. OUT: $(cat "$out")"
fi
# ...and the runner says so, because a silently different base is worse than a
# loud one.
if grep -q 'diffing from the merge base' "$out"; then
  pass=$((pass + 1))
else
  fail_case "the runner must say when it diffs from the merge base rather than the tip: $(cat "$out")"
fi
git -C "$fixture" checkout -q work

# --- A MALFORMED LEDGER ENTRY IS DROPPED, NOT FATAL ---------------------------
# The filter calls `ascii_downcase` on `.title`, which is a hard error under
# `set -e` for an entry whose title is missing or is not a string. That killed
# the run before the convergence table printed, which is exactly what the
# array-shape check one level up exists to prevent. The ledger is hand-edited by
# design, so a malformed entry is ordinary rather than exotic.
mkdir -p "$fixture/.harnx"
printf '[{"file":"a.txt","title":"a real one","reason":"r"},{"file":"a.txt"},{"title":"no file"},"not an object"]\n' \
  >"$fixture/.harnx/ai-review-dismissed.json"
run >"$out" 2>&1 || true
if grep -q 'ignored 3 malformed' "$out"; then
  pass=$((pass + 1))
else
  fail_case "malformed ledger entries must be counted and reported: $(cat "$out")"
fi
# The run must still COMPLETE. Reaching the table is the whole point: a crash
# here loses the findings the pass did produce.
if grep -q 'local ai-review vs' "$out"; then
  pass=$((pass + 1))
else
  fail_case "a malformed ledger entry must not stop the run before its table: $(cat "$out")"
fi
# The well-formed entry beside them is still honoured, so the drop is surgical
# rather than a fallback to an empty ledger.
if grep -q 'ignoring it for this run' "$out"; then
  fail_case "a malformed ENTRY must not discard the whole ledger: $(cat "$out")"
else
  pass=$((pass + 1))
fi
rm -f "$fixture/.harnx/ai-review-dismissed.json"

# --- AI_REVIEW_FILE NARROWS THE PASS, AND CANNOT SATISFY THE PUSH GATE --------
# The narrowing exists for the case a whole-diff pass keeps returning findings
# that do not shrink: one file at a time is small enough to converge and small
# enough to read.
#
# The second half is what makes it safe to offer at all. The gate records "this
# tree was reviewed". A pass that saw one file has not reviewed the tree, so
# writing that record from a narrowed pass is the same failure as writing it
# from a refused one: unreviewed code, marked reviewed.
git -C "$fixture" checkout -q work
printf 'second file\n' >"$fixture/second.txt"
statefile="$(cd "$fixture" && git rev-parse --git-path ai-review-reviewed-tree)"
rm -f "$fixture/$statefile"

run AI_REVIEW_FILE=a.txt >"$out" 2>&1 || true
# Only the named file reaches the review.
if grep -q 'a.txt' "$prompt" && ! grep -q 'second.txt' "$prompt"; then
  pass=$((pass + 1))
else
  fail_case "AI_REVIEW_FILE must narrow the diff to that path: $(head -c 300 "$prompt")"
fi
# THE ASSERTION THAT MATTERS.
if [ ! -s "$fixture/$statefile" ]; then
  pass=$((pass + 1))
else
  fail_case "a narrowed pass must NOT record the tree as reviewed"
fi
# ...and it says so, both before and after, because a silent narrowing is how
# somebody concludes the tree is clean when one file is.
if grep -q 'CANNOT satisfy the push gate' "$out"; then
  pass=$((pass + 1))
else
  fail_case "a narrowed pass must announce that it cannot satisfy the gate: $(cat "$out")"
fi
if grep -q 'push gate is UNCHANGED' "$out"; then
  pass=$((pass + 1))
else
  fail_case "a clean narrowed pass must say the gate is unchanged: $(cat "$out")"
fi

# The same run WITHOUT the narrowing does record it, or the case above passes on
# a script that never records anything.
run >"$out" 2>&1 || true
if [ -s "$fixture/$statefile" ]; then
  pass=$((pass + 1))
else
  fail_case "a full clean pass must still record the reviewed tree: $(cat "$out")"
fi

# --- THE HARNESS RECORD IS ACTUALLY WRITTEN ----------------------------------
# The runner calls record-pass.sh on every path out of a review. Until the
# fixture carried that script the call failed, `|| true` swallowed it, and this
# wiring was never executed while every assertion above still passed. These
# assert the two rows a clean pass must leave behind, which is what the round
# cap later counts.
log="$fixture/.harnx/loop/passes.jsonl"
if [ -s "$log" ] && [ "$(jq -s '[.[] | select(.type == "pass")] | length' "$log")" -ge 1 ]; then
  pass=$((pass + 1))
else
  fail_case "a review must leave a pass row in $log: $(cat "$log" 2>/dev/null)"
fi
# A clean full pass is an acceptance, and the acceptance row is what resets the
# round cap. It carries the CI count, which is why the fixture stubs gh.
if [ "$(jq -s '[.[] | select(.type == "acceptance")] | length' "$log")" -ge 1 ] &&
  [ "$(jq -s -r '[.[] | select(.type == "acceptance")] | last | .ci_head_shas' "$log")" = "2" ]; then
  pass=$((pass + 1))
else
  fail_case "a clean full pass must record an acceptance carrying the CI count: $(cat "$log" 2>/dev/null)"
fi
# The regime travels from the engine's sidecar onto the row. A row without it
# cannot be compared with any other row, which is the whole reason the second
# log exists.
if [ "$(jq -s -r '[.[] | select(.type == "pass")] | last | .cli_version' "$log")" = "9.9.9 (Claude Code Test Stub)" ]; then
  pass=$((pass + 1))
else
  fail_case "the pass row must carry the regime from the sidecar: $(jq -s -c '[.[] | select(.type == "pass")] | last' "$log" 2>/dev/null)"
fi

rm -f "$fixture/second.txt" "$fixture/$statefile"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
