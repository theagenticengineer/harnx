#!/usr/bin/env bash
# Standalone test for scripts/ai-review/post-findings.sh.
# Run: bash scripts/tests/post-findings.bash
#
# WHAT THIS PROTECTS. post-findings.sh is what turns a review finding into a
# resolvable thread, and a finding it cannot post makes the whole ai-review job
# exit non-zero, which turns the required check red. That is deliberate: an
# untracked finding must never be silently merged past. It also means the
# anchoring logic is load-bearing for merge, so a finding that is merely
# awkward to anchor must not be able to block every pull request that receives
# one.
#
# The cascade is the mechanism, so the cascade is what is pinned here:
#
#   1. the reported line
#   2. line 1 of the same file, skipped when the finding is already at line 1
#   3. the file itself, via subject_type=file, which needs no diff hunk
#
# Step 3 exists because of a real failure: a Minor reported at line 1 skipped
# step 2 (correctly, since retrying the identical anchor fails identically) and
# the single rejected attempt reddened the gate on an unrelated pull request.
#
# `gh` is stubbed on PATH, which makes this hermetic: the script's only side
# effects are API calls, and the stub records which anchor each attempt used
# and decides which attempts GitHub would have accepted.
#
# EVERY BARE HELPER CALL CARRIES `|| true`. This file runs under `set -e`, so a
# bare call to a helper that propagates the tested script's non-zero exit
# ABORTS the suite rather than failing an assertion: no FAIL line, no RESULT
# line, just an exit status that reads like an infrastructure problem. Where
# the exit status IS the assertion, the call sits inside an `if` and needs no
# guard.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/ai-review/post-findings.sh"

# THE KEY IS COMPUTED BY PRODUCTION'S OWN FUNCTION, not re-implemented here.
# These cases assert dedup and relocation-note survival, both of which are
# behaviours ABOUT the key rather than claims about how it is derived; what the
# key must be is finding-key.bash's subject. An earlier version pasted a raw
# `sha256sum` pipe, which meant a change to the normalisation (the case-folding
# and punctuation stripping the real function does) would leave this suite
# green while it silently stopped exercising the paths it names.
#
# THIS IS THE COMMIT THAT OWNS THE REPAIR, not the one that wrote the pipe.
# finding-key.sh does not exist before this commit, so the raw pipe was the
# only thing the earlier suite could have written; extracting the shared
# function here and leaving the test with its own copy is what created the
# divergence. Folding the fix any earlier makes that commit source a file its
# own tree does not contain.
# shellcheck source=scripts/ai-review/finding-key.sh
# shellcheck disable=SC1091  # sourced at runtime; not followed without -x
. "$repo_root/scripts/ai-review/finding-key.sh"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
attempts="$stub_dir/attempts.log"
args_log="$stub_dir/args.log"
payloads="$stub_dir/payloads.log"

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Records one line per comment-posting attempt naming the ANCHOR it used, so
# the cascade's order is observable, and separately dumps every argument AND
# the JSON payload so a body can be inspected. GH_STUB_ALLOW is the
# space-separated set of anchors GitHub would accept; anything outside it
# fails the way a rejected anchor does, with a message on stderr and a
# non-zero exit.
#
# The payload is read from the file named by `--input`, not from argv,
# because that is how the script sends it now: a body assembled into argv
# trips ARG_MAX on a large pull request, and gh's `-F` reads a local file
# when a value begins with `@`.
printf '%s\n' "--- $*" >>"$GH_STUB_ARGS"
payload=""
prev=""
for a in "$@"; do
  [ "$prev" = "--input" ] && payload="$a"
  prev="$a"
done
if [ -n "$payload" ] && [ -f "$payload" ]; then
  # One payload per line, in its own log, so an assertion can read it back
  # with jq without having to skip the argv lines around it.
  jq -c . "$payload" >>"$GH_STUB_PAYLOADS"
fi

case "$*" in
*graphql*)
  # An empty default assigned on its own line, NOT inline as
  # ${GH_STUB_THREADS:-{...}}: bash matches the closing brace of a parameter
  # expansion against the FIRST unescaped one it finds, so a JSON default
  # ends the expansion early and the rest of the object is emitted as
  # literal text after it, producing a payload that parses as garbage.
  threads="${GH_STUB_THREADS:-}"
  [ -n "$threads" ] ||
    threads='{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}'
  printf '%s' "$threads"
  exit 0
  ;;
