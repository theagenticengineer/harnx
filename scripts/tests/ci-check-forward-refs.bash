#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/ci-check-forward-refs.sh.
# Run: bash scripts/tests/ci-check-forward-refs.bash
#
# ONE CASE MATTERS MORE THAN THE REST, and the suite is built around it: a
# branch whose TIP is clean and whose middle commit is broken. That is the exact
# shape of the defect this gate exists for, and it is the shape a tip-only check
# cannot see, because by the time the last commit exists every referenced file
# has landed and every reference resolves.
#
# If this suite only tested a broken tip it would pass against a check that
# examined nothing but the tip, which is the check that already failed to catch
# this once.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/git-discipline/ci-check-forward-refs.sh"

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
mkdir -p "$repo/scripts/git-discipline"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
# The check under test resolves its sibling from its own location, so both are
# copied in rather than run from this repository.
cp "$repo_root/scripts/git-discipline/check-no-forward-refs.sh" "$repo/scripts/git-discipline/"
cp "$script" "$repo/scripts/git-discipline/"

out="$work/out"
run() {
  (cd "$repo" && env BASE_SHA="$1" HEAD_SHA="$2" \
    bash scripts/git-discipline/ci-check-forward-refs.sh) >"$out" 2>&1
}

write_config() {
  cat >"$repo/.pre-commit-config.yaml" <<CONFIG
repos:
  - repo: local
    hooks:
      - id: a-hook
        name: a-hook
        entry: $1
        language: system
        stages: [pre-commit]
CONFIG
}

printf '#!/usr/bin/env bash\n' >"$repo/scripts/git-discipline/first.sh"
write_config "scripts/git-discipline/first.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the base commit for this range'
base="$(git -C "$repo" rev-parse HEAD)"

# --- a range whose every commit resolves passes ------------------------------
printf '#!/usr/bin/env bash\n' >"$repo/scripts/git-discipline/second.sh"
write_config "scripts/git-discipline/second.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): a script and its reference together'
if run "$base" HEAD; then ok; else
  fail_case "a range with no forward references must pass: $(cat "$out")"
fi
if grep -q 'all 1 commit' "$out"; then ok; else
  fail_case "the success line must say how many commits were examined: $(cat "$out")"
fi

# --- THE CASE A TIP-ONLY CHECK CANNOT SEE ------------------------------------
# Commit A references a script that arrives in commit B. At B the reference
# resolves, so the tip is clean; A is broken and nothing tip-only looks at it.
write_config "scripts/git-discipline/late.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): reference a script that has not landed'
broken="$(git -C "$repo" rev-parse HEAD)"
printf '#!/usr/bin/env bash\n' >"$repo/scripts/git-discipline/late.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the script the previous commit named'

# The tip really is clean, which is what makes this case the interesting one.
if (cd "$repo" && bash scripts/git-discipline/check-no-forward-refs.sh HEAD) >/dev/null 2>&1; then ok; else
  fail_case "the fixture's TIP must be clean, or this case proves nothing"
fi
# ...and the range is not.
if run "$base" HEAD; then
  fail_case "a clean tip must NOT hide a broken commit earlier in the range"
else ok; fi
if grep -q "$(git -C "$repo" rev-parse --short "$broken")" "$out"; then ok; else
  fail_case "the error must name the offending commit: $(cat "$out")"
fi
if grep -q 'late.sh' "$out"; then ok; else
  fail_case "the error must name the unresolved reference: $(cat "$out")"
fi

# --- EVERY commit is reported, not just the first ----------------------------
# A branch usually carries this in several commits at once, and reporting one
# per push turns one fix into several round trips.
write_config "scripts/git-discipline/another-late.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): a second forward reference'
printf '#!/usr/bin/env bash\n' >"$repo/scripts/git-discipline/another-late.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the second script lands too'
run "$base" HEAD || true
if [ "$(grep -c 'does not exist in commit' "$out")" -ge 2 ]; then ok; else
  fail_case "both offending commits must be reported in one run: $(cat "$out")"
fi

# --- AN EMPTY RANGE IS AN ERROR, not a pass ----------------------------------
# A check that examined nothing must never report success; that is the failure
# this floor spends most of its effort on.
if run HEAD HEAD; then
  fail_case "an empty range must fail rather than report success"
else ok; fi
if grep -q 'nothing was examined' "$out"; then ok; else
  fail_case "an empty range must say it examined nothing: $(cat "$out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
