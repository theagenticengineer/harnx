#!/usr/bin/env bash
# Standalone test for scripts/ai-review/post-check-run.sh.
# Run: bash scripts/tests/post-check-run.bash
#
# The script under test is what puts the ai-review-resolved verdict back onto
# the pull request, so the two things asserted here are the two that decide
# whether branch protection ever sees it: the check run's NAME and its
# CONCLUSION reach the API unaltered, and a conclusion the API would reject is
# refused here instead of one layer down.
#
# `gh` is stubbed on PATH. That is what makes this test hermetic: the real
# script's only side effect is one API call, and the stub captures the exact
# JSON body it would have sent.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/post-check-run.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

stub_dir="$(mktemp -d)"
captured="$stub_dir/payload.json"
cat >"$stub_dir/gh" <<STUB
#!/usr/bin/env bash
# Stub: records the JSON body piped to \`gh api --input -\`.
cat >"$captured"
STUB
chmod +x "$stub_dir/gh"
trap 'rm -rf "$stub_dir"' EXIT

run() {
  # Deliberately not exported into this test's own shell: each case gets its
  # own environment so a leftover SUMMARY or DETAILS_URL cannot leak forward.
  env PATH="$stub_dir:$PATH" \
    GH_TOKEN=t OWNER=o REPO_NAME=r HEAD_SHA=deadbeef \
    CHECK_NAME=ai-review-resolved "$@" bash "$script"
}

# --- a green verdict ---------------------------------------------------------
out="$(mktemp)"
if run CONCLUSION=success DETAILS_URL=https://example.test/run >"$out" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a success conclusion should exit 0: $(cat "$out")"
fi
if [ "$(jq -r '.name' "$captured")" = "ai-review-resolved" ]; then
  pass=$((pass + 1))
else
  fail_case "the check run name must reach the API verbatim"
fi
if [ "$(jq -r '.conclusion' "$captured")" = "success" ]; then
  pass=$((pass + 1))
else
  fail_case "a success conclusion must be reported as success"
fi
if [ "$(jq -r '.head_sha' "$captured")" = "deadbeef" ]; then
  pass=$((pass + 1))
else
  fail_case "the check run must anchor to the head SHA it was given"
fi
if [ "$(jq -r '.status' "$captured")" = "completed" ]; then
  pass=$((pass + 1))
else
  fail_case "a check run carrying a conclusion must be status=completed"
fi
if [ "$(jq -r '.details_url' "$captured")" = "https://example.test/run" ]; then
  pass=$((pass + 1))
else
  fail_case "DETAILS_URL must be passed through when set"
fi

# --- a red verdict -----------------------------------------------------------
if run CONCLUSION=failure >"$out" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a failure conclusion is a normal outcome and must still exit 0: $(cat "$out")"
fi
if [ "$(jq -r '.conclusion' "$captured")" = "failure" ]; then
  pass=$((pass + 1))
else
  fail_case "a failure conclusion must be reported as failure"
fi
# Absent, not empty-string: the API rejects an empty details_url outright.
if [ "$(jq -r 'has("details_url")' "$captured")" = "false" ]; then
  pass=$((pass + 1))
else
  fail_case "details_url must be omitted entirely when DETAILS_URL is unset"
fi

# --- the failure TITLE carries the cause --------------------------------------
# The title is the only part of a check run GitHub renders in the merge box.
# It used to be the fixed sentence "The ai-review gate is red.", so a dead
# engine token and a disposition backlog were indistinguishable without
# opening the workflow logs. These cases pin the two apart.
if run CONCLUSION=failure SUMMARY="12 resolved Major finding(s) have no disposition." >"$out" 2>&1; then
  pass=$((pass + 1))
else
  fail_case "a failure carrying a cause must still exit 0: $(cat "$out")"
fi
if [ "$(jq -r '.output.title' "$captured")" = "12 resolved Major finding(s) have no disposition." ]; then
  pass=$((pass + 1))
else
  fail_case "SUMMARY must become the failure title, got: $(jq -r '.output.title' "$captured")"
fi
run CONCLUSION=failure \
  SUMMARY="The review pipeline did not complete (review=failure, post-findings=skipped), so the review never ran." >"$out" 2>&1
if [ "$(jq -r '.output.title' "$captured")" != "12 resolved Major finding(s) have no disposition." ]; then
  pass=$((pass + 1))
else
  fail_case "two different causes must produce two different titles"
fi
# The fallback survives for a caller that computed no cause.
run CONCLUSION=failure >"$out" 2>&1
if [ "$(jq -r '.output.title' "$captured")" = "The ai-review gate is red." ]; then
  pass=$((pass + 1))
else
  fail_case "with no SUMMARY the failure title must fall back to the fixed sentence"
fi
# A success title is deliberately NOT taken from SUMMARY: there is only one
# way to be green, so the title is fixed and the cause line would add nothing.
run CONCLUSION=success SUMMARY="something else entirely" >"$out" 2>&1
if [ "$(jq -r '.output.title' "$captured")" = "No unresolved Major ai-review findings." ]; then
  pass=$((pass + 1))
