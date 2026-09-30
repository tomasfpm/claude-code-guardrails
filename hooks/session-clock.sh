#!/usr/bin/env bash
# SessionStart / Stop — tell Claude what time it is and how long since the last session.
#
# WHY THIS EXISTS
# Claude is given today's date, but nothing about elapsed time. In the setup this came from,
# a session once reasoned as though the user was still on holiday when they had been back
# for days — a wrong assumption that a single number would have prevented. Dates without
# intervals are how a model ends up confidently out of date.
#
# Machine-local on purpose: the state file lives in ~/.claude, NOT in any repo. Writing a
# timestamp into a git repo on every session start would produce a commit per session and
# guarantee conflicts across machines. The cost is that this measures "since we last spoke
# ON THIS MACHINE" — the output says so rather than implying it is global.
#
#   session-clock.sh            report the gap, then record now   (SessionStart)
#   session-clock.sh --record   record now, print nothing         (Stop)
#
# SessionStart hooks talk to Claude through plain stdout: whatever this prints is added to
# the session's context as text.

set -u
STATE="${CLAUDE_SESSION_CLOCK:-$HOME/.claude/last-session}"
now="$(date +%s)"

record() { mkdir -p "$(dirname "$STATE")" 2>/dev/null; printf '%s\n' "$now" > "$STATE" 2>/dev/null; }

if [ "${1:-}" = "--record" ]; then record; exit 0; fi

printf 'Current time: %s\n' "$(date '+%A, %Y-%m-%d %H:%M %Z')"

last=""
if [ -r "$STATE" ]; then
  last="$(head -1 "$STATE" 2>/dev/null | tr -dc '0-9')"
fi

if [ -n "$last" ] && [ "$last" -gt 0 ] 2>/dev/null; then
  d=$(( now - last ))
  [ "$d" -lt 0 ] && d=0
  days=$(( d / 86400 )); hrs=$(( (d % 86400) / 3600 )); mins=$(( (d % 3600) / 60 ))
  prev="$(date -d "@$last" '+%A, %Y-%m-%d %H:%M' 2>/dev/null || date -r "$last" '+%A, %Y-%m-%d %H:%M' 2>/dev/null)"
  printf 'Last activity on this machine: %s\n' "${prev:-unknown}"
  if [ "$days" -gt 0 ]; then
    printf 'Gap since then: %s day(s), %s hour(s).\n' "$days" "$hrs"
  elif [ "$hrs" -gt 0 ]; then
    printf 'Gap since then: %s hour(s), %s minute(s).\n' "$hrs" "$mins"
  else
    printf 'Gap since then: %s minute(s) — continuing recent work.\n' "$mins"
  fi
  [ "$days" -ge 3 ] && printf 'NOTE: it has been a while. Do not assume what the user has been doing; ask.\n'
else
  printf 'Last activity: no record yet (first run of this hook on this machine).\n'
fi

record
exit 0
