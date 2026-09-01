#!/usr/bin/env bash
# Standalone test for scripts/ai-review/ci-head-shas.sh.
# Run: bash scripts/tests/ci-head-shas.bash
#
# The script produces one number, and the round cap subtracts a recorded copy of
# that number from a fresh one. That makes two of its properties load-bearing in
# a way a one-number script usually is not:
#
#   - it counts DISTINCT head SHAs, not runs. One push starts several workflows,
#     so a run count would tick several times per push and a cap expressed in it
#     would mean something different on a repository with a different number of
#     workflows.
#   - it FAILS rather than printing 0 when it cannot read. Zero is a claim that
#     CI has never run, and a caller believing it would count local passes only
#     while reporting that it had counted both.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/ci-head-shas.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

bin="$work/bin"
mkdir -p "$bin"
for tool in bash git sed sort wc tr printf head; do
  src="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$bin/$tool"
done

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
printf 'one\n' >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the first commit here'
git -C "$repo" branch -M feat-9-a-rung

# `gh` is written per case; $out captures stdout only, so a count can never be
# satisfied by a message on stderr.
gh_says() {
  cat >"$bin/gh"
  chmod +x "$bin/gh"
}
run() { (cd "$repo" && env PATH="$bin" bash "$script" "$@" >"$work/out" 2>"$work/err"); }

# --- 1. DISTINCT states, not runs --------------------------------------------
gh_says <<'EOF'
#!/usr/bin/env bash
printf 'aaa\naaa\naaa\nbbb\n'
EOF
if run && [ "$(cat "$work/out")" = "2" ]; then ok; else
  fail_case "three runs over two SHAs must count 2, got '$(cat "$work/out")'"
fi

# --- 2. no runs at all is a real zero ----------------------------------------
# Distinct from "cannot read", which must fail instead. A branch that has never
# been pushed genuinely has zero.
gh_says <<'EOF'
#!/usr/bin/env bash
printf ''
EOF
if run && [ "$(cat "$work/out")" = "0" ]; then ok; else
  fail_case "no runs must count 0, got '$(cat "$work/out")'"
fi

# --- 3. gh ABSENT fails, and does not print a number -------------------------
rm -f "$bin/gh"
if run; then
  fail_case "a missing gh must fail rather than answer"
else ok; fi
if [ -z "$(cat "$work/out")" ]; then ok; else
  fail_case "a failure must print no count, got '$(cat "$work/out")'"
fi
if grep -q 'not on PATH' "$work/err"; then ok; else
  fail_case "it must say gh is missing, got: $(cat "$work/err")"
fi

# --- 4. gh PRESENT BUT FAILING also fails ------------------------------------
# Unauthenticated, rate-limited, or offline. This is the case a `command -v`
# check alone would wave through, and it is far more common than a missing gh.
gh_says <<'EOF'
#!/usr/bin/env bash
echo "gh: HTTP 401" >&2
exit 1
EOF
if run; then
  fail_case "a failing gh must fail rather than answer 0"
else ok; fi
if [ -z "$(cat "$work/out")" ]; then ok; else
  fail_case "a failing gh must print no count, got '$(cat "$work/out")'"
fi
if grep -q 'could not read workflow runs' "$work/err"; then ok; else
  fail_case "it must say the read failed, got: $(cat "$work/err")"
fi

# --- 5. it asks about the branch it was given --------------------------------
# The cap counts per rung. A script that ignored its argument would count the
# whole repository's history against every branch.
gh_says <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
  feat-77-elsewhere) printf 'z1\nz2\nz3\n'; exit 0 ;;
  esac
done
printf 'only-one\n'
EOF
if run feat-77-elsewhere && [ "$(cat "$work/out")" = "3" ]; then ok; else
  fail_case "the branch argument must be passed through, got '$(cat "$work/out")'"
fi
# ...and defaults to the current branch when not given one.
if run && [ "$(cat "$work/out")" = "1" ]; then ok; else
  fail_case "with no argument it must ask about the current branch, got '$(cat "$work/out")'"
fi

# --- 6. the default limit is not left at gh's 20 ------------------------------
# gh's default is 20 runs. A truncated count is worse than none: it is wrong in
# the direction that makes the cap fire LATE, which is the direction nobody
# notices.
if grep -q -- '--limit 500' "$script"; then ok; else
  fail_case "the run listing must raise gh's default limit, or the count silently truncates"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
