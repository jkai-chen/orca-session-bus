#!/bin/bash
# permission-gate.example.sh: an example Claude Code PermissionRequest hook for unattended role sessions.
# Role sessions should never stop to ask the user. This answers their Bash prompts:
#   - allow, unless the command matches a destructive pattern, which is denied with "send it to your lead";
#   - the lead's own worktree (LEAD_DIRS) keeps the normal dialog, because the user talks to the lead.
# Every decision is logged. Register it under hooks.PermissionRequest in settings.json. Adapt the patterns to your stack.
LOG="${PERMISSION_GATE_LOG:-$HOME/.orca-session-bus/permission-gate.log}"; mkdir -p "$(dirname "$LOG")"
LEAD_DIRS="${LEAD_DIRS:-}"     # colon-separated path prefixes that keep normal prompts
in=$(cat)
read -r cwd tool cmd < <(printf '%s' "$in" | python3 -c '
import json,sys
d=json.load(sys.stdin); ti=d.get("tool_input") or {}
c=(ti.get("command") or ti.get("file_path") or "").replace("\n"," ")[:400]
print(d.get("cwd",""), d.get("tool_name",""), c)')
ts=$(date '+%F %T')
pass() { echo "$ts PASS  $tool cwd=$cwd :: $cmd" >> "$LOG"; exit 0; }   # no decision: the normal dialog shows
IFS=: read -ra leads <<< "$LEAD_DIRS"
for p in "${leads[@]}"; do [ -n "$p" ] && case "$cwd" in "$p"*) pass ;; esac; done
[ "$tool" = "Bash" ] || pass
if printf '%s' "$cmd" | grep -qE 'rm -[a-zA-Z]*r[a-zA-Z]*f? +(/|~|\$HOME)/?( |$)|git push[^|;&]*--force|git reset --hard|git clean -[a-z]*f|terraform (destroy|apply)|docker (system|volume) prune|DROP (DATABASE|TABLE)'; then
  echo "$ts DENY  $tool cwd=$cwd :: $cmd" >> "$LOG"
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Blocked by the permission gate: role sessions never ask the user. If this destructive command is really needed, send it to your lead with the reason."}}}'
  exit 0
fi
echo "$ts ALLOW $tool cwd=$cwd :: $cmd" >> "$LOG"
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
