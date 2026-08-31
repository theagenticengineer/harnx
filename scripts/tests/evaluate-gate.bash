#!/usr/bin/env bash
# Standalone test for scripts/ai-review/evaluate-gate.sh.
# Run: bash scripts/tests/evaluate-gate.bash
#
# This is the logic that decides whether a pull request may merge, and what the
# pull request is told when the answer is no. Three properties are pinned:
#
#   1. A pipeline that did not complete fails the gate. Without this, a review
#      that never ran would reach the finding checks, find no threads, and
#      report a clean pass. That is the fail-open the whole gate exists to
#      avoid, one stage later than require-diff.sh catches it.
#   2. The CAUSE is specific. Every failure used to publish the identical
#      string "The ai-review gate is red.", so a dead engine token and a
#      backlog of undispositioned findings looked the same in the merge box.
#   3. Both sub-checks run even when the first fails, so a pull request with
#      two problems learns about both in one round rather than one per push.
#
# Hermetic: the two sub-checks are stubbed by copying the script under test
# into a scratch directory beside fake siblings, which is what its own
# `$script_dir` lookup resolves against. No network, no API, no `gh`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/evaluate-gate.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="$work/out"
cause_file="$work/cause.txt"
detail_file="$work/detail.txt"

# Rebuilds the scratch directory: the real script plus two stub siblings whose
# exit status and output the caller chooses. `ran-*` marker files record
# whether each stub was actually invoked, which is how the short-circuit case
# below is proved rather than assumed.
setup() {
  local resolved_rc="$1" resolved_out="$2" disp_rc="$3" disp_out="$4"
  rm -rf "$work/scripts"
  mkdir -p "$work/scripts"
  cp "$script" "$work/scripts/evaluate-gate.sh"
  cat >"$work/scripts/check-resolved.sh" <<STUB
#!/usr/bin/env bash
touch "$work/ran-resolved"
printf '%s\n' "$resolved_out"
exit $resolved_rc
STUB
  cat >"$work/scripts/check-dispositions.sh" <<STUB
#!/usr/bin/env bash
touch "$work/ran-dispositions"
printf '%s\n' "$disp_out"
exit $disp_rc
STUB
  chmod +x "$work/scripts"/*.sh
  rm -f "$work/ran-resolved" "$work/ran-dispositions" "$cause_file" "$detail_file"
}

run_gate() {
  local review="$1" post="$2" status
  set +e
  env REVIEW_RESULT="$review" POST_RESULT="$post" \
    GATE_CAUSE_FILE="$cause_file" GATE_DETAIL_FILE="$detail_file" \
    bash "$work/scripts/evaluate-gate.sh" >"$out" 2>&1
  status=$?
  set -e
  printf '%s' "$status"
}

# --- B5: a pipeline that did not complete fails the gate ----------------------
# The load-bearing case, and the one that was untestable while this logic lived
# inline in the workflow YAML.
# A here-doc, not a pipeline: `while read` on the right of a pipe runs in a
# subshell, and the pass/fail counters incremented inside it would be discarded
# when the pipeline exits, so every case would silently count for nothing.
while read -r review post; do
  [ -n "$review" ] || continue
  setup 0 "clean" 0 "clean"
  st="$(run_gate "$review" "$post")"
  if [[ "$st" -eq 1 ]]; then
    pass=$((pass + 1))
  else
    fail_case "review=$review post=$post must fail the gate, got exit $st: $(cat "$out")"
  fi
done <<'PAIRS'
failure success
success failure
cancelled success
skipped skipped
PAIRS

# It must short-circuit, not fall through into the finding checks: with no
# review there are no threads, so those checks would report a clean pass about
# a review that never happened.
setup 0 "clean" 0 "clean"
run_gate failure success >/dev/null
if [ ! -e "$work/ran-resolved" ] && [ ! -e "$work/ran-dispositions" ]; then
  pass=$((pass + 1))
else
  fail_case "a failed pipeline must not run the finding checks at all"
fi
if grep -q 'did not complete' "$cause_file" && grep -q 'review=failure' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "the cause must name the pipeline failure and the job results: $(cat "$cause_file")"
fi

# --- a CONTEXT failure must still publish a verdict --------------------------
# ai-review-resolved is a REQUIRED context. The resolved job used to require
# the context job to have succeeded, so a context failure published no check run
# at all and the pull request sat on "Expected" forever: no red check to read,
# no automatic recovery, and strictly worse than a red gate. Publishing needs
# only the head SHA, which comes from the workflow_run event rather than from
# the context job, so a context failure can and must still be reported.
# REVIEW and POST are reported as SUCCESS here deliberately. With them
# "skipped" the run fails for a second reason too, so removing the context
# check entirely would still fail the gate and the assertion would pin nothing:
# caught by mutating the condition away and watching nothing fail.
setup 0 "ok" 0 "ok"
set +e
env CONTEXT_RESULT=failure REVIEW_RESULT=success POST_RESULT=success \
  GATE_CAUSE_FILE="$cause_file" GATE_DETAIL_FILE="$detail_file" \
  bash "$work/scripts/evaluate-gate.sh" >"$out" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
  pass=$((pass + 1))
else
  fail_case "a failed context job must fail the gate"
fi
if grep -q 'context=failure' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "the cause must name the context job: $(cat "$cause_file")"
fi
# The sub-checks must NOT run: without a pull request number there is nothing
# for them to read, and running them would report "no findings" about a review
# that never happened.
if [ ! -f "$work/ran-resolved" ] && [ ! -f "$work/ran-dispositions" ]; then
  pass=$((pass + 1))
else
  fail_case "a context failure must short-circuit before the sub-checks"
fi
# And the detail must say why publishing at all matters, since the alternative
# looks like success to anyone reading the pull request.
if grep -q "required context" "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "the detail must explain why a broken pipeline still reports"
fi

# An ABSENT CONTEXT_RESULT is treated as success, so a caller that predates the
# variable keeps working rather than reporting a permanent pipeline failure.
setup 0 "ok" 0 "ok"
run_gate success success >/dev/null
if grep -q 'No unresolved Major' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "an absent CONTEXT_RESULT must not be read as a failure: $(cat "$cause_file")"
fi

# --- the green path -----------------------------------------------------------
setup 0 "no unresolved" 0 "all accounted for"
st="$(run_gate success success)"
if [[ "$st" -eq 0 ]]; then
  pass=$((pass + 1))
else
  fail_case "both checks passing must pass the gate, got exit $st: $(cat "$out")"
fi
if [ "$(cat "$cause_file")" = "No unresolved Major ai-review findings." ]; then
  pass=$((pass + 1))
else
  fail_case "a green gate must record a green cause, got: $(cat "$cause_file")"
fi

# --- a disposition backlog is COUNTED, not quoted -----------------------------
# check-dispositions.sh prints one error line per offending finding plus a
# trailing summary, so quoting its first line would name one finding and hide
# that there are eleven more. The count is the number a reader can act on.
backlog=""
for i in 1 2 3; do
  backlog+="::error::resolved Major finding has no disposition: file$i.sh"$'\n'
done
setup 0 "no unresolved" 1 "$backlog"
st="$(run_gate success success)"
if [[ "$st" -eq 1 ]]; then
  pass=$((pass + 1))
else
  fail_case "an undispositioned backlog must fail the gate, got exit $st"
fi
if [ "$(cat "$cause_file")" = "3 resolved Major finding(s) have no disposition." ]; then
  pass=$((pass + 1))
else
  fail_case "the cause must carry the COUNT, got: $(cat "$cause_file")"
fi

# --- an unresolved finding reuses the sub-check's own wording -----------------
setup 1 "::error::2 unresolved Major ai-review finding(s). Resolve each thread on the PR before merging." 0 "ok"
st="$(run_gate success success)"
if [[ "$st" -eq 1 ]] && grep -q '2 unresolved Major' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "an unresolved finding must fail and reuse the check's own line: $(cat "$cause_file")"
fi

# --- the two failure causes must be DISTINGUISHABLE ---------------------------
# The whole point of the change: a dead pipeline and a finding backlog must not
# render as the same sentence.
setup 0 "clean" 1 "::error::resolved Major finding has no disposition: a.sh"
run_gate success success >/dev/null
backlog_cause="$(cat "$cause_file")"
setup 0 "clean" 0 "clean"
run_gate failure skipped >/dev/null
pipeline_cause="$(cat "$cause_file")"
if [ "$backlog_cause" != "$pipeline_cause" ]; then
  pass=$((pass + 1))
else
  fail_case "a pipeline failure and a finding backlog must not share a cause line"
fi

# --- both sub-checks run when the first fails ---------------------------------
# Accumulation, not abort-on-first: otherwise a pull request with both problems
# burns one CI round per problem to discover them.
setup 1 "::error::1 unresolved Major ai-review finding(s)." 1 "::error::resolved Major finding has no disposition: a.sh"
st="$(run_gate success success)"
if [[ "$st" -eq 1 ]]; then
  pass=$((pass + 1))
else
  fail_case "two failing checks must still fail the gate"
fi
if [ -e "$work/ran-resolved" ] && [ -e "$work/ran-dispositions" ]; then
  pass=$((pass + 1))
else
  fail_case "a failing check-resolved must not stop check-dispositions from running"
fi
if grep -q 'unresolved Major' "$detail_file" && grep -q 'has no disposition' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "the detail must carry BOTH checks' output: $(cat "$detail_file")"
fi

# --- broken invocations --------------------------------------------------------
setup 0 "clean" 0 "clean"
set +e
env -u REVIEW_RESULT POST_RESULT=success bash "$work/scripts/evaluate-gate.sh" >"$out" 2>&1
st=$?
set -e
if [[ "$st" -ne 0 ]]; then
  pass=$((pass + 1))
else
  fail_case "a missing REVIEW_RESULT must be refused, not treated as success"
fi

# --- a sub-check that CRASHED is not a finding backlog ------------------------
# A sub-check fails in two completely different ways. It can run to a verdict
# and print an `::error::` line naming what is open, which the contributor can
# act on. Or it can die before reaching a verdict: an unset GH_TOKEN, a token
# missing `issues: read`, a GraphQL error under `set -e`. bash's own
# "parameter null or not set" is not an `::error::` line, so the earlier
# fallback announced a finding backlog for it and sent the contributor looking
# for threads to resolve on a pull request whose problem is a misconfigured
# pipeline. No number of resolutions clears that.
setup 1 "check-resolved.sh: line 21: GH_TOKEN: parameter null or not set" 0 "ok"
if [ "$(run_gate success success)" = "1" ]; then
  pass=$((pass + 1))
else
  fail_case "a crashed check-resolved.sh must still fail the gate"
fi
if grep -q 'without reaching a verdict' "$cause_file" &&
  grep -q 'not a finding backlog' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "a crash must be named as a pipeline failure: $(cat "$cause_file")"
fi
# What the sub-check did manage to say is quoted, so the cause names the real
# problem rather than the category.
if grep -q 'GH_TOKEN' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "the crash cause must quote the sub-check's own output: $(cat "$cause_file")"
fi
if grep -q 'check-resolved.sh' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "the crash cause must name which sub-check died"
fi

setup 0 "ok" 1 "check-dispositions.sh: line 9: GH_TOKEN: parameter null or not set"
if [ "$(run_gate success success)" = "1" ]; then
  pass=$((pass + 1))
else
  fail_case "a crashed check-dispositions.sh must still fail the gate"
fi
if grep -q 'check-dispositions.sh exited non-zero without reaching a verdict' "$cause_file" &&
  ! grep -q 'not properly accounted for' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "a crashed disposition check must not be reported as a backlog: $(cat "$cause_file")"
fi

# The reporting path is unaffected: a real backlog with no per-finding count
# still gets the accounted-for sentence, which is what proves the cases above
# discriminate rather than reclassify everything as a crash.
setup 0 "ok" 1 "::error::a.sh is deferred to #36, which is closed."
if [ "$(run_gate success success)" = "1" ] &&
  grep -q 'not properly accounted for' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "a reported disposition failure must keep its own cause: $(cat "$cause_file")"
fi

# --- a red gate links the page that explains what to do about it -------------
# The gate already enforced the behaviour; what was missing was anywhere
# explaining it. A red required check with no explanation reads as a failure to
# diagnose rather than as a decision pending, and after a refutation or a
# deferral nothing re-runs the pipeline on its own.
setup 0 "ok" 1 "::error::a.sh has no disposition"
run_gate success success >/dev/null
if grep -q 'docs/ai-review.md' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "a red gate's detail must link the resolution protocol: $(cat "$detail_file")"
fi
# The re-run is the single most confusing part, so the detail says it without
# needing the click.
if grep -q 'gh run rerun --failed' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "the detail must say that a refutation or deferral needs a manual re-run"
fi
# An ABSOLUTE url when the environment supplies one: a check run's output is
# markdown, and a repository-relative link in it resolves to nothing.
setup 0 "ok" 1 "::error::a.sh has no disposition"
set +e
env REVIEW_RESULT=success POST_RESULT=success \
  GATE_CAUSE_FILE="$cause_file" GATE_DETAIL_FILE="$detail_file" \
  GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=o/r \
  GITHUB_REF_NAME=trunk \
  bash "$work/scripts/evaluate-gate.sh" >"$out" 2>&1
set -e
if grep -q 'https://github.example/o/r/blob/trunk/docs/ai-review.md' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "the link must be absolute when the run environment supplies one: $(cat "$detail_file")"
fi

# --- the pipeline-failure path links it too ----------------------------------
# That path exits before the finding checks run, so it does not go through the
# same code, and it is the path a contributor hits when the engine token has
# expired: exactly when knowing where to look matters most.
setup 0 "ok" 0 "ok"
run_gate failure success >/dev/null
if grep -q 'docs/ai-review.md' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "a pipeline failure must link the protocol too: $(cat "$detail_file")"
fi

# --- a GREEN gate does not decorate itself with remediation ------------------
# Nothing to resolve, so a link telling the reader how to resolve it is noise,
# and this repository's stated position is that output nobody acts on teaches
# readers to skip the output that matters.
setup 0 "ok" 0 "ok"
run_gate success success >/dev/null
if ! grep -q 'docs/ai-review.md' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "a passing gate must not append remediation text: $(cat "$detail_file")"
fi

# --- DORMANT IS A PASS, and must be distinguishable from broken --------------
# When no reviewer is armed the review job never runs, and a SKIPPED review job
# looks exactly like a FAILED one to the pipeline check: both are "not
# success". Without the probe's verdict an unarmed repository would carry a
# permanently red required check it has no way to clear, which is the opposite
# of what an unarmed floor should do.
setup 0 "ok" 0 "ok"
set +e
env CONFIGURED=false REVIEW_RESULT=skipped POST_RESULT=skipped \
  GATE_CAUSE_FILE="$cause_file" GATE_DETAIL_FILE="$detail_file" \
  bash "$work/scripts/evaluate-gate.sh" >"$out" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail_case "an unarmed repository must PASS dormant, not carry a red gate it cannot clear: $(cat "$out")"
fi
if grep -qi 'dormant' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "the dormant pass must say it is dormant: $(cat "$cause_file")"
fi
# It must NOT read as a broken pipeline, which is the whole distinction.
if ! grep -q 'did not complete' "$cause_file"; then
  pass=$((pass + 1))
else
  fail_case "dormant must not be reported as a pipeline failure: $(cat "$cause_file")"
fi
# And it must say there is nothing for a contributor to do, because arming a
# reviewer is a repository setting a pull request cannot change.
if grep -q 'nothing here for a contributor to fix' "$detail_file"; then
  pass=$((pass + 1))
else
  fail_case "the dormant detail must say a contributor cannot fix it"
fi
# The sub-checks must not run: with no review there are no threads to judge.
if [ ! -f "$work/ran-resolved" ] && [ ! -f "$work/ran-dispositions" ]; then
  pass=$((pass + 1))
else
  fail_case "a dormant gate must not run the sub-checks"
fi

# --- but ARMED and broken is still red ---------------------------------------
# The dormancy must not become a way to pass a broken pipeline.
setup 0 "ok" 0 "ok"
set +e
env CONFIGURED=true REVIEW_RESULT=failure POST_RESULT=skipped \
  GATE_CAUSE_FILE="$cause_file" GATE_DETAIL_FILE="$detail_file" \
  bash "$work/scripts/evaluate-gate.sh" >"$out" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ]; then
  pass=$((pass + 1))
else
  fail_case "an armed pipeline that failed must still be red"
fi
# An ABSENT CONFIGURED behaves as armed, so a caller predating the probe is
# unchanged rather than silently passing everything dormant.
setup 0 "ok" 0 "ok"
if [ "$(run_gate failure success)" = "1" ]; then
  pass=$((pass + 1))
else
  fail_case "an absent CONFIGURED must behave as armed"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
