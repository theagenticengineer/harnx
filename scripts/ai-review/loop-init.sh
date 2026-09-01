#!/usr/bin/env bash
# loop-init.sh — materialise the loop's working memory in .harnx/loop/.
#
# WHAT A LOOP NEEDS TO READ, and why these files and not others. A pass runs in
# a clean context window, so everything it must know has to be on disk before it
# starts. The set is not a preference; it is what the loop-engineering practice
# enumerates:
#
#   prompt-plan.md   the fixed instruction for a planning pass
#   prompt-build.md  the fixed instruction for a building pass
#   plan.md          the ordered plan whose TOP UNCHECKED ITEM is this pass's job
#   learnings.md     facts discovered by running something, appended
#   decisions.md     decisions taken, appended and superseded, never rewritten
#   manual.md        how this repository actually works, status-free
#   last-failure.txt the last failure, read FIRST, written by the harness
#   passes.jsonl     the harness's own record: what each pass cost and decided
#   handoff.md       the report written when the loop stops at its cap
#
# NEVER OVERWRITES ANYTHING. Every file is created only if absent, so running
# this twice changes nothing and running it in a loop that is mid-flight cannot
# destroy the state that loop is standing on. That is also why it is safe to
# invoke from `loop:prompt` as well as from `loop:init`.
#
# DELIBERATELY NOT IN mise.toml's `postinstall`. `mise install` runs in CI and in
# every repository harnx generates, and seeding a loop nobody asked for is noise
# in both. The hooks ride postinstall because a gate that is not installed is not
# a gate; loop state that is not seeded is simply not in use yet.
#
# THE TRACKED ARTIFACT IS THIS SCRIPT. The files it writes are per-instance and
# never enter git (see .harnx/loop/.gitignore). This script is what ships to a
# generated repository, what a reviewer reads, and what CODEOWNERS protects
# through its existing /scripts/ directory rule.
#
# passes.jsonl ROW FORMAT, defined here because this script writes the first row
# and everything downstream reads it. One JSON object per line, each with a
# `type`:
#
#   baseline    written here, once per rung. Records the distinct CI head-SHA
#               count at the moment the loop was installed.
#   pass        one review pass: its findings, its cost, its regime.
#   acceptance  a full non-narrowed review converged to zero accepted Majors.
#               Content-addressed by the reviewed tree. Resets the round count.
#   escalation  the round cap was reached and the loop stopped.
#
# WHY THE BASELINE ROW EXISTS AT ALL. The round counter is
# "local passes since the last acceptance, plus CI head SHAs since that same
# point". passes.jsonl starts empty while CI already counts the branch's whole
# history, so without a baseline a branch with 38 pushes behind it would install
# pre-spent against a cap of 15, and a branch with none would start at zero
# despite having done the same amount of work locally. Counting rounds collected
# under one regime against a cap born under another is the exact error the
# metrics exist to avoid.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

loop_dir=".harnx/loop"
mkdir -p "$loop_dir"

created=0
seed() {
  local path="$loop_dir/$1"
  if [ -e "$path" ]; then
    return 0
  fi
  cat >"$path"
  created=$((created + 1))
  echo "loop-init: seeded $path"
}

# The .gitignore is TRACKED in harnx's own repository, so this branch already
# has it and the seed below is a no-op here. It is still written, because a
# repository harnx generates receives this script without it, and loop state
# reaching that repository's git history is precisely what must not happen.
seed .gitignore <<'EOF'
*
!.gitignore
EOF

# THE TWO FIXED PROMPTS. Their canonical text is HERE, tracked, and the copies
# in .harnx/loop/ are per-instance seeds that are never overwritten.
#
# WHY TWO, AND WHY THE CALLER PICKS. Planning and building are different jobs,
# and a single prompt that branched on whether plan.md still had unchecked items
# would hand the agent the decision about which job it is doing. That is exactly
# the judgement a fixed prompt exists to remove. loop-prompt.sh requires the mode
# as an argument and refuses without one.
#
# WHY SEEDED RATHER THAN TRACKED IN PLACE. Tracking .harnx/loop/prompt-*.md would
# churn this branch's pull request every time the prompt is improved, which is
# the cost that was declined for the other loop files and should not be paid here
# alone. It also ships to a generated repository as a seed a project can adapt
# rather than as harnx's fixed opinion. The cost, stated plainly: byte-identical
# reload is no longer guaranteed by git. It holds within a rung because nothing
# rewrites these files, and `drafter_prompt_sha` on every pass row makes a change
# VISIBLE in the harness record rather than prevented. Drift from the seed is
# legitimate; these files are per-instance by design.
seed prompt-plan.md <<'PROMPT_PLAN'
You are running one PLAN pass of a loop, in a fresh context window.

Your entire job is to turn the issue's acceptance criteria into an ordered
checklist in `.harnx/loop/plan.md`. You implement nothing.

