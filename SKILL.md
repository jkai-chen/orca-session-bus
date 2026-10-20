---
name: orca-session-bus
description: "Keep a team of long-running AI agent sessions reachable from each other when they run in Orca across several accounts, machines and providers (any CLI agent: Claude Code, Codex, Gemini CLI, aider and the like). Use this whenever a message between sessions bounces or never arrives, a running session is missing from the agent list, you are about to switch the active account, sessions need to move to another account (usage limit, plan change), a session starts, ends or moves and the routing table needs a row, or you start, brief or message a session whose agent has no built-in cross-session messaging. Also use it when agents 'can't see each other' after an account switch or an Orca update, even if nobody says 'bus'."
---

# Orca session bus

Multi-agent work in Orca breaks in quiet ways. Sessions stop seeing each other after an account switch. A moved
session keeps firing its old scheduled jobs. Agents without built-in messaging can't receive anything at all. This
skill keeps every session reachable, whatever account, machine or provider it runs on, and gives you a fallback for
when messaging fails.

## Three ways a session can be reached

Every session falls into one of these. Find out which before you message it:

1. **Native bus.** The agent has built-in cross-session messaging backed by a registry folder that all sessions read,
   for example Claude Code's `sessions/` registry used by its SendMessage and ListAgents tools. It's fast and
   reliable, as long as everyone shares the same registry.
2. **Mailbox.** The agent has no built-in messaging. It writes outgoing messages to a status file, and a relay types
   incoming ones into its pane. This covers most CLI agents. See [references/mailbox-sessions.md](references/mailbox-sessions.md).
3. **Pane.** Last resort for anyone: type into the Orca terminal pane by its handle. It always works, but it's
   unstructured and can collide with a human or another sender.

The routing table records which way each session is reached
([references/routing-table.md](references/routing-table.md)).

## Why accounts split the native bus

Orca keeps a profile home per managed account. On macOS that's
`~/Library/Application Support/orca/<provider>-profiles/<id>/home` (`claude-profiles` today). It links shared folders
(transcripts, skills, plugins) back to the provider's main config folder, but gives each profile its **own** session
registry. So sessions started under different accounts land on different buses. They keep running and can still type
into each other's panes, but native messages between the groups bounce.

The fix: make every profile's registry folder a symlink to one shared folder. Transcripts are already shared, so
resuming a conversation works under any account.

## Pick the task

| Situation | Go to |
| --- | --- |
| Before or after switching the active account, or after an Orca update | [Link the bus](#link-the-bus) |
| A message bounced, or a live session is missing from the agent list | [references/troubleshooting.md](references/troubleshooting.md) |
| Running sessions must move to another account | [references/moving-sessions.md](references/moving-sessions.md) |
| Starting, briefing, messaging or retiring a session without built-in messaging | [references/mailbox-sessions.md](references/mailbox-sessions.md) |
| A session starts, ends or moves, or messaging is down and you need to reach someone | [references/routing-table.md](references/routing-table.md) |

## Link the bus

The scripts in `scripts/` default to Claude Code's layout: the `claude-profiles` folder and `~/.claude/sessions`. For
another provider with per-account profiles and a registry folder, set the environment variables below. `$SKILL_DIR`
means this skill's folder.

1. Check: `bash "$SKILL_DIR/scripts/bus-link.sh" --check`. Every profile should print `linked`.
2. For any `SPLIT` line, run the script without `--check`. It moves the profile's live registry entries into the
   shared folder and replaces the profile's folder with a symlink. It's idempotent, so re-running is safe.
3. Switch the account, if that's why you're here. New panes now register on the shared bus.
4. You're done when an older session's agent list shows a session started after the switch.

**Keep it linked.** Starting, resuming or compacting an agent process on a profile can recreate a real registry folder
and split the bus again, and so can an Orca update. Run the guard once per machine; it re-links within about 15 s:

```bash
nohup bash "$SKILL_DIR/scripts/bus-guard.sh" >/dev/null 2>&1 &   # log: $BUS_GUARD_LOG
pgrep -f bus-guard.sh                                            # empty = not running; start it again
```

A message sent inside that 15 s gap can still bounce. Resend it once.

Settings (all optional):

| Variable | Default | What it is |
| --- | --- | --- |
| `ORCA_PROFILES_ROOT` | `~/Library/Application Support/orca/claude-profiles` | Orca's profiles folder for the provider (set it on Linux) |
| `SESSION_BUS_DIR` | `~/.claude/sessions` | the shared registry every profile should point at |
| `BUS_REGISTRY_NAME` | `sessions` | the registry folder's name inside each profile home |

## Which account is a session on?

Read the process environment for the profile path:

```bash
ps eww -o command= -p <pid> | tr ' ' '\n' | grep -E '^[A-Z_]*CONFIG_DIR='   # e.g. CLAUDE_CONFIG_DIR; none = the default
```

Match the provider's config-dir variable itself. Other variables (Orca's profile pointers, for example) also name a
profile and will mislead you.

## Typing into a pane safely

Every fallback ends in `orca terminal send`. An empty `--terminal` sends to the *active* pane, which belongs to someone
else's session, so always guard the handle:

```bash
T=<pane handle>; [ -n "$T" ] && orca terminal send --terminal "$T" --text "…" --enter
```

Add `--environment "<host>"` for a pane on another Orca host. Type only into an idle, empty prompt; anything after the
prompt marker is someone's draft.
