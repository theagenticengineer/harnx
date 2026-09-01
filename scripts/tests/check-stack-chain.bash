#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/check-stack-chain.sh.
# Run: bash scripts/tests/check-stack-chain.bash
#
# THE CASE THAT MATTERS MOST IS A CHAIN DEEPER THAN ONE. An earlier draft of
# this gate asked "does this pull request's base equal `main`?", which is right
# for exactly one pull request in a stack, the bottom one, and wrong for every
# rung above it. A suite that only tested a one-link chain would pass against
# that draft, so the fixtures here are three links deep.
#
# `gh` is STUBBED, and `git ls-remote` with it. Every question this gate asks is
# a network read, and a suite depending on real ones would fail offline, fail
# without a token, and give different answers as this repository's own pull
# requests open and close.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
mkdir -p "$repo/scripts/git-discipline" "$work/bin"
git -C "$repo" init -q -b top
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
cp "$repo_root/scripts/git-discipline/check-stack-chain.sh" "$repo/scripts/git-discipline/"
cp "$repo_root/scripts/git-discipline/resolve-base.sh" "$repo/scripts/git-discipline/"
cp "$repo_root/scripts/git-discipline/stacking-policy.sh" "$repo/scripts/git-discipline/"
printf 'x\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the fixture base commit'

# CHAIN is a "branch:base" map, one per line. The stub answers from it, so a
# test case is a data change rather than a new stub.
cat >"$work/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
*"repo view"*)
  # GH_STUB_FAIL_REPO makes the DEFAULT-BRANCH lookup fail. That is a different
  # call from the pull request list, and it used to swallow its own failure with
  # `|| echo main`, so a walk could terminate at the wrong branch and still
  # report the chain intact.
  [ -z "${GH_STUB_FAIL_REPO:-}" ] || {
    echo "gh: could not connect" >&2
    exit 1
  }
  printf '%s\n' "${STOP_BRANCH:-main}"
  exit 0
  ;;
esac
head=""
prev=""
for a in "$@"; do
  [ "$prev" = "--head" ] && head="$a"
  prev="$a"
done
# GH_STUB_FAIL makes the call FAIL rather than return an empty list. Those are
# different answers and the gate must not confuse them: an unreadable branch is
# a pipeline failure, while a branch with no pull request is the normal state of
# a stack's bottom rung.
[ -z "${GH_STUB_FAIL:-}" ] || {
  echo "gh: could not connect" >&2
  exit 1
}
# A SUCCESSFUL call that also writes to stderr, which is ordinary CLI behaviour
# (update banners, auth warnings). Merging the streams put that text inside the
# JSON and broke the parse, turning a healthy chain into a false failure.
[ -z "${GH_STUB_NOISE:-}" ] || echo "gh: a new release of cli is available" >&2
printf '%s\n' "$CHAIN" | awk -F: -v h="$head" '
  BEGIN { printf "[" ; n = 0 }
  $1 == h { if (n++) printf ","; printf "{\"number\":%d,\"baseRefName\":\"%s\"}", n, $2 }
  END { print "]" }'
GH_STUB
chmod +x "$work/bin/gh"

# Every branch named in EXISTING_BRANCHES resolves on the "remote"; anything
# else does not, which is how the broken-link case is built.
cat >"$work/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "ls-remote" ]; then
  for a in "$@"; do :; done
  wanted="${!#}"
  printf '%s\n' "${EXISTING_BRANCHES:-}" | grep -qx "$wanted" || exit 2
  printf 'ref\trefs/heads/%s\n' "$wanted"
  exit 0
fi
exec /usr/bin/git "$@"
GIT_STUB
chmod +x "$work/bin/git"

out="$work/out"
run() {
  (cd "$repo" && env PATH="$work/bin:$PATH" "$@" \
    bash scripts/git-discipline/check-stack-chain.sh) >"$out" 2>&1
}

THREE_LINKS='c:b
b:a
a:main'
ALL_EXIST='main
a
b
c'

