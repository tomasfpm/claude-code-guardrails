#!/usr/bin/env bash
# SessionStart hook — bring a shared notes repo up to date before the session reads it.
#
# WHY: if several sessions on several machines write to the same git repo of notes, a
# session that starts from a stale copy will either conflict on push or, worse, reason from
# an out-of-date note.
#
# SAFETY: it only rebases a CLEAN tree. If another session left work uncommitted, this does
# nothing rather than risk touching it — finishing someone else's work is not this hook's
# job. It never fails the session. Wire it with "async": true so it never delays startup.
#
# Set NOTES_REPO to the repo's path. Unset means this hook does nothing.

NOTES="${NOTES_REPO:-}"
[ -n "$NOTES" ] || exit 0
[ -d "$NOTES/.git" ] || exit 0

# Refuse to rebase over uncommitted work.
git -C "$NOTES" diff --quiet 2>/dev/null || exit 0
git -C "$NOTES" diff --cached --quiet 2>/dev/null || exit 0

git -C "$NOTES" pull --rebase -q 2>/dev/null || true
exit 0
