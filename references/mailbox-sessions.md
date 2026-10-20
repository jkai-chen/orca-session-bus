# Sessions without built-in messaging (the mailbox)

Read this before you start, brief, message or retire a session whose agent has no cross-session messaging. That covers
most CLI agents (Codex, Gemini CLI, aider and others), and any agent on a machine where the native bus doesn't reach.

A common split, and why: sessions that coordinate (leads, builders) run on an agent with native messaging and
sub-agents; cheap, repetitive review and test jobs run on whichever provider is cheapest, often on a second machine.
Keep the "who runs where" table in the routing table, so a new lead doesn't have to guess.

## The mailbox protocol

- **Outgoing:** one status file per session, for example `~/agent-status/<name>.md`.
  - Its first line must be exactly `# <name> status`. A reader that splits files by header would otherwise merge it
    into the previous session's file and drop its lines silently.
  - Sends go under `## OUTBOX` as `To <session> [msg <YYYYMMDD-HHMMSS>-<name>-<n>]: <text>`.
  - Replies go under `## REPLIES` as `Reply [msg <their id>] to <session>: <text>`.
  - Keep the file small (under ~64 KB) so pollers accept it.
- **Incoming:** a relay polls the status files and types new messages into the target pane, only at an idle prompt. The
  relay can be a session on the native bus or a small script.
- **Ids:** the message id makes resends and replies traceable, and lets the relay skip duplicates.
- **Stamps:** every time comes from `date`, never estimated. Agents that estimate drift by tens of minutes.

## Starting one in Orca

1. **Give it its own Orca worktree**, so it is visible and named in Orca. A terminal created in the main checkout hides
   under the "main" workspace with whatever title the agent picks:
   `orca worktree create [--environment "<host>"] --repo path:<repo> --name <name> --base-branch origin/main --setup skip`
2. **Settle trust and permissions before launch.** Many agents ask "Trust this folder?" on first run. Pre-trust the exact
   path in the agent's config instead of answering interactively. For Codex, add `[projects."<path>"]` with
   `trust_level = "trusted"` to `~/.codex/config.toml`; a parent folder's trust isn't inherited, and answering the
   prompt can append a duplicate key that stops the whole config loading. Then check the config still loads.
3. **Launch through an Orca terminal** (agent-launch helpers may not support replay on a remote host):
   ```bash
   W=<worktree path>
   orca terminal create [--environment "<host>"] --worktree path:$W --title "<name>" \
     --command "cd $W && <agent command> '<prompt pointing at its brief file>'"
   ```
4. **Rename the tab** after launch, since some agents retitle it:
   `orca terminal rename [--environment "<host>"] --terminal <handle> --title "<name> (<agent>)"`.
5. **Brief it from a written file**, not a long typed prompt. Cover:
   - its rules and its worktree;
   - where full logs go;
   - which shared resources (databases, test slots) it may use, and when;
   - the status-file format;
   - "stamp from `date`".
6. **Pair it with the relay.** Its lead sends the relay its name, pane handle, host, owner and status file.
7. **Add its routing row** (`route.sh set`), with the agent and model recorded and `reach=mailbox`.

It's done when its first OUTBOX line (for example `READY`) reaches its lead through the relay.

## Guard rails for unattended sessions

Unattended sessions shouldn't stop on permission prompts, and they shouldn't be able to destroy things either.
- **Agents with hooks** (Claude Code's `PermissionRequest` hook, for example): allow ordinary commands, deny a
  destructive list with "send it to your lead", and pass the lead's own worktree through to the human. Log every
  decision. `assets/permission-gate.example.sh` is a starting point.
- **Agents with a command policy file** (Codex's execpolicy rules, for example): forbid `git push`, `git reset --hard`,
  `git clean`, forced worktree removal, docker prune, cloud CLIs and destructive `rm`. Check that the policy still
  holds under any "bypass approvals" flag you launch with: run one command that must be rejected, and confirm it is.
- **Agents with neither:** run them in a sandbox or a separate user account. A prompt alone isn't a guard.

## Delivering into a pane

Deliver only at an idle, empty prompt, then read the pane to confirm the message landed. Learn each agent's idle marker:
the prompt character plus its placeholder text and footer line. Any other text after the prompt marker is a draft, so
never type over it.

## Retiring one to make room

Machines have a practical cap on concurrent sessions. To retire one:
1. At its next free point, it writes its handoff into its status file.
2. Close it cleanly, stopping its scheduled jobs.
3. Retire its routing row (`route.sh retire`).
4. Tell the relay to drop the pane.
