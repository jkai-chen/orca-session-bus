#!/bin/bash
# bus-guard.sh: keep the bus linked. Every BUS_GUARD_INTERVAL seconds (default 15) it checks every Orca profile and
# re-links any that split (a claude start, resume or /compact, or an Orca update, can recreate a profile's sessions/).
# Run once per machine: nohup bash bus-guard.sh >/dev/null 2>&1 &     Stop: pkill -f bus-guard.sh
# Env: BUS_GUARD_LOG (default ~/.orca-session-bus/bus-guard.log), plus bus-link.sh's settings.
trap ': keep going' HUP URG
L="$(cd "$(dirname "$0")" && pwd)/bus-link.sh"
LOG="${BUS_GUARD_LOG:-$HOME/.orca-session-bus/bus-guard.log}"; mkdir -p "$(dirname "$LOG")"
while :; do
  if ! out=$(bash "$L" --check 2>&1); then
    split=$(printf '%s\n' "$out" | awk '/^SPLIT/{print substr($2,1,8)}' | tr '\n' ' ')
    fix=$(bash "$L" 2>&1 | grep -v '^linked' | tr '\n' ' ')
    echo "$(date '+%F %T') split: ${split}-> ${fix}" >> "$LOG"
  fi
  sleep "${BUS_GUARD_INTERVAL:-15}"
done
