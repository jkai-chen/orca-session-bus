# The routing table: the fallback that is always current

Keep one file (for example `ROUTING.md` next to your project notes) that lists every session on every provider and
machine: name, role, owner, bus (which registry or "status file"), pane handle, host, provider/model, successor.

Why it matters: when the bus splits, the only way to reach a session is its pane, and only the table knows the handle.
It is also the record of who exists, so nobody briefs a session that has already ended.

## One editor

Give the file exactly one editor (usually the coordinating lead). Everyone else sends one line:
`ROUTING: <session> <field> <new value>`, or `ROUTING ok` when asked to confirm. Concurrent edits to a shared table lose
rows silently.

- **Session starts:** its starter sends the full row at once.
- **Session ends:** its owner reports it; the row is deleted, not left "idle".
- **Session moves** (pane, account or machine): it sends the new Pane or Bus.
- **Lead handover:** the outgoing lead names the successor in the table before stopping.

Each sweep, the editor re-checks rows against the registries (`ls ~/.claude/sessions/*.json`) and
`orca terminal list`, and fixes drift.

## Copying it to another machine

If sessions on a second machine read the table, publish a read-only copy atomically so nobody reads a half-written
file: write a temp file, `chmod 444` it, then `mv` it over the destination.

## Reaching a session through its pane

```bash
T=<handle from the table>; [ -n "$T" ] && orca terminal send [--environment "<host>"] --terminal "$T" --text "…" --enter
```

The empty-handle guard matters: `orca terminal send` without a terminal types into whatever pane is active.
