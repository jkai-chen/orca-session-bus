# orca-session-bus

An agent skill for running a team of long-running AI agent sessions side by side in Orca across several accounts,
machines and providers, without losing track of who can reach whom. It works with any CLI agent: Claude Code, Codex,
Gemini CLI, aider and others.

It covers:

- **Three ways to reach a session.** A native bus for agents with built-in cross-session messaging, a file mailbox
  plus relay for agents without it, and the Orca pane as the last resort.
- **Multiple accounts.** Orca gives each account profile its own session registry, so after an account switch new
  sessions can't message old ones. The skill links every profile to one shared registry and keeps it linked.
- **Moving sessions between accounts.** Restart a running session under another account in the same pane, keeping its
  conversation, for example before a usage limit. Move one at a time, or everyone at once with the coordinator last.
- **Agents without built-in messaging.** A status-file mailbox protocol, relay pairing, pre-trusted paths, launch
  steps, guard rails for unattended runs, and safe delivery into panes.
- **Fallbacks and troubleshooting.** A SQLite routing table (one master chosen by the user, synced read-only replicas,
  a markdown view, promote/demote failover), safe pane typing, bounced or held messages,
  crossed instructions and duplicate scheduled jobs after a resume.

## Install

```sh
npx skills add jkai-chen/orca-session-bus --skill orca-session-bus
```

For a global install into a specific agent, add `--agent <name> --global`, for example:

```sh
npx skills add jkai-chen/orca-session-bus --skill orca-session-bus --agent codex --global
```

To list the available skill:

```sh
npx skills add jkai-chen/orca-session-bus --list
```

Installation follows the [Vercel skills CLI](https://github.com/vercel-labs/skills) format. The CLI finds this
repository's root `SKILL.md` and installs its supporting files.

## Use

Ask your agent:

> My sessions stopped seeing each other after I switched Orca accounts. Use $orca-session-bus to fix it.

> Move all running sessions to my other account before the usage limit hits.

> Start a review agent on the second machine and wire it up so my lead can message it.

## Contents

- [SKILL.md](SKILL.md): the three ways to reach a session, why accounts split the bus, linking it, task routing.
- [Troubleshooting](references/troubleshooting.md): bounced or held messages, missing sessions, crossed instructions,
  duplicate scheduled jobs.
- [Moving sessions](references/moving-sessions.md): one session or everyone, safely.
- [Mailbox sessions](references/mailbox-sessions.md): agents without built-in messaging: protocol, launch, trust,
  guard rails, delivery and retiring.
- [Routing table](references/routing-table.md): the SQLite routing table, master and replicas, failover, and the
  markdown fallback.
- `scripts/`: `bus-link.sh`, `bus-guard.sh`, `move-session.sh`, `mover.sh`, `route.sh`, `route-replicator.sh`.
- `tests/route-test.sh`: tests for the routing table (`bash tests/route-test.sh`).
- `assets/permission-gate.example.sh`: an example permission hook for unattended sessions.

## Requirements

- Orca with its CLI (`orca terminal …`) on PATH.
- `bash`; `sqlite3` for the routing table; `python3` for the permission-gate example.
- The scripts default to Claude Code's layout (Orca's `claude-profiles` folder, `~/.claude/sessions`, its exit and
  resume commands). For another agent, set the variables below. The defaults are macOS paths; on Linux, set
  `ORCA_PROFILES_ROOT`. Linux hasn't been tested.

## Settings

| Variable | Default | Used by |
| --- | --- | --- |
| `ORCA_PROFILES_ROOT` | `~/Library/Application Support/orca/claude-profiles` | bus-link, move-session |
| `SESSION_BUS_DIR`, `BUS_REGISTRY_NAME` | `~/.claude/sessions`, `sessions` | bus-link |
| `BUS_GUARD_LOG`, `BUS_GUARD_INTERVAL` | `~/.orca-session-bus/bus-guard.log`, `15` | bus-guard |
| `AGENT_EXIT`, `AGENT_RESUME_CMD` | `/exit`, a Claude Code resume command | move-session |
| `CLAUDE_FLAGS`, `REARM_PROMPT`, `REPORT_TO` | `--dangerously-skip-permissions`, built-in, none | move-session |
| `MOVE_DIR`, `MOVER_HOURS` | required, `3` | mover |
| `ROUTE_DB`, `ROUTE_MD`, `ROUTE_ACTOR`, `ROUTE_HOST` | `~/.orca-session-bus/routing.db`, `ROUTING.md` beside it, required for writes, `hostname -s` | route |
| `ROUTE_REPLICAS`, `ROUTE_REPLICATE_INTERVAL`, `ROUTE_REPLICATOR_LOG` | none, `60`, `~/.orca-session-bus/route-replicator.log` | route, route-replicator |

## License

MIT. See [LICENSE](LICENSE).
