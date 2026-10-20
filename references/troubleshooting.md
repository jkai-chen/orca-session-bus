# A message bounced, or a session is missing from ListAgents

Work down the list; most cases end at step 1.

1. **Split bus.** Run `bash "$SKILL_DIR/scripts/bus-link.sh" --check`. A `SPLIT` line is the cause: run the script
   without `--check`. Both groups show up in `ListAgents` within a few seconds. Then check the guard is running
   (`pgrep -f bus-guard.sh`); a split that keeps coming back means it isn't.
2. **Registered somewhere else.** If every profile says `linked`, look for the session's registry file by its pid:
   `ls "${SESSION_BUS_DIR:-$HOME/.claude/sessions}/<pid>.json"`. A missing file means it registered under another
   `CLAUDE_CONFIG_DIR`; read it with `ps eww -o command= -p <pid>` and link that location too.
3. **A name clash.** `bus-link.sh` prints `LEFT` when a profile's registry file has the same name as one in the shared
   folder. Compare the two files (the pid in the name tells you which process each belongs to), remove the one whose pid
   is dead, and run the script again.
4. **It's not a Claude session.** Codex and other providers are never on the bus. See
   [multi-provider.md](multi-provider.md).
5. **Delivery was held, not lost.** A session running in a different permission mode can hold cross-session messages
   for its user's approval. The send succeeds, but nothing is read. Ask its user, or use the pane fallback.

Until it's fixed, reach the session through its pane (see [routing-table.md](routing-table.md)).

## Messages arrive late or out of order

Cross-session messages are read between tool rounds, not mid-tool. A session busy in a long command reads them when it
finishes. Two leads sending conflicting instructions will cross; whoever receives them should act on the one with the
later timestamp *taken from `date`* (sessions estimating the time drift by tens of minutes), and say so.

## Duplicate crons or reminders after a resume

`--resume` can bring back the old session's crons, and a session closed with "Move to background and exit" leaves a
`claude daemon` firing them under the same name. Run `CronList` first after any resume, delete duplicates, and close
sessions with **"Exit and stop tasks"** when you intend to resume them elsewhere.