esac

# A PATCH to pulls/comments/<id> is an UPDATE of a thread that already
# exists, not an anchoring attempt, so it is recorded in the argument log
# above and deliberately not in the attempts log the cascade is asserted on.
case "$*" in
*"-X PATCH"*) exit 0 ;;
esac
case "$*" in
*/comments*) ;;
*)
  exit 0
  ;;
esac

if [ -z "$payload" ] || [ ! -f "$payload" ]; then
  echo "gh: the stub received a comment post with no --input payload" >&2
  exit 1
fi
# GH_STUB_ONLY_PATH mimics GitHub's real behaviour for a file the pull request
# does not touch: every anchor on it is a 422, however it is anchored.
if [ -n "${GH_STUB_ONLY_PATH:-}" ] &&
  [ "$(jq -r '.path // empty' "$payload")" != "$GH_STUB_ONLY_PATH" ]; then
  printf 'rejected\n' >>"$GH_STUB_ATTEMPTS"
  echo "gh: Validation Failed (HTTP 422) for a path outside the diff" >&2
  exit 1
fi
if [ "$(jq -r '.subject_type // empty' "$payload")" = "file" ]; then
  anchor=file
elif [ "$(jq -r '.line // empty' "$payload")" = "1" ] &&
  [ "$(jq -r '.side // empty' "$payload")" = "RIGHT" ]; then
  anchor=line1
else
  anchor=line
fi
printf '%s\n' "$anchor" >>"$GH_STUB_ATTEMPTS"

case " ${GH_STUB_ALLOW:-} " in
*" $anchor "*) exit 0 ;;
esac
echo "gh: Unprocessable Entity (HTTP 422) for the $anchor anchor" >&2
exit 1
STUB
chmod +x "$stub_dir/gh"

findings="$stub_dir/findings.json"
out="$stub_dir/out.txt"

# $1 line number, $2 GH_STUB_ALLOW, $3 optional GH_STUB_THREADS,
# $4 optional side (default RIGHT), $5 optional raw JSON for `line`.
run() {
  local line="$1" allow="$2" threads="${3:-}" side="${4:-RIGHT}" raw_line="${5:-}"
  if [ -n "$raw_line" ]; then
    jq -cn --argjson line "$raw_line" --arg side "$side" \
      '[{file: "scripts/a.sh", line: $line, side: $side, title: "a finding", severity: "Major"}]' >"$findings"
  else
    jq -cn --argjson line "$line" --arg side "$side" \
      '[{file: "scripts/a.sh", line: $line, side: $side, title: "a finding", severity: "Major"}]' >"$findings"
  fi
  : >"$attempts"
  : >"$args_log"
  : >"$payloads"
  env PATH="$stub_dir:$PATH" \
    GH_STUB_ATTEMPTS="$attempts" GH_STUB_ARGS="$args_log" \
    GH_STUB_PAYLOADS="$payloads" \
    GH_STUB_ALLOW="$allow" GH_STUB_THREADS="$threads" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 HEAD_SHA=deadbeef \
    FINDINGS="$findings" bash "$script" >"$out" 2>&1
}

# --- the reported line is tried first, and nothing else is tried when it works
if run 12 "line"; then
  pass=$((pass + 1))
else
  fail_case "a postable finding must exit 0: $(cat "$out")"
fi
if [ "$(cat "$attempts")" = "line" ]; then
  pass=$((pass + 1))
else
  fail_case "an accepted line anchor must be the only attempt, got: $(tr '\n' ',' <"$attempts")"
fi

# --- step 2: line 1 of the same file --------------------------------------
if run 12 "line1"; then
  pass=$((pass + 1))
else
  fail_case "a finding postable at line 1 must exit 0: $(cat "$out")"
fi
if [ "$(tr '\n' ' ' <"$attempts")" = "line line1 " ]; then
  pass=$((pass + 1))
else
  fail_case "the cascade must try the reported line before line 1, got: $(tr '\n' ' ' <"$attempts")"