# --- A THREE-LINK CHAIN IS INTACT --------------------------------------------
# The case the earlier "base must equal main" draft got wrong.
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then ok; else
  fail_case "a three-link chain must pass: $(cat "$out")"
fi
if [ "$(grep -c ' -> ' "$out")" -eq 3 ]; then ok; else
  fail_case "every link must be reported, got $(grep -c ' -> ' "$out"): $(cat "$out")"
fi
if grep -q 'reached main' "$out"; then ok; else
  fail_case "the walk must say it reached the expected terminus: $(cat "$out")"
fi

# --- BROKEN: a link names a base that does not exist -------------------------
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES='main
a
c' STOP_BRANCH=main; then
  fail_case "a base branch missing from the remote must fail"
else ok; fi
if grep -q "does not exist on the remote" "$out"; then ok; else
  fail_case "the error must say the link is broken: $(cat "$out")"
fi

# --- AMBIGUOUS: a branch with two open pull requests -------------------------
# Checked BEFORE the base is read, because reading first would silently take
# whichever pull request the API listed first.
if run HEAD_BRANCH=c CHAIN='c:b
c:other
b:main' EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then
  fail_case "a branch with two open pull requests must fail as ambiguous"
else ok; fi
if grep -q 'ambiguous' "$out"; then ok; else
  fail_case "the error must say the base is ambiguous: $(cat "$out")"
fi

# --- MISMATCHED: the local declaration disagrees with GitHub -----------------
git -C "$repo" config branch.c.base something-else
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then
  fail_case "a local base disagreeing with the PR's base must fail"
else ok; fi
if grep -q 'declares base' "$out"; then ok; else
  fail_case "the error must name both claims: $(cat "$out")"
fi
# ...and agreement passes, or the case above would pass on a gate that always
# fails when a declaration exists.
git -C "$repo" config branch.c.base b
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then ok; else
  fail_case "a local base AGREEING with the PR's base must pass: $(cat "$out")"
fi
# A branch that declares NOTHING must not be treated as declaring the fallback.
# With `${BASE_FALLBACK:-main}` it was, and every undeclared branch looked like
# a mismatch; that is what this gate's first live run reported.
git -C "$repo" config --unset branch.c.base
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then ok; else
  fail_case "a branch declaring no base must not count as a mismatch: $(cat "$out")"
fi

# --- A CYCLE IS REPORTED, NOT FOLLOWED ---------------------------------------
# Two branches each declaring the other. A gate that hangs is worse than one
# that fails.
if run HEAD_BRANCH=c CHAIN='c:b
b:c' EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then
  fail_case "a cyclic chain must fail"
else ok; fi
if grep -q 'cycle' "$out"; then ok; else
  fail_case "the error must name it a cycle: $(cat "$out")"
fi

# --- THE WALK IS BOUNDED -----------------------------------------------------
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main MAX_DEPTH=1; then
  fail_case "a chain deeper than MAX_DEPTH must fail rather than keep walking"
else ok; fi
if grep -q 'deeper than' "$out"; then ok; else
  fail_case "the error must say the chain exceeded its ceiling: $(cat "$out")"
fi

# --- A BRANCH WITH NO OPEN PULL REQUEST ends the chain -----------------------
# The normal state of the stack's bottom rung, and not a failure.
if run HEAD_BRANCH=c CHAIN='c:b' EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then ok; else
  fail_case "a chain ending at a branch with no open PR must pass: $(cat "$out")"
fi
if grep -q 'no open pull request' "$out"; then ok; else
  fail_case "the walk must say why it stopped: $(cat "$out")"
fi

# --- A BASE NAME THAT GIT WOULD READ AS AN OPTION IS REFUSED -----------------
# The name arrives from the GitHub API, so it is not attacker-authored in the
# usual sense, but it IS a string handed to git as a positional argument, and
# git reads a leading dash as an option wherever it can. `stack.sh` guards its
# own two arguments the same way; a gate that walks branch names should not be
# the one place that does not.
for bad in '--upload-pack=evil' 'has a space' 'refs/../../etc'; do
  if run HEAD_BRANCH=c CHAIN="c:$bad" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main; then
    fail_case "a base named '$bad' must be refused"
  else ok; fi
