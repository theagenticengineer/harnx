#!/usr/bin/env bash
# pre-push gate: refuse to push a tree that has not passed a CLEAN full local
# ai-review. `mise run ai-review:local` records the reviewed working-tree hash
# when a whole-diff review converges to zero Major findings; this compares the
# current tree to that record and blocks the push on a mismatch, so nothing
# reaches the metered CI gate without first converging locally.
#
# Keys off the TREE (content) hash, not the commit hash: folding fixups and
# rebasing rewrite the commit but preserve the content, so a reviewed tree that
# is re-committed still matches, while any real content change since the
# review does not.
set -euo pipefail

statefile="$(git rev-parse --git-path ai-review-reviewed-tree 2>/dev/null || echo)"

# The temp index is removed by a TRAP, not by the line after `git write-tree`.
# Under `set -e` a failing write-tree exits the script before that line runs and
# leaves the index behind, once per failed push, which is the same leak class
# the trunk's pagination loops carry a note about. A trap covers the whole
# window rather than the success path.
current_tree() {
  local idx tree
  idx="$(mktemp)"
  trap 'rm -f "$idx"' RETURN
  GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null || true
  GIT_INDEX_FILE="$idx" git add -A 2>/dev/null || true
  tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
  printf '%s' "$tree"
}

reviewed="$(cat "$statefile" 2>/dev/null || true)"
current="$(current_tree)"

if [ -z "$reviewed" ]; then
  echo "pre-push blocked: this tree has never passed a local ai-review." >&2
  echo "  Run 'mise run ai-review:local' and converge (zero Major findings) before pushing." >&2
  exit 1
fi
if [ "$current" != "$reviewed" ]; then
  echo "pre-push blocked: the current tree differs from the last locally-reviewed one." >&2
  echo "  current:  $current" >&2
  echo "  reviewed: $reviewed" >&2
  echo "  The code changed since the last clean local review. Run" >&2
  echo "  'mise run ai-review:local' and converge before pushing." >&2
  exit 1
fi
