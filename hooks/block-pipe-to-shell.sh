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
#   … | sh / bash / zsh / ksh / dash / fish   with sudo, env, xargs, flags, a path or quotes
#   … | python / perl / ruby / node with no script   (the interpreter reads code from stdin)
#   bash <(curl …)        sh -c "$(curl …)"        … | $SHELL        the classic fork bomb
# It does NOT block downloading a script, reading it, and then running it. That is the point:
# the danger is executing bytes nobody looked at, not fetching them.
#
# ⚠️ WHAT IT IS NOT: a security boundary. It is a regex over the command text, and shell has
# endless spellings - base64, a variable holding the word "bash", a script written to disk and
# run by the next command. It catches the common spellings a model writes out of habit, or
# that a README tells it to paste. The real controls are Claude Code's permission prompt and
# a sandbox. A security review of this repo got past the first version five different ways;
# those five are now in the tests, and the claim is now smaller.
#
# It will also block `make || bash fix.sh`, because `||` contains a pipe character. Rare, and
# the direction to be wrong in.
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

# Each pattern is one way of running text as code without it ever being a file you can read.
WRAP='((sudo|env|xargs|command|exec|nohup)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)*'
Q="[\"']?"
SHELLS="${Q}([^[:space:]|;&\"']*/)?(ba|z|k|da|fi)?sh${Q}"
END='([[:space:];&|)]|$)'
patterns=(
  "\\|[[:space:]]*${WRAP}${SHELLS}${END}"                                          # … | sudo -E bash
  "\\|[[:space:]]*${WRAP}(python[0-9.]*|perl|ruby|node)[[:space:]]*(-[[:space:]]*)?([;&|)]|\$)"  # … | python3 -
  "\\|[[:space:]]*${WRAP}${Q}\\\$\\{?SHELL"                                         # … | \$SHELL
  "(ba|z|k|da|fi)?sh[[:space:]]+<\\([[:space:]]*(curl|wget)"                         # bash <(curl …)
  "-c[[:space:]]+${Q}(\\\$\\(|\`)[[:space:]]*(curl|wget)"                            # sh -c "\$(curl …)"
)
for re in "${patterns[@]}"; do
  if printf '%s' "$cmd" | grep -Eq -- "$re"; then
    echo "BLOCKED: this runs downloaded or piped text as code that nobody has read." >&2
    echo "Download it to a file, read it, then run the file — that is the whole difference." >&2
    exit 2
  fi
done

# The classic fork bomb, and the reason the old pattern rule could not express it.
if printf '%s' "$cmd" | grep -Eq ':\(\)[[:space:]]*\{.*\|.*&[[:space:]]*\}[[:space:]]*;[[:space:]]*:'; then
  echo "BLOCKED: fork bomb." >&2
  exit 2
fi

exit 0
