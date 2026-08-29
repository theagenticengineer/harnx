#!/usr/bin/env bash
# Standalone test for scripts/ai-review/configure-environment.sh.
# Run: bash scripts/tests/configure-environment.bash
#
# This script provisions the environment that holds every ai-review credential,
# so the properties worth pinning down are the ones a mistake would quietly
# break:
#
#   - DRY_RUN calls no mutating API at all. A "dry run" that writes is worse
#     than no dry run, because the operator inspects the plan and trusts it.
#   - It refuses a key file that is not a private key, instead of storing the
#     contents of whatever file it was pointed at as the App's key.
#   - It converges: a branch policy that is already present is reported as
#     present rather than added a second time, and one that is NOT on the
#     allow-list is reported for removal.
#
# `gh` is stubbed on PATH. The stub records every call and REFUSES any
# mutating verb, which is what turns "DRY_RUN calls no mutating API" into an
# assertion rather than a claim.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/configure-environment.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
calls="$stub_dir/calls.log"

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_CALLS"
policies="${GH_STUB_POLICIES:-}"
[ -n "$policies" ] || policies='{"branch_policies":[]}'
case "$*" in
  # Any mutating call is a test failure by construction, not a stubbed
  # success: this stub exists to prove the dry run never reaches one.
  # GH_STUB_MUTABLE lifts that refusal for the LIVE-run cases below, which
  # cannot be exercised at all without letting the writes through; the dry-run
  # cases leave it unset, so the assertion they rest on is untouched.
  *"-X PUT"* | *"-X POST"* | *"-X DELETE"* | "secret set"*)
    if [ -z "${GH_STUB_MUTABLE:-}" ]; then
      echo "stub: refusing mutating call: $*" >&2
      exit 90
    fi
    exit 0
    ;;
  *deployment-branch-policies*)
    # GH_STUB_POLICIES_AFTER, when set, is what a LIVE run reads back AFTER its
    # writes, and it is deliberately a separate value from GH_STUB_POLICIES:
    # the read-back only proves anything if the two can disagree. The script
    # reads this endpoint exactly twice in a live run (the convergence snapshot
    # up front, then the verification at the end), so a marker file, not a
    # variable, distinguishes them: each `gh` call is its own process and an
    # exported variable would not survive between them.
    seen="${GH_STUB_CALLS}.policies-read"
    if [ -n "${GH_STUB_POLICIES_AFTER:-}" ] && [ -f "$seen" ]; then
      printf '%s' "$GH_STUB_POLICIES_AFTER"
    else
      : >"$seen"
      printf '%s' "$policies"
    fi
    ;;
  *"-q .default_branch"*)
    printf '%s\n' "${GH_STUB_DEFAULT_BRANCH-}"
    ;;
  *"/secrets"*)
    printf '%s\n' "${GH_STUB_SECRETS:-}"
    ;;
  *)
    printf '%s\n' ''
    ;;
esac
STUB
chmod +x "$stub_dir/gh"

pem="$stub_dir/key.pem"
# The PEM banner is assembled from two halves rather than written as one
# literal. The floor's own secret scanner treats a contiguous
# BEGIN-...-PRIVATE-KEY banner as a leak wherever it appears, source file or
# not, and it is right to: a scanner that could be talked out of it with "but
# this one is a fixture" would be no scanner at all. Splitting it keeps the
# fixture doing its job (the script under test greps for the banner in the
# FILE, which is assembled at run time and does match) without teaching
# anything to ignore a real key.
banner_head='-----BEGIN RSA '
banner_tail='PRIVATE KEY-----'
printf -- '%s%s\nnot-a-real-key\n%s%s\n' \
  "$banner_head" "$banner_tail" '-----END RSA ' "$banner_tail" >"$pem"
notpem="$stub_dir/notes.txt"
printf 'just some text\n' >"$notpem"

log="$(mktemp)"
run() {
  : >"$calls"
  rm -f "$calls.policies-read"
  env PATH="$stub_dir:$PATH" GH_STUB_CALLS="$calls" \
    GITHUB_REPOSITORY=o/r "$@" bash "$script"
}

# --- DRY_RUN is genuinely dry ------------------------------------------------
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a dry run against a stubbed gh should succeed: $(cat "$log")"
fi
if grep -Eq -- '-X (PUT|POST|PATCH|DELETE)' "$calls"; then
  fail_case "DRY_RUN reached a mutating API call"
