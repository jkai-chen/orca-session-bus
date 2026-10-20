# orca-session-bus

An agent skill for running many Claude Code sessions (and Codex sessions) side by side in Orca across several accounts, machines and providers, without losing track of who can reach whom.

It covers:

- **Multiple accounts.** Orca gives each account profile its own session registry, so after an account switch new sessions can't message old ones. The skill links every profile to one shared registry and keeps it linked.
- **Moving sessions between accounts.** Restart a running session under another account in the same pane, keeping its conversation, for example before a weekly limit. One at a time or everyone at once.
- **Multiple providers.** Codex and other CLI agents have no cross-session messaging, so the skill sets up a file-based mailbox, a relay, trusted paths, launch steps and guard rules.
- **Fallbacks and troubleshooting.** A routing table with one editor, safe pane typing, bounced messages, held deliveries and duplicate crons after a resume.

## Install

```sh
npx skills add jkai-chen/orca-session-bus --skill orca-session-bus
```

For a global Codex installation:

```sh
npx skills add jkai-chen/orca-session-bus --skill orca-session-bus --agent codex --global
```

To list the available skill:

```sh
npx skills add jkai-chen/orca-session-bus --list
```

Installation follows the [Vercel skills CLI](https://github.com/vercel-labs/skills) format. The CLI finds this repository's root `SKILL.md` and installs its supporting files.

## Use

Ask your agent:

> My sessions stopped seeing each other after I switched Orca accounts. Use $orca-session-bus to fix it.

> Move all running sessions to my other account before the weekly limit hits.

> Start a Codex review session on the desktop and wire it up so my lead can message it.

## Contents

- [SKILL.md](SKILL.md): how the bus works, linking it, task routing.
- [Troubleshooting](references/troubleshooting.md): bounced messages, missing sessions, late messages, duplicate crons.
- [Moving sessions](references/moving-sessions.md): one session or everyone, safely, with the coordinator last.
- [Multi-provider](references/multi-provider.md): Codex mailbox, launch, trust, permissions, delivery, retiring.
- [Routing table](references/routing-table.md): the always-current fallback and how to keep it honest.
- `scripts/`: `bus-link.sh`, `bus-guard.sh`, `move-session.sh`, `mover.sh`.
- `assets/permission-gate.example.sh`: an example `PermissionRequest` hook for unattended sessions.

## Requirements

- Orca with its CLI (`orca terminal …`) on PATH, and Claude Code.
- macOS paths by default. On Linux, set `ORCA_PROFILES_ROOT` to your Orca profiles folder. Linux hasn't been tested.
- `bash`; `python3` for the permission-gate example.

## Settings

| Variable | Default | Used by |
| --- | --- | --- |
| `ORCA_PROFILES_ROOT` | `~/Library/Application Support/orca/claude-profiles` | bus-link, move-session |
| `SESSION_BUS_DIR` | `~/.claude/sessions` | bus-link |
| `BUS_GUARD_LOG`, `BUS_GUARD_INTERVAL` | `~/.orca-session-bus/bus-guard.log`, `15` | bus-guard |
| `CLAUDE_FLAGS`, `REARM_PROMPT`, `REPORT_TO` | `--dangerously-skip-permissions`, built-in, none | move-session |
| `MOVE_DIR`, `MOVER_HOURS` | required, `3` | mover |

## License

MIT. See [LICENSE](LICENSE).
