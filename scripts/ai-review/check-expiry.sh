#!/usr/bin/env bash
# check-expiry.sh — warns before a reviewer's credential lapses, not after.
#
# WHY THIS IS LOAD-BEARING RATHER THAN A NICETY. It was optional while a lapsed
# credential merely made a reviewer dormant: nothing broke, the reviewer simply
# stopped reviewing. Under the registry's hard-fail rule a named reviewer that
# cannot run FAILS its leg and the gate goes red, which is the honest report
# and also a nasty surprise.
#
# So the two are a pair. Warn at seven days; fail when it actually lapses.
# Without the warning, a repository discovers an expiry as a red required check
# on somebody's unrelated pull request, and the person who has to read that
# failure is never the person who can fix it.
#
# PER REVIEWER, AND OPTIONAL PER REVIEWER. A reviewer with no expiry variable
# set is silent: plenty of credentials do not expire, and a warning nobody can
# act on is the noise this repository already refuses elsewhere.
#
# A MALFORMED DATE WARNS AND IS SKIPPED, never crashes the step. The value is
# repository state somebody typed, and the cost of a typo must be a message
# rather than a red gate on a pull request that has nothing to do with it.
#
# THE DATE ARITHMETIC IS PORTABLE, done in awk rather than with `date -d` or
# `date -v`. Those are GNU and BSD spellings of the same idea and neither runs
# on both, and this script has to give the same answer on a contributor's Mac
# and on the Ubuntu runner. The days-from-civil conversion below is exact for
# any Gregorian date and needs no date library at all.
#
# Env:
#   REVIEWERS  required; the probe's reviewer array, each entry carrying the
#              `expires` variable name. The uppercase mapping lives in the
#              probe so there is one copy of it.
#   VARS       required; the repository's variables as JSON, from
#              `toJSON(vars)`. Read as a map because GitHub cannot index the
#              vars context by a computed name. These are variables, not
#              secrets: nothing sensitive is materialised by reading them.
#   WARN_DAYS  optional; how many days ahead to warn, default 7.
#   TODAY      optional; an ISO date to treat as today, for tests.
set -euo pipefail

: "${REVIEWERS:?REVIEWERS is required}"
: "${VARS:?VARS is required}"

warn_days="${WARN_DAYS:-7}"
case "$warn_days" in
'' | *[!0-9]*) warn_days=7 ;;
esac

today="${TODAY:-$(date -u +%Y-%m-%d)}"

# Days from the civil epoch, Howard Hinnant's algorithm. Exact for any
# Gregorian date, and it is arithmetic, so it behaves identically everywhere.
days_from_civil() {
  printf '%s' "$1" | awk -F- '
    {
      y = $1 + 0; m = $2 + 0; d = $3 + 0
      if (m <= 2) y -= 1
      era = (y >= 0 ? y : y - 399) / 400
      era = int(era)
      yoe = y - era * 400
      mp = (m + 9) % 12
      doy = int((153 * mp + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      print era * 146097 + doe - 719468
    }'
}

is_iso_date() {
  case "$1" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) return 1 ;;
  esac
  # A SHAPE THAT PARSES IS NOT A DATE THAT EXISTS, and the conversion below
  # cannot tell the difference: it is arithmetic, so it converts 2026-02-30 to
  # a number as happily as any real date and the result is silently four weeks
  # wrong. The month and the day are checked against the calendar here, leap
  # years included.
  printf '%s' "$1" | awk -F- '
    function leap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
    {
      y = $1 + 0; m = $2 + 0; d = $3 + 0
      split("31 28 31 30 31 30 31 31 30 31 30 31", len, " ")
      if (leap(y)) len[2] = 29
      if (m < 1 || m > 12) exit 1
      if (d < 1 || d > len[m]) exit 1
      exit 0
    }'
}

today_n="$(days_from_civil "$today")"
warned=0

while read -r entry; do
  [ -n "$entry" ] || continue
  slug="$(printf '%s' "$entry" | jq -r '.slug')"
  var="$(printf '%s' "$entry" | jq -r '.expires')"
  value="$(printf '%s' "$VARS" | jq -r --arg v "$var" '.[$v] // ""' 2>/dev/null || true)"

  [ -n "$value" ] || continue

  if ! is_iso_date "$value"; then
    echo "::warning::$var is set to '$value', which is not an ISO date (YYYY-MM-DD), so the credential for reviewer '$slug' cannot be checked for expiry. Fix the value or unset it."
    warned=1
    continue
  fi

  expires_n="$(days_from_civil "$value")"
  remaining=$((expires_n - today_n))

  if [ "$remaining" -lt 0 ]; then
    echo "::warning::reviewer '$slug' has a credential recorded as EXPIRED since $value. Its leg fails until the secret is rotated and $var is updated."
    warned=1
  elif [ "$remaining" -le "$warn_days" ]; then
    echo "::warning::reviewer '$slug' has a credential expiring in $remaining day(s), on $value. Rotate the secret and update $var before it lapses: after that its leg fails and the gate goes red on whatever pull request happens to run next."
    warned=1
  fi
done <<EOF
$(printf '%s' "$REVIEWERS" | jq -c '.[]?' 2>/dev/null || true)
EOF

if [ "$warned" -eq 0 ]; then
  echo "check-expiry: no reviewer credential is near expiry."
fi
