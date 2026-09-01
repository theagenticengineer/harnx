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
*"-X PATCH"*)
  # The repository merge settings. Captured separately from the protection
  # payload: they are two different writes to two different endpoints, and a
  # test that could not tell them apart could not catch one being sent to the
  # other.
  cat >"$GH_STUB_MERGE_CAPTURED"
  exit 0
  ;;
*apps/github-actions*)
  printf '%s\n' "${GH_STUB_APP_ID-15368}"
  ;;
*branches/*protection*)
  # RUNG read-back: the script asks for the whole protection object here and
  # pipes it through jq itself, rather than for a -q projection.
  if [ -n "${GH_STUB_RUNG_LIVE+set}" ]; then
    printf '%s' "$GH_STUB_RUNG_LIVE"
    exit 0
  fi
  # The main-mode read-back. GH_STUB_LIVE is newline-separated "context|app_id"
  # pairs, exactly the shape the script's own -q template produces. Unset means
  # "the write landed", built from the same list the script requires so a
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
  # Two different reads hit `repos/{owner}/{repo}`, told apart by the jq filter
  # the script asks for: the default branch, and the merge settings read-back.
  case "$*" in
  *default_branch*)
    printf '%s\n' "${GH_STUB_DEFAULT_BRANCH-main}"
    ;;
  *allow_squash_merge*)
    if [ -n "${GH_STUB_MERGE_LIVE+set}" ]; then
      printf '%s' "$GH_STUB_MERGE_LIVE"
    else
      printf '%s' '{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":true}'
    fi
    ;;
  *)
    printf '%s\n' "${GH_STUB_DEFAULT_BRANCH-main}"
    ;;
  esac
  ;;
esac
STUB
chmod +x "$stub_dir/gh"

merge_captured="$stub_dir/merge-payload.json"
log="$(mktemp)"
run() {
  : >"$calls"
  : >"$captured"
  : >"$merge_captured"
  env PATH="$stub_dir:$PATH" GH_STUB_CALLS="$calls" GH_STUB_CAPTURED="$captured" \
    GH_STUB_MERGE_CAPTURED="$merge_captured" \
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

# A dry run now prints MORE THAN ONE JSON block (the merge settings, then the
# branch protection), so a block is selected by index rather than by "from the
# first brace to the end". Taken from the braces rather than by line offset for
# the original reason: the number of status lines printed around them is not
# part of this script's contract and has already changed twice.
payload_of() {
  awk -v want="${2:-1}" '
    /^\{$/ { inblk = 1; n++; buf = "" }
    inblk   { buf = buf $0 "\n" }
    /^\}$/ { if (inblk && n == want) { printf "%s", buf; exit } ; inblk = 0 }
  ' "$1"
}
merge_payload="$(payload_of "$log" 1)"
payload="$(payload_of "$log" 2)"

# --- the merge settings, re-homed from #34, which could only claim them ------
# AGENTS.md and validate-pr-title.sh both assert squash-merge-only, and nothing
# enforced it: verified live before this landed, allow_merge_commit and
# allow_rebase_merge were both true and delete_branch_on_merge was false.
if printf '%s' "$merge_payload" | jq -e '
  .allow_squash_merge == true and .allow_merge_commit == false
  and .allow_rebase_merge == false and .delete_branch_on_merge == true' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "the merge settings must be squash-only with branch deletion on merge: $merge_payload"
fi

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
  payload_of "$log" 2 | jq -e '.required_status_checks.checks | all(.app_id == 4242)' >/dev/null; then
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
# --- the merge settings are READ BACK, like the protection is ----------------
# A 2xx on the PATCH says GitHub accepted the request, not that the setting
# holds. This repository's own claim about squash-only merges was false for
# months while prose asserted it, which is exactly what an unverified write
# looks like from the outside.
if run GH_STUB_MERGE_LIVE='{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":false,"delete_branch_on_merge":true}' \
  >"$log" 2>&1; then
  fail_case "a merge setting that did not take must fail the run"
else
  pass=$((pass + 1))
fi
if grep -q 'allow_merge_commit' "$log"; then
  pass=$((pass + 1))
else
  fail_case "the failure must name which merge setting did not take: $(cat "$log")"
fi
if run GH_STUB_MERGE_LIVE='{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"delete_branch_on_merge":false}' \
  >"$log" 2>&1; then
  fail_case "delete_branch_on_merge not taking must fail the run"
else
  pass=$((pass + 1))
fi

# --- a live run writes the merge settings to the REPOSITORY, not to a branch --
if run >"$log" 2>&1 && [ -s "$merge_captured" ]; then
  pass=$((pass + 1))
else
  fail_case "a live run must PATCH the repository's merge settings: $(cat "$log")"
fi
if grep -q -- '-X PATCH repos/o/r' "$calls"; then
  pass=$((pass + 1))
else
  fail_case "the merge settings must go to the repository endpoint: $(cat "$calls")"
fi

# --- RUNG MODE ---------------------------------------------------------------
# A rung is protected, but not the way a default branch is. Required checks
# block pushes, force-with-lease included, so a rung carrying them gives a
# stacking model only repository admins can operate. harnx generates
# repositories for teams; a ripple rule most contributors cannot execute is
# worse than no rung protection at all.
rung_live='{"required_status_checks":null,"required_pull_request_reviews":null,"enforce_admins":{"enabled":false},"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":false}}'

if run MODE=rung BRANCH=feat-9-something DRY_RUN=1 >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a rung dry run must succeed: $(cat "$log")"
fi
rung_payload="$(payload_of "$log" 1)"
# NO required checks and NO required reviews. These are the two that would make
# a rung unrippleable.
if printf '%s' "$rung_payload" | jq -e '
  .required_status_checks == null and .required_pull_request_reviews == null' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "a rung must carry no required checks and no required reviews: $rung_payload"
fi
# Force pushes ALLOWED: a stacked epic ripples, a ripple is a rebase, and a
# rebase is a force push. A rung that refuses them cannot be a rung.
if printf '%s' "$rung_payload" | jq -e '.allow_force_pushes == true' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "a rung must allow force pushes, or it cannot be rippled: $rung_payload"
fi
# Deletion REFUSED: this is the one thing rung protection actually buys. A rung
# deleted out from under the stack takes every branch above it with it.
if printf '%s' "$rung_payload" | jq -e '.allow_deletions == false' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "a rung must not be deletable: $rung_payload"
fi

# --- rung mode does NOT touch the repository's merge settings ----------------
# They are repository-wide. Protecting one branch must not silently change how
# every pull request in the repository merges.
if run MODE=rung BRANCH=feat-9-something GH_STUB_RUNG_LIVE="$rung_live" >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a live rung run must succeed: $(cat "$log")"
fi
if [ ! -s "$merge_captured" ]; then
  pass=$((pass + 1))
else
  fail_case "rung mode must not write the repository's merge settings"
fi
# And it must target the branch it was given, not the default branch.
if grep -q 'branches/feat-9-something/protection' "$calls"; then
  pass=$((pass + 1))
else
  fail_case "rung mode must target BRANCH, not the default branch: $(cat "$calls")"
fi

# --- rung mode reads its protection back too ---------------------------------
if run MODE=rung BRANCH=feat-9-something \
  GH_STUB_RUNG_LIVE='{"required_status_checks":null,"required_pull_request_reviews":null,"enforce_admins":{"enabled":false},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}' \
  >"$log" 2>&1; then
  fail_case "a rung whose force-push setting did not take must fail"
else
  pass=$((pass + 1))
fi
if run MODE=rung BRANCH=feat-9-something \
  GH_STUB_RUNG_LIVE='{"required_status_checks":null,"required_pull_request_reviews":null,"enforce_admins":{"enabled":false},"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":true}}' \
  >"$log" 2>&1; then
  fail_case "a rung that came back deletable must fail"
else
  pass=$((pass + 1))
fi
# A required check surviving on a rung is the failure that would make the whole
# stack admin-only, so the read-back has to catch it specifically.
if run MODE=rung BRANCH=feat-9-something \
  GH_STUB_RUNG_LIVE='{"required_status_checks":{"contexts":["pre-commit"]},"required_pull_request_reviews":null,"enforce_admins":{"enabled":false},"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":false}}' \
  >"$log" 2>&1; then
  fail_case "a rung that came back carrying required checks must fail"
else
  pass=$((pass + 1))
fi

# --- rung mode refuses to guess which branch ---------------------------------
if run MODE=rung DRY_RUN=1 >"$log" 2>&1; then
  fail_case "MODE=rung with no BRANCH must be refused, not applied to the default branch"
else
  pass=$((pass + 1))
fi
if run MODE=nonsense DRY_RUN=1 >"$log" 2>&1; then
  fail_case "an unknown MODE must be refused rather than silently treated as main"
else
  pass=$((pass + 1))
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
