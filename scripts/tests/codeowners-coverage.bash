#!/usr/bin/env bash
# Standalone test: every linter config a required check reads is
# CODEOWNERS-protected.
# Run: bash scripts/tests/codeowners-coverage.bash
#
# WHAT IT PROTECTS, and why a list of paths in CODEOWNERS is not enough on its
# own. A linter's config decides what that linter actually enforces. Blanking
# one is the same tamper as deleting the hook: `gitleaks` with an allowlist
# matching everything, `markdownlint` with `default: false`, `taplo` with no
# rules, all leave the `pre-commit` check reporting green over a gate that
# stopped checking. CODEOWNERS is what makes that edit require a human review of
# that exact diff.
#
# The gap this closes is the one that produced it. `.yamllint.yaml` and
# `.vale.ini` were listed because they existed when the list was written. Three
# more configs were added later, gating three more required checks, and nothing
# noticed they were unprotected: CODEOWNERS has no way to say "and any future
# one", and a hand-kept list silently stops being complete the moment somebody
# adds a tool.
#
# So the list is DERIVED, from the configs the hooks and workflows actually name
# with `--config`, rather than restated here. A new linter added with its config
# is covered by this assertion on the day it lands.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
codeowners="${CO_FILE:-$repo_root/.github/CODEOWNERS}"
sources_default="$repo_root/.pre-commit-config.yaml $repo_root/.github/workflows/ci.yml"
sources="${CO_SOURCES:-$sources_default}"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

if [ -f "$codeowners" ]; then ok; else
  fail_case "$codeowners must exist"
  echo "RESULT: $pass passed, $fail failed"
  exit 1
fi

# Every file named by a `--config <path>` or `-c <path>`. Both spellings are in
# use: yamllint's hook uses `-c`, the rest use `--config`.
# shellcheck disable=SC2086  # $sources is a deliberate space-separated list
configs="$(grep -hoE '(--config|-c) +[A-Za-z0-9._/-]+' $sources 2>/dev/null |
  awk '{print $2}' | sort -u || true)"

if [ -n "$configs" ]; then ok; else
  fail_case "no --config references found in: $sources"
fi

# AUTO-DISCOVERED IGNORE FILES COUNT TOO, and they are the reason this suite
# needed a second pass. A `--config` flag is not the only way a linter's
# behaviour is declared: markdownlint reads `.markdownlintignore` without being
# told to, and `**` in that file turns the linter off just as completely as
# `default: false` in its config would. Derived by looking for the companion
# next to each discovered config, so a linter that gains one later is covered.
for cfg in $configs; do
  base="${cfg%.*}"
  for candidate in "${base}ignore" "${cfg}ignore"; do
    [ -f "$repo_root/$candidate" ] || continue
    printf '%s\n' "$configs" | grep -Fxq "$candidate" || configs="$configs
$candidate"
  done
done

unprotected=""
while IFS= read -r cfg; do
  [ -n "$cfg" ] || continue
  # A config is protected either by its own line or by a directory entry that
  # contains it. `styles/House/*.yml` is covered by `/styles/`, and requiring a
  # line per file there would be noise.
  if grep -qE "^/?${cfg//./\\.}( |\$)" "$codeowners"; then continue; fi
  covered=0
  while IFS= read -r entry; do
    case "$entry" in
    */) case "/$cfg" in "$entry"*) covered=1 ;; esac ;;
    esac
  done < <(awk '/^\// { print $1 }' "$codeowners")
  [ "$covered" -eq 1 ] || unprotected="$unprotected $cfg"
done <<CONFIG_LIST
$configs
CONFIG_LIST

if [ -z "$unprotected" ]; then ok; else
  fail_case "these configs gate a required check but are not CODEOWNERS-protected, so they can be blanked without a human review:$unprotected"
fi

# The derivation must actually be finding things. An assertion that passes
# because its input list came back empty is the failure this whole file exists
# to prevent, one level up.
found="$(printf '%s\n' "$configs" | grep -c . || true)"
if [ "$found" -ge 4 ]; then ok; else
  fail_case "expected at least 4 linter configs to be discovered, found $found: $configs"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
