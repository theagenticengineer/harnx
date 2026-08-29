#!/usr/bin/env bash
# Standalone test for scripts/ai-review/resolve-pr-context.sh.
# Run: bash scripts/tests/resolve-pr-context.bash
#
# What matters here is not that the script finds A number, but that it refuses
# to invent one. Everything downstream splices its answer straight into an API
# path, so a wrong or empty value posts one pull request's review onto another,
# or onto nothing at all. The cases below cover both sources it is allowed to
# use, and the refusal when neither answers.
#
# `gh` is stubbed on PATH so the API-fallback path is exercised without a
# network call.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/resolve-pr-context.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# The stub answers with whatever GH_STUB_PULLS holds, so one stub covers "the
# commit belongs to an open pull request", "it belongs to a closed one", and
# "it belongs to none". The real script asks with `-q`, so the stub applies the
# same jq filter the real gh would.
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
filter=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-q" ] && filter="$arg"
  prev="$arg"
done
# `pulls/<n>` (no trailing path) is the payload-verification lookup; anything
# else is the commits/{sha}/pulls resolution. The verification lookup fetches
# the WHOLE pull request payload now, not just `-q .head.sha`, because the
# primary path checks the state as well as the head.
# GH_STUB_PAYLOAD_HEAD is what the named pull request's head resolves to and
# GH_STUB_PAYLOAD_STATE its state.
case "$*" in
  *"/pulls/"*)
    jq -cn --arg h "${GH_STUB_PAYLOAD_HEAD-deadbeef}" \
      --arg s "${GH_STUB_PAYLOAD_STATE-open}" \
      --arg b "${GH_STUB_PAYLOAD_BASE-trunk}" \
      '{state: $s, head: {sha: $h}, base: {ref: $b}}'
    exit 0
    ;;
esac
printf '%s' "${GH_STUB_PULLS:-[]}" | jq -r "$filter"
STUB
chmod +x "$stub_dir/gh"

run() {
  local outfile="$1"
  shift
  env PATH="$stub_dir:$PATH" \
    GH_TOKEN=t OWNER=o REPO_NAME=r HEAD_SHA=deadbeef \
    GITHUB_OUTPUT="$outfile" "$@" bash "$script"
}

log="$(mktemp)"

# --- the payload's own number, when GitHub supplied one ----------------------
gh_out="$(mktemp)"
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER=42 >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a payload-supplied pull request number should resolve: $(cat "$log")"
fi
if grep -Fxq 'pr=42' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "the payload's number must be written to GITHUB_OUTPUT verbatim"
fi

# --- the payload's number is verified against the reviewed commit ------------
# One branch can carry more than one open pull request, and pull_requests[0] is
# an ordering GitHub chose, not a statement about which one this run reviewed.
# A payload naming a pull request whose head is some other commit must be
# ignored, not trusted, or the verdict lands on the wrong pull request.
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER=42 GH_STUB_PAYLOAD_HEAD=cafebabe \
  GH_STUB_PULLS='[{"state":"open","number":77,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}}]' >"$log" 2>&1 &&
  grep -Fxq 'pr=77' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "a payload number whose head is a different commit must be ignored: $(cat "$log")"
fi
if grep -q 'ignoring it and resolving from the commit' "$log"; then
  pass=$((pass + 1))
else
  fail_case "the mismatch must be reported, not silently corrected"
fi

# --- the API fallback, which is the fork case --------------------------------
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= \
  GH_STUB_PULLS='[{"state":"open","number":77,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}}]' >"$log" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "an empty payload number must fall back to the API: $(cat "$log")"
fi
if grep -Fxq 'pr=77' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "the API's answer must be written to GITHUB_OUTPUT"
fi

# --- a closed pull request is not an answer ----------------------------------
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= \
  GH_STUB_PULLS='[{"state":"closed","number":88,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}}]' >"$log" 2>&1; then
  fail_case "a closed pull request must not be resolved into; a review would post onto a merged PR"
else
  pass=$((pass + 1))
fi
if grep -q 'pr=' "$gh_out"; then
  fail_case "nothing must be written to GITHUB_OUTPUT when resolution failed"
else
  pass=$((pass + 1))
fi

# --- an open one is still picked when a closed one is listed alongside it ----
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= \
  GH_STUB_PULLS='[{"state":"closed","number":88,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}},{"state":"open","number":99,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}}]' \
  >"$log" 2>&1 && grep -Fxq 'pr=99' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "the open pull request must be selected out of a mixed list: $(cat "$log")"