else
  pass=$((pass + 1))
fi
if grep -q 'DRY_RUN, would set AI_REVIEW_APP_KEY' "$log"; then
  pass=$((pass + 1))
else
  fail_case "a dry run must say which secrets it would set"
fi
# The client id, not the app id: the trunk workflow reads
# secrets.AI_REVIEW_APP_CLIENT_ID, so a rename here without a rename there
# leaves the token-minting step reading an empty value.
if grep -q 'would set AI_REVIEW_APP_CLIENT_ID' "$log"; then
  pass=$((pass + 1))
else
  fail_case "the App identity secret must be AI_REVIEW_APP_CLIENT_ID: $(cat "$log")"
fi
# The whole point of piping the key: its contents must never be printed, not
# even in a preview.
if grep -q 'not-a-real-key' "$log"; then
  fail_case "the private key's contents appeared in the output"
else
  pass=$((pass + 1))
fi

# --- a file that is not a private key is refused -----------------------------
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$notpem" >"$log" 2>&1; then
  fail_case "a non-PEM key file must be refused before anything is stored"
else
  pass=$((pass + 1))
fi
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$stub_dir/absent.pem" >"$log" 2>&1; then
  fail_case "a missing key file must be refused"
else
  pass=$((pass + 1))
fi

# --- a NUMERIC client id is refused ------------------------------------------
# The inverse of the check this replaced, and the reason is the migration
# itself: actions/create-github-app-token now takes the App's client id, an
# `Iv`-prefixed string, where it used to take the numeric app id. Those two
# values sit next to each other on the App's settings page, so passing the old
# one is the obvious mistake, and it would not surface until the credentialed
# job failed to mint a token with a message about an unknown App.
if run DRY_RUN=1 CLIENT_ID=4651823 APP_KEY_PATH="$pem" >"$log" 2>&1; then
  fail_case "a numeric CLIENT_ID is the App's app id, not its client id, and must be refused"
else
  pass=$((pass + 1))
fi
if grep -q "NUMERIC id" "$log"; then
  pass=$((pass + 1))
else
  fail_case "the refusal must say which of the two identifiers was supplied: $(cat "$log")"
fi
# A missing CLIENT_ID is refused before anything is read.
if run DRY_RUN=1 APP_KEY_PATH="$pem" >"$log" 2>&1; then
  fail_case "a missing CLIENT_ID must be refused"
else
  pass=$((pass + 1))
fi

# --- an empty allow-list is refused ------------------------------------------
# An environment with no allowed branch can never release its secrets, so this
# would silently disable the whole pipeline rather than secure it.
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" ALLOWED_BRANCHES=" " >"$log" 2>&1; then
  fail_case "an empty ALLOWED_BRANCHES must be refused"
else
  pass=$((pass + 1))
fi

# --- the default allow-list is a single, conservative branch -----------------
# Not a guess at an epic's trust-anchor name: the allow-list IS the Pattern 1
# mitigation, so shipping an extra default entry would silently widen it in
# every repository that used this script without thinking about it.
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" >"$log" 2>&1 &&
  grep -q 'allowed branches: main$' "$log"; then
  pass=$((pass + 1))
else
  fail_case "the default allow-list must be exactly 'main': $(cat "$log")"
fi

# --- convergence: what is already right is left alone ------------------------
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" ALLOWED_BRANCHES="main,epic-trunk" \
  GH_STUB_POLICIES='{"branch_policies":[{"id":1,"name":"main","type":"branch"}]}' \
  >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a converging dry run should succeed: $(cat "$log")"
fi
if grep -q "branch policy 'main' already present" "$log"; then
  pass=$((pass + 1))
else
  fail_case "an already-present branch policy must be reported as present, not re-added"
fi
if grep -q "would add branch policy 'epic-trunk'" "$log"; then
  pass=$((pass + 1))
else
  fail_case "a missing branch policy must be reported as an addition"
fi

# --- convergence: anything not on the allow-list is reported for removal -----
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" ALLOWED_BRANCHES="main" \
  GH_STUB_POLICIES='{"branch_policies":[{"id":2,"name":"attacker-branch","type":"branch"}]}' \
  >"$log" 2>&1 && grep -q "would REMOVE unlisted branch policy 'attacker-branch'" "$log"; then
  pass=$((pass + 1))
else
  fail_case "a branch policy outside the allow-list must be reported for removal: $(cat "$log")"
fi

