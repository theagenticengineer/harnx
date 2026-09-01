#!/usr/bin/env bash
# ci-check-forward-refs.sh
# CI mirror of check-no-forward-refs.sh: runs it against EVERY commit in the
# pull request's range, not only the tip.
#
# THE TIP IS THE ONE COMMIT THAT CANNOT HAVE THIS DEFECT, which is why a
# tip-only check would not close it. A forward reference is a spine file
# pointing at a file that arrives in a LATER commit; by the time the branch's
# last commit exists, every one of those files has landed and the reference
# resolves. The broken commits are all in between, and CI never ran for any of
# them. That is exactly how the defect survived in the earlier rebuild this gate
# exists to prevent.
#
# So this walks the range link by link, the same shape ci-check-merge-commits.sh
# uses, and for the same reason: the local hook is the fast feedback and is
# bypassable with --no-verify, and this repository rewrites history routinely
# through --fixup and --autosquash, which can reorder a reference ahead of the
# file it names without anybody touching either.
#
# Env:
#   BASE_SHA  required; the PR base commit SHA.
#   HEAD_SHA  required; the PR head commit SHA.
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

commits="$(git rev-list --reverse "${BASE_SHA}..${HEAD_SHA}")"
total="$(printf '%s\n' "$commits" | grep -c . || true)"

# A range with no commits means the check examined nothing. Reporting success
# for that is the failure this floor spends most of its effort on, so it is a
# hard error rather than a quiet pass.
if [ "$total" -eq 0 ]; then
  echo "::error::ci-check-forward-refs: the range ${BASE_SHA}..${HEAD_SHA} contains no commits, so nothing was examined. Refusing to report success for a check that saw nothing." >&2
  exit 1
fi

failed=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  # EVERY commit is checked before failing, rather than stopping at the first.
  # A branch with the problem usually has it in several commits at once, and
  # reporting one per push turns one fix into several round trips.
  bash "$script_dir/check-no-forward-refs.sh" "$sha" || failed=1
done <<COMMITS
$commits
COMMITS

if [ "$failed" -ne 0 ]; then
  echo "::error::ci-check-forward-refs: at least one commit in ${BASE_SHA}..${HEAD_SHA} carries a forward reference. Each is named above." >&2
  exit 1
fi

echo "ci-check-forward-refs: all $total commit(s) in the range resolve every spine reference."
