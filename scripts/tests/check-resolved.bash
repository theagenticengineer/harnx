#!/usr/bin/env bash
# Standalone test for scripts/ai-review/check-resolved.sh.
# Run: bash scripts/tests/check-resolved.bash
#
# WHAT THIS PROTECTS. check-resolved.sh IS the ai-review-resolved gate. Its
# exit status is what branch protection blocks a merge on, so both directions
# are dangerous in different ways:
#
#   fail-open   an unresolved Major read as absent lets a real finding merge.
#   fail-closed a Minor or nit read as blocking, or a busy pull request read as
#               unresolvable, blocks a merge nobody can clear. An earlier
#               version failed closed on page count alone, which reddened every
#               pull request with more than 100 threads regardless of findings.
#
# `gh` is stubbed on PATH so the whole gate runs without a network call.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/check-resolved.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}
ok() { pass=$((pass + 1)); }

stub_dir="$(mktemp -d)"
out="$(mktemp)"
trap 'rm -rf "$stub_dir" "$out"' EXIT

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q 'after=CURSOR1'; then
  # GH_STUB_FAIL2 returns a SUCCESSFUL but unparseable second page, which is
  # what an API error page or a truncated response looks like from here. It has
  # to be this and not a non-zero exit: the temp file is created AFTER the
  # `gh` call and consumed by the `mv` two lines later, so a `gh` that fails
  # never enters the window at all. Only a failure between the create and the
  # move leaves a file behind, and `jq` refusing this input is exactly that.
  if [ -n "${GH_STUB_FAIL2:-}" ]; then
    printf 'not json at all'
    exit 0
  fi
  printf '%s' "${GH_STUB_PAGE2:-}"
else
  printf '%s' "${GH_STUB_PAGE1:-}"
fi
STUB
chmod +x "$stub_dir/gh"

# One thread: $1 resolved, $2 severity.
thread() {
  jq -cn --argjson resolved "$1" --arg sev "$2" '
    { isResolved: $resolved,
      comments: { nodes: [ { body: "<!-- ai-review-key:k -->\n<!-- ai-review-severity:\($sev) -->\n**[\($sev)]** a finding" } ] } }'
}
page() {
  # $1 hasNextPage, $2 cursor, rest: thread objects
  local more="$1" cursor="$2"
  shift 2
  jq -cn --argjson more "$more" --arg cursor "$cursor" \
    --argjson nodes "$(printf '%s\n' "$@" | jq -sc '.')" \
    '{ pageInfo: { hasNextPage: $more,
                   endCursor: (if $cursor == "" then null else $cursor end) },
       nodes: $nodes }'
}

# $1 label, $2 expected exit, $3 page1, $4 optional page2
check() {
  local label="$1" expect="$2" p1="$3" p2="${4:-}"
  local status
  set +e
  env PATH="$stub_dir:$PATH" GH_STUB_PAGE1="$p1" GH_STUB_PAGE2="$p2" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
    bash "$script" >"$out" 2>&1
  status=$?
  set -e
  if [ "$status" -eq "$expect" ]; then ok; else
    fail_case "$label: expected exit $expect, got $status: $(cat "$out")"
  fi
}

# --- the gate's two answers ---------------------------------------------------
check "an-unresolved-major-blocks" 1 "$(page false "" "$(thread false Major)")"
check "a-resolved-major-clears" 0 "$(page false "" "$(thread true Major)")"
check "no-threads-at-all-clears" 0 "$(page false "")"

# --- scope: only Major blocks -------------------------------------------------
# Minor and nit findings are real but non-blocking. Blocking on them would make
# the required check unclearable without resolving cosmetic threads, which
# trains contributors to resolve everything on sight, which is exactly the
# behaviour check-dispositions.sh exists to catch.
check "an-unresolved-minor-does-not-block" 0 "$(page false "" "$(thread false Minor)")"
check "an-unresolved-nit-does-not-block" 0 "$(page false "" "$(thread false nit)")"

