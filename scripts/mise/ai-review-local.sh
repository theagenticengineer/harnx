#!/usr/bin/env bash
set -euo pipefail

# THE ENGINE TOKEN IS NOT CLAUDE CODE'S OWN CREDENTIAL, and the two must not
# share a variable name. CLAUDE_CODE_OAUTH_TOKEN is what the Claude Code CLI
# ITSELF authenticates with, so exporting it in a shell profile, which is what
# this script used to instruct, silently replaces the operator's saved login
# for every Claude Code session started from that shell. The observed symptom
# was a session that had lost capabilities its saved login carried, with
# nothing anywhere connecting that to a review-tooling instruction. harnx
# reproduces this floor into every repository it generates, so the instruction
# would have shipped everywhere.
#
# Deliberately NO fallback to the old name. A fallback would keep the hazard
# alive, which is the entire thing being removed. Its presence is warned about
# instead, because an operator who exported it once will otherwise never learn
# why their Claude Code sessions changed.
#
# review-engine.sh still sets CLAUDE_CODE_OAUTH_TOKEN, and must: it is a
# per-process assignment scoped to the `claude` invocation itself, never
# exported into the operator's shell, and it is how the CLI is meant to be fed.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "ai-review:local: WARNING: CLAUDE_CODE_OAUTH_TOKEN is set in this environment." >&2
  echo "  That is the variable the Claude Code CLI authenticates with, so an exported" >&2
  echo "  value silently overrides your saved login in every Claude Code session started" >&2
  echo "  from this shell. This script does not read it. Unset it, and export the token" >&2
  echo "  as AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN instead." >&2
fi
# AN ABSENT TOKEN IS NOT AN ERROR HERE, and this is the difference between the
# local runner and CI. The `claude` CLI authenticates from `~/.claude` on a
# developer machine, and an EMPTY value is exactly what makes it fall back to
# that login. CI genuinely needs the environment-scoped secret, because a runner
# has no `~/.claude`; a contributor does not, and requiring one added a setup
# step to every contributor and to every repository harnx generates, for a
# credential they already have.
#
# The variable is still READ, and still under the AI_REVIEW_ name, so an
# operator who does export one gets that token used. What changed is only that
# not exporting one now means "use my login" instead of "refuse to run".
tok="${AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN:-}"
if [ -z "$tok" ]; then
  echo "ai-review:local: no AI_REVIEW_CLAUDE_CODE_OAUTH_TOKEN set; using the claude CLI's own login from ~/.claude."
fi

# THE DEFAULT BASE IS THE REMOTE'S DEFAULT BRANCH, RESOLVED LIVE, not the
# literal "origin/main" this used to assume. Those are not the same branch:
# during an epic that promotes a trust anchor to default, `main` is the empty
# root commit, so an unset BASE diffed the ENTIRE repository and submitted all
# of it for review on every default run.
#
# `git ls-remote --symref` rather than `git symbolic-ref refs/remotes/origin/HEAD`:
# the latter is a local cache written at clone time and is not updated when the
# remote's default branch changes, which is exactly the situation this fix is
# about. Verified live: it still answered `origin/main` long after the default
# had moved.
resolve_default_base() {
  git ls-remote --symref origin HEAD 2>/dev/null |
    awk '$1 == "ref:" { sub(/^refs\/heads\//, "", $2); print "origin/" $2; exit }'
}
base="${BASE:-}"
if [ -z "$base" ]; then
  base="$(resolve_default_base)"
  if [ -z "$base" ]; then
    echo "ai-review:local: could not resolve origin's default branch; pass BASE=origin/<branch> explicitly." >&2
    exit 1
  fi
  echo "ai-review:local: BASE not set; using origin's default branch, $base."
fi

diff_file="$(mktemp)"
out="$(mktemp)"
idx="$(mktemp)"
# The HANDLED memory handed to the engine, written from the VALIDATED ledger
# content below rather than pointing at the ledger file itself. See the
# assignment for why the difference matters.
handled_file="$(mktemp)"
trap 'rm -f "$diff_file" "$out" "$idx" "$handled_file"' EXIT

