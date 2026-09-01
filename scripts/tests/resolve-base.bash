#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/resolve-base.sh.
# Run: bash scripts/tests/resolve-base.bash
#
# THE ORDER IS THE CONTRACT, so every tier is asserted both when it answers and
# when a higher one overrides it. A resolver that returns a plausible base for
# the wrong reason is worse than one that fails: three gates consume this, and
# they would disagree with each other while each looked correct.
#
# `gh` is STUBBED rather than called. Tier 2 is a network read, and a suite that
# depended on it would fail offline, fail without a token, and pass or fail
# differently depending on whether this branch happens to have an open pull
# request today.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/git-discipline/resolve-base.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

stub_dir="$work/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/gh" <<'GH_STUB'
#!/usr/bin/env bash
# GH_STUB_BASE, when set, is the base the "open pull request" reports. Unset
# means no pull request, which is the ordinary case for a fresh branch and must
# fall through rather than error.
[ -n "${GH_STUB_BASE:-}" ] || exit 1
printf '%s\n' "$GH_STUB_BASE"
GH_STUB
chmod +x "$stub_dir/gh"

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b feat-1-a-branch
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'x\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the fixture base commit'

out="$work/out"
err="$work/err"
run() { (cd "$repo" && env PATH="$stub_dir:$PATH" "$@" bash "$script") >"$out" 2>"$err"; }

# --- tier 3: no declaration, no pull request ---------------------------------
if run && [ "$(cat "$out")" = "main" ]; then ok; else
  fail_case "with nothing declared and no PR, the fallback must be main, got '$(cat "$out")'"
fi
if grep -q 'fallback' "$err"; then ok; else
  fail_case "the resolver must say WHICH tier answered: $(cat "$err")"
fi
# The fallback is overridable, so this suite does not depend on what any
# particular repository's default branch is called.
if run BASE_FALLBACK=trunk && [ "$(cat "$out")" = "trunk" ]; then ok; else
  fail_case "BASE_FALLBACK must override tier 3, got '$(cat "$out")'"
fi

# AN EMPTY BASE_FALLBACK DISABLES TIER 3, rather than being substituted away.
# `${BASE_FALLBACK:-main}` would treat empty as unset and answer `main`, which
# is not a harmless difference: check-stack-chain.sh asks this question to find
# out whether a base was DECLARED, and a fallback answer makes every branch that
# declares nothing look like it disagrees with its pull request. That is exactly
# what happened on the gate's first live run.
if run BASE_FALLBACK= && [ -z "$(cat "$out")" ]; then ok; else
  fail_case "an empty BASE_FALLBACK must disable tier 3, got '$(cat "$out")'"
fi

# --- tier 2: an open pull request answers ------------------------------------
if run GH_STUB_BASE=feat-2-below && [ "$(cat "$out")" = "feat-2-below" ]; then ok; else
  fail_case "an open PR's base must win over the fallback, got '$(cat "$out")'"
fi
if grep -q 'open pull request' "$err"; then ok; else
  fail_case "tier 2 must name itself: $(cat "$err")"
fi

# --- tier 1: an explicit declaration beats both ------------------------------
git -C "$repo" config branch.feat-1-a-branch.base declared-parent
if run GH_STUB_BASE=feat-2-below && [ "$(cat "$out")" = "declared-parent" ]; then ok; else
  fail_case "a declared base must beat the PR's base, got '$(cat "$out")'"
fi
if grep -q 'declared in branch' "$err"; then ok; else
  fail_case "tier 1 must name itself: $(cat "$err")"
fi
git -C "$repo" config --unset branch.feat-1-a-branch.base

# --- BASE_NO_NETWORK skips tier 2 entirely -----------------------------------
# A pre-push hook cannot afford a network call on every push, and must not fail
# when offline. Asserted by leaving the stub ANSWERING and requiring the
# resolver to ignore it.
if run BASE_NO_NETWORK=1 GH_STUB_BASE=feat-2-below && [ "$(cat "$out")" = "main" ]; then ok; else
  fail_case "BASE_NO_NETWORK must skip tier 2 even when it would answer, got '$(cat "$out")'"
fi
# ...but tier 1 still applies, because that one costs nothing.
git -C "$repo" config branch.feat-1-a-branch.base declared-parent
if run BASE_NO_NETWORK=1 GH_STUB_BASE=feat-2-below && [ "$(cat "$out")" = "declared-parent" ]; then ok; else
  fail_case "BASE_NO_NETWORK must not disable tier 1, got '$(cat "$out")'"
fi
git -C "$repo" config --unset branch.feat-1-a-branch.base

# --- A FAILING `gh` IS NOT AN ERROR ------------------------------------------
# No pull request, no token, no network and a rate limit all land in the same
# place, and none of them means "resolution failed". A hard failure here would
# make every gate that calls this fail offline, which is how a gate gets
# disabled.
cat >"$stub_dir/gh" <<'GH_FAIL'
#!/usr/bin/env bash
echo "gh: could not connect" >&2
exit 1
GH_FAIL
chmod +x "$stub_dir/gh"
if run && [ "$(cat "$out")" = "main" ]; then ok; else
  fail_case "a failing gh must fall through to the fallback, not fail: $(cat "$err")"
fi

# --- THE UPSTREAM-TRACKING REF IS NOT A TIER ---------------------------------
# `git stack` sets one with `git worktree add --track`, which makes it look like
# a fourth answer. It is not: tracking says where push and pull go, a
# contributor can repoint it in one command for unrelated reasons, and it is set
# by tooling rather than declared. Tier 1 exists so an explicit declaration has
# a home that tracking cannot silently overwrite.
git -C "$repo" branch -q an-upstream
git -C "$repo" config branch.feat-1-a-branch.remote .
git -C "$repo" config branch.feat-1-a-branch.merge refs/heads/an-upstream
if run && [ "$(cat "$out")" = "main" ]; then ok; else
  fail_case "an upstream-tracking ref must NOT be treated as the base, got '$(cat "$out")'"
fi

# --- A DETACHED HEAD is a hard error -----------------------------------------
# Every tier is keyed on a branch name, so there is no answer to give, and
# guessing one would be worse than saying so.
git -C "$repo" checkout -q --detach
if run; then
  fail_case "a detached HEAD must fail rather than resolve to something"
else ok; fi
if grep -q 'detached' "$err"; then ok; else
  fail_case "the error must say the head is detached: $(cat "$err")"
fi

# --- A BRANCH NAME GIT OR GH WOULD READ AS AN OPTION IS REFUSED --------------
# `BRANCH` is a documented override, and check-stack-chain.sh also passes it a
# name read from the API while walking a chain, so it reaches this script from
# outside. It is interpolated into a `git config` key and handed to `gh` as a
# positional argument. Both consumers guard the base name they produce; this
# guards the name they start from, which is what stops the resolver being the
# hole underneath them.
for bad in '--upload-pack=evil' 'has a space' 'refs/../../etc' 'a~1' 'a^' 'a:b'; do
  if run BRANCH="$bad"; then
    fail_case "a branch named '$bad' must be refused"
  else ok; fi
done
if grep -q 'not a usable branch name' "$err"; then ok; else
  fail_case "the error must say why the name is unusable: $(cat "$err")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
