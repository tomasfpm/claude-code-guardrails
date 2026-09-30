# claude-code-guardrails

Five hooks and three reviewer agents for [Claude Code](https://docs.claude.com/en/docs/claude-code),
each one built after something actually went wrong, and each one tested against the input it
will really receive.

## In plain words

An AI coding assistant follows written instructions *most* of the time. "Most" is the
problem: a rule like "never empty a file by accident" has to be remembered at exactly the
moment it matters, and that is the moment it gets forgotten.

A **hook** is different. It is a small script that Claude Code itself runs at fixed moments —
when a session starts, before a command runs, after a command runs, when the session tries to
end. The model does not get a vote. It is the difference between a sign saying "mind the
step" and a handrail.

An **agent** here means a second, separate copy of Claude that starts with a blank memory,
does one job and reports back. The three in this repo are reviewers. Their value comes from
*not* having seen the conversation that produced the work they are checking.

## What's in it

### Hooks (`hooks/`)

| Hook | When it runs | What it does | Why it exists |
|---|---|---|---|
| `block-pipe-to-shell.sh` | before every shell command | refuses `curl … \| sh`, `wget … \| sudo bash` and the fork bomb | the permission-rule version of this is **silently invalid** — Claude Code warns once and enforces nothing |
| `zero-byte-guard.sh` | after every shell command | notices when a tracked file that had content is now 0 bytes, and puts the one-line recovery in front of the model | a failed write truncated three files in one week, and a written rule about it prevented none of them |
| `session-clock.sh` | session start and end | tells Claude the time and how long since the last session on this machine | the model knows the date but not the gap, and once reasoned as if the user were still on holiday days after they got back |
| `notes-pull.sh` | session start (async) | rebases a shared notes repo, but only if its tree is clean | several sessions on several machines share one notes repo |
| `notes-writeback-gate.sh` | session end | refuses to let the session finish with uncommitted notes | edits left locally are invisible to every other machine |

### Agents (`agents/`)

| Agent | Job | Measured cost per run |
|---|---|---|
| `fresh-eyes` | read-only code review of something Claude just wrote, judged against the stated intent — not the author's reasoning | ~43k tokens (average of three runs) |
| `security-master` | static security review of your own code: auth, secrets, trusting the client. Never attacks a live system | per feature, not per session |
| `the-clerk` | end-of-session audit: uncommitted or unpushed work, broken links, and the same fact drifting between two files | ~67k tokens (two runs) |
| `should-i-run.sh` | **not an agent** — a free script that decides whether `the-clerk` is worth spawning | ~0 tokens |

That last line is the most useful idea in the repo. The clerk costs 67k tokens, and most of
that is *reading*. Almost everything it can find starts as a dirty file or an unpushed commit,
which `git` can detect for free. On its first day, the script found the same three stale
notes the clerk had just charged 67k for. **A script counts; an agent judges what the count
means. Don't pay an agent to count.**

## The three things worth knowing about hooks

These are what the incidents behind this repo taught, and none of them is obvious from the
docs.

### 1. Each event talks back through a different channel

Same word, different contracts. Use the wrong channel and you get a hook that runs perfectly
and does nothing.

| Event | How the hook reaches Claude |
|---|---|
| `SessionStart` | **plain stdout** is added to the session's context as text |
| `PreToolUse` | **exit code 2 blocks the tool**; stderr is shown to the model as the reason |
| `PostToolUse` | **exit code 2**, stderr shown to the model. The tool has *already run*, so this cannot prevent anything — it makes the damage impossible to miss |
| `Stop` | **JSON on stdout**: `{"decision":"block","reason":"…"}` makes the session carry on |

### 2. A hook sees an event, not an actor

The Stop gate once fired on a *read-only* Claude session — one launched with no write tools
— and demanded a commit it had no way to make. It argued with the gate for five replies in a
row instead of answering questions. The hook couldn't tell that session from a normal one,
and no amount of cleverness inside the hook could fix that. The fix came from outside: the
caller declares itself with `READONLY_SESSION=1`.

Every hook bug so far came from asking a hook to know something only its caller knows.

### 3. A guard that can't run must fail closed, loudly

The first version of `block-pipe-to-shell.sh` hardcoded `python3`. On Windows that resolves
to the Microsoft Store stub, which exits 0 and prints nothing — so the hook parsed an empty
command and **allowed everything**. It now checks that its interpreter actually runs, and
blocks with a clear message if none does.

And the mirror image: a guard that fires on harmless things gets ignored. The zero-byte guard
deliberately ignores placeholder files and new empty files, and the notes gate ignores
Obsidian's zoom-level noise. The tests check those negative cases just as hard as the
positive ones.

## Install

Requirements: `bash` (Git Bash on Windows is fine), `git`, and Python 3 for the pipe guard.
No `jq`.

```bash
git clone https://github.com/<you>/claude-code-guardrails ~/claude-code-guardrails
bash ~/claude-code-guardrails/tests/run.sh
```

**Hooks:** merge `examples/settings.json` into `~/.claude/settings.json` (every project) or a
project's `.claude/settings.json` (one project). Take only the hooks you want. The two notes
hooks do nothing until you point them at a repo:

```json
{ "env": { "NOTES_REPO": "/path/to/your/notes" } }
```

⚠️ Hooks in `~/.claude/settings.json` run in **every** Claude Code session on the machine.
To undo, delete the entries you added. The settings file points at these scripts by path, so
if you move the folder, the hooks stop firing without saying so.

**Agents:** copy them to `~/.claude/agents/`, then fill in the "project-specific" section at
the bottom of each one. A reviewer that starts blind doesn't know your codebase's traps;
those few lines are the cheapest way to tell it.

```bash
cp ~/claude-code-guardrails/agents/*.md ~/.claude/agents/
```

For `the-clerk` and `should-i-run.sh`, list your repos one per line in
`~/.claude/clerk-repos.txt`.

## Design rules the agents follow

- **Read-only, all three.** A reviewer that can fix things becomes an author and stops being
  independent. A security auditor that can act is a security problem of its own. A clerk that
  commits its own findings removes the check that made it worth trusting. Note that
  read-only is enforced by the `tools:` list for editing, but only *by instruction* for
  `Bash` — that part is a prompt, not a sandbox.
- **Never a weaker model than the author.** A reviewer that is less capable than the thing it
  reviews is a rubber stamp that costs tokens. These inherit the session's model on purpose.
- **"Nothing found" is a valid answer.** Every finding must name the input that triggers it
  and what goes wrong. A reviewer that invents problems to look thorough trains you to
  ignore it.

## Tests

```bash
bash tests/run.sh
```

23 cases, run against throwaway git repos in a temp folder — nothing on your machine is
touched. The payloads are passed with `< file`, never `echo … |`, because run through Claude
Code the pipe guard would block the test itself: feeding a hook its own input looks exactly
like piping a download into a shell.

## Licence

MIT. See `LICENSE`.
