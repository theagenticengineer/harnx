#!/usr/bin/env bash
# Standalone test for the credentialed trunk workflow's per-job tool scoping.
# Run: bash scripts/tests/trunk-toolchain.bash
#
# WHAT IT PROTECTS. Each job in .github/workflows/ai-review-trunk.yml passes
# `install_args` to jdx/mise-action naming only the tools it actually runs, so
# the jobs holding the review engine's token and the App private key do not put
# nine unrelated third-party binaries on their PATH. Every installed tool's bin
# directory joins PATH, so a compromised pinned artifact can SHADOW a binary
# these scripts do execute, `jq` above all: "installed but never invoked" is
# not inert in a job holding a live credential.
#
# That property is invisible when it breaks. Adding a `jq` call to a job scoped
# without it fails at runtime in CI, which is loud; but WIDENING a scope, or
# dropping install_args entirely, breaks nothing, goes green, and silently
# restores the whole toolchain to a credentialed job. Only a test notices.
#
# It asserts BOTH directions, because each catches a different mistake:
#
#   forward  every external binary a job's scripts invoke is installed by that
#            job. Catches a scope that is too NARROW (a runtime break).
#   reverse  every install_args entry is pinned in mise.toml. Catches a typo
#            or a stale name, which mise would treat as an unknown tool.
#
# Deliberately NOT asserted: that a job installs nothing beyond what it
# invokes. That is the property worth having, but a script can gain a tool
# invocation legitimately, and a test that forbids any slack would fail on the
# honest change as loudly as on the careless one. The forward direction plus
# code review is the balance struck.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/ai-review-trunk.yml"
mise_toml="$repo_root/mise.toml"

pass=0
fail=0
fail_case() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# The binary a tool key provides. Hand-maintained because there is no
# machine-readable link between a mise tool key and the command it installs,
# and guessing (strip the backend prefix, take the basename) is wrong for
# exactly the entry that matters most here: `npm:@anthropic-ai/claude-code`
# provides `claude`, not `claude-code`.
tool_key_for_binary() {
  case "$1" in
  jq) echo "jq" ;;
  claude) echo "npm:@anthropic-ai/claude-code" ;;
  shellcheck) echo "shellcheck" ;;
  shfmt) echo "shfmt" ;;
  yamllint) echo "yamllint" ;;
  actionlint) echo "actionlint" ;;
  taplo) echo "taplo" ;;
  vale) echo "vale" ;;
  gitleaks) echo "gitleaks" ;;
  markdownlint) echo "npm:markdownlint-cli" ;;
  pre-commit) echo "pre-commit" ;;
  *) echo "" ;;
  esac
}
CANDIDATE_BINARIES="jq claude shellcheck shfmt yamllint actionlint taplo vale gitleaks markdownlint pre-commit"

