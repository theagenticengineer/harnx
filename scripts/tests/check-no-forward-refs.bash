#!/usr/bin/env bash
# Standalone test for scripts/git-discipline/check-no-forward-refs.sh.
# Run: bash scripts/tests/check-no-forward-refs.bash
#
# Runs against a throwaway repository rather than this one, because the cases
# that matter are BROKEN trees: a spine file naming a script that is not there.
# Constructing those here is the only way to exercise the failure path, and
# doing it in this repository would mean committing the defect to test it.
#
# Every helper call not already inside an `if` carries `|| true`; under `set -e`
# a bare failing call aborts the suite, which reads as a smaller run rather than
# a failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/git-discipline/check-no-forward-refs.sh"

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
mkdir -p "$repo/scripts/git-discipline" "$repo/.agents/rules"
git -C "$repo" init -q
git -C "$repo" config user.email t@acme.dev
git -C "$repo" config user.name Tester

out="$work/out"
run() { (cd "$repo" && bash "$script" "$@") >"$out" 2>&1; }

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

# --- a spine file naming a script that IS there passes -----------------------
printf '#!/usr/bin/env bash\n' >"$repo/scripts/git-discipline/present.sh"
write_config "scripts/git-discipline/present.sh"
git -C "$repo" add -A
if run; then ok; else
  fail_case "a reference that resolves must pass: $(cat "$out")"
fi
if grep -q 'all resolve' "$out"; then ok; else
  fail_case "the success line must say the references resolved: $(cat "$out")"
fi

# --- THE DEFECT: a hook declared before its script exists --------------------
write_config "scripts/git-discipline/not-yet.sh"
git -C "$repo" add -A
if run; then
  fail_case "a hook naming a script that does not exist must fail"
else ok; fi
if grep -q 'not-yet.sh' "$out"; then ok; else
  fail_case "the error must name the missing script: $(cat "$out")"
fi

# --- mise.toml naming a script that does not exist ---------------------------
write_config "scripts/git-discipline/present.sh"
printf '[tasks.t]\nrun = "bash scripts/mise/absent.sh"\n' >"$repo/mise.toml"
git -C "$repo" add -A
if run; then
  fail_case "a mise task naming a missing script must fail"
else ok; fi
if grep -q 'absent.sh' "$out"; then ok; else
  fail_case "the error must name the missing mise script: $(cat "$out")"
fi
# A COMMENT NAMING A SCRIPT IS NOT A REFERENCE. mise.toml's comments name
# scripts constantly, to explain what a hook runs; nothing executes a comment,
# so one naming a script that no longer exists is stale prose rather than a
# broken commit. Scanning them would make this gate fail on the documentation
# written to explain it.
printf '# see scripts/mise/absent.sh for why\n[tasks.t]\nrun = "bash scripts/git-discipline/present.sh"\n' >"$repo/mise.toml"
git -C "$repo" add -A
if run; then ok; else
  fail_case "a full-line comment naming a missing script must not trip the gate: $(cat "$out")"
fi
# A TRAILING comment is just as much a comment. Stripping only full lines left
# this case scanned, which is a spurious failure waiting for somebody to explain
# a hook in a same-line note.
printf '[tasks.t]\nrun = "bash scripts/git-discipline/present.sh"  # not scripts/mise/absent.sh\n' >"$repo/mise.toml"
git -C "$repo" add -A
if run; then ok; else
  fail_case "a trailing comment naming a missing script must not trip the gate: $(cat "$out")"
fi
# ...and a `#` INSIDE a quoted value is data, not a comment, so the reference
# beside it must still be seen. Without this, the fix above could be a `sed
# s/#.*//` that silently ate real references.
# The reference sits AFTER the quoted `#`, deliberately. Put before it, the
# case passes under a naive `sed s/#.*//` too, because the naive strip only eats
# what follows; only a reference on the far side of the quoted hash tells the
# two implementations apart.
printf '[tasks.t]\nrun = "bash --tag \x27#1\x27 scripts/git-discipline/absent2.sh"\n' >"$repo/mise.toml"
git -C "$repo" add -A
if run; then
  fail_case "a reference before a quoted # must still be checked"
else ok; fi
if grep -q 'absent2.sh' "$out"; then ok; else
  fail_case "the error must name the reference that preceded the quoted #: $(cat "$out")"
fi
rm -f "$repo/mise.toml"

# --- AGENTS.md indexing a document that does not exist -----------------------
printf '# i\n\n- [Gone](.agents/rules/absent.md): not written yet.\n' >"$repo/AGENTS.md"
git -C "$repo" add -A
if run; then
  fail_case "an index entry for a missing document must fail"
else ok; fi
if grep -q 'absent.md' "$out"; then ok; else
  fail_case "the error must name the missing document: $(cat "$out")"
fi

# A MENTION IS NOT A REFERENCE. The path is taken from inside the parentheses,
# so prose or a code span naming a file is not an index entry.
# shellcheck disable=SC2016  # the backticks are a markdown code span in the
# fixture's text, not a command substitution; single quotes keep them literal,
# which is the whole point of this case.
printf '# i\n\nThe file `.agents/rules/absent.md` is discussed but not linked.\n' >"$repo/AGENTS.md"
git -C "$repo" add -A
if run; then ok; else
  fail_case "a bare mention must not count as a reference: $(cat "$out")"
fi
rm -f "$repo/AGENTS.md"

# --- `mise exec -- <tool>` IS NOT A REFERENCE --------------------------------
# The tool comes from mise.toml's [tools], not from this repository, and
# hook-stages.bash already checks that every one of them is pinned. Treating it
# as a repo path would make this gate fail on every hook in the real config.
write_config "mise exec -- shellcheck"
git -C "$repo" add -A
if run; then ok; else
  fail_case "a mise exec entry must not be treated as a repo path: $(cat "$out")"
fi

# --- IT READS THE TREE, NOT THE WORKING DIRECTORY ----------------------------
# The whole question is whether the reference resolves IN THAT COMMIT. A file
# present on disk but not committed is precisely the case that must fail, and a
# check reading from disk would pass it for the wrong reason.
write_config "scripts/git-discipline/uncommitted.sh"
printf '#!/usr/bin/env bash\n' >"$repo/scripts/git-discipline/uncommitted.sh"
git -C "$repo" add .pre-commit-config.yaml
if run; then
  fail_case "a script present on disk but NOT staged must still fail"
else ok; fi
git -C "$repo" add -A
if run; then ok; else
  fail_case "once staged, the same script must pass: $(cat "$out")"
fi

# --- A COMMIT-ISH ARGUMENT checks that commit, not the index -----------------
# This is what the CI mirror depends on, so it is asserted here rather than
# only there.
git -C "$repo" commit -qm 'feat(#1): a commit whose references all resolve'
good="$(git -C "$repo" rev-parse HEAD)"
write_config "scripts/git-discipline/vanished.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feat(#1): a commit with a forward reference'
if run "$good"; then ok; else
  fail_case "the earlier good commit must still pass when named: $(cat "$out")"
fi
if run HEAD; then
  fail_case "the later broken commit must fail when named"
else ok; fi
if grep -q 'vanished.sh' "$out"; then ok; else
  fail_case "the error must name the commit's own missing script: $(cat "$out")"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