# Build the FULL working-tree content as a real git tree object up front:
# HEAD plus every staged, unstaged, AND untracked change, via `git add -A`
# into a throwaway index (never touches the real index). This tree, not the
# plain working tree via `git diff "$base"` (what an earlier version of this
# script used), is what BOTH the diff sent for review and the "reviewed"
# hash recorded at the end are computed from, reusing the exact same
# variable for both. That makes it structurally impossible for the two to
# diverge: `git diff` never shows an untracked file's content regardless of
# what it is diffed against, while the reviewed-tree hash (via this same
# `git add -A` pattern) always included it, so an untracked file's content
# could previously be recorded as "reviewed" and pass the pre-push gate
# without ever actually being sent to the model. Diffing `$base` against
# this tree object instead of the working tree closes that gap.
GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null || true
GIT_INDEX_FILE="$idx" git add -A 2>/dev/null || true
current_tree="$(GIT_INDEX_FILE="$idx" git write-tree)"

# THREE-DOT, from the MERGE BASE, which is what CI diffs. Two-dot compares the
# base's current tip against this tree, so every commit that landed on the base
# after this branch left it appears in the local diff and not in CI's. A clean
# local pass would then be a claim about a superset of what CI reviews, and the
# pre-push gate would record that superset's tree as reviewed.
#
# `git merge-base` explicitly rather than `git diff base...tree`: the three-dot
# form is only defined between two COMMITS, and the right-hand side here is a
# tree object written from the index, which has no history to walk.
merge_base="$(git merge-base "$base" HEAD 2>/dev/null || printf '%s' "$base")"
if [ "$merge_base" != "$base" ]; then
  echo "ai-review:local: diffing from the merge base $(git rev-parse --short "$merge_base"), not $base's tip, so this matches what CI reviews."
fi
# AI_REVIEW_FILE narrows the review to ONE path. It exists for the case where a
# whole-diff pass keeps returning findings that do not shrink: draining one file
# at a time makes each pass small enough to converge, and small enough to read.
#
# A NARROWED PASS CANNOT SATISFY THE PUSH GATE, and that is what makes it safe
# to offer. The gate records "this tree was reviewed"; a pass that saw one file
# has not reviewed the tree, and letting it write that record would be the same
# failure as recording a refused review: unreviewed code, marked reviewed, with
# nothing afterwards to say otherwise.
if [ -n "${AI_REVIEW_FILE:-}" ]; then
  git diff "$merge_base" "$current_tree" -- "$AI_REVIEW_FILE" >"$diff_file"
  echo "ai-review:local: narrowed to $AI_REVIEW_FILE; this pass CANNOT satisfy the push gate."
else
  git diff "$merge_base" "$current_tree" >"$diff_file"
fi
if [ ! -s "$diff_file" ]; then
  echo "ai-review:local: no diff vs $base; nothing to review."
  exit 0
fi

# A persisted, append-only local pass LOG (JSON Lines, one record per past
# run), alongside the dismissal ledger in .harnx/ (gitignored, same as it):
# a bare counter would only ever show the current pass, throwing away
# exactly the information that makes "convergence" visible, whether the
# finding count is actually trending down across passes or stuck. This
# session's pass number is simply this file's current line count + 1.
log_file=".harnx/ai-review-pass-log.jsonl"
# Not `wc -l <"$log_file" 2>/dev/null || echo 0`: bash sets up redirections
# left-to-right on one command line, so the `<"$log_file"` open is attempted
# (and its "No such file" error printed to the real stderr) BEFORE the later
# `2>/dev/null` on the same line ever takes effect, leaking a spurious error
# on a first run in a fresh worktree even though the `||` fallback still
# produces the right value (verified live). An explicit existence check
# avoids the whole redirection-ordering trap.
if [ -f "$log_file" ]; then
  pass="$(($(wc -l <"$log_file") + 1))"