else
  fail_case "a success title must stay fixed regardless of SUMMARY"
fi
# The API rejects a title over 255 characters, and a cause built from a
# check's own output has no guaranteed length. A failed publish would leave
# the required context unreported and block the pull request on nothing.
run CONCLUSION=failure SUMMARY="$(printf 'x%.0s' $(seq 1 400))" >"$out" 2>&1
title_len="$(jq -r '.output.title | length' "$captured")"
if [ "$title_len" -le 255 ]; then
  pass=$((pass + 1))
else
  fail_case "an over-long cause must be truncated to 255, got $title_len"
fi

# --- TEXT becomes the expandable body, and is omitted when empty --------------
run CONCLUSION=failure SUMMARY="a cause" TEXT="line one
line two" >"$out" 2>&1
if [ "$(jq -r '.output.text' "$captured")" = "line one
line two" ]; then
  pass=$((pass + 1))
else
  fail_case "TEXT must reach output.text intact, newlines included"
fi
# Absent, not empty-string: an empty text renders as an empty section rather
# than as no section, so "nothing to show" would look like "a blank detail".
run CONCLUSION=failure SUMMARY="a cause" >"$out" 2>&1
if [ "$(jq -r '.output | has("text")' "$captured")" = "false" ]; then
  pass=$((pass + 1))
else
  fail_case "output.text must be omitted entirely when TEXT is unset"
fi
# Adding text must not drop the fields it sits beside.
run CONCLUSION=failure SUMMARY="a cause" TEXT="detail" >"$out" 2>&1
if [ "$(jq -r '.output.title' "$captured")" = "a cause" ] &&
  [ "$(jq -r '.output.summary' "$captured")" = "a cause" ] &&
  [ "$(jq -r '.conclusion' "$captured")" = "failure" ]; then
  pass=$((pass + 1))
else
  fail_case "adding output.text must not displace title, summary or conclusion"
fi

# --- summary and text are bounded before they are sent ------------------------
# The Checks API rejects the whole request when output.summary or output.text
# exceeds 65535 characters. A rejected publish leaves the required
# ai-review-resolved context unreported and blocks the pull request on nothing
# at all, which is strictly worse than a clipped field. Neither is a sentence
# somebody wrote: both are assembled from a failing check's own output, so
# neither has a bounded length. Built with head/tr rather than a `seq` loop,
# which is measurably slow at this size.
huge="$(head -c 70000 /dev/zero | tr '\0' 'x')"
run CONCLUSION=failure SUMMARY="$huge" >"$out" 2>&1
summary_len="$(jq -r '.output.summary | length' "$captured")"
if [ "$summary_len" -le 65535 ]; then
  pass=$((pass + 1))
else
  fail_case "an over-long summary must be clamped to 65535, got $summary_len"
fi
# Visibly truncated, not silently cut: a reader has to be able to tell "this
# is the whole detail" from "this is as much of it as fitted".
if jq -r '.output.summary' "$captured" | grep -q 'truncated here'; then
  pass=$((pass + 1))
else
  fail_case "a clamped summary must say that it was clamped"
fi
run CONCLUSION=failure SUMMARY="a cause" TEXT="$huge" >"$out" 2>&1
text_len="$(jq -r '.output.text | length' "$captured")"
if [ "$text_len" -le 65535 ]; then
  pass=$((pass + 1))
else
  fail_case "an over-long text must be clamped to 65535, got $text_len"
fi
if jq -r '.output.text' "$captured" | grep -q 'truncated here'; then
  pass=$((pass + 1))
else
  fail_case "a clamped text must say that it was clamped"
fi
# The clamp must not touch a field that fits, and must not resurrect the
# empty-text case the omission rule exists for.
run CONCLUSION=failure SUMMARY="a cause" TEXT="short detail" >"$out" 2>&1
if [ "$(jq -r '.output.text' "$captured")" = "short detail" ]; then
  pass=$((pass + 1))
else
  fail_case "a text within the limit must reach the API unaltered"
fi
run CONCLUSION=failure SUMMARY="a cause" TEXT="" >"$out" 2>&1
if [ "$(jq -r '.output | has("text")' "$captured")" = "false" ]; then
  pass=$((pass + 1))
else
  fail_case "clamping must not turn an empty TEXT into a present, empty output.text"
fi

# --- refusals ----------------------------------------------------------------
if run CONCLUSION=neutral >"$out" 2>&1; then
  fail_case "an unsupported conclusion must be refused, not forwarded"
else
  pass=$((pass + 1))
fi
if env PATH="$stub_dir:$PATH" GH_TOKEN=t OWNER=o REPO_NAME=r HEAD_SHA=x \
  CONCLUSION=success bash "$script" >"$out" 2>&1; then
  fail_case "a missing CHECK_NAME must be refused: the required context would never report"
else
  pass=$((pass + 1))
fi
rm -f "$out"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