fi
# The reader has to be able to tell a relocated comment from one that was
# genuinely reported where it sits.
if grep -q 'originally reported at line 12' "$payloads"; then
  pass=$((pass + 1))
else
  fail_case "a comment relocated to line 1 must say where it was reported"
fi

# --- step 3: the file itself ------------------------------------------------
if run 12 "file"; then
  pass=$((pass + 1))
else
  fail_case "a finding postable only at file level must exit 0: $(cat "$out")"
fi
if [ "$(tr '\n' ' ' <"$attempts")" = "line line1 file " ]; then
  pass=$((pass + 1))
else
  fail_case "the cascade order must be line, line 1, file, got: $(tr '\n' ' ' <"$attempts")"
fi
# subject_type=file is rejected by GitHub when line or side is sent with it.
# Read off the payload the stub captured, since the fields no longer travel
# in argv at all.
file_payload="$(grep -F '"subject_type"' "$payloads" | tail -n1 || true)"
if [ -n "$file_payload" ] &&
  printf '%s' "$file_payload" | jq -e 'has("line") | not' >/dev/null &&
  printf '%s' "$file_payload" | jq -e 'has("side") | not' >/dev/null; then
  pass=$((pass + 1))
else
  fail_case "the file-level attempt must send neither line nor side"
fi

# --- THE CASE THAT REDDENED A REAL GATE -------------------------------------
# A finding already at line 1 has no line-1 fallback to fall back to. Before
# the file-level attempt existed, that was one rejected call and then a failed
# job. It must now reach step 3, and it must not waste an attempt re-posting
# the identical line-1 anchor.
if run 1 "file"; then
  pass=$((pass + 1))
else
  fail_case "a line-1 finding must still be postable at file level: $(cat "$out")"
fi
if [ "$(tr '\n' ' ' <"$attempts")" = "line1 file " ]; then
  pass=$((pass + 1))
else
  fail_case "a finding already at line 1 must not retry the same anchor, got: $(tr '\n' ' ' <"$attempts")"
fi

# --- all three failing is still a hard failure ------------------------------
# The cascade widens what can be posted; it does not soften what happens when
# nothing can be. An untracked finding must never report success.
if run 12 ""; then
  fail_case "a finding no anchor could post must exit non-zero"
else
  pass=$((pass + 1))
fi
if [ "$(tr '\n' ' ' <"$attempts")" = "line line1 file " ]; then
  pass=$((pass + 1))
else
  fail_case "every anchor must be tried before giving up, got: $(tr '\n' ' ' <"$attempts")"
fi
# The reason each attempt failed must survive. Discarding it into /dev/null is
# what made "that line is not in the diff" and a 403 from a token missing
# pull-requests: write indistinguishable in the log.
if grep -q 'HTTP 422' "$out"; then
  pass=$((pass + 1))
else
  fail_case "the API's own error must be surfaced, not discarded: $(cat "$out")"
fi
if grep -q 'scripts/a.sh' "$out"; then
  pass=$((pass + 1))
else
  fail_case "the failure must name the file the finding is on"
fi

# --- dedup: a finding already tracked is not posted again -------------------
# The key is a sha256 of "file:normalized title", so it is computed here the
# same way the script computes it rather than hardcoded.
key="$(finding_key "scripts/a.sh" "a finding")"
existing="$(jq -cn --arg m "<!-- ai-review-key:$key -->" --arg sev "Major" '
  { pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [ { id: "T_1", isResolved: false,
               comments: { nodes: [ { databaseId: 7,
                 body: "\($m)\n<!-- ai-review-severity:\($sev) -->\n**[\($sev)]** a finding" } ] } } ] }')"
if run 12 "line" "$existing"; then
  pass=$((pass + 1))
else
  fail_case "a re-run over an already-tracked finding must exit 0: $(cat "$out")"
fi
if [ ! -s "$attempts" ]; then
  pass=$((pass + 1))
else
  fail_case "an already-tracked finding must not be posted again, got: $(tr '\n' ' ' <"$attempts")"
fi

