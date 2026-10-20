#!/bin/bash
# route-replicator.sh: on the master, run `route.sh replicate` every ROUTE_REPLICATE_INTERVAL seconds (default 60),
# but only when the database changed since the last successful run (change counter = newest history id).
# Run once on the master: nohup bash route-replicator.sh >/dev/null 2>&1 &     Stop: pkill -f route-replicator.sh
# On a replica it just waits, so it keeps working after a promote. Failed runs are retried on the next tick.
# Env: ROUTE_DB, ROUTE_REPLICAS and the rest of route.sh's settings, ROUTE_REPLICATE_INTERVAL,
#      ROUTE_REPLICATOR_LOG (default ~/.orca-session-bus/route-replicator.log).
trap ': keep going' HUP URG
R="$(cd "$(dirname "$0")" && pwd)/route.sh"
DB="${ROUTE_DB:-$HOME/.orca-session-bus/routing.db}"
LOG="${ROUTE_REPLICATOR_LOG:-$HOME/.orca-session-bus/route-replicator.log}"; mkdir -p "$(dirname "$LOG")"
last=""
while :; do
  if [ "$(bash "$R" role 2>/dev/null | cut -d' ' -f1)" = master ]; then
    cur="$(sqlite3 -readonly -cmd '.timeout 5000' "$DB" 'SELECT ifnull(max(id),0) FROM history' 2>/dev/null)"
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
      if out=$(bash "$R" replicate 2>&1); then last="$cur"; echo "$(date '+%F %T') replicated at change $cur" >> "$LOG"
      else echo "$(date '+%F %T') FAILED at change $cur: $(printf '%s' "$out" | tr '\n' ' ')" >> "$LOG"; fi
    fi
  fi
  sleep "${ROUTE_REPLICATE_INTERVAL:-60}"
done
