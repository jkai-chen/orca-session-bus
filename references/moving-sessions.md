# Moving running sessions to another account

Switching the account in Orca only affects **new** panes. A running session keeps the account it started on until it
is restarted. To move one, restart it in the same pane under the target profile and resume its conversation:

- kept: the conversation and context (transcripts are shared across profiles), the pane handle, the session name;
- lost: anything that lived in the agent process: scheduled jobs, background shells, watchers and sub-agents (re-arm them after the move);
- untouched: `nohup` processes and jobs on other machines.

Link the bus first (`bus-link.sh`), or the moved session lands on a separate registry.

## One session

```bash
bash "$SKILL_DIR/scripts/move-session.sh" <name> <pane> <pid> <session-id> [target-profile-home]
```

- `<pid>` and `<session-id>` come from the agent's registry (for Claude Code, `~/.claude/sessions/<pid>.json`, fields `sessionId` and `name`).
- The target defaults to the account Orca has selected now (`$ORCA_PROFILES_ROOT/selected-host`).
- The re-arm prompt sent to the restarted session comes from `REARM_PROMPT`; set `REPORT_TO=<lead session name>` to
  have the default prompt ask it to report back there.
- The built-in exit and resume steps match Claude Code. For another agent, set `AGENT_EXIT` (its quit command) and
  `AGENT_RESUME_CMD`, a command template with `{profile}`, `{name}`, `{id}` and `{prompt}`, for example
  `AGENT_RESUME_CMD='MYAGENT_HOME="{profile}" myagent --resume {id} {prompt}'`. For Claude Code, extra flags go in
  `CLAUDE_FLAGS` (default `--dangerously-skip-permissions`; match how your sessions normally run).

What the script does, so you know what to expect:
1. Refuses unless the pane's footer shows `<name>` (it never restarts the wrong session).
2. Waits up to 10 minutes for the pane to go idle; never interrupts a running turn.
3. Clears the input line, sends the exit command, answers Claude Code's "Exit and stop tasks" if the session has
   scheduled jobs, discards (never sends) any open feedback draft, and waits for the pid to end.
4. Relaunches the resume command in the same pane, under the target profile.
5. Re-links the bus and prints the new pid.

## Everyone at once (a lead coordinates)

1. Write `sessions.txt` in a fresh folder: one line per session, `<name> <pane> <pid> <session-id>`. Skip dead pids.
   Put your own session **last**.
2. Start the mover: `MOVE_DIR=<folder> nohup bash "$SKILL_DIR/scripts/mover.sh" >/dev/null 2>&1 &`.
3. Tell every session: at its next safe point (never mid-test, mid-migration or mid-DB-run) it writes its re-arm list in
   its notes, stops its background jobs, then, as the **last action of its turn**, runs `touch <folder>/<its name>.ready`.
4. The mover restarts each ready session once its pane is idle (log `<folder>/mover.log`; `<name>.done` marks it
   moved). It gives up after 3 hours.
5. When all others are done, touch your own `.ready` and end your turn; the mover restarts you last. After your
   restart, list your scheduled jobs before re-creating anything (a resume can bring old ones back), update the Bus column in the routing table, and run
   `bus-link.sh --check`.

Why the coordinator goes last: if it moved first, nobody would be left to watch the mover or answer stuck sessions.