# --- severity is whitelisted, because the marker it lands in gates merge -----
# `<!-- ai-review-severity:X -->` is what check-resolved.sh reads to decide
# which threads block merge. A severity carrying a newline could forge a second
# marker line, so a Major would post under a nit marker and its unresolved
# thread would stop blocking anything. Only the three legal values may reach it;
# anything else fails closed to Major, matching review-engine.sh's own rule
# that an unrecognized severity is the most severe rather than the least
# visible.
severity_case() {
  local raw="$1"
  jq -cn --argjson sev "$raw" \
    '[{file: "scripts/a.sh", line: 12, side: "RIGHT", title: "a finding", severity: $sev}]' >"$findings"
  : >"$attempts"
  : >"$args_log"
  : >"$payloads"
  env PATH="$stub_dir:$PATH" \
    GH_STUB_ATTEMPTS="$attempts" GH_STUB_ARGS="$args_log" \
    GH_STUB_PAYLOADS="$payloads" GH_STUB_ALLOW="line" GH_STUB_THREADS="" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 HEAD_SHA=deadbeef \
    FINDINGS="$findings" bash "$script" >"$out" 2>&1
}

# The three legal values survive untouched.
for sev in Major Minor nit; do
  severity_case "\"$sev\"" || true
  if grep -qF "<!-- ai-review-severity:$sev -->" "$payloads"; then
    pass=$((pass + 1))
  else
    fail_case "severity '$sev' must reach the marker unchanged: $(cat "$payloads")"
  fi
done

# A forged marker inside the severity value must not produce a second marker
# line. This is the attack: post a Major that reads as a nit.
severity_case '"Major\n<!-- ai-review-severity:nit -->"' || true
if [ "$(grep -cF 'ai-review-severity:nit' "$payloads")" = "0" ]; then
  pass=$((pass + 1))
else
  fail_case "a forged severity marker must never reach the comment body: $(cat "$payloads")"
fi
if grep -qF '<!-- ai-review-severity:Major -->' "$payloads"; then
  pass=$((pass + 1))
else
  fail_case "an unusable severity must fail closed to Major: $(cat "$payloads")"
fi
# And it must say so, rather than silently reclassifying.
if grep -q 'unusable severity' "$out"; then
  pass=$((pass + 1))
else
  fail_case "an unusable severity must be reported: $(cat "$out")"
fi

# Non-string severities reach here only from a producer other than the engine,
# which is precisely the case the guard exists for.
for raw in '7' 'null' '{"a":1}' '["Major"]'; do
  severity_case "$raw" || true
  if grep -qF '<!-- ai-review-severity:Major -->' "$payloads"; then
    pass=$((pass + 1))
  else
    fail_case "severity $raw must fail closed to Major: $(cat "$payloads")"
  fi
done

# --- STEP 4: a finding about a file the diff does not touch ------------------
# Every anchor above needs the file to be part of this pull request's diff, and
# GitHub rejects a review comment on any other path with a 422 however it is
# anchored. A description-drift finding is often about exactly such a file
# ("the issue claims work on AGENTS.md and the diff never touches it"), which
# is the most useful thing a drift pass can say. Measured on this pull request:
# the issue-body pass reported precisely that, and the posting failed on it,
# taking the whole job red.
# `${3-default}`, without the colon: an explicitly EMPTY fallback must mean
# "none configured", and `${3:-default}` would substitute the default for it,
# testing the opposite of what the case is named for.
setup_fallback() {
  jq -cn '[{file: "AGENTS.md", line: 1, side: "RIGHT", title: "the issue claims a file the diff never touches", severity: "Major"}]' >"$findings"
  : >"$attempts"
  : >"$args_log"
  : >"$payloads"
  env PATH="$stub_dir:$PATH" \
    GH_STUB_ATTEMPTS="$attempts" GH_STUB_ARGS="$args_log" \
    GH_STUB_PAYLOADS="$payloads" GH_STUB_ALLOW="$1" GH_STUB_THREADS="" \
    GH_STUB_ONLY_PATH="${2:-}" \
    GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 HEAD_SHA=deadbeef \
    ANCHOR_FALLBACK="${3-scripts/in-the-diff.sh}" \
    FINDINGS="$findings" bash "$script" >"$out" 2>&1
}

# GitHub accepts nothing for AGENTS.md and everything for the fallback path,
# which is what the 422 actually looks like.
if setup_fallback "line line1 file" "scripts/in-the-diff.sh"; then pass=$((pass + 1)); else
  fail_case "a finding about a file outside the diff must still be posted: $(cat "$out")"
