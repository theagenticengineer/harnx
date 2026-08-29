#!/usr/bin/env bash
# Standalone test for scripts/ai-review/extract-diff.sh.
# Run: bash scripts/tests/extract-diff.bash
#
# WHAT THIS PROTECTS. This script IS the review input. Before it existed the
# diff was produced by a `pull_request`-triggered workflow, which the pull
# request author controls, so replacing one line of that workflow with
# `echo "benign" >diff.txt` gave a pull request whose review was of the word
# "benign": the artifact name was unchanged so the download succeeded,
# `require-diff.sh` saw a present and non-empty file, and the nonce protects
# the fence rather than the content. The engine reported nothing, no thread was
# posted, and `ai-review-resolved`, a REQUIRED context, went green over a pull
# request nothing had read.
#
# So the properties pinned here are the ones that make the input trustworthy:
# it comes from GitHub's refs, it is the diff of the commit this run is a
# verdict about, and it is three-dot so a commit landing on the base branch
# does not appear as the author's work.
#
# Hermetic: a REAL local git repository is built and served as `origin`, so the
# fetch, the ref names and the three-dot semantics are exercised rather than
# stubbed. Nothing is faked except the network distance.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/extract-diff.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
diff_file="$work/diff.txt"
log="$work/log.txt"

# Identity is set per-repository so this never depends on, or touches, the
# operator's global git config.
git_init() {
  git -C "$1" init --quiet --initial-branch=trunk
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "Test"
  git -C "$1" config commit.gpgsign false
}

# THE UPSTREAM. `base` is the pull request's target branch; the pull request's
# commits live under refs/pull/7/head, exactly as GitHub publishes them in the
# base repository, for fork pull requests included.
upstream="$work/upstream"
mkdir -p "$upstream"
git_init "$upstream"
printf 'base line\n' >"$upstream/shared.txt"
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m "base"
fork_point="$(git -C "$upstream" rev-parse HEAD)"

# The pull request's two commits.
git -C "$upstream" checkout --quiet -b pr-branch
printf 'base line\nthe change under review\n' >"$upstream/shared.txt"
printf 'a new file\n' >"$upstream/added.txt"
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m "the change"
head_sha="$(git -C "$upstream" rev-parse HEAD)"
git -C "$upstream" update-ref refs/pull/7/head "$head_sha"

# A commit that lands on the BASE branch after the pull request was cut. It
# must not appear in the review: the author did not write it, and reporting it
# as theirs is how a reviewer's findings end up on somebody else's code.
git -C "$upstream" checkout --quiet trunk
printf 'unrelated work\n' >"$upstream/unrelated.txt"
git -C "$upstream" add -A
git -C "$upstream" commit --quiet -m "someone else's commit"

# THE TRUNK CHECKOUT. This is what the credentialed job has: the default
# branch's tree, with `origin` pointing at the upstream. It has never seen the
# pull request's commits.
clone="$work/clone"
git clone --quiet "$upstream" "$clone"
git -C "$clone" config user.email "test@example.invalid"
git -C "$clone" config user.name "Test"

run() {
  rm -f "$diff_file"
  (cd "$clone" && env \
    OWNER=o REPO_NAME=r PR_NUMBER=7 BASE_REF=trunk HEAD_SHA="$head_sha" \
    DIFF_FILE="$diff_file" "$@" bash "$script") >"$log" 2>&1
}

# --- the happy path ----------------------------------------------------------
run || fail_case "a normal extraction must exit 0: $(cat "$log")"

if [ -s "$diff_file" ]; then ok; else
  fail_case "the extraction must produce a non-empty diff"
fi
if grep -q 'the change under review' "$diff_file" &&
  grep -q 'added.txt' "$diff_file"; then ok; else
  fail_case "the pull request's own changes must be in the diff: $(cat "$diff_file")"
fi

# THREE-DOT. The base branch advanced after the pull request was cut; that
# commit is not the author's and must not be reviewed as though it were.
if ! grep -q 'unrelated' "$diff_file"; then ok; else
  fail_case "a commit that landed on the base branch must not appear in the review"
