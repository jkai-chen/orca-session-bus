#!/bin/bash
# bus-link.sh [--check]: make every Orca account profile of a provider share ONE session registry (the "bus").
# Orca links each profile's shared folders back to the provider's main config folder but gives it its own session
# registry, so sessions on different accounts can't see each other. This links the registry the same way.
# Defaults fit Claude Code (claude-profiles, ~/.claude/sessions); set the env vars for other providers.
#   --check  report only (exit 1 if any profile is split)
#   (none)   move each profile's live registry entries into the shared folder, then replace the profile's
#            registry folder with a symlink. Idempotent; safe to re-run after an Orca update.
# Env: ORCA_PROFILES_ROOT (default: macOS Orca claude-profiles folder), SESSION_BUS_DIR (default: ~/.claude/sessions),
#      BUS_REGISTRY_NAME (default: sessions).
set -u
BUS="${SESSION_BUS_DIR:-$HOME/.claude/sessions}"
ROOT="${ORCA_PROFILES_ROOT:-$HOME/Library/Application Support/orca/claude-profiles}"
[ -d "$ROOT" ] || { echo "no Orca profiles folder at $ROOT (set ORCA_PROFILES_ROOT)"; exit 2; }
mkdir -p "$BUS"; rc=0
for home in "$ROOT"/*/home; do
  [ -d "$home" ] || continue
  s="$home/${BUS_REGISTRY_NAME:-sessions}"; id=$(basename "$(dirname "$home")")
  if [ -L "$s" ] && [ "$(readlink "$s")" = "$BUS" ]; then echo "linked   $id"; continue; fi
  if [ "${1:-}" = "--check" ]; then echo "SPLIT    $id (own registry)"; rc=1; continue; fi
  if [ -d "$s" ] && [ ! -L "$s" ]; then
    for f in "$s"/*; do [ -e "$f" ] && mv -n "$f" "$BUS"/; done
    rmdir "$s" 2>/dev/null || { echo "LEFT     $id: $s not empty after the move (name clash), not linked"; rc=1; continue; }
  fi
  ln -sfn "$BUS" "$s" && echo "LINKED   $id"
done
exit $rc
