# Sessions on other providers (Codex and similar)

Read this before you start, brief, message or retire a session that isn't Claude Code. The examples use Codex; the
pattern applies to any CLI agent that runs in an Orca terminal.

A typical split, and why: engineering sessions stay in Claude Code (sub-agents, cross-session messaging, hooks), while
cheap, repetitive review and test jobs run on another provider, often on a second machine. Write your own table of
who runs where and keep it in the routing file, so a new lead doesn't guess.

## Why a Codex session is never on the bus

It has no `SendMessage`, no `ListAgents` and no Claude registry entry. Give it a file-based mailbox instead:

- **Outgoing:** a status file per session (for example `~/agent-status/<name>.md`). The first line must be exactly
  `# <name> status`; a reader that splits files by header will otherwise merge it into the previous session's file and
  drop its lines. Sends go under `## OUTBOX` as `To <session> [msg <YYYYMMDD-HHMMSS>-<name>-<n>]: <text>`; replies under
  `## REPLIES` as `Reply [msg <their id>] to <session>: <text>`. Keep the file small (under ~64 KB) so pollers accept it.
- **Incoming:** a relay session (a Claude session or a script) polls the status files and types messages into the
  Codex pane, only at an idle prompt.
- **Stamps:** every line's time comes from `date`, never estimated.

## Starting one in Orca

1. **Its own Orca worktree**, so it is visible and named in Orca (a terminal created in the main checkout hides under
   the "main" workspace with a provider-chosen title):
   `orca worktree create [--environment "<host>"] --repo path:<repo> --name <name> --base-branch origin/main --setup skip`
2. **Trust the exact path before launch.** For Codex, add `[projects."<path>"]` with `trust_level = "trusted"` to
   `~/.codex/config.toml`; a parent folder's trust is not inherited. Don't answer the interactive "Trust this folder?"
   prompt: it can append a duplicate key, and a duplicate key stops the whole config loading. Check with `codex doctor`.
3. **Launch through an Orca terminal** (`orca agent launch` may not support replay on a remote host):
   ```bash
   W=<worktree path>
   orca terminal create [--environment "<host>"] --worktree path:$W --title "<name>" \
     --command "cd $W && codex -m <model> '<prompt pointing at its brief file>'"
   ```
4. **Rename the tab** after launch, since Codex retitles it:
   `orca terminal rename [--environment "<host>"] --terminal <handle> --title "<name> (Codex)"`.
5. **Brief from a written file**, not a long typed prompt: rules, its worktree, where full logs go, which shared
   resources (databases, slots) it may use and when, the status-file format, and "stamp from `date`".
6. **Pair it with the relay**: its lead sends the relay its name, pane handle, host, owner and status file.
7. **Add the routing row** with the provider and model in the role column.

Done when its first OUTBOX line (for example `READY`) reaches its lead through the relay.

## Permissions without asking the user

Unattended sessions shouldn't stop on permission prompts, but they also shouldn't be able to destroy things.
- **Claude Code:** run with the permission mode you've chosen, and add a `PermissionRequest` hook that allows ordinary
  commands, denies a destructive list with "send it to your lead", and passes the lead's own worktree through to the
  user. Log every decision. A starting point is `assets/permission-gate.example.sh`.
- **Codex:** it has no Claude hooks. Use an execpolicy rules file (for example `~/.codex/rules/guard.rules`) that forbids
  `git push`, `git reset --hard`, `git clean`, forced worktree removal, docker prune, cloud CLIs and destructive `rm`.
  Rules hold even under the bypass flag; test with `codex execpolicy check --rules <file> <command…>`, and prove it once
  with a command that must be rejected.

## Delivering to a non-Claude pane

Deliver only at an idle, empty prompt, and read the pane afterwards to confirm. Learn each provider's idle marker (for
Codex, the `›` prompt with its placeholder and the model/cwd footer line); any other text after the prompt marker is a
draft, so don't type over it.

## Retiring one to make room

Machines have a practical cap on concurrent sessions. To retire one: at its next free point it writes its handoff into
its status file; close it ("Exit and stop tasks" for Claude); delete its routing row; tell the relay to drop the pane.
