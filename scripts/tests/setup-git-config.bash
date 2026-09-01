#!/usr/bin/env bash
# Standalone test for scripts/mise/setup-git-config.sh. Copies the script into
# a throwaway repo at its real relative path, because the script deliberately
# derives its target repository from its OWN location rather than from the
# caller's cwd; testing it anywhere else would test the wrong thing.
# Run: bash scripts/tests/setup-git-config.bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_script="$repo_root/scripts/mise/setup-git-config.sh"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# A private HOME so a stray --global write lands here and is visible to the
# assertions below, instead of silently editing the developer's own config.
export HOME="$sandbox/home"
mkdir -p "$HOME"

repo="$sandbox/repo"
mkdir -p "$repo/scripts/mise" "$repo/scripts/git-discipline"
git -C "$repo" init -q -b main
cp "$source_script" "$repo/scripts/mise/setup-git-config.sh"
# The script sources the shared stacking-policy fragment, so every fixture
# needs it beside the script. A fixture missing it fails for a reason that has
# nothing to do with the case under test.
cp "$repo_root/scripts/git-discipline/stacking-policy.sh" "$repo/scripts/git-discipline/"

# --- test 1: the three settings are written, and written locally ---
bash "$repo/scripts/mise/setup-git-config.sh" >/dev/null

got="$(git -C "$repo" config --local --get pull.rebase || true)"
[[ "$got" == "true" ]] || fail "expected local pull.rebase=true, got '$got'"

got="$(git -C "$repo" config --local --get push.default || true)"
[[ "$got" == "current" ]] || fail "expected local push.default=current, got '$got'"

got="$(git -C "$repo" config --local --get alias.stack || true)"
[[ "$got" == *"stack.sh"* ]] || fail "expected alias.stack to invoke stack.sh, got '$got'"
[[ "$got" == '!'* ]] || fail "alias.stack must be a shell alias (leading '!'), got '$got'"

# --- test 2: the alias keeps its command substitution UNEXPANDED ---
# The alias resolves the repo top level at RUN time so it works from any
# worktree. If the script ever expands it at write time the alias still looks
# plausible but is pinned to one path, which is exactly the bug worth catching.
# shellcheck disable=SC2016  # the literal, unexpanded form is the assertion
[[ "$got" == *'$(git rev-parse --show-toplevel)'* ]] ||
  fail "alias.stack must store the \$(...) literally, got '$got'"

# --- test 3: nothing was written to the global config ---
[[ ! -f "$HOME/.gitconfig" ]] ||
  fail "script wrote a --global config at $HOME/.gitconfig; it must only write --local"

# --- test 4: idempotent, and no key accumulates a second value ---
bash "$repo/scripts/mise/setup-git-config.sh" >/dev/null
bash "$repo/scripts/mise/setup-git-config.sh" >/dev/null

for key in pull.rebase push.default alias.stack; do
  count="$(git -C "$repo" config --local --get-all "$key" | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] || fail "expected exactly one value for $key after 3 runs, got $count"
done

# --- test 5: a linked worktree shares the same config, no re-run needed ---
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m "init"
git -C "$repo" worktree add -q "$sandbox/linked" -b feat-1-x >/dev/null 2>&1
got="$(git -C "$sandbox/linked" config --local --get pull.rebase || true)"
[[ "$got" == "true" ]] ||
  fail "expected a linked worktree to inherit pull.rebase from the shared config, got '$got'"

# --- test 6: outside a repository it exits 0 and writes nothing ---
outside="$sandbox/outside/scripts/mise"
mkdir -p "$outside"
cp "$source_script" "$outside/setup-git-config.sh"
set +e
out="$(bash "$outside/setup-git-config.sh" 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "expected exit 0 outside a repository, got $status"
[[ "$out" == *"not inside a git repository"* ]] ||
  fail "expected an explanatory message outside a repository, got '$out'"

# --- test 7: mise invokes this script by ABSOLUTE path ---
# The script locates its own repository precisely because mise's cwd is not
# guaranteed to be inside it. A repo-relative hook body would fail to find the
# script at all in that same case, making the script's care pointless. The two
# have to agree, so assert the contract here rather than leave it to a reader
# noticing the contradiction.
hook_line="$(grep -E '^postinstall' "$repo_root/mise.toml" || true)"
[[ -n "$hook_line" ]] || fail "mise.toml has no postinstall hook"
[[ "$hook_line" == *"setup-git-config.sh"* ]] ||
  fail "the postinstall hook must invoke setup-git-config.sh, got '$hook_line'"
[[ "$hook_line" == *"{{config_root}}"* ]] ||
  fail "the postinstall hook must use an absolute {{config_root}} path, got '$hook_line'"
# and the interpolation must be quoted: config_root expands to a real path, and
# a clone under a directory containing a space would word-split without this
[[ "$hook_line" == *'"{{config_root}}'* ]] ||
  fail "the {{config_root}} interpolation must be quoted, got '$hook_line'"

# --- test 8: the script survives a repository path containing a space ---
spaced="$sandbox/dir with space/repo"
mkdir -p "$spaced/scripts/mise" "$spaced/scripts/git-discipline"
git -C "$sandbox" init -q -b main "$spaced" 2>/dev/null || git init -q -b main "$spaced"
cp "$source_script" "$spaced/scripts/mise/setup-git-config.sh"
cp "$repo_root/scripts/git-discipline/stacking-policy.sh" "$spaced/scripts/git-discipline/"
bash "$spaced/scripts/mise/setup-git-config.sh" >/dev/null
got="$(git -C "$spaced" config --local --get pull.rebase || true)"
[[ "$got" == "true" ]] || fail "expected the script to work under a spaced path, got '$got'"

echo "PASS: setup-git-config.bash"