READ, IN THIS ORDER, BEFORE ANYTHING ELSE:
  1. the LAST FAILURE block below, if it is not empty. It is the most recent
     thing that went wrong and it is the single most useful thing you know.
  2. the PLAN block. If it already has items, you are refining it, not starting.
  3. the DECISIONS block. A question settled there is settled. Do not re-open it.
  4. the DISCOVERED FACTS block. These were established by running something.
     Do not re-derive them and do not contradict them without running something
     yourself.
  5. the MANUAL block, for how this repository actually works.

WRITE ONLY `.harnx/loop/plan.md`. Not code, not tests, not documentation, not
configuration. A plan pass that edits a tracked file has done the wrong job, and
`scripts/ai-review/check-plan-pass.sh` fails it.

WHAT A GOOD ITEM LOOKS LIKE:
  - one concern, small enough that a single build pass can finish it;
  - ordered so that each item can be completed without the ones below it;
  - phrased as the observable result, not the activity. "the engine records what
    a pass cost", not "work on metrics".
  - a paired test lands with the code it tests, so an item that adds a script
    includes its test. Do not make the test a separate item.

NON-FABRICATION. Everything below applies to this pass and to every build pass
after it:
  - Never state that a command was run unless you ran it and read its output.
  - Never report a result you did not observe. "I expect this passes" is not a
    result.
  - If something is unknown, write that it is unknown. An assumption recorded as
    a fact is worse than an open question, because the next pass cannot tell
    them apart.
  - Do not conclude something is absent because a search did not find it. Search
    tools miss things; check directly before writing it down.

WHEN YOU ARE DONE, append to `.harnx/loop/learnings.md` anything you ESTABLISHED
by running something, with what established it. Append nothing you merely
believe.
PROMPT_PLAN

seed prompt-build.md <<'PROMPT_BUILD'
You are running one BUILD pass of a loop, in a fresh context window.

Your entire job is the TOP UNCHECKED ITEM of `.harnx/loop/plan.md`, and nothing
below it.

READ, IN THIS ORDER, BEFORE ANYTHING ELSE:
  1. the LAST FAILURE block below, if it is not empty. It is what the gate said
     last time. Start there; it is usually the whole job.
  2. the PLAN block. The top unchecked item is your job. Only that one.
  3. the DECISIONS block. A question settled there is settled. Do not re-open it.
  4. the DISCOVERED FACTS block. Established by running something. Do not
     re-derive them, and do not contradict one without running something
     yourself.
  5. the MANUAL block, for how this repository actually works.

MAKE THE SMALLEST CHANGE THAT TURNS THE TOP FAILURE GREEN. Not the change that
would be nicest, and not the one that also fixes the next item. If you find
other problems, they are plan items, not this pass's work.

A PAIRED TEST LANDS IN THE SAME COMMIT AS THE CODE IT TESTS. This is enforced by
`scripts/check-paired-tests.sh`, so it is not advice.

THE CONTRACT IS THREE COMMANDS. Run them; do not re-derive what they check and
do not substitute your own reading of the code for them:
    mise run lint
    mise run test
    mise run ai-review:local
`docs/ai-review.md` is the gate contract. Read it there. Do not restate it
anywhere, because a restatement is a second copy free to disagree with the gate
that is actually enforced.

WHAT YOU MAY NOT DO, each with the command that would do it. These are the gates
judging this work, and a worker that can move them is not being judged:
  - Do not resolve a review thread.
    `gh api graphql ... resolveReviewThread`
  - Do not edit, close or re-open an issue to make a finding go away.
    `gh issue edit`, `gh issue close`
  - Do not delete or re-run a CI run to change a verdict.
    `gh run delete`, `gh run rerun`
  - Do not push past a hook.
    `git push --no-verify`
  - Do not weaken a gate to make it pass. That means `.pre-commit-config.yaml`,
    `mise.toml`, anything under `scripts/`, and the workflow files. If a gate is
    wrong, that is a decision to record and escalate, not an edit to make.
Your credential is expected to refuse several of these outright. A 403 is the
design working, not an obstacle to route around.

WHERE THINGS GO WHEN YOU ARE DONE:
  - `.harnx/loop/plan.md`: check off what you finished. Status lives here and
    ONLY here.
  - `.harnx/loop/learnings.md`: APPEND facts you ESTABLISHED by running
    something, with what established them. Never edit or delete a line.
  - `.harnx/loop/decisions.md`: APPEND a decision, or append a superseding entry
    below the one it replaces, with the reason. NEVER rewrite an entry. A future
    pass needs to see that a question was already settled.
  - `.harnx/loop/manual.md`: improve it when you learned something a future pass
    would waste time rediscovering. NO STATUS here; status is plan.md's job.
  - A SCOPE-CHANGING DECISION ALSO GOES IN THE ISSUE OR PULL REQUEST before this
    pass ends. `.harnx/loop/` is gitignored, so nothing written only there ever
    crosses a human's eyes in a diff.

