#!/bin/bash
# move-session.sh <name> <pane> <pid> <session-id> [target-profile-home]
# Restart an IDLE agent session in the same Orca pane under another account's profile, resuming the same
# conversation. The target defaults to the account Orca has selected now. The built-in exit/resume steps match
# Claude Code's CLI; for another agent set AGENT_EXIT and AGENT_RESUME_CMD (the latter gets {profile} {name} {id} {prompt}).
# Env: ORCA_PROFILES_ROOT, CLAUDE_FLAGS (default --dangerously-skip-permissions), REARM_PROMPT, REPORT_TO.
trap ': keep going' HUP URG
N=${1:-}; T=${2:-}; PID=${3:-}; ID=${4:-}
ROOT="${ORCA_PROFILES_ROOT:-$HOME/Library/Application Support/orca/claude-profiles}"
TGT=${5:-$(cat "$ROOT/selected-host" 2>/dev/null)}
[ -n "$N" ] && [ -n "$T" ] && [ -n "$PID" ] && [ -n "$ID" ] && [ -d "$TGT" ] \
  || { echo "usage: move-session.sh <name> <pane> <pid> <session-id> [target-profile-home]"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
R(){ orca terminal read --terminal "$T" 2>&1 | grep -v '^\s*$' | tail -8; }
R | grep -q -- "─ $N ─" || { echo "$N: pane $T does not show $N; not touching it"; exit 3; }
for _ in $(seq 1 120); do R | grep -qE "esc to interrupt|…\s*\(" || break; sleep 5; done   # wait up to 10 min for idle
orca terminal send --terminal "$T" --text $'\x15' >/dev/null 2>&1; sleep 1                   # clear the input line
orca terminal send --terminal "$T" --text "${AGENT_EXIT:-/exit}" --enter >/dev/null 2>&1
sleep 3; R | grep -q "Exit and stop tasks" && orca terminal send --terminal "$T" --text "" --enter >/dev/null 2>&1   # crons: "1. Exit and stop tasks"
sleep 2; R | grep -q "Esc to discard and exit" && orca terminal send --terminal "$T" --text $'\x1b' >/dev/null 2>&1  # feedback draft: discard
for _ in $(seq 1 60); do ps -p "$PID" >/dev/null || break; sleep 1; done
ps -p "$PID" >/dev/null && { echo "$N: pid $PID still alive after /exit; not relaunching"; exit 1; }
ACCT=$(basename "$(dirname "$TGT")" | cut -c1-8)
P=${REARM_PROMPT:-"You were restarted on account $ACCT. Your conversation is intact; scheduled jobs, background shells and sub-agents ended. Check your scheduled jobs for duplicates, re-arm what your notes list${REPORT_TO:+, then reply to $REPORT_TO with one line: moved, and what is re-armed}."}
printf -v Q "%q" "$P"
CMD=${AGENT_RESUME_CMD:-"CLAUDE_CONFIG_DIR=\"{profile}\" claude ${CLAUDE_FLAGS:---dangerously-skip-permissions} -n {name} --resume {id} {prompt}"}
CMD=${CMD//\{profile\}/$TGT}; CMD=${CMD//\{name\}/$N}; CMD=${CMD//\{id\}/$ID}; CMD=${CMD//\{prompt\}/$Q}
orca terminal send --terminal "$T" --text "$CMD" --enter >/dev/null 2>&1
sleep 25; bash "$HERE/bus-link.sh" >/dev/null 2>&1
np=$(pgrep -f -- "$ID" | head -1)
echo "$(date +%T) $N moved to $ACCT: new pid ${np:-NOT FOUND}"
