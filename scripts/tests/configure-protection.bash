#!/usr/bin/env bash
# Standalone test for scripts/configure-protection.sh.
# Run: bash scripts/tests/configure-protection.bash
#
# WHAT THIS PROTECTS. This script is what arms the default branch, so a defect
# here does not break anything visibly; it quietly leaves the branch less
# protected than the log says it is. Two properties carry that weight:
#
#   - Every required check names the APP allowed to report it. GitHub's
#     deprecated `contexts` form back-fills each check's app from whichever app
#     most recently REPORTED that context, so in a freshly generated
#     repository, where nothing has reported anything, all nine required checks
#     are satisfiable by ANY app. `ai-review-resolved` is the one that makes
#     that concrete: post-check-run.sh publishes it on github.token precisely
#     so it is attributed to GitHub Actions.
#   - The protection is READ BACK. A 2xx on the PUT means GitHub accepted the
#     request, not that the branch now holds what was asked for: an unknown
#     field is ignored rather than rejected, so a renamed API field would leave
#     this script reporting success over a branch with no required checks at
#     all.
#
# `gh` is stubbed on PATH. The stub answers the two reads the script makes, and
# the read-back can be made to disagree with the write, which is the only way
# to assert that the disagreement is caught.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/configure-protection.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
calls="$stub_dir/calls.log"
captured="$stub_dir/payload.json"

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_CALLS"
case "$*" in
*"-X PUT"*)
  cat >"$GH_STUB_CAPTURED"
  exit 0
  ;;
*apps/github-actions*)
  printf '%s\n' "${GH_STUB_APP_ID-15368}"
  ;;
