---
name: orca-session-bus
description: "Keep many Claude Code (and Codex) sessions reachable from each other when they run in Orca across several accounts, machines and providers. Use this whenever SendMessage bounces, a running session is missing from ListAgents, you are about to switch the active Orca/Claude account, sessions need to move to another account (weekly limit, plan change), a session starts, ends or moves and the routing table needs a row, or you start, brief or message a non-Claude session such as Codex. Also use it when a team of agent sessions 'can't see each other' after an Orca update, even if the user doesn't say 'bus'."
---

# Orca session bus

Long-running multi-agent work in Orca breaks in quiet ways: sessions stop seeing each other after an account switch,
a moved session keeps firing old crons, and non-Claude sessions can't receive messages at all. This skill keeps every
session reachable, whatever account or provider it runs on, and gives a fallback when the bus fails.

## How the bus works (read once)

`SendMessage` and `ListAgents` only reach sessions registered in the same **registry**: the `sessions/` folder under the
session's `CLAUDE_CONFIG_DIR` (default `~/.claude/sessions`).

Orca gives every managed account a profile home (macOS: `~/Library/Application Support/orca/claude-profiles/<id>/home`).
It links that profile's `projects/`, `skills/` and `plugins/` back to `~/.claude`, but gives it its **own** `sessions/`.
So sessions started under different accounts land on different buses. They keep running and can still type into each
other's panes, but messages between the groups bounce.

The fix: make every profile's `sessions/` a symlink to one shared folder. Transcripts are already shared through
`projects/`, so `--resume` works under any account.

## Pick the task

| Situation | Do this |
| --- | --- |
| Before or after switching the active account, or after an Orca update | [Link the bus](#link-the-bus) |
| A message bounced, or a live session is missing from `ListAgents` | [references/troubleshooting.md](references/troubleshooting.md) |
| Running sessions must move to another account (limit, plan) | [references/moving-sessions.md](references/moving-sessions.md) |
| Starting, briefing, messaging or retiring a Codex (or other non-Claude) session | [references/multi-provider.md](references/multi-provider.md) |
| A session starts, ends or moves; the bus is down and you need to reach someone | [references/routing-table.md](references/routing-table.md) |

## Link the bus

Scripts live in `scripts/` next to this file; call them by their full path (`$SKILL_DIR` below means this skill's folder).

1. Check: `bash "$SKILL_DIR/scripts/bus-link.sh" --check`. Every profile should print `linked`.
2. For any `SPLIT` line, run it without `--check`. It moves the profile's live registry entries into the shared folder
   and replaces the folder with a symlink. It is idempotent, so re-running is safe.
3. Switch the account (if that's why you're here). New panes now register on the shared bus.
4. Done when `ListAgents` from an older session shows a session started after the switch.

**Keep it linked.** Starting, resuming or `/compact`-ing a `claude` process on a profile can recreate a real `sessions/`
folder and split the bus again, and an Orca update can too. Run the guard once per machine; it re-links within ~15 s:

```bash
nohup bash "$SKILL_DIR/scripts/bus-guard.sh" >/dev/null 2>&1 &   # log: $BUS_GUARD_LOG (default ~/.orca-session-bus/bus-guard.log)
pgrep -f bus-guard.sh   # empty = not running; start it again
```

A message sent inside that 15 s gap can still bounce; resend once.

Settings (environment variables, all optional):
- `ORCA_PROFILES_ROOT`: where Orca keeps account profiles. Default is the macOS path above; set it on Linux.
- `SESSION_BUS_DIR`: the shared registry. Default `~/.claude/sessions`.

## Which account is a session on?

```bash
ps eww -o command= -p <pid> | grep -oE "CLAUDE_CONFIG_DIR=[^ ]*claude-profiles/[0-9a-f]{8}"   # no output = ~/.claude
```

Match `CLAUDE_CONFIG_DIR` itself: other variables (for example `ORCA_CLAUDE_PROFILE_POINTER`) also name a profile and
will mislead you.

## Typing into a pane safely

Every fallback ends in `orca terminal send`. An empty `--terminal` sends to the *active* pane, which is someone else's
session, so always guard the handle:

```bash
T=<pane handle>; [ -n "$T" ] && orca terminal send --terminal "$T" --text "…" --enter
```

Add `--environment "<name>"` for a pane on another Orca host (a remote desktop). Type only into an idle, empty prompt;
anything after the prompt marker is someone's draft.
