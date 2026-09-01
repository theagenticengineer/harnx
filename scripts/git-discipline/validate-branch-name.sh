#!/usr/bin/env bash
set -euo pipefail
b="${1:-$(git rev-parse --abbrev-ref HEAD)}"
[[ "$b" == "main" || "$b" == "HEAD" ]] && exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/git-discipline/parse-commit-header.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$script_dir/parse-commit-header.sh"

re="^(${COMMIT_TYPES_RE})-[0-9]+-[a-z0-9-]+\$"
[[ "$b" =~ $re ]] || {
  echo "branch '$b' must match '<type>-<issue-N>-<kebab-title>'" >&2
  exit 1
}