# --- the allow-list must contain the LIVE default branch ---------------------
# The trunk workflow is workflow_run-triggered, so GitHub always runs it on the
# default branch. If that name is absent from this list, the server-side policy
# check releases nothing to it and every credentialed job runs with EMPTY
# secrets, with no message anywhere naming the allow-list as the cause. Checked
# before anything is written, so a wrong list costs nothing to discover.
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" ALLOWED_BRANCHES="main" \
  GH_STUB_DEFAULT_BRANCH=epic-trunk >"$log" 2>&1; then
  fail_case "an allow-list missing the live default branch must be refused"
else
  pass=$((pass + 1))
fi
# Naming BOTH values is the point: "the default branch is not allowed" without
# saying which branch is which sends the reader back to the GitHub UI.
if grep -q "epic-trunk" "$log" && grep -q "main" "$log"; then
  pass=$((pass + 1))
else
  fail_case "the refusal must name both the default branch and the allow-list: $(cat "$log")"
fi
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" ALLOWED_BRANCHES="main,epic-trunk" \
  GH_STUB_DEFAULT_BRANCH=epic-trunk >"$log" 2>&1 &&
  grep -q "default branch 'epic-trunk' is on the allow-list" "$log"; then
  pass=$((pass + 1))
else
  fail_case "a default branch that IS on the allow-list must be reported and pass: $(cat "$log")"
fi
# An unreadable default branch is a token or network problem, not a wrong
# allow-list, so it warns instead of blocking a run that may be perfectly fine.
if run DRY_RUN=1 CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" >"$log" 2>&1 &&
  grep -q 'could not read' "$log"; then
  pass=$((pass + 1))
else
  fail_case "an unreadable default branch must warn, not refuse: $(cat "$log")"
fi

# --- a live run verifies the allow-list it just wrote ------------------------
# Every write above is best-effort by design: GitHub rejects a policy for a
# branch that does not exist yet, and aborting there would leave the branches
# that DID configure unset. The cost is that a run can print a converged-looking
# log over a live allow-list that is narrower, or wider, than the one it was
# given. Only a read-back closes that.
live() {
  run CLIENT_ID=Iv23liEXAMPLE0000000 APP_KEY_PATH="$pem" GH_STUB_MUTABLE=1 \
    GH_STUB_DEFAULT_BRANCH=main GH_STUB_SECRETS="AI_REVIEW_ENGINE_TOKEN_CLAUDE" "$@"
}
if live ALLOWED_BRANCHES="main" \
  GH_STUB_POLICIES='{"branch_policies":[]}' \
  GH_STUB_POLICIES_AFTER='{"branch_policies":[{"id":1,"name":"main","type":"branch"}]}' \
  >"$log" 2>&1 && grep -q 'verified live allow-list: main' "$log"; then
  pass=$((pass + 1))
else
  fail_case "a live run whose read-back matches must report it verified: $(cat "$log")"
fi
# The branch GitHub rejected. Today this only warns and the script still exits
# 0, which is exactly the "the secrets are empty in the trunk workflow" symptom
# that can otherwise only be diagnosed after the fact.
if live ALLOWED_BRANCHES="main" \
  GH_STUB_POLICIES='{"branch_policies":[]}' \
  GH_STUB_POLICIES_AFTER='{"branch_policies":[]}' >"$log" 2>&1; then
  fail_case "a branch policy that never landed must fail the run"
else
  pass=$((pass + 1))
fi
if grep -q "'main' is on ALLOWED_BRANCHES but is still absent" "$log"; then
  pass=$((pass + 1))
else
  fail_case "the failure must name the branch that is missing: $(cat "$log")"
fi
# Wider is a failure too, and a more serious one: an allow-list nobody asked
# for is the Pattern 1 mitigation quietly widening.
if live ALLOWED_BRANCHES="main" \
  GH_STUB_POLICIES='{"branch_policies":[]}' \
  GH_STUB_POLICIES_AFTER='{"branch_policies":[{"id":1,"name":"main","type":"branch"},{"id":2,"name":"attacker-branch","type":"branch"}]}' \
  >"$log" 2>&1; then
  fail_case "a live allow-list wider than ALLOWED_BRANCHES must fail the run"
else
  pass=$((pass + 1))
fi
if grep -q "attacker-branch" "$log"; then
  pass=$((pass + 1))
else
  fail_case "the failure must name the branch that should not be there: $(cat "$log")"
fi

rm -f "$log"
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
