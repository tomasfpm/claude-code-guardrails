#!/usr/bin/env bash
# Stop hook — do not let a session end with uncommitted edits in the shared notes repo.
#
# WHY: a shared notes repo is only as good as the last session that pushed. Edits left
# sitting locally are invisible to every other machine and turn into conflicts later.
#
# It does NOT ask "did you learn anything?" — that question has no mechanical answer, so it
# would fire constantly and get ignored. It enforces a rule a script can check instead:
# the notes repo must not be left dirty.
#
# Stop hooks talk back with JSON on stdout: {"decision":"block","reason":"..."} makes the
# session carry on and shows Claude the reason.
#
# LOOP SAFETY, two independent ways:
#   1. It honours stop_hook_active, so a continuation this hook caused can never
#      re-trigger it.
#   2. The block condition is cleared by the exact action it asks for — once the repo is
#      committed, status is clean and the hook stays silent.
#
# Set NOTES_REPO to the repo's path. Unset means this hook does nothing.

input=$(cat 2>/dev/null)
case "$input" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;;
esac

# A gate must be something the agent it fires on can actually clear.
#
# If you run read-only Claude sessions (for example a chat front-end that launches
# `claude -p` with no write tools), blocking one demands a commit it is structurally unable
# to make. It cannot clear the block, so it argues with it. Measured in the setup this came
# from: with the notes repo dirty, five questions in a row came back as "that gate is firing
# again" instead of an answer.
#
# The hook cannot tell a read-only session from a full one — it sees an event, not an actor.
# So the CALLER declares itself: launch those sessions with READONLY_SESSION=1.
[ "${READONLY_SESSION:-}" = "1" ] && exit 0

NOTES="${NOTES_REPO:-}"
[ -n "$NOTES" ] || exit 0
[ -d "$NOTES/.git" ] || exit 0

# Obsidian rewrites .obsidian/graph.json's VIEW state — the zoom "scale" and the pane's
# "close" flag — whenever the graph pane is open. A one-float diff is not knowledge, and a
# gate that blocks on it teaches you to dismiss the gate. The file can stay tracked (its
# colour groups are real settings); the noise is filtered here instead.
is_view_state_noise() {
  local changed
  changed=$(git -C "$NOTES" diff HEAD -U0 -- "$1" 2>/dev/null \
            | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)')
  [ -n "$changed" ] || return 1                      # no diff to classify
  printf '%s\n' "$changed" | grep -qvE '"(scale|close)"' && return 1
  return 0                                            # every changed line is view state
}

n=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path=${line:3}
  path=${path#\"}; path=${path%\"}
  if [ "$path" = ".obsidian/graph.json" ] && is_view_state_noise "$path"; then
    continue
  fi
  n=$((n + 1))
done <<EOF
$(git -C "$NOTES" status --porcelain 2>/dev/null)
EOF
[ "$n" -eq 0 ] && exit 0

printf '{"decision":"block","reason":"The notes repo has %s uncommitted change(s) at %s. Commit and push before finishing: git add -A, then commit, then git pull --rebase, then git push. If the edits were unintended, revert them instead. Do not leave notes uncommitted — other sessions and machines cannot see them."}' "$n" "$NOTES"
exit 0