else
  pass=1
fi

# Read the dismissal ledger BEFORE the engine call, not after: it is now
# passed into the model itself as HANDLED memory (see review-engine.sh), so the
# model can skip re-reporting an already-dispositioned finding even when
# reworded, rather than reporting it and relying entirely on the exact-match
# filter below to catch it. A malformed or empty ledger must not crash the
# script: a failing command substitution in a plain assignment DOES abort
# under `set -e` (unlike inside an `if`), which would skip the convergence
# table entirely, the same class of bug the crashed-engine guard below
# exists to prevent. Validate and fall back to an empty ledger instead.
ledger=".harnx/ai-review-dismissed.json"
dismissed="[]"
[ -f "$ledger" ] && dismissed="$(cat "$ledger")"
if ! printf '%s' "$dismissed" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ai-review:local: WARNING: $ledger is not a valid JSON array; ignoring it for this run." >&2
  dismissed="[]"
fi
# THE ENTRIES ARE VALIDATED TOO, not only the array around them. The filter
# below calls `ascii_downcase` on `.title`, which is a hard error under `set -e`
# for an entry whose title is missing or is not a string. That killed the run
# before the convergence table printed, which is the exact failure the array
# check above exists to prevent, one level down. The ledger is hand-edited by
# design, so a malformed entry is an ordinary event and not an exotic one.
#
# Dropped, not defaulted. An entry missing a `file` or a `title` cannot identify
# a finding, so there is nothing to suppress and guessing would silently
# suppress the wrong one. Mirrors what review-engine.sh already does for
# AI_REVIEW_HANDLED.
kept="$(printf '%s' "$dismissed" | jq -c '[.[] | select(type == "object" and (.file | type == "string") and (.title | type == "string"))]')"
dropped=$(($(printf '%s' "$dismissed" | jq 'length') - $(printf '%s' "$kept" | jq 'length')))
if [ "$dropped" -gt 0 ]; then
  echo "ai-review:local: WARNING: ignored $dropped malformed entr(ies) in $ledger; each needs a string \"file\" and \"title\"." >&2
fi
dismissed="$kept"
# The engine is handed this VALIDATED content, not the ledger's path. It reads
# AI_REVIEW_HANDLED as a file and treats a payload that is not a JSON array as
# a hard error, refusing to mistake corrupt memory for "nothing known", so
# pointing it at the raw ledger meant the fallback computed just above governed
# only this script's own filtering: a malformed ledger still crashed the pass
# through the engine's separate read of the same file. One validated value now
# feeds both readers.
printf '%s' "$dismissed" >"$handled_file"

# The convergence table below must print on every run, a crash included: an
# `if` condition is exempt from `set -e`, so a non-zero exit here does not
# abort the script before the table has a chance to print. Timed with `date
# +%s`, not bash 5's $EPOCHSECONDS: macOS ships bash 3.2 as its default
# /usr/bin/bash (Apple has not shipped a GPLv3 bash since), and this script
# is invoked via `#!/usr/bin/env bash`, which resolves to that 3.2 on an
# otherwise-unmodified Mac; $EPOCHSECONDS is silently empty there (verified),
# turning Review Time into broken arithmetic on exactly the platform most
# contributors run this locally on. `date +%s` works identically everywhere.
t0="$(date +%s)"
crashed=0
engine_err="$(mktemp)"
trap 'rm -f "$diff_file" "$out" "$idx" "$handled_file" "$engine_err"' EXIT
# The engine's stderr is TEED, not captured: an operator watching a slow review
# should still see it as it happens, and the copy is only so the exit can say
# WHICH kind of failure this was.
if ! AI_REVIEW_ENGINE_TOKEN="$tok" AI_REVIEW_DIFF_FILE="$diff_file" AI_REVIEW_OUTPUT="$out" \
  AI_REVIEW_HANDLED="$handled_file" \
  bash scripts/ai-review/review-engine.sh 2> >(tee "$engine_err" >&2); then
  crashed=1