NON-FABRICATION:
  - Never state that a command was run unless you ran it and read its output.
  - Never report a result you did not observe.
  - If something is unknown, write that it is unknown.
  - Do not conclude something is absent because a search did not find it. Check
    directly before writing it down.
  - If you cannot finish, say what is blocking in `.harnx/loop/handoff.md` and
    stop. Stopping is a valid outcome. Reporting success is not.
PROMPT_BUILD

seed plan.md <<'EOF'
# Plan

<!--
ONE ORDERED CHECKLIST. The TOP UNCHECKED ITEM is the next pass's job, and the
only one it may work on.

Written by a `plan` pass, which writes this file and nothing else. A `build`
pass checks an item off and may split one it found to be two; it does not add
new work, because deciding what the work is belongs to a plan pass.
-->

- [ ] (no plan yet: run `mise run loop:prompt plan`)
EOF

seed learnings.md <<'EOF'
# Discovered facts

<!--
APPEND ONLY. Never edit or delete a line here.

A fact belongs here once something ESTABLISHED it: a command that was run, an
output that was read, a measurement that was taken. Record what established it
alongside the fact itself, because the next pass cannot re-derive your
confidence and will otherwise either distrust a real finding or inherit a
guess as though it were measured.

Not for intentions, plans, or things believed to be true. Those are the other
two files.
-->
EOF

seed decisions.md <<'EOF'
# Decisions

<!--
APPEND AND SUPERSEDE, NEVER REWRITE. A decision that turned out wrong is
recorded as superseded, immediately below the entry it replaces, with the
reason. Editing the original away destroys the one thing this file is for:
that the next pass can see a question was already settled and not re-open it.

A SCOPE-CHANGING DECISION ALSO GOES IN THE ISSUE OR PULL REQUEST before the
pass ends. This file is gitignored, so nothing written only here ever crosses a
human's eyes in a diff.
-->
EOF

seed manual.md <<'EOF'
# Operating manual

<!--
HOW THIS REPOSITORY ACTUALLY WORKS: the commands that matter, the traps, the
things that look wrong and are not. Improve it whenever a pass learns something
a future pass would waste time rediscovering. This is the one file here a
worker is invited to rewrite.

NO STATUS. Not what is done, not what is next, not what is blocked. That is
plan.md's job, and a manual carrying status goes stale silently, which is worse
than one that is merely incomplete.

The GATE CONTRACT is not here. It is docs/ai-review.md, which is tracked and
human-owned. Point at it; do not restate it, because a restatement is a second
copy free to disagree with the gate that is actually enforced.
-->
EOF

seed handoff.md <<'EOF'
<!--
THE REPORT WRITTEN WHEN THE LOOP STOPS AT ITS CAP. Empty until then.

It must carry `rung:` and `rounds:` matching the count at the stop, plus a body
saying what was tried, what is known, and what the next person should decide.
An empty or stale report does not release the cap.
-->
EOF

# Harness-written, seeded empty. A worker never writes this file: if it wrote
# its own account of its failure, the loop would be reading the worker's
# narrative rather than the gate's verdict, which inverts the whole arrangement.
seed last-failure.txt </dev/null

# THE DISTINCT CI HEAD-SHA COUNT for this rung, or null when it cannot be read.
#
# Null rather than zero, and the difference matters downstream: zero is a claim
# that CI has never run, which would make the cap count only local passes while
# looking like it had counted both. Null says "not known", and the cap says so
# out loud when it falls back.
# ONE IMPLEMENTATION OF THE COUNT, shared with check-round-cap.sh, which
# subtracts the number recorded here from a freshly computed one. Two copies
# would be free to disagree, and a disagreement would not look like a bug: it
# would look like rounds that were never spent.
rung="$(git rev-parse --abbrev-ref HEAD)"
ci_head_shas() { bash scripts/ai-review/ci-head-shas.sh "$rung" 2>/dev/null; }

log="$loop_dir/passes.jsonl"
# Asked STRUCTURALLY, not by grepping for a key order. jq emits the keys in the
# order they are written above, so a substring match works today and breaks the
# moment a field is inserted before `rung`, silently writing a second baseline
# and halving every round count computed from it.
if [ -f "$log" ] && jq -s -e --arg r "$rung" \
  'any(.[]; .type == "baseline" and .rung == $r)' "$log" >/dev/null 2>&1; then
  echo "loop-init: baseline row for '$rung' already present; leaving it."
else
  count="$(ci_head_shas || true)"
  [ -n "$count" ] || count=null
  jq -cn --arg rung "$rung" --argjson ci "$count" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:"baseline", rung:$rung, ci_head_shas:$ci, at:$at}' >>"$log"
  if [ "$count" = null ]; then
    echo "loop-init: baseline row for '$rung' written with ci_head_shas: null (gh could not be read); the round cap will count local passes only." >&2
  else
    echo "loop-init: baseline row for '$rung' written at $count distinct CI head SHA(s)."
  fi
  created=$((created + 1))
fi

if [ "$created" -eq 0 ]; then
  echo "loop-init: $loop_dir is already seeded; nothing to do."
fi