fi

# --- a commit that is only an ANCESTOR of an open PR is not its head ---------
# The endpoint answers "which pull requests is this commit associated with",
# which is a wider question than "which pull request has this commit as its
# head". Reviewing the wider answer would post onto a pull request whose
# current head is some later commit entirely.
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= \
  GH_STUB_PULLS='[{"state":"open","number":55,"head":{"sha":"cafebabe"},"base":{"ref":"trunk"}}]' >"$log" 2>&1; then
  fail_case "a PR whose head is a different commit must not be resolved into"
else
  pass=$((pass + 1))
fi

# --- two open PRs sharing a head commit are refused, not guessed between -----
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= \
  GH_STUB_PULLS='[{"state":"open","number":11,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}},{"state":"open","number":12,"head":{"sha":"deadbeef"},"base":{"ref":"trunk"}}]' \
  >"$log" 2>&1; then
  fail_case "an ambiguous head commit must be refused, not resolved to whichever GitHub listed first"
else
  pass=$((pass + 1))
fi
if grep -q 'more than one open pull request' "$log"; then
  pass=$((pass + 1))
else
  fail_case "the ambiguity error must say what was ambiguous: $(cat "$log")"
fi

# --- neither source answers ---------------------------------------------------
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= GH_STUB_PULLS='[]' >"$log" 2>&1; then
  fail_case "no resolvable pull request must be an error, never a silent empty value"
else
  pass=$((pass + 1))
fi

# --- a non-numeric payload value is refused rather than spliced into a path ---
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER='1;rm' >"$log" 2>&1; then
  fail_case "a non-numeric pull request number must be refused"
else
  pass=$((pass + 1))
fi

# --- the payload names a pull request that is no longer open -----------------
# The fallback path always filtered on `state == "open"`; the primary path did
# not. The workflow_run payload is a snapshot from when the triggering run
# started, so a pull request closed or merged in the interim is still named
# there, and a review posted onto it lands where nobody is looking while the
# gate is computed from its threads.
for state in closed merged; do
  : >"$gh_out"
  if run "$gh_out" EVENT_PR_NUMBER=42 GH_STUB_PAYLOAD_STATE="$state" \
    GH_STUB_PULLS='[]' >"$log" 2>&1; then
    fail_case "a $state pull request named by the payload must not be resolved into"
  else
    pass=$((pass + 1))
  fi
  if grep -q "not open" "$log"; then
    pass=$((pass + 1))
  else
    fail_case "the refusal must say the payload's pull request was not open: $(cat "$log")"
  fi
done

# The head check and the state check are independent, so a still-open pull
# request whose head matches must still resolve through the primary path. This
# is what proves the cases above fail on the state rather than on the stub.
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER=42 GH_STUB_PAYLOAD_STATE=open >"$log" 2>&1 &&
  grep -q '^pr=42$' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "an open payload-named pull request must still resolve: $(cat "$log")"
fi

# --- the base branch is resolved and refused when absent ----------------------
# extract-diff.sh recomputes the reviewed diff on the trusted side and diffs
# against this branch. An empty value would be handed straight to `git fetch`,
# so it is refused here rather than failing somewhere far less legible, and a
# review computed against the wrong base is a review of the wrong thing.
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER=42 GH_STUB_PAYLOAD_BASE=some-base >"$log" 2>&1 &&
  grep -q '^base=some-base$' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "the base branch must be written to GITHUB_OUTPUT: $(cat "$gh_out")"
fi
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER=42 GH_STUB_PAYLOAD_BASE= >"$log" 2>&1; then
  fail_case "a pull request with no resolvable base must be refused"
else
  pass=$((pass + 1))
fi
# The fallback path resolves it too, from the same server-side payload.
: >"$gh_out"
if run "$gh_out" EVENT_PR_NUMBER= \
  GH_STUB_PULLS='[{"state":"open","number":77,"head":{"sha":"deadbeef"},"base":{"ref":"other-base"}}]' \
  >"$log" 2>&1 && grep -q '^base=other-base$' "$gh_out"; then
  pass=$((pass + 1))
else
  fail_case "the API fallback must resolve the base branch too: $(cat "$gh_out")"
fi

rm -f "$log" "$gh_out"
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