fi
elapsed="$(($(date +%s) - t0))"
# review-engine.sh always writes a valid JSON array itself, even on its own failure
# paths, but guard here too so a table render never aborts on malformed JSON.
jq -e 'type == "array"' "$out" >/dev/null 2>&1 || echo '[]' >"$out"
# A defense-in-depth BACKSTOP, not the primary recurrence-detection
# mechanism: the model itself already has this same ledger as HANDLED memory
# (passed via AI_REVIEW_HANDLED above) and is instructed to match by MEANING
# and skip reworded recurrences at the source, so `$out` should normally
# already exclude them. This filter catches the case where the model did
# not comply. Dismissal entries are {"file": "...", "title": "...", "reason":
# "..."}. Match on (file, normalized title), not title alone: title-only
# would let a dismissal for one finding silently suppress an unrelated
# finding elsewhere that happens to share similar wording. Normalizing
# (lowercase, alnum/space only) tolerates trivial formatting drift, but is
# deliberately EXACT (no fuzzy/truncated matching): fuzzy matching in shell/
# jq risks false-positive suppression of a genuinely different finding, and
# is redundant now that the model does semantic matching upstream, where it
# belongs (it is the same model producing the wording variance in the first
# place, so it is best positioned to recognize its own rewording).
open="$(jq --argjson d "$dismissed" '
  def norm: (ascii_downcase | gsub("[^a-z0-9 ]"; " ") | gsub(" +"; " ") | ltrimstr(" ") | rtrimstr(" "));
  ($d | map({file, key: (.title | norm)})) as $dn
  | [.[] | select(({file, key: (.title | norm)}) as $k | ($dn | any(. == $k)) | not)]
' "$out")"

echo "=== local ai-review vs $base ==="
count="$(printf '%s' "$open" | jq 'length')"
if [ "$count" -eq 0 ]; then
  echo "  STABLE: no findings"
else
  printf '%s' "$open" | jq -r '.[] | "  [\(.severity)] \(.file):\(.line // "file")  \(.title)"'
fi
# "Accepted" = still open after ledger filtering, i.e. neither fixed nor
# successfully refuted yet; this is what actually gates the push below.
# "Raw" = everything the model reported this pass, before that filtering.
# Both are tracked (not just accepted): a log that only ever showed the
# post-filter count could never distinguish "the model found nothing" from
# "the model found 3 Majors and all 3 were dismissed as false positives",
# even though those are very different signals about review quality.
majors_accepted="$(printf '%s' "$open" | jq '[.[] | select(.severity == "Major")] | length')"
minors_accepted="$(printf '%s' "$open" | jq '[.[] | select(.severity == "Minor")] | length')"
nits_accepted="$(printf '%s' "$open" | jq '[.[] | select(.severity == "nit")] | length')"
# `$out` is a FILE PATH (from mktemp), unlike `$open` which holds actual
# JSON content: passed directly to jq as its input file, not piped via
# printf (piping the literal path string into jq is not valid JSON and was
# the exact bug this comment now guards against, caught by an actual crash
# during testing).
majors_raw="$(jq '[.[] | select(.severity == "Major")] | length' "$out")"
minors_raw="$(jq '[.[] | select(.severity == "Minor")] | length' "$out")"
nits_raw="$(jq '[.[] | select(.severity == "nit")] | length' "$out")"
# The gate below (majors_accepted > 0) is unaffected: dismissed findings
# never block, only genuinely still-open ones do.
majors="$majors_accepted"

# Append THIS pass's record before rendering, so the table below (read back
# from the same file) includes it. A crashed pass is recorded distinctly
# (crashed: true), not as a misleading "0 Major, 0 Minor, 0 nit" clean pass.
jq -cn --argjson pass "$pass" \
  --argjson major "$majors_raw" --argjson major_accepted "$majors_accepted" \
  --argjson minor "$minors_raw" --argjson minor_accepted "$minors_accepted" \
  --argjson nit "$nits_raw" --argjson nit_accepted "$nits_accepted" \
  --argjson seconds "$elapsed" \
  --argjson crashed "$([ "$crashed" = 1 ] && echo true || echo false)" \
  '{pass: $pass, runner: "Local", major: $major, major_accepted: $major_accepted,
    minor: $minor, minor_accepted: $minor_accepted, nit: $nit, nit_accepted: $nit_accepted,
    seconds: $seconds, crashed: $crashed}' \
  >>"$log_file"

