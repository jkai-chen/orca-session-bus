#!/bin/bash
# mover.sh: move many sessions, each when it is ready. Reads $MOVE_DIR/sessions.txt (lines: <name> <pane> <pid> <session-id>)
# and moves a session once $MOVE_DIR/<name>.ready exists. The LAST line (the coordinating lead) moves only after all
# others. Marks each with <name>.done. Gives up after MOVER_HOURS (default 3). Run with nohup; log $MOVE_DIR/mover.log.
trap ': keep going' HUP URG TERM
D=${MOVE_DIR:?set MOVE_DIR to the folder holding sessions.txt}
[ -f "$D/sessions.txt" ] || { echo "no $D/sessions.txt"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LAST=$(tail -1 "$D/sessions.txt" | cut -d" " -f1)
end=$(( $(date +%s) + ${MOVER_HOURS:-3}*3600 ))
while [ "$(date +%s)" -lt "$end" ]; do
  left=0
  while read -r N T PID ID; do
    [ -n "$N" ] || continue
    [ -e "$D/$N.done" ] && continue; left=$((left+1))
    [ "$N" = "$LAST" ] && [ "$left" -gt 1 ] && continue
    [ -e "$D/$N.ready" ] || continue
    bash "$HERE/move-session.sh" "$N" "$T" "$PID" "$ID" >> "$D/mover.log" 2>&1 && touch "$D/$N.done"
  done < "$D/sessions.txt"
  [ "$left" -eq 0 ] && { echo "$(date +%T) all moved" >> "$D/mover.log"; exit 0; }
  sleep 20
done
echo "$(date +%T) gave up after ${MOVER_HOURS:-3} h" >> "$D/mover.log"