fi

# --- the input is GitHub's, not the pull request's ---------------------------
# The trunk checkout never had the pull request's commits; they arrive by
# fetching refs/pull/<n>/head from the server. This is the whole point: there
# is no artifact, so there is nothing a pull request can write into the review
# input except the commits it actually pushed.
if git -C "$clone" rev-parse --verify --quiet refs/ai-review/head >/dev/null; then ok; else
  fail_case "the pull request's head must be fetched into refs/ai-review/head"
fi
if [ "$(git -C "$clone" rev-parse refs/ai-review/head)" = "$head_sha" ]; then ok; else
  fail_case "refs/ai-review/head must be the reviewed commit"
fi

# --- the head is ASSERTED against the commit this run is a verdict about -----
# refs/pull/<n>/head tracks the CURRENT tip. If the author pushed again while
# this run was starting, reviewing the newer commit while post-check-run.sh
# publishes the gate against the older one is a verdict about code nobody read.
if run HEAD_SHA=0000000000000000000000000000000000000000; then
  fail_case "a head that is not the reviewed commit must fail closed"
else ok; fi
if grep -q 'Refusing to review one commit and report against another' "$log"; then ok; else
  fail_case "the mismatch must say what it refused and why: $(cat "$log")"
fi
if [ ! -s "$diff_file" ]; then ok; else
  fail_case "a refused extraction must not leave a diff behind for require-diff.sh to accept"
fi

# --- an empty range produces an empty file, not a crash ----------------------
# require-diff.sh, not this script, is what turns an empty diff into a red
# gate. This one must simply report the truth.
git -C "$upstream" update-ref refs/pull/8/head "$fork_point"
if run PR_NUMBER=8 HEAD_SHA="$fork_point" && [ ! -s "$diff_file" ]; then ok; else
  fail_case "a pull request whose changes are already in its base must yield an empty diff"
fi

# --- the two values that reach `git fetch` are validated ---------------------
# PR_NUMBER is spliced into a ref path and BASE_REF into a refspec, and both
# cross from an API payload rather than being computed here.
#
# THE INJECTION PAYLOAD IS A CANARY, NOT A DESTRUCTIVE COMMAND. An earlier
# version of this suite used `rm -rf /`. The reasoning was that the assertion
# refuses the value, so the command never runs, but that reasoning is backwards:
# the payload only executes in the exact case this test exists to catch, so the
# consequence of the regression it hunts was to wipe the machine running the
# suite. This file tells a developer to run it locally, which makes that
# machine theirs. A test may not depend on the correctness of the code under
# test for its own safety.
#
# `touch <canary>` is equally metacharacter-rich, and it is strictly stronger:
# refusal is asserted, and the canary's absence then proves nothing executed,
# where a destructive payload proves that only by the machine surviving.
canary="$work/canary-must-not-exist"
for bad in "7; touch $canary" '../../refs/heads/trunk' '' 'seven'; do
  if run PR_NUMBER="$bad"; then
    fail_case "PR_NUMBER '$bad' must be refused"
  else ok; fi
done
for bad in '--upload-pack=evil' 'trunk;evil' 'refs/../../etc' ''; do
  if run BASE_REF="$bad"; then
    fail_case "BASE_REF '$bad' must be refused"
  else ok; fi
done
if [ ! -e "$canary" ]; then ok; else
  fail_case "a rejected PR_NUMBER reached a shell: the canary at $canary was created"
fi
# A legitimate branch name with the characters GitHub allows must still work.
git -C "$upstream" branch feat/some-branch.v2 trunk
if run BASE_REF=feat/some-branch.v2; then ok; else
  fail_case "an ordinary branch name must be accepted: $(cat "$log")"
fi

# --- required inputs ----------------------------------------------------------
for missing in OWNER REPO_NAME PR_NUMBER BASE_REF HEAD_SHA DIFF_FILE; do
  if run "$missing="; then
    fail_case "$missing must be required"
  else ok; fi
done

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