# The convergence table is a deterministic property of THIS script's own
# output, not something reconstructed by hand outside it: it shows every
# pass in this session's log, not just the current one, so an upward or
# downward trend is directly visible without cross-referencing prior runs.
# Each severity cell is "accepted/raw": accepted is what actually blocks or
# needs action; raw minus accepted is how many were dismissed (a false
# positive refuted with evidence, or an accepted tradeoff) this pass.
# `// .major` etc. falls back to raw for a log line written before this
# accepted/raw split existed, treating it as nothing-dismissed-yet, the only
# honest reading of a record that never tracked the distinction.
echo "| Pass | Runner | Major | Minor | Nit | Review Time |"
echo "|---|---|---|---|---|---|"
if ! jq -r '
  if .crashed then "| #\(.pass) | \(.runner) | CRASHED | CRASHED | CRASHED | \(.seconds)s |"
  else "| #\(.pass) | \(.runner) | \(.major_accepted // .major)/\(.major) | \(.minor_accepted // .minor)/\(.minor) | \(.nit_accepted // .nit)/\(.nit) | \(.seconds)s |" end
' "$log_file" 2>/dev/null; then
  echo "ai-review:local: WARNING: $log_file could not be fully read; showing this pass only." >&2
  echo "| #${pass} | Local | ${majors_accepted}/${majors_raw} | ${minors_accepted}/${minors_raw} | ${nits_accepted}/${nits_raw} | ${elapsed}s |"
fi

if [ "$crashed" = 1 ]; then
  # A REFUSAL IS NOT A CRASH, and reporting one as the other sends the operator
  # looking for a broken pipeline when the answer is "this diff is too big to
  # review in one pass". The engine refuses an unreviewably large diff by name
  # and with its numbers rather than starting a review it cannot finish; that
  # message is already on stderr above, so this only has to say what to DO.
  if grep -q 'over the limit of' "$engine_err"; then
    echo "ai-review:local: ERROR: the diff is too large to review in one pass, so no review ran." >&2
    echo "  This is a refusal, not a crash. See the engine's message above for the numbers." >&2
    echo "  On a stacked branch the usual cause is a missing BASE: without it the diff carries" >&2
    echo "  every inherited, already-reviewed change too. Pass BASE=origin/<the branch below>." >&2
    echo "  If the diff really is that large, split the pull request, or raise" >&2
    echo "  AI_REVIEW_MAX_CHUNKS and the job's timeout together." >&2
  else
    echo "ai-review:local: ERROR: the review engine crashed; the results above are INCOMPLETE, not a clean pass." >&2
  fi
  exit 1
fi

if [ "$majors" -gt 0 ]; then
  echo "ai-review:local: unresolved Major finding(s); fix, or record a reason in $ledger, then re-run." >&2
  exit 1
fi

# Reuses $current_tree computed at the top, the exact tree the diff sent for
# review was built from, rather than recomputing a second tree here: two
# separate computations of "the current tree" could in principle diverge
# (even though nothing in this script modifies the working tree in between);
# reusing one variable makes the two structurally identical, not just
# usually identical.
if [ -n "${AI_REVIEW_FILE:-}" ]; then
  echo "ai-review:local: clean for $AI_REVIEW_FILE. The push gate is UNCHANGED: re-run without AI_REVIEW_FILE to review the whole tree."
  exit 0
fi

printf '%s\n' "$current_tree" >"$(git rev-parse --git-path ai-review-reviewed-tree)"
echo "ai-review:local: recorded clean review of tree $current_tree (push gate satisfied)."