# --- parse mise.toml's [tools] keys -------------------------------------------
# Only the [tools] table: [tasks."lint:shell"] bodies name binaries too, and
# treating those as pins would make the reverse assertion vacuous.
tools_keys="$(awk '
  /^\[tools\]/ { in_tools = 1; next }
  /^\[/        { in_tools = 0 }
  in_tools && /^[^#[:space:]]/ {
    key = $1
    gsub(/"/, "", key)
    print key
  }' "$mise_toml")"

if [ -z "$tools_keys" ]; then
  fail_case "could not parse any [tools] entries from mise.toml"
fi

# --- parse each job's install_args --------------------------------------------
jobs_with_mise="$(awk '
  /^  [a-z_]+:$/          { job = $1; sub(/:$/, "", job) }
  /jdx\/mise-action/      { pending = 1 }
  pending && /install_args:/ {
    line = $0
    sub(/^.*install_args:[[:space:]]*/, "", line)
    print job "|" line
    pending = 0
  }' "$workflow")"

job_count="$(printf '%s\n' "$jobs_with_mise" | grep -c . || true)"
mise_step_count="$(grep -c "jdx/mise-action" "$workflow" || true)"
if [ "$job_count" -eq "$mise_step_count" ] && [ "$job_count" -gt 0 ]; then
  pass=$((pass + 1))
else
  fail_case "every jdx/mise-action step in the trunk must carry install_args: found $mise_step_count steps but $job_count with install_args"
fi

# --- which scripts does each job run, transitively? ---------------------------
# Transitive because a job's `run:` names one script that calls others:
# evaluate-gate.sh runs check-resolved.sh, check-dispositions.sh. Scoping the
# job on the entry point alone would miss every binary the callees use.
scripts_for_job() {
  local job="$1" seen="" queue frontier script found
  queue="$(awk -v want="$job" '
    /^  [a-z_]+:$/ { job = $1; sub(/:$/, "", job) }
    job == want {
      while (match($0, /scripts\/ai-review\/[a-z-]+\.sh/)) {
        print substr($0, RSTART, RLENGTH)
        $0 = substr($0, RSTART + RLENGTH)
      }
    }' "$workflow" | sort -u)"
  while [ -n "$queue" ]; do
    frontier="$queue"
    queue=""
    while read -r script; do
      [ -n "$script" ] || continue
      case " $seen " in *" $script "*) continue ;; esac
      seen="$seen $script"
      [ -f "$repo_root/$script" ] || continue
      found="$(grep -oE 'scripts/ai-review/[a-z-]+\.sh' "$repo_root/$script" 2>/dev/null | sort -u || true)"
      # A callee referenced as "$script_dir/name.sh" carries no directory
      # prefix to match on, so resolve that form too. The single quotes below
      # are deliberate: '$script_dir/' is a LITERAL string being searched for
      # in the file, not a variable this test wants expanded.
      # shellcheck disable=SC2016
      found="$found
$(grep -oE '\$script_dir/[a-z-]+\.sh' "$repo_root/$script" 2>/dev/null |
        sed 's|\$script_dir/|scripts/ai-review/|' | sort -u || true)"
      queue="$queue
$found"
    done <<<"$frontier"
  done
  printf '%s' "$seen" | tr ' ' '\n' | grep -v '^$' || true
}

# --- which binaries does a script invoke? -------------------------------------
# Comment lines are stripped first: `# shellcheck disable=SC2016` is a directive
# to a linter, not an invocation of it, and counting it would demand shellcheck
# be installed in every credentialed job.
binaries_in_script() {
  local file="$1" bin body
  body="$(sed 's/^[[:space:]]*#.*$//' "$file")"
  for bin in $CANDIDATE_BINARIES; do
    # Command position only: start of line, or after a pipe, semicolon,
    # ampersand, opening paren, backtick or $( . Matching the bare word
    # anywhere would fire on prose inside a double-quoted error message.
    #
    # The trailing side is a WORD BOUNDARY, not a space. Requiring a space
    # after the name meant an invocation that ends the line right there was
    # invisible, and three ordinary forms do exactly that: `foo | jq` at the
    # end of a pipeline, `if jq; then`, and `$(jq)`. A detector with blind
    # spots is worse than no detector here, because its whole job is to catch a
    # job that under-scopes install_args, and it would have reported green.
    # `_` and `-` stay excluded so `jq-1.7.1` is still not an invocation of jq.
    if printf '%s' "$body" | grep -qE "(^|[|;&(\`]|\\\$\\()[[:space:]]*${bin}([^[:alnum:]_-]|\$)"; then
      printf '%s\n' "$bin"
    fi
  done
}

# --- forward: a job installs every binary its scripts invoke ------------------
while IFS='|' read -r job args; do
  [ -n "$job" ] || continue
  for script in $(scripts_for_job "$job"); do
    [ -f "$repo_root/$script" ] || continue
    for bin in $(binaries_in_script "$repo_root/$script"); do
      key="$(tool_key_for_binary "$bin")"
      if [ -z "$key" ]; then
        fail_case "$script invokes '$bin', which has no entry in tool_key_for_binary; add one"
        continue
      fi
      case " $args " in
      *" $key "*)
        pass=$((pass + 1))
        ;;
      *)
        fail_case "job '$job' runs $script, which invokes '$bin', but its install_args ($args) does not include '$key'"
        ;;
      esac
    done
  done
done <<<"$jobs_with_mise"

# --- reverse: every install_args entry is pinned in mise.toml -----------------
while IFS='|' read -r job args; do
  [ -n "$job" ] || continue
  for key in $args; do
    if printf '%s\n' "$tools_keys" | grep -qxF "$key"; then
      pass=$((pass + 1))
    else
      fail_case "job '$job' installs '$key', which mise.toml's [tools] does not pin"
    fi
  done
done <<<"$jobs_with_mise"

# --- the review job is the ONLY one that gets the review engine ---------------
# The specific property the scoping exists for: post_findings holds the App
# private key, resolved and context hold nothing but github.token, and none of
# the three runs the engine.
while IFS='|' read -r job args; do
  [ -n "$job" ] || continue
  case " $args " in
  *" npm:@anthropic-ai/claude-code "*)
    if [ "$job" = "review" ]; then
      pass=$((pass + 1))
    else
      fail_case "job '$job' installs the claude CLI but does not run the review engine"
    fi
    ;;
  esac