*branches/*protection*)
  # The read-back. GH_STUB_LIVE is newline-separated "context|app_id" pairs,
  # exactly the shape the script's own -q template produces. Unset means "the
  # write landed", which is built from the same list the script requires so a
  # future check added to the floor does not need this stub edited.
  if [ -n "${GH_STUB_LIVE+set}" ]; then
    printf '%s\n' "$GH_STUB_LIVE"
  else
    for c in pre-commit gitleaks actionlint shell-tests commitlint \
      branch-name pr-title pr-body ai-review-resolved; do
      printf '%s|%s\n' "$c" "${GH_STUB_APP_ID-15368}"
    done
  fi
  ;;
*)
  printf '%s\n' "${GH_STUB_DEFAULT_BRANCH-main}"
  ;;
esac
STUB
chmod +x "$stub_dir/gh"

log="$(mktemp)"
run() {
  : >"$calls"
  : >"$captured"
  env PATH="$stub_dir:$PATH" GH_STUB_CALLS="$calls" GH_STUB_CAPTURED="$captured" \
    GITHUB_REPOSITORY=o/r "$@" bash "$script"
}

# --- DRY_RUN is genuinely dry ------------------------------------------------
if run DRY_RUN=1 >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a dry run against a stubbed gh should succeed: $(cat "$log")"
fi
if grep -Eq -- '-X (PUT|POST|PATCH|DELETE)' "$calls"; then
  fail_case "DRY_RUN reached a mutating API call"
else
  pass=$((pass + 1))
fi

# The payload is the JSON block, taken from its opening brace rather than by
# line offset: the number of status lines printed before it is not part of
# this script's contract and has already changed once.
payload_of() { sed -n '/^{$/,$p' "$1"; }
payload="$(payload_of "$log")"

# --- the payload uses `checks`, not the deprecated `contexts` ----------------
if printf '%s' "$payload" | jq -e '.required_status_checks | has("checks")' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "required_status_checks must carry a checks array: $payload"
fi
if printf '%s' "$payload" | jq -e '.required_status_checks | has("contexts") | not' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "the deprecated contexts list must not be sent alongside checks"
fi
# All nine, so a check silently dropped from the floor set is caught here.
if [ "$(printf '%s' "$payload" | jq '.required_status_checks.checks | length')" = "9" ]; then
  pass=$((pass + 1))
else
  fail_case "the floor requires nine checks, payload had $(printf '%s' "$payload" | jq '.required_status_checks.checks | length')"
fi
# --- EVERY entry names the app; a null app_id is the defect being closed ------
if printf '%s' "$payload" |
  jq -e '.required_status_checks.checks | all(.app_id == 15368)' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "every required check must pin the GitHub Actions app id"
fi
if printf '%s' "$payload" |
  jq -e '[.required_status_checks.checks[].context] | index("ai-review-resolved")' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "ai-review-resolved must be among the required checks"
fi
# The id comes from the API, not from a constant: hardcoding it is silently
# wrong on GitHub Enterprise Server, where app ids are per-instance.
if run DRY_RUN=1 GH_STUB_APP_ID=4242 >"$log" 2>&1 &&
  payload_of "$log" | jq -e '.required_status_checks.checks | all(.app_id == 4242)' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "the app id must come from /apps/github-actions, not a constant"
fi
# An unresolvable app id must refuse, not fall back to "any app may report".
if run DRY_RUN=1 GH_STUB_APP_ID="" >"$log" 2>&1; then
  fail_case "an unresolvable app id must be refused"
else
  pass=$((pass + 1))
fi
if run DRY_RUN=1 GH_STUB_APP_ID="not-a-number" >"$log" 2>&1; then
  fail_case "a non-numeric app id must be refused"
else
  pass=$((pass + 1))
fi

# --- the branch is read live, never hardcoded to main ------------------------
if run DRY_RUN=1 GH_STUB_DEFAULT_BRANCH=trunk >"$log" 2>&1 &&
  grep -q "default branch, 'trunk'" "$log"; then
  pass=$((pass + 1))
else
  fail_case "the target branch must be the repository's live default: $(cat "$log")"
fi

# --- a live run writes, then verifies what it wrote --------------------------
if run >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a live run whose read-back agrees should succeed: $(cat "$log")"
fi
if grep -q -- '-X PUT' "$calls"; then
  pass=$((pass + 1))
else
  fail_case "a live run must actually PUT the protection"
fi
# The payload that reached the API is the same shape the dry run previewed.
if jq -e '.required_status_checks.checks | length == 9 and all(.app_id == 15368)' "$captured" >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "the live payload must carry the same nine app-pinned checks"
fi
if grep -q 'verified live' "$log"; then
  pass=$((pass + 1))
else
  fail_case "a live run must report what it read back: $(cat "$log")"
fi

# --- the read-back is what makes success mean something ----------------------
# A branch that accepted the write but holds fewer checks than were asked for
# is the failure mode this exists for, and it is invisible without a read.
if run GH_STUB_LIVE="pre-commit|15368" >"$log" 2>&1; then
  fail_case "a read-back missing eight required checks must fail"
else
  pass=$((pass + 1))
fi
if grep -q 'ai-review-resolved' "$log"; then
  pass=$((pass + 1))
else
  fail_case "the failure must name the checks that are missing: $(cat "$log")"
fi
# Present under the WRONG app is not present. This is the exact state the
# deprecated contexts form leaves behind in a fresh repository.
live_wrong=""
for c in pre-commit gitleaks actionlint shell-tests commitlint \
  branch-name pr-title pr-body ai-review-resolved; do
  live_wrong="${live_wrong}${c}|null
"
done
if run GH_STUB_LIVE="$live_wrong" >"$log" 2>&1; then
  fail_case "checks satisfiable by any app must not be reported as verified"
else
  pass=$((pass + 1))
fi
# An empty read-back (a renamed field, or a protection that never landed) must
# fail rather than report green over nothing.
if run GH_STUB_LIVE="" >"$log" 2>&1; then
  fail_case "an empty read-back must fail, not pass vacuously"
else
  pass=$((pass + 1))
fi

rm -f "$log"
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
