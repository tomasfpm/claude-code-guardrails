#!/usr/bin/env bash
# PreToolUse(Bash) — refuse to pipe downloaded content straight into a shell.
#
# WHY THIS IS A HOOK AND NOT A PERMISSION RULE
# The obvious first attempt is two deny rules in settings.json:
#
#     "Bash(:(){:|:&};:)"     -> skipped, empty parentheses
#     "Bash(curl:*|*sh)"      -> skipped, ":*" must be at the end
#
# Both are silently invalid. Claude Code prints a warning and carries on, so the file LOOKS
# protective and enforces nothing. In the setup this came from, they sat on a server for its
# whole life before anyone noticed.
#
# They were never fixable as patterns. A permission rule matches the command PREFIX, so it
# cannot see a pipe in the middle, and `Bash(curl:*)` would have to ban curl outright to
# catch `curl x | sh`. A fork bomb has unlimited spellings. Deciding on the actual command
# text needs code, and code is what a hook is.
#
# WHAT IT BLOCKS
#   anything | sh|bash|zsh|ksh|dash        curl … | sudo bash        wget -O- … | sh
#   the classic fork bomb
# It does NOT block downloading a script, reading it, and then running it. That is the point:
# the danger is executing bytes nobody looked at, not fetching them.
#
# EXIT CODES: 0 = allow, 2 = block and tell Claude why (stderr is shown to the model).

payload="$(cat)"

# python3 on Linux, python in Git Bash on Windows. Resolving this explicitly matters: the
# first version of this hook hardcoded python3, silently extracted nothing on Windows, and
# FAILED OPEN — allowing every command it was written to stop. A guard that cannot run must
# say so, never shrug.
# Note: `command -v python3` is NOT enough. On Windows it resolves to the Microsoft Store
# stub, which exits 0 and prints nothing — so the guard "found" an interpreter that silently
# returned an empty command and allowed everything. Test that it actually runs.
PY=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 || continue
  [ "$("$c" -c 'print("ok")' 2>/dev/null)" = "ok" ] && { PY="$c"; break; }
done
if [ -z "$PY" ]; then
  echo "BLOCKED: block-pipe-to-shell.sh found no python to parse the hook payload." >&2
  echo "Fix the hook or remove it — it is not silently allowing commands it cannot inspect." >&2
  exit 2
fi

cmd="$(printf '%s' "$payload" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
print((d.get("tool_input") or {}).get("command", ""))
' 2>/dev/null)"

[ -z "$cmd" ] && exit 0

# Pipe into a shell interpreter, with or without sudo and with or without an absolute path.
if printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(sudo[[:space:]]+)?(/(usr/)?bin/)?(ba|z|k|da)?sh([[:space:]]|$)'; then
  echo "BLOCKED: piping content directly into a shell executes code nobody has read." >&2
  echo "Download it, read it, then run it as a file — that is the whole difference." >&2
  exit 2
fi

# The classic fork bomb, and the reason the old pattern rule could not express it.
if printf '%s' "$cmd" | grep -Eq ':\(\)[[:space:]]*\{.*\|.*&[[:space:]]*\}[[:space:]]*;[[:space:]]*:'; then
  echo "BLOCKED: fork bomb." >&2
  exit 2
fi

exit 0
