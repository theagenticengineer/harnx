#!/usr/bin/env bash
# Standalone test for what the local review does with a diff too large to
# review in one pass.
# Run: bash scripts/tests/large-diff.bash
#
# The dangerous outcome is not the failure. It is a diff so large the engine
# never reviewed it, reported as a clean pass, with the reviewed-tree record
# written and the pre-push gate satisfied. Everything downstream then treats
# unreviewed code as reviewed, and nothing says otherwise.
#
# So the assertions are about what must NOT happen:
#
#   - the reviewed-tree record must not be written;
#   - the run must exit non-zero;
#   - the message must say the diff was REFUSED, and why, rather than only that
#     something crashed. A refusal and a crash need opposite responses, and
#     "the review engine crashed" sends an operator looking for a broken
#     pipeline when the answer is to pass BASE or split the pull request.
#
# The last of those is the one that decays quietly: the first two already held
# through the generic crash path, so the refusal could be reported as a crash
# forever without any gate noticing.
#
# Runs against a throwaway repository with a stubbed `claude`, so no token, no
# network and no model are involved. The size limits are lowered by environment
# rather than by generating a 400KB diff, which keeps the suite fast and tests
# the same code path.
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

stub_dir="$work/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/claude" <<'CLAUDE_STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '{"result":"[]","is_error":false}'
CLAUDE_STUB
chmod +x "$stub_dir/claude"

# A repository with a base commit and, on top of it, enough separate files that
# the diff cannot fit in the chunk budget set below.
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester
# `.harnx/` too: the runner appends its pass log there, and a missing directory
# would fail the run for a reason that has nothing to do with diff size.
mkdir -p "$repo/scripts/ai-review" "$repo/scripts/mise" "$repo/.harnx"
cp "$repo_root/scripts/ai-review/review-engine.sh" "$repo/scripts/ai-review/"
cp "$repo_root/scripts/mise/ai-review-local.sh" "$repo/scripts/mise/"
printf 'base\n' >"$repo/base.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): the base commit here'
git -C "$repo" branch -q -M main
git -C "$repo" tag base-point

for i in 1 2 3 4 5 6 7 8 9 10; do
  # Each file is its own `diff --git` header, which is where the engine splits,
  # and each is comfortably larger than the byte budget set below.
  for n in $(seq 1 40); do
    printf 'line %s of padding content for file %s\n' "$n" "$i"
  done >"$repo/f$i.txt"
done
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): ten files of padding content'

statefile="$repo/$(git -C "$repo" rev-parse --git-path ai-review-reviewed-tree)"
statefile="$(cd "$repo" && git rev-parse --git-path ai-review-reviewed-tree)"

out="$work/out"
run() {
  # `-u` before any assignment: env stops parsing options at the first NAME=VALUE.
  (cd "$repo" && env -u CLAUDE_CODE_OAUTH_TOKEN \
    PATH="$stub_dir:$PATH" \
    AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN=stub-token \
    BASE=base-point \
    AI_REVIEW_MAX_DIFF_BYTES=200 \
    AI_REVIEW_MAX_CHUNKS=2 \
    "$@" bash scripts/mise/ai-review-local.sh) >"$out" 2>&1
}

rm -f "$repo/$statefile"

# --- an over-large diff must not be reported as a clean review ---------------
if run; then
  fail_case "a diff over the chunk limit must exit non-zero, got success: $(cat "$out")"
else ok; fi

# THE ASSERTION THAT MATTERS. Everything else about this run could be right and
# this one wrong, and the result would be unreviewed code recorded as reviewed.
if [ ! -s "$repo/$statefile" ]; then ok; else
  fail_case "the reviewed-tree record must NOT be written when no review ran; it says $(cat "$repo/$statefile")"
fi

# --- the message says REFUSED, not crashed -----------------------------------
if grep -q 'too large to review in one pass' "$out"; then ok; else
  fail_case "the message must say the diff was too large: $(cat "$out")"
fi
if grep -q 'refusal, not a crash' "$out"; then ok; else
  fail_case "the message must distinguish a refusal from a crash: $(cat "$out")"
fi
# The most common real cause on this repository's stacked branches, named so
# the operator does not go looking for a broken pipeline first.
if grep -q 'BASE=origin/' "$out"; then ok; else
  fail_case "the message must name the missing-BASE cause: $(cat "$out")"
fi
# The engine's own numbers must still reach the operator, not be swallowed by
# the friendlier message wrapped around them.
if grep -q 'over the limit of' "$out"; then ok; else
  fail_case "the engine's own refusal, with its numbers, must still be shown: $(cat "$out")"
fi

# --- a diff WITHIN the budget still reviews and records ----------------------
# Without this the suite would pass on a script that refused everything.
git -C "$repo" checkout -q -b small base-point
printf 'one small change\n' >"$repo/small.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): one small file only'
rm -f "$repo/$statefile"
if run AI_REVIEW_MAX_DIFF_BYTES=400000 AI_REVIEW_MAX_CHUNKS=6; then ok; else
  fail_case "a diff within budget must still review cleanly: $(cat "$out")"
fi
if [ -s "$repo/$statefile" ]; then ok; else
  fail_case "a clean review within budget must record the reviewed tree"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