# --- a thread that is not an ai-review finding at all -------------------------
# Ordinary human review comments share the same thread type. The gate matches
# on the severity marker post-findings.sh writes, so a human thread saying the
# word "Major" is not a finding.
human="$(jq -cn '{isResolved: false, comments: {nodes: [{body: "This looks like a Major problem to me."}]}}')"
check "a-human-thread-is-not-a-finding" 0 "$(page false "" "$human")"

# --- the count in the failure message -----------------------------------------
check "two-unresolved-majors-block" 1 \
  "$(page false "" "$(thread false Major)" "$(thread false Major)")"
if grep -q '2 unresolved Major' "$out"; then ok; else
  fail_case "the failure must say how many findings are open: $(cat "$out")"
fi

# --- pagination, in both directions -------------------------------------------
# A busy pull request must not be read as clean because the finding sat on
# page 2, and must not be read as blocked merely for having a page 2.
check "an-unresolved-major-on-page-two-still-blocks" 1 \
  "$(page true CURSOR1 "$(thread true Major)")" \
  "$(page false "" "$(thread false Major)")"
check "a-multi-page-pull-request-with-nothing-open-clears" 0 \
  "$(page true CURSOR1 "$(thread true Major)")" \
  "$(page false "" "$(thread true Major)")"

# --- required inputs ----------------------------------------------------------
for missing in GH_TOKEN OWNER REPO_NAME PR_NUMBER; do
  set +e
  env PATH="$stub_dir:$PATH" GH_STUB_PAGE1="$(page false "")" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 "$missing=" \
    bash "$script" >"$out" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then ok; else
    fail_case "$missing must be required"
  fi
done
# --- A MID-LOOP FAILURE LEAVES NO TEMP FILE BEHIND ----------------------------
# The pagination loop creates a temp file per iteration and consumes it with
# `mv`. Under `set -e` a failure between those two exits the script with the
# file still on disk, once per failed run, in a long-lived CI runner's temp
# directory.
#
# `mktemp` IS STUBBED rather than pointed at a private TMPDIR. BSD mktemp,
# which is what macOS ships and what a developer running this suite locally
# gets, ignores TMPDIR for a template-less call: the files land in the per-user
# folder regardless, so a TMPDIR-based version of this check silently observed
# an empty directory and passed whether or not the leak existed. It was written
# that way first and caught by mutating the trap back. The stub is also the
# portable choice, since the GNU mktemp on the CI runner does honour TMPDIR and
# the two would otherwise disagree.
leak_dir="$(mktemp -d)"
cat >"$stub_dir/mktemp" <<'MKSTUB'
#!/usr/bin/env bash
# Template-less form only, which is all these scripts use.
f="$MKTEMP_STUB_DIR/t$$-$RANDOM"
: >"$f"
printf '%s\n' "$f"
MKSTUB
chmod +x "$stub_dir/mktemp"

# The second page returns a SUCCESSFUL but unparseable body, which is what an
# API error page or a truncated response looks like from here. It has to be
# this and not a non-zero exit: the temp file is created AFTER the `gh` call,
# so a `gh` that fails never enters the window at all. Only a failure between
# the create and the `mv` leaves a file behind, and `jq` refusing this input is
# exactly that.
set +e
env PATH="$stub_dir:$PATH" MKTEMP_STUB_DIR="$leak_dir" GH_STUB_FAIL2=1 \
  GH_STUB_PAGE1="$(page true CURSOR1 "$(thread false Major)")" \
  GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 \
  bash "$script" >"$out" 2>&1
leak_status=$?
set -e
if [ "$leak_status" -ne 0 ]; then ok; else
  fail_case "an unparseable second page must fail the script, or the leak window is never entered"
fi
leaked="$(find "$leak_dir" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$leaked" = "0" ]; then ok; else
  fail_case "the pagination loop leaked $leaked temp file(s) on a mid-loop failure"
fi
rm -f "$stub_dir/mktemp"
rm -rf "$leak_dir"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