fi
# It must say which file it is really about, or the thread is unanswerable.
if grep -qF 'AGENTS.md' "$payloads"; then pass=$((pass + 1)); else
  fail_case "the relocated finding must name the file it is about: $(cat "$payloads")"
fi
if grep -qF 'not part of this pull request' "$payloads"; then pass=$((pass + 1)); else
  fail_case "the relocated finding must explain why it is posted elsewhere"
fi
# It stays a resolvable thread, which is what keeps it blocking.
if grep -qF '"subject_type":"file"' "$payloads" || grep -qF '"subject_type": "file"' "$payloads"; then
  pass=$((pass + 1))
else
  fail_case "the fallback must post as a file-level review comment, not an issue comment"
fi
# Without a fallback the behaviour is unchanged: it still fails loudly rather
# than inventing somewhere to put it.
if setup_fallback "line line1 file" "scripts/in-the-diff.sh" ""; then
  fail_case "with no fallback configured, an unpostable finding must still fail"
else
  pass=$((pass + 1))
fi
# And the fallback is a LAST resort: a finding whose own file works must not be
# relocated.
jq -cn '[{file: "scripts/a.sh", line: 12, side: "RIGHT", title: "ordinary", severity: "Major"}]' >"$findings"
: >"$attempts"
: >"$payloads"
env PATH="$stub_dir:$PATH" GH_STUB_ATTEMPTS="$attempts" GH_STUB_ARGS="$args_log" \
  GH_STUB_PAYLOADS="$payloads" GH_STUB_ALLOW="line" GH_STUB_THREADS="" \
  GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 HEAD_SHA=deadbeef \
  ANCHOR_FALLBACK="scripts/in-the-diff.sh" FINDINGS="$findings" bash "$script" >"$out" 2>&1 || true
if ! grep -qF 'in-the-diff.sh' "$payloads"; then pass=$((pass + 1)); else
  fail_case "a finding that anchors normally must not be relocated"
fi

# --- the step 4 note survives a re-review ------------------------------------
# The relocated note is the only sentence saying the thread is about a
# different file than the one it is anchored to. It was missed when step 4 was
# added, and the effect was worse than losing it once: the freshly built body
# never carries the note, so it always differed from the stored one, so every
# re-review updated the comment and stripped it again.
relocated_key="$(finding_key "AGENTS.md" "the issue claims a file the diff never touches")"
relocated_body="<!-- ai-review-key:$relocated_key -->
<!-- ai-review-severity:Major -->
**[Major]** the issue claims a file the diff never touches

(This finding is about \`AGENTS.md\`, which is not part of this pull request's diff, so it cannot be anchored there. It is posted here only so it remains a resolvable thread. Answer it as you would any other finding.)"
existing_relocated="$(jq -cn --arg b "$relocated_body" '
  { pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [ { id: "T_R", isResolved: false,
               comments: { nodes: [ { databaseId: 9, body: $b } ] } } ] }')"

jq -cn '[{file: "AGENTS.md", line: 1, side: "RIGHT", title: "the issue claims a file the diff never touches", severity: "Major"}]' >"$findings"
: >"$attempts"
: >"$payloads"
env PATH="$stub_dir:$PATH" GH_STUB_ATTEMPTS="$attempts" GH_STUB_ARGS="$args_log" \
  GH_STUB_PAYLOADS="$payloads" GH_STUB_ALLOW="line line1 file" \
  GH_STUB_THREADS="$existing_relocated" \
  GH_TOKEN=t OWNER=o REPO_NAME=r PR_NUMBER=1 HEAD_SHA=deadbeef \
  ANCHOR_FALLBACK="scripts/in-the-diff.sh" FINDINGS="$findings" bash "$script" >"$out" 2>&1 || true
# Unchanged content plus a carried note means nothing to update at all.
if [ ! -s "$payloads" ]; then
  pass=$((pass + 1))
else
  fail_case "an unchanged relocated finding must not be rewritten on every pass: $(cat "$payloads")"
fi
if [ ! -s "$attempts" ]; then
  pass=$((pass + 1))
else
  fail_case "an already-threaded relocated finding must not be posted again"
fi

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
