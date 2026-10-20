# The routing table: the fallback that is always current

A SQLite database lists every session on every provider and machine: name, role, owner, how it's reached (`bus`,
`mailbox` or `pane`), pane handle, host, agent/model, account, status, successor, notes, last seen. `scripts/route.sh`
reads and writes it. A generated markdown file (`ROUTING.md`) is the human-readable view and the fallback when the
database or its tooling is unavailable.

Why it matters: when the bus splits, the only way to reach a session is its pane, and only the table knows the handle.
It is also the record of who exists, so nobody briefs a session that has already ended.

## Who picks the master: the user

**With more than one host, the user picks the master host. Ask, don't assume.** An agent must never choose the master
itself, not even "the machine I'm on". Ask which host holds the master database before running `init --master`, and ask
again before any `promote`. The choice is recorded (`master_host`, `chosen_by`, `chosen_at`), shown by `route.sh role`
and in the markdown header, and every master change is written to the history.

## One master, synced replicas

- The **master** is the one machine where the database file and a `<db>.master` marker file both exist. Only the master
  accepts writes. Concurrent writers on SQLite (WAL, busy timeout) are safe on one machine, so any session on the master
  machine can run `route.sh` directly.
- A **replica** is a read-only copy on another machine, refreshed from the master. It answers reads (`get`, `list`,
  `who`, `history`) and refuses writes with "replica: send the change to the master, or promote". `route.sh init`
  without `--master` creates an empty replica, so nothing becomes a master by accident.
- Everything is local disk. **Never put the database on a network share or synced folder** (NFS, SMB, Dropbox, iCloud):
  SQLite's locking is unreliable there and a corrupted table is worse than a stale one. Replicate copies instead.

## Who writes

Set `ROUTE_ACTOR` to your session name; writes require it and stamp `updated_by` and `updated_at`.

```bash
export ROUTE_ACTOR=<your session name>
bash scripts/route.sh set worker-2 role="reviewer" owner=lead reach=mailbox pane=<handle> host=<env> agent=codex
bash scripts/route.sh set worker-2 status=moved successor=worker-3
bash scripts/route.sh retire worker-2 [successor]      # session ended: keep the row visible for the day
bash scripts/route.sh who reviewer                     # who has this role, and how to reach them
bash scripts/route.sh history worker-2                 # who changed what, old and new values
```

- **On the master machine:** any session runs `route.sh` itself.
- **On a replica machine:** send the master's owner one line through the mailbox, relay or pane:
  `ROUTING: <session> <field>=<value> ...`. The master applies it with `route.sh set`. Never edit a replica; it would be
  overwritten.
- **Session starts:** its starter sets the full row. **Ends:** `retire` it (it shows under "Retired today", then drops
  out of the view; the history keeps it). **Moves** (pane, account, machine): `set` the new pane, host or bus.
- **Lead handover:** set the successor's row before the outgoing lead stops.

`route.sh sweep` compares active rows with the native registry (default `~/.claude/sessions/*.json`, set
`SESSION_BUS_DIR`) and `orca terminal list`, and prints rows with no live session and live sessions with no row. It
changes nothing unless you pass `--apply`, which only stamps `last_seen`. Set `ROUTE_HOST` so rows for other hosts are
skipped rather than reported missing.

Moving from an old markdown table: `route.sh import ROUTING.md` once. It maps headers case-insensitively, keeps unmapped
columns in notes, and prints every row or column it could not map. Check the output, then retire the old file.

## The markdown view and replication

`route.sh render [file]` writes the active sessions plus "Retired today" atomically (temp file, `chmod 444`, `mv`). Read
it when the database is out of reach.

On the master, `route.sh replicate` takes a consistent snapshot (`VACUUM INTO`), renders the markdown, and copies both
to every target in `ROUTE_REPLICAS` (space-separated): a local directory, or `host:dir` over ssh/scp (absolute, or
relative to the remote home). Each file lands under a temp name, is made read-only, then renamed, so readers never see
a half-written file. Orca-environment targets are not supported, since the orca CLI has no file copy. To keep replicas
fresh, run the watcher once on the master:

```bash
ROUTE_REPLICAS="otherhost:.orca-session-bus" nohup bash scripts/route-replicator.sh >/dev/null 2>&1 &
```

It replicates every `ROUTE_REPLICATE_INTERVAL` seconds (default 60) only if something changed. Point each replica
machine's `ROUTE_DB` at the copied file.

## Disaster failover: promote and demote

The master machine is down and will stay down for a while. **Ask the user which host to promote, and confirm the old
master is down or will be demoted.** Then:

1. On the chosen replica, check the copy is recent: `route.sh role` and `route.sh history | head`. Anything written
   after the last replication is lost; ask the owners to resend recent changes afterwards.
2. `ROUTE_ACTOR=<name> route.sh promote --yes`. Without `--yes` it only prints the warning. It makes the copy writable,
   creates the marker, records the new master host and chooser, and writes a history entry.
3. Set `ROUTE_REPLICAS` there and start `route-replicator.sh`, so the other machines follow the new master.
4. Tell every session where to send changes now.
5. **Before the old master comes back**, run `route.sh demote` on it (or, if it cannot start, delete its marker file
   `<db>.master` first). That removes the marker, makes the file read-only and records the demotion. Two masters is split
   brain: both accept writes and rows are lost. After demoting, let replication overwrite it from the new master.

To move the master on purpose (not a disaster), replicate, promote the new host, then demote the old one.

## Reaching a session through its pane

```bash
T=<handle from the table>; [ -n "$T" ] && orca terminal send [--environment "<host>"] --terminal "$T" --text "…" --enter
```

The empty-handle guard matters: `orca terminal send` without a terminal types into whatever pane is active.

## Settings

| Variable | Default | What it is |
| --- | --- | --- |
| `ROUTE_DB` | `~/.orca-session-bus/routing.db` | the database (local disk) |
| `ROUTE_MD` | `ROUTING.md` next to the database | the markdown view |
| `ROUTE_ACTOR` | none | who is writing; required for writes |
| `ROUTE_HOST` | `hostname -s` | this machine's name; used for `master_host` and by sweep |
| `ROUTE_REPLICAS` | none | replica targets: `dir` or `host:dir` |
| `ROUTE_REPLICATE_INTERVAL`, `ROUTE_REPLICATOR_LOG` | `60`, `~/.orca-session-bus/route-replicator.log` | the watcher |