done <<<"$jobs_with_mise"

# --- no job caches its toolchain ----------------------------------------------
# The default cache key is derived from the config hash, which is identical for
# all four jobs. Sharing it lets one job restore tools it deliberately did not
# install, putting their bin directories back on PATH and undoing the scoping
# above. Distinct per-job keys, which this test used to require, mitigate that;
# `cache: false` removes it, because there is nothing to share.
#
# It is also the only accurate description of what happens. This workflow
# declares `permissions: {}` and no job grants `actions: write`, which the
# Actions cache service requires in order to SAVE, so nothing was ever cached:
# every run simply annotated itself with "cache write denied". Asserting the
# disable, rather than the key prefixes, pins the property that actually holds.
n_disabled="$(grep -cE '^ +cache: false$' "$workflow" || true)"
if [ "$n_disabled" -eq "$mise_step_count" ]; then
  pass=$((pass + 1))
else
  fail_case "each of the $mise_step_count mise steps must set cache: false; found $n_disabled"
fi
# A leftover prefix would read as though caching were configured and scoped.
if grep -q 'cache_key_prefix:' "$workflow"; then
  fail_case "cache_key_prefix is dead configuration once cache: false is set; remove it"
else
  pass=$((pass + 1))
fi

# --- the App identity secret is the CLIENT id ---------------------------------
# actions/create-github-app-token v3 deprecated `app-id` in favour of
# `client-id`, and the two are separate values rather than two spellings of
# one. The secret name and the input have to move together: renaming the secret
# in configure-environment.sh while the workflow still reads the old name
# leaves the token-minting step reading an empty value, which fails inside the
# one job holding the App private key.
if grep -qE '^ +client-id: \$\{\{ secrets\.AI_REVIEW_APP_CLIENT_ID \}\}$' "$workflow"; then
  pass=$((pass + 1))
else
  fail_case "the token-minting step must read client-id from secrets.AI_REVIEW_APP_CLIENT_ID"
fi
if grep -qE '^ +app-id:' "$workflow"; then
  fail_case "app-id is deprecated and warns on every run; use client-id"
else
  pass=$((pass + 1))
fi

# --- the detector's own reach, and what it admits it misses ------------------
# binaries_in_script is what decides whether a job under-scopes install_args, so
# a form it cannot see is a job that passes this suite while invoking a binary
# it never installed. Exercised directly, because every form below is ordinary
# shell that simply does not appear in the trunk's scripts today.
probe_dir="$(mktemp -d)"
probe_detects() {
  printf '%s\n' "$2" >"$probe_dir/p.sh"
  binaries_in_script "$probe_dir/p.sh" | grep -Fxq "$1"
}

# Forms that ARE invocations. The last three were invisible while the pattern
# required a space after the name.
# shellcheck disable=SC2016  # these are shell forms being SEARCHED for, not
# expansions this suite wants performed.
for form in 'jq -r .a f' 'foo | jq' 'x="$(jq)"' 'printf y | jq' '(jq)' 'a; jq'; do
  if probe_detects jq "$form"; then
    pass=$((pass + 1))
  else
    fail_case "binaries_in_script must see 'jq' in: $form"
  fi
done

# Forms that are NOT invocations. Over-detection is the safer direction but
# still wrong: it would demand a job install a tool it only names in a message.
for form in 'jq-1.7.1 = "pinned"' 'echo "install jq first"' 'use jq for this' 'jqx -r .a'; do
  if probe_detects jq "$form"; then
    fail_case "binaries_in_script must NOT see an invocation in: $form"
  else
    pass=$((pass + 1))
  fi
done

# A RESIDUAL GAP, written down rather than papered over. `if jq; then` is a
# real invocation and is not detected, because adding `if` to the command
# position prefixes would also match prose inside a double-quoted string
# ("fails if jq is absent"), which is a false positive that demands a job
# install a tool it never runs. No trunk script uses the form; this assertion
# exists so the limitation is a recorded decision rather than a surprise, and
# it fails if somebody widens the pattern without revisiting the tradeoff.
if probe_detects jq 'if jq; then'; then
  fail_case "the 'if <bin>;' form is now detected: revisit the false-positive tradeoff in binaries_in_script and update this assertion"
else
  pass=$((pass + 1))
fi
rm -rf "$probe_dir"

echo "RESULT: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