done
if grep -q 'not a usable branch name' "$out"; then ok; else
  fail_case "the error must say why the name is unusable: $(cat "$out")"
fi

# --- DEPTH COUNTS ESTABLISHED LINKS, not iterations --------------------------
# A branch with no open pull request is not a link. Counting on entry overstated
# the chain by one there, and made MAX_DEPTH trip an iteration early.
run HEAD_BRANCH=c CHAIN='c:b' EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main || true
if grep -q 'ends here after 1 link' "$out"; then ok; else
  fail_case "a one-link chain ending at an unopened branch must report 1 link: $(cat "$out")"
fi
# A chain of exactly MAX_DEPTH links must PASS; only one deeper may fail.
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main MAX_DEPTH=3; then ok; else
  fail_case "a chain of exactly MAX_DEPTH links must pass: $(cat "$out")"
fi

# --- AN UNREADABLE BRANCH IS A FAILURE, NOT "no pull request" ----------------
# THE MOST DANGEROUS CASE IN THIS SUITE. An auth failure, a network failure and
# a rate limit all made `gh pr list` fail, and swallowing that as zero ended the
# walk and reported the chain intact. A gate that reports success because it
# could not read anything is the exact failure this floor exists to prevent.
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main GH_STUB_FAIL=1; then
  fail_case "an unreadable branch must FAIL, not be treated as having no pull request"
else ok; fi
if grep -q 'not an answer' "$out"; then ok; else
  fail_case "the error must distinguish a pipeline failure from an answer: $(cat "$out")"
fi
if grep -q 'chain is intact' "$out"; then
  fail_case "a run that could not read the chain must never claim it is intact"
else ok; fi

# --- A BROKEN LINK MUST NOT PRINT "the chain is intact" ----------------------
# The exit code was always right; the message contradicted it, which is worse
# than useless in a log somebody skims.
# The BROKEN-link fixture, not the invalid-name one. An invalid name breaks out
# of the walk immediately, so it never reaches the success line and would pass
# whether or not the line is guarded. A broken link records the failure and
# KEEPS WALKING to the terminus, which is the only path that can reach the
# message while `status` is already non-zero.
run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES='main
a
c' STOP_BRANCH=main || true
if grep -q 'chain is intact' "$out"; then
  fail_case "a run that recorded a broken link must not also claim the chain is intact: $(cat "$out")"
else ok; fi

# --- STDERR NOISE ON A SUCCESSFUL CALL MUST NOT CORRUPT THE PARSE ------------
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main GH_STUB_NOISE=1; then ok; else
  fail_case "a CLI notice on stderr must not break a healthy chain: $(cat "$out")"
fi
if grep -q 'not valid JSON' "$out"; then
  fail_case "stderr noise must not be parsed as part of the payload: $(cat "$out")"
else ok; fi

# --- AN UNREADABLE DEFAULT BRANCH IS A FAILURE, NOT "main" -------------------
# The same fail-open as the pull request list, in the other call. Assuming
# `main` is specifically wrong during an epic that promotes a trust anchor: the
# walk would stop at a branch that is not the top of the stack, or never reach
# one and be cut off by MAX_DEPTH, and either way could report the chain intact
# having verified something else.
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" GH_STUB_FAIL_REPO=1; then
  fail_case "an unreadable default branch must FAIL, not silently become 'main'"
else ok; fi
if grep -q "Refusing to assume" "$out"; then ok; else
  fail_case "the error must say it refuses to assume a terminus: $(cat "$out")"
fi
# STOP_AT stays an explicit override, so a caller that names the terminus needs
# no lookup and is unaffected by the lookup failing.
if run HEAD_BRANCH=c CHAIN="$THREE_LINKS" EXISTING_BRANCHES="$ALL_EXIST" STOP_BRANCH=main STOP_AT=main GH_STUB_FAIL_REPO=1; then ok; else
  fail_case "an explicit STOP_AT must not need the default-branch lookup: $(cat "$out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
