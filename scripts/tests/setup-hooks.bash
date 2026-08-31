#!/usr/bin/env bash
# Standalone test for scripts/mise/setup-hooks.sh.
# Run: bash scripts/tests/setup-hooks.bash
#
# WHAT THIS PROTECTS. This script is why the anchor's gates are installed at
# all: mise.toml's `[hooks] postinstall` runs it, so the hooks arrive with the
# toolchain rather than in a README instruction. Every failure mode here is
# silent, which is the whole problem with setup code:
#
#   - it installs nothing, and every local gate is off with no symptom until a
#     red CI round on something a hook would have caught in a second.
#   - it installs only SOME hook types, so a stage reports nothing. That is the
#     shape this repository has already paid for once: the git-identity gate
#     shipped dormant and its own paired test asserted the pass.
#   - it runs in CI, spending time on every job to arm something nothing fires.
#
# `pre-commit` and `git` are exercised for real against a scratch repository,
# except that pre-commit itself is stubbed so this suite never depends on a
# network fetch or on which pre-commit version is on PATH.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/mise/setup-hooks.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/out.txt"
calls="$work/calls.txt"
stub_dir="$work/bin"
repo="$work/repo"

mkdir -p "$stub_dir"
cat >"$stub_dir/pre-commit" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PRE_COMMIT_STUB_CALLS"
exit "${PRE_COMMIT_STUB_EXIT:-0}"
STUB
chmod +x "$stub_dir/pre-commit"

setup() {
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet --initial-branch=trunk
  [ "${1:-with-config}" = "no-config" ] || printf 'repos: []\n' >"$repo/.pre-commit-config.yaml"
  : >"$calls"
}

# run_in <dir> [env assignments...]; run [env assignments...] uses $repo.
run_in() {
  local cwd="$1" status
  shift
  set +e
  (cd "$cwd" && env PATH="$stub_dir:$PATH" \
    PRE_COMMIT_STUB_CALLS="$calls" CI= "$@" bash "$script") >"$out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}
run() { run_in "$repo" "$@"; }

# --- the ordinary case: hooks get installed ----------------------------------
setup
if [ "$(run)" = "0" ]; then ok; else
  fail_case "an ordinary install must exit 0: $(cat "$out")"
fi
if grep -q 'install' "$calls"; then ok; else
  fail_case "pre-commit install must actually be called: $(cat "$calls")"
fi

# --- ALL FOUR hook types, not only the ones this branch's config uses --------
# The child branch's config replaces this one at the same path and declares
# commit-msg, pre-push and post-checkout hooks. Installing only pre-commit here
# would leave three stages silently uninstalled after a rebase onto it, which
# is a gate that reports nothing rather than one that fails.
for hook in pre-commit commit-msg pre-push post-checkout; do
  if grep -q -- "--hook-type $hook" "$calls"; then ok; else
    fail_case "hook type '$hook' must be installed: $(cat "$calls")"
  fi
done
# --overwrite, so re-running is free and a stale hook from an earlier config
# cannot survive.
if grep -q -- '--overwrite' "$calls"; then ok; else
  fail_case "the install must overwrite, so it is idempotent: $(cat "$calls")"
fi

# --- idempotent --------------------------------------------------------------
if [ "$(run)" = "0" ] && [ "$(run)" = "0" ]; then ok; else
  fail_case "re-running must stay a clean exit"
fi

# --- CI is excluded ----------------------------------------------------------
# jdx/mise-action runs `mise install` on every job. CI never commits, and the
# checks the hooks run are the same ones the pre-commit job runs directly.
setup
if [ "$(run CI=true)" = "0" ]; then ok; else
  fail_case "a CI run must exit 0: $(cat "$out")"
fi
if [ ! -s "$calls" ]; then ok; else
  fail_case "CI must install nothing, got: $(cat "$calls")"
fi
if grep -q 'CI detected' "$out"; then ok; else
  fail_case "the CI skip must say so rather than being silent: $(cat "$out")"
fi

# --- a tree with no hook config ----------------------------------------------
# `mise install` is a legitimate thing to run on a branch that carries no
# config. It must not install anything and must not fail the install.
setup no-config
if [ "$(run)" = "0" ]; then ok; else
  fail_case "a tree with no .pre-commit-config.yaml must not fail mise install"
fi
if [ ! -s "$calls" ]; then ok; else
  fail_case "with no config there is nothing to install, got: $(cat "$calls")"
fi

# --- not a git work tree ------------------------------------------------------
# Same reasoning: `mise install` in an unpacked tarball is legitimate, and
# there is no .git to install into.
mkdir -p "$work/nogit"
printf 'repos: []\n' >"$work/nogit/.pre-commit-config.yaml"
: >"$calls"
if [ "$(run_in "$work/nogit")" = "0" ] && [ ! -s "$calls" ]; then ok; else
  fail_case "outside a git work tree it must exit quietly: $(cat "$out")"
fi

# --- pre-commit missing is LOUD ----------------------------------------------
# It is pinned in mise.toml, so its absence means the toolchain did not
# install. Exiting 0 there is the dormant-gate pattern: everything looks fine
# and no hook is armed.
setup
: >"$calls"
# An EMPTY directory as the whole PATH, not "/usr/bin:/bin". This suite claims
# hermeticity, and that claim was false here: on a machine with pre-commit
# installed system-wide (an apt package lands in /usr/bin), this case silently
# exercised the ordinary-install path instead of the missing-pre-commit path,
# giving a result unrelated to the code under test. An empty directory cannot
# contain pre-commit anywhere.
#
# `git` goes missing too, which is fine and in fact tightens the case: the
# script's first act is a `git rev-parse`, and without git it takes the quiet
# not-a-work-tree exit rather than the loud missing-pre-commit one. So the PATH
# keeps the system directories for git alone, via a shim directory that
# contains everything except pre-commit.
shim="$work/nopc"
rm -rf "$shim"
mkdir -p "$shim"
for tool in bash git sed grep cat; do
  real="$(command -v "$tool" || true)"
  [ -z "$real" ] || ln -sf "$real" "$shim/$tool"
done
set +e
(cd "$repo" && env PATH="$shim" CI= bash "$script") >"$out" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then ok; else
  fail_case "a missing pre-commit must fail, not silently install nothing"
fi
if grep -q 'NOT installed' "$out"; then ok; else
  fail_case "the missing-pre-commit failure must say the hooks are not armed: $(cat "$out")"
fi

# --- a failing install is not swallowed --------------------------------------
setup
if [ "$(run PRE_COMMIT_STUB_EXIT=1)" != "0" ]; then ok; else
  fail_case "a failing pre-commit install must fail the script"
fi

# --- it works from a subdirectory --------------------------------------------
setup
mkdir -p "$repo/scripts/ai-review"
: >"$calls"
if [ "$(run_in "$repo/scripts/ai-review")" = "0" ] && grep -q 'install' "$calls"; then ok; else
  fail_case "the script must resolve the repository root itself: $(cat "$out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
