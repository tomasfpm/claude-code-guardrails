#!/usr/bin/env bash
# Decide whether the-clerk is worth spawning - for about zero tokens.
#
#   ./agents/should-i-run.sh
#
# WHY THIS EXISTS
# the-clerk cost ~67k tokens a run, measured over two runs. Most of that is READING: every
# note, every repo, an SSH round trip. Spawning it to be told "books balance" is the single
# most wasteful thing an agent setup can do.
#
# Almost every finding it can produce starts as a dirty file, an unpushed commit, or a note
# whose `updated:` is behind its last real edit. All three are detectable by `git` for free.
# So: run the cheap check first, and only spend the 67k when this says there is something
# to find. On its first day this script found the same three stale notes the clerk had
# charged 67k for.
#
# The rule underneath: a script counts, an agent reasons about what the counts mean. Do not
# pay an agent to count.
#
# CONFIG
#   CLERK_REPOS    newline-separated repo roots, or one per line in ~/.claude/clerk-repos.txt
#   NOTES_REPO     optional: a markdown notes repo whose `updated:` frontmatter to check
#
# Exit 0 = nothing found, do not spawn. Exit 1 = findings, spawning is justified.

set -uo pipefail

if [ -n "${CLERK_REPOS:-}" ]; then
  mapfile -t REPOS < <(printf '%s\n' "$CLERK_REPOS")
elif [ -r "$HOME/.claude/clerk-repos.txt" ]; then
  mapfile -t REPOS < <(grep -v '^[[:space:]]*\(#\|$\)' "$HOME/.claude/clerk-repos.txt" | tr -d '\r')
else
  echo "No repos configured. Set CLERK_REPOS or list them in ~/.claude/clerk-repos.txt." >&2
  exit 2
fi
NOTES="${NOTES_REPO:-}"

found=0
note() { printf '  %s\n' "$1"; found=1; }

echo "== git state =="
for r in "${REPOS[@]}"; do
  [ -n "$r" ] || continue
  [ -d "$r/.git" ] || { note "MISSING: $r is not a git repo"; continue; }
  name="$(basename "$r")"

  dirty="$(git -C "$r" status --porcelain 2>/dev/null | wc -l)"
  [ "$dirty" -gt 0 ] && note "$name: $dirty uncommitted change(s)"

  # unpushed, without contacting the remote (cheap and offline-safe)
  if git -C "$r" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    ahead="$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "$ahead" -gt 0 ] && note "$name: $ahead commit(s) not pushed"
  else
    note "$name: no upstream branch set"
  fi

  branch="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$branch" = "HEAD" ] && note "$name: detached HEAD"
done

if [ -n "$NOTES" ] && [ -d "$NOTES/.git" ]; then
  echo "== notes frontmatter =="
  # `updated:` behind the note's last real edit - the one kind of drift that is silent.
  #
  # ⚠️ WHY IT ASKS GIT AND NOT THE FILE'S MODIFIED TIME. The first version compared against
  # mtime, which a sweep changes without changing a fact: one commit that renamed a project
  # touched 18 notes by a line or two each and left every one of them permanently "stale".
  # A check that always fires is a thing you learn to scroll past - and on the day it was
  # caught it was burying the three notes that were genuinely out of date.
  #
  # So: compare against the last commit that changed the note by more than a trivial number
  # of lines. ⚠️ That threshold is a heuristic that cannot be made exact - no line count
  # tells "renamed a word 8 times" from "rewrote a paragraph". It turns 18 false alarms into
  # a handful. It does not make the check correct, and should not be trusted as if it were.
  MIN_REAL_EDIT=12
  stale=0
  while IFS= read -r f; do
    u="$(sed -n 's/^updated: \([0-9-]*\)$/\1/p' "$f" | head -1)"
    [ -n "$u" ] || continue
    m=""
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      ch="$(git -C "$NOTES" show --numstat --format= "$sha" -- "$f" 2>/dev/null \
            | awk '{a+=$1; d+=$2} END {print a+d+0}')"
      if [ "${ch:-0}" -ge "$MIN_REAL_EDIT" ]; then
        m="$(git -C "$NOTES" show -s --format=%ad --date=short "$sha" 2>/dev/null)"
        break
      fi
    done < <(git -C "$NOTES" log --format=%H -20 -- "$f" 2>/dev/null)
    # An uncommitted edit is not in history yet, so fall back to mtime for those.
    if [ -z "$m" ] && [ -n "$(git -C "$NOTES" status --porcelain -- "$f" 2>/dev/null)" ]; then
      m="$(date -r "$f" +%Y-%m-%d 2>/dev/null)"
    fi
    [ -n "$m" ] || continue
    [[ "$u" < "$m" ]] && { note "$(basename "$f"): updated=$u, last real edit $m"; stale=$((stale+1)); }
  done < <(find "$NOTES" -name '*.md' -not -path '*/.git/*' -not -name '_template.md')
  [ "$stale" -eq 0 ] && echo "  (none)"
fi

echo
if [ "$found" -eq 0 ]; then
  echo "NOTHING TO AUDIT - do not spawn the-clerk."
  exit 0
fi
echo "FINDINGS ABOVE - spawning the-clerk is justified. Scope its task to what is listed."
exit 1
