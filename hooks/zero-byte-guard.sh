#!/usr/bin/env bash
# Refuse to let a session continue quietly after a tracked file has been emptied.
#
#   PostToolUse, matcher Bash. Exit 2 + stderr = the model is told what it just destroyed.
#
# WHY THIS EXISTS
# `open(p, 'w')` truncates on open, BEFORE anything is written. If the write then raises -
# in practice, an encode error on a hand-escaped emoji or other astral character - the file
# is already zero bytes and the traceback reads like nothing happened.
#
# In the setup this came from, that cost three files in one week: a 453-line note, a
# curriculum, then the same note again (587 lines) hours after the second. A written rule
# about it existed after the first one, said exactly what to do, and did not prevent the
# second or the third. That is the entire argument for a hook: an instruction has to be
# recalled at the moment of writing a long string, and it never is. A hook fires on the
# moment instead.
#
# Cause-agnostic on purpose. It does not care which language, which escape, or which tool -
# only that something which had content no longer does.
#
# ⚠️ WHAT IT DELIBERATELY DOES NOT DO
# It does not fire on a file that was ALREADY empty in HEAD (.gitkeep, placeholders), and it
# does not fire on a newly added empty file. Only on content that existed and is now gone.
# A check that always fires is not a check, it is a thing you learn to scroll past.
#
# WHICH REPOS IT WATCHES
#   ZERO_BYTE_GUARD_REPOS   newline-separated list of repo roots, if you want several
#   otherwise               the current project ($CLAUDE_PROJECT_DIR, or the working dir)
# Cost is one `git diff --name-only HEAD` per repo, per Bash call: about 35 ms each on the
# machine it was measured on.

set -uo pipefail

if [ -n "${ZERO_BYTE_GUARD_REPOS:-}" ]; then
  mapfile -t REPOS < <(printf '%s\n' "$ZERO_BYTE_GUARD_REPOS")
else
  REPOS=("${CLAUDE_PROJECT_DIR:-$PWD}")
fi

emptied=""

for r in "${REPOS[@]}"; do
  [ -n "$r" ] || continue
  [ -d "$r/.git" ] || continue

  # Only files that differ from HEAD - a small set, so this stays cheap enough to run
  # after every Bash call. Covers staged and unstaged alike.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$r/$f" ] || continue          # deleted, not emptied - that is a normal git op
    [ -s "$r/$f" ] && continue          # still has content

    # It is zero bytes NOW. Did it have content in HEAD? If it never did, this is a
    # placeholder or a new empty file, and firing on it would be noise.
    was=$(git -C "$r" cat-file -s "HEAD:$f" 2>/dev/null || echo 0)
    [ "${was:-0}" -gt 0 ] || continue

    emptied="${emptied}  $(basename "$r")/$f — was ${was} bytes in HEAD, now 0"$'\n'
  done < <(git -C "$r" diff --name-only HEAD 2>/dev/null)
done

[ -z "$emptied" ] && exit 0

# PostToolUse: exit 2 puts stderr in front of the model. The tool already ran, so this
# cannot prevent the damage - it makes it impossible to miss, which is the whole job.
{
  echo "ZERO-BYTE FILE(S) - a tracked file that had content is now empty:"
  echo
  printf '%s' "$emptied"
  echo
  echo "This is almost always open(p,'w') truncating before a write that then raised."
  echo "The content is NOT lost: it is in HEAD. Recover it now, before editing anything else:"
  echo
  echo "    git -C <repo> restore <file>"
  echo
  echo "Then fix the write. Encode first, open second, so nothing that can raise sits"
  echo "between the truncate and the write:"
  echo
  echo "    data = out.encode('utf-8')   # can raise - nothing is open yet"
  echo "    with open(p,'wb') as fh: fh.write(data)"
} >&2

exit 2
