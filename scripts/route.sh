#!/bin/bash
# route.sh: the routing table, kept in SQLite. One master database, synced read-only replicas.
#
# Usage: route.sh <command> [args]
#   init [--master [--host H]]     create the database. Without --master it is a read-only REPLICA. --master makes
#                                  this machine the master: only run it when the USER has chosen this host.
#   set <name> field=value ...     add or update a session (master only)
#   retire <name> [successor]      mark a session retired (master only)
#   get <name>                     show one session
#   list [--all] [--where f=v]     active sessions (--all adds retired and moved)
#   who <role-substring>           active sessions whose role contains the text
#   history [name]                 change log, newest first
#   render [out.md|-]              write the markdown view (default $ROUTE_MD), atomically, read-only file
#   import <ROUTING.md>            one-time best-effort load from a markdown table (master only)
#   sweep [--apply]                compare active rows with live sessions; --apply stamps last_seen (master only)
#   replicate                      master only: snapshot + markdown to every target in $ROUTE_REPLICAS
#   role                           print master or replica, and who chose the master host
#   promote --yes [--host H]       disaster failover: make this replica the master (the USER decides)
#   demote                         make this master a read-only replica again
#
# Fields: role owner reach(bus|mailbox|pane) pane host agent account status(active|retired|moved) successor notes last_seen
#
# Env (all optional except ROUTE_ACTOR for writes):
#   ROUTE_DB        database file, default ~/.orca-session-bus/routing.db (local disk only, never a network share)
#   ROUTE_MD        markdown view, default ROUTING.md next to the database
#   ROUTE_ACTOR     who is making the change; required for every write
#   ROUTE_HOST      this machine's name in routing rows and master_host, default `hostname -s`
#   ROUTE_REPLICAS  space-separated replica targets: /local/dir, host:dir (scp/ssh), directories on the remote side
#                   are absolute or relative to its home. orca:<environment>:<dir> is not supported (no file copy in orca).
#   SESSION_BUS_DIR registry read by sweep, default ~/.claude/sessions; ROUTE_NO_ORCA=1 skips `orca terminal list`
#   ROUTE_HISTORY_LIMIT  rows shown by history, default 50
# The master is the machine where $ROUTE_DB and $ROUTE_DB.master both exist.
set -u

DB="${ROUTE_DB:-$HOME/.orca-session-bus/routing.db}"
MD="${ROUTE_MD:-$(dirname "$DB")/ROUTING.md}"
FIELDS="role owner reach pane host agent account status successor notes last_seen"
Q="'"

err() { echo "route.sh: $*" >&2; }
die() { err "$*"; exit 1; }
esc() { printf '%s' "${1//$Q/$Q$Q}"; }
lit() { printf "'%s'" "$(esc "$1")"; }
now() { date '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }
myhost() { echo "${ROUTE_HOST:-$(hostname -s 2>/dev/null || echo unknown)}"; }
sql() { sqlite3 -cmd '.timeout 5000' "$DB" "$@"; }
rsql() { sqlite3 -readonly -cmd '.timeout 5000' "$DB" "$@"; }

role_of() {
  if [ ! -e "$DB" ]; then echo none
  elif [ -e "$DB.master" ]; then echo master
  else echo replica; fi
}
need_db() { [ -e "$DB" ] || die "no database at $DB (run: route.sh init)"; }
need_actor() { [ -n "${ROUTE_ACTOR:-}" ] || die "ROUTE_ACTOR is required for writes (who is making this change?)"; }
need_master() {
  case "$(role_of)" in
    master) need_actor ;;
    replica) die "replica: send the change to the master, or promote (the user decides; see references/routing-table.md)" ;;
    *) die "no database at $DB (run: route.sh init)" ;;
  esac
}
meta() { rsql "SELECT value FROM meta WHERE key=$(lit "$1")" 2>/dev/null; }

valid_field() { case " $FIELDS " in *" $1 "*) return 0 ;; esac; return 1; }
valid_value() { # field value
  case "$1" in
    reach) case "$2" in ""|bus|mailbox|pane) return 0 ;; esac; err "reach must be bus, mailbox or pane (got '$2')"; return 1 ;;
    status) case "$2" in active|retired|moved) return 0 ;; esac; err "status must be active, retired or moved (got '$2')"; return 1 ;;
  esac
  return 0
}

schema_sql() {
  local f ins="" upd=""
  for f in $FIELDS; do
    ins="$ins INSERT INTO history(at,name,actor,action,field,old,new) SELECT NEW.updated_at,NEW.name,NEW.updated_by,'insert','$f',NULL,NEW.$f WHERE NEW.$f IS NOT NULL;"
    upd="$upd INSERT INTO history(at,name,actor,action,field,old,new) SELECT NEW.updated_at,NEW.name,NEW.updated_by,'update','$f',OLD.$f,NEW.$f WHERE OLD.$f IS NOT NEW.$f;"
  done
  cat <<EOF
CREATE TABLE IF NOT EXISTS sessions(
  name TEXT PRIMARY KEY CHECK(length(name)>0),
  role TEXT, owner TEXT,
  reach TEXT CHECK(reach IS NULL OR reach IN ('bus','mailbox','pane')),
  pane TEXT, host TEXT, agent TEXT, account TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','retired','moved')),
  successor TEXT, notes TEXT, last_seen TEXT,
  updated_at TEXT NOT NULL, updated_by TEXT NOT NULL CHECK(length(updated_by)>0));
CREATE TABLE IF NOT EXISTS history(
  id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, name TEXT NOT NULL, actor TEXT NOT NULL,
  action TEXT NOT NULL, field TEXT, old TEXT, new TEXT);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TRIGGER IF NOT EXISTS sessions_ai AFTER INSERT ON sessions BEGIN $ins END;
CREATE TRIGGER IF NOT EXISTS sessions_au AFTER UPDATE ON sessions BEGIN $upd END;
PRAGMA user_version=1;
EOF
}

# Record a master change: meta rows plus a history entry. Args: host actor action(init|promote|demote)
master_change_sql() {
  local host="$1" actor="$2" action="$3" ts old
  ts="$(now)"; old="$(meta master_host)"
  if [ "$action" = demote ]; then
    echo "INSERT INTO history(at,name,actor,action,field,old,new) VALUES($(lit "$ts"),'*',$(lit "$actor"),'demote','master_host',$(lit "$old"),NULL);"
    return
  fi
  cat <<EOF
INSERT OR REPLACE INTO meta(key,value) VALUES('master_host',$(lit "$host")),('chosen_by',$(lit "$actor")),('chosen_at',$(lit "$ts"));
INSERT INTO history(at,name,actor,action,field,old,new) VALUES($(lit "$ts"),'*',$(lit "$actor"),$(lit "$action"),'master_host',$(lit "$old"),$(lit "$host"));
EOF
}

cmd_init() {
  local master=0 host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --master) master=1 ;;
      --host) host="${2:-}"; shift ;;
      *) die "init: unknown option $1" ;;
    esac
    shift
  done
  mkdir -p "$(dirname "$DB")"
  if [ -e "$DB" ]; then
    [ "$(role_of)" = replica ] && die "replica database already exists at $DB. To make it the master, the user must decide: route.sh promote --yes"
    schema_sql | sql >/dev/null || die "schema update failed"
    echo "database ready (master): $DB"; return 0
  fi
  if [ $master -eq 0 ]; then
    schema_sql | sql >/dev/null || die "init failed"
    sql "PRAGMA journal_mode=DELETE;" >/dev/null; chmod 444 "$DB"
    echo "created a read-only REPLICA database: $DB"
    echo "It has no master. The user chooses which host is the master; ask, don't assume. On that host run:"
    echo "  ROUTE_ACTOR=<name> route.sh init --master"
    return 0
  fi
  need_actor
  [ -n "$host" ] || host="$(myhost)"
  { schema_sql; master_change_sql "$host" "$ROUTE_ACTOR" init; } | sql >/dev/null || { rm -f "$DB" "$DB-wal" "$DB-shm"; die "init failed"; }
  sql "PRAGMA journal_mode=WAL;" >/dev/null
  : > "$DB.master"
  echo "created MASTER database: $DB (master host: $host, chosen by $ROUTE_ACTOR)"
}

cmd_role() {
  local r; r="$(role_of)"
  case "$r" in
    none) echo "none (no database at $DB)"; return 0 ;;
  esac
  local h by at
  h="$(meta master_host)"; by="$(meta chosen_by)"; at="$(meta chosen_at)"
  if [ -n "$h" ]; then echo "$r (master host: $h, chosen by $by at $at)"
  else echo "$r (no master host recorded)"; fi
}

# Sets globals SET_SQL from name and field=value args. Returns 1 on bad input.
build_set() {
  local name="$1" kv f v seen="" cols="" vals="" ups=""; shift
  [ -n "$name" ] || { err "set: name is required"; return 1; }
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) err "expected field=value, got '$kv'"; return 1 ;; esac
    f="${kv%%=*}"; v="${kv#*=}"
    [ "$f" = name ] && { err "name is the first argument, not a field"; return 1; }
    valid_field "$f" || { err "unknown field '$f' (allowed: $FIELDS)"; return 1; }
    case " $seen " in *" $f "*) err "field '$f' given twice"; return 1 ;; esac
    seen="$seen $f"
    valid_value "$f" "$v" || return 1
    [ "$f" = status ] && [ -z "$v" ] && { err "status cannot be empty"; return 1; }
    cols="$cols,$f"
    if [ -z "$v" ]; then vals="$vals,NULL"; else vals="$vals,$(lit "$v")"; fi
    ups="$ups$f=excluded.$f,"
  done
  local ts; ts="$(now)"
  SET_SQL="INSERT INTO sessions(name$cols,updated_at,updated_by) VALUES($(lit "$name")$vals,$(lit "$ts"),$(lit "$ROUTE_ACTOR")) ON CONFLICT(name) DO UPDATE SET ${ups}updated_at=excluded.updated_at,updated_by=excluded.updated_by;"
}

cmd_set() {
  need_master
  [ $# -ge 1 ] || die "usage: route.sh set <name> field=value ..."
  build_set "$@" || exit 1
  sql "$SET_SQL" || die "write failed"
  echo "ok: $1"
}

cmd_retire() {
  need_master
  [ $# -ge 1 ] || die "usage: route.sh retire <name> [successor]"
  [ "$(rsql "SELECT count(*) FROM sessions WHERE name=$(lit "$1")")" = 1 ] || die "no such session: $1"
  if [ -n "${2:-}" ]; then build_set "$1" status=retired "successor=$2"; else build_set "$1" status=retired; fi || exit 1
  sql "$SET_SQL" || die "write failed"
  echo "retired: $1"
}

cmd_get() {
  need_db; [ $# -eq 1 ] || die "usage: route.sh get <name>"
  [ "$(rsql "SELECT count(*) FROM sessions WHERE name=$(lit "$1")")" = 1 ] || die "no such session: $1"
  rsql -line "SELECT * FROM sessions WHERE name=$(lit "$1")"
}

cmd_list() {
  need_db
  local all=0 where="" f v
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --where)
        case "${2:-}" in *=*) ;; *) die "--where needs field=value" ;; esac
        f="${2%%=*}"; v="${2#*=}"
        if [ "$f" != name ] && [ "$f" != updated_by ] && [ "$f" != updated_at ]; then valid_field "$f" || die "unknown field '$f'"; fi
        where="$where AND $f=$(lit "$v")"; shift ;;
      *) die "list: unknown option $1" ;;
    esac
    shift
  done
  [ $all -eq 1 ] || where="$where AND status='active'"
  rsql -header -column "SELECT name,role,owner,reach,pane,host,agent,account,status,successor,last_seen FROM sessions WHERE 1=1$where ORDER BY name"
}

cmd_who() {
  need_db; [ $# -eq 1 ] || die "usage: route.sh who <role-substring>"
  rsql -header -column "SELECT name,role,reach,pane,host FROM sessions WHERE status='active' AND instr(lower(ifnull(role,'')),lower($(lit "$1")))>0 ORDER BY name"
}

cmd_history() {
  need_db
  local w=""; [ -n "${1:-}" ] && w="WHERE name=$(lit "$1")"
  rsql -header -column "SELECT id,at,name,actor,action,field,old,new FROM history $w ORDER BY id DESC LIMIT ${ROUTE_HISTORY_LIMIT:-50}"
}

render_to() { # out ; reads $DB
  local out="$1" tmp today mh by at
  today="$(date +%F)"; mh="$(meta master_host)"; by="$(meta chosen_by)"; at="$(meta chosen_at)"
  tmp="$(mktemp "$(dirname "$out")/.routing.XXXXXX")" || return 1
  {
    echo "# Routing table"
    echo
    echo "Generated by route.sh from the SQLite database at $(now). Read-only: change it with route.sh on the master."
    if [ -n "$mh" ]; then echo "Master host: $mh (chosen by $by at $at)."; else echo "Master host: not recorded."; fi
    echo
    echo "## Active"
    echo
    echo "| Name | Role | Owner | Reach | Pane | Host | Agent | Account | Successor | Notes | Last seen |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    rsql "SELECT '| '||$(cols_md)||' |' FROM sessions WHERE status='active' ORDER BY name"
    echo
    echo "## Retired today"
    echo
    echo "| Name | Role | Owner | Reach | Pane | Host | Agent | Account | Successor | Notes | Last seen |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    rsql "SELECT '| '||$(cols_md)||' |' FROM sessions WHERE status<>'active' AND substr(updated_at,1,10)=$(lit "$today") ORDER BY name"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 444 "$tmp" && mv -f "$tmp" "$out"
}
cols_md() {
  local c out=""
  for c in name role owner reach pane host agent account successor notes last_seen; do
    out="$out${out:+||' | '||}replace(replace(replace(ifnull($c,''),'|','\\|'),char(10),' '),char(13),' ')"
  done
  echo "$out"
}

cmd_render() {
  need_db
  local out="${1:-$MD}"
  if [ "$out" = - ]; then
    local t; t="$(mktemp)"; render_to "$t" && cat "$t"; rm -f "$t"; return 0
  fi
  mkdir -p "$(dirname "$out")"
  render_to "$out" || die "render failed"
  echo "wrote $out"
}

cmd_import() {
  need_master
  [ $# -eq 1 ] && [ -f "$1" ] || die "usage: route.sh import <ROUTING.md>"
  local ok=0 bad=0 line kind a b rest parts
  local out; out="$(mktemp)"
  awk '
    function norm(s){ s=tolower(s); gsub(/[^a-z0-9]/,"",s); return s }
    function clean(s){ gsub(/\001/,"|",s); gsub(/`/,"",s); gsub(/\*\*/,"",s); gsub(/\t/," ",s); sub(/^[ ]+/,"",s); sub(/[ ]+$/,"",s)
      if (s=="-"||s=="--"||s=="n/a"||s=="N/A"||s=="none"||s=="None"||s=="\342\200\224") s=""; return s }
    function mapf(h,  n){ n=norm(h)
      if (n ~ /^(name|session|sessionname|id)$/) return "name"
      if (n ~ /^(role|purpose|job)$/) return "role"
      if (n ~ /^(owner|lead|ownedby)$/) return "owner"
      if (n ~ /^(reach|reached|reachedvia|reachvia|via|how|bus|transport|channel)$/) return "reach"
      if (n ~ /^(pane|panehandle|handle|terminal)$/) return "pane"
      if (n ~ /^(host|environment|env|machine|orcaenvironment)$/) return "host"
      if (n ~ /^(agent|model|agentmodel|provider)$/) return "agent"
      if (n ~ /^(account|profile|accountprofile)$/) return "account"
      if (n ~ /^(status|state)$/) return "status"
      if (n ~ /^(successor|replacedby|movedto)$/) return "successor"
      if (n ~ /^(notes|note|comments|comment)$/) return "notes"
      if (n ~ /^(lastseen|seen)$/) return "last_seen"
      return "" }
    function cells(line, arr,  n){ gsub(/\\\|/,"\001",line); sub(/^[ \t]*\|/,"",line); sub(/\|[ \t]*$/,"",line); n=split(line,arr,"|"); return n }
    /^#/ { section=tolower($0); intable=0; next }
    /^[ \t]*\|/ {
      n=cells($0,c)
      if (!intable) { intable=1; nm=0; nc=n; hasname=0
        for(i=1;i<=n;i++){ h[i]=clean(c[i]); f[i]=mapf(h[i]); if(f[i]=="name") hasname=1
          if(f[i]=="") print "UNMAPPED_COL\t" h[i] }
        if(!hasname) print "WARN\t" NR "\theader has no name column; table skipped"
        next }
      sep=1; for(i=1;i<=n;i++){ if (clean(c[i]) !~ /^:?-+:?$/) sep=0 }
      if (sep) next
      if (!hasname) next
      delete v; extra=""
      for(i=1;i<=nc;i++){ x=clean(c[i]); if(x=="") continue
        if(f[i]=="") extra=extra (extra==""?"":"; ") h[i] ": " x; else v[f[i]]=x }
      if (v["name"]=="") { print "WARN\t" NR "\trow has no name; skipped"; next }
      r=tolower(v["reach"]); if (r!="") { if (r ~ /bus/) v["reach"]="bus"; else if (r ~ /mailbox|relay|status/) v["reach"]="mailbox"; else if (r ~ /pane|terminal/) v["reach"]="pane"
        else { print "WARN\t" NR "\t" v["name"] ": reach \"" v["reach"] "\" not recognised; kept in notes"; extra=extra (extra==""?"":"; ") "reach: " v["reach"]; delete v["reach"] } }
      s=tolower(v["status"])
      if (s=="" && section ~ /retired|ended/) v["status"]="retired"
      else if (s!="") { if (s ~ /^active/) v["status"]="active"; else if (s ~ /moved/) v["status"]="moved"; else if (s ~ /retire|ended|done/) v["status"]="retired"
        else { print "WARN\t" NR "\t" v["name"] ": status \"" v["status"] "\" not recognised; set to active"; extra=extra (extra==""?"":"; ") "status: " v["status"]; delete v["status"] } }
      if (extra!="") v["notes"]=(v["notes"]==""?"":v["notes"] "; ") extra
      line="ROW\t" NR "\t" v["name"]
      split("role owner reach pane host agent account status successor notes last_seen",ff," ")
      for(k=1;k<=11;k++){ if (v[ff[k]]!="") line=line "\t" ff[k] "=" v[ff[k]] }
      print line; next }
    { intable=0 }
  ' "$1" > "$out"
  while IFS=$'\t' read -r -a parts; do
    case "${parts[0]}" in
      UNMAPPED_COL) echo "note: column '${parts[1]:-}' has no matching field; its values were appended to notes" ;;
      WARN) echo "warning: line ${parts[1]}: ${parts[2]}"; bad=$((bad+1)) ;;
      ROW)
        if build_set "${parts[@]:2}" && sql "$SET_SQL"; then ok=$((ok+1)); else echo "ERROR: line ${parts[1]}: could not import '${parts[2]}'" >&2; bad=$((bad+1)); fi ;;
    esac
  done < "$out"
  rm -f "$out"
  echo "import: $ok rows imported, $bad problems reported"
  [ $ok -gt 0 ] || { err "import: nothing imported (no pipe table with a name column found?)"; return 1; }
  [ $bad -eq 0 ]
}

cmd_sweep() {
  local apply=0; [ "${1:-}" = "--apply" ] && apply=1
  [ $apply -eq 1 ] && need_master
  need_db
  local reg="${SESSION_BUS_DIR:-$HOME/.claude/sessions}" live=$'\n' f n pid have_reg=0 orca_out="" have_orca=0
  local here="${ROUTE_HOST:-}"
  if [ -d "$reg" ]; then
    have_reg=1
    for f in "$reg"/*.json; do
      [ -e "$f" ] || continue
      n="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')"
      pid="$(grep -o '"pid"[[:space:]]*:[[:space:]]*[0-9]*' "$f" | head -1 | sed -E 's/.*:[[:space:]]*//')"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then continue; fi
      [ -n "$n" ] && live="$live$n"$'\n'
    done
  fi
  if [ -z "${ROUTE_NO_ORCA:-}" ] && command -v orca >/dev/null 2>&1; then
    if orca_out="$(orca terminal list 2>/dev/null)"; then have_orca=1; fi
  fi
  [ $have_reg -eq 1 ] || [ $have_orca -eq 1 ] || { err "sweep: no registry at $reg and no orca CLI; nothing to compare"; return 1; }
  local name host pane reach alive checked missing=0 unchecked=0 seen=0 ts
  ts="$(now)"
  local rows; rows="$(rsql -separator $'\037' "SELECT name,ifnull(host,''),ifnull(pane,''),ifnull(reach,'') FROM sessions WHERE status='active' ORDER BY name")"
  local alive_names=""
  while IFS=$'\037' read -r name host pane reach; do
    [ -n "$name" ] || continue
    if [ -n "$here" ] && [ -n "$host" ] && [ "$host" != "$here" ]; then unchecked=$((unchecked+1)); continue; fi
    alive=0; checked=0
    if [ $have_reg -eq 1 ] && { [ "$reach" = bus ] || [ -z "$reach" ]; }; then
      checked=1; case "$live" in *$'\n'"$name"$'\n'*) alive=1 ;; esac
    fi
    if [ $have_orca -eq 1 ] && [ -n "$pane" ]; then
      checked=1; printf '%s' "$orca_out" | grep -qF -- "$pane" && alive=1
    fi
    if [ $alive -eq 1 ]; then alive_names="$alive_names$name"$'\n'
    elif [ $checked -eq 1 ]; then echo "MISSING: row '$name' is active but no live session found"; missing=$((missing+1))
    else unchecked=$((unchecked+1)); fi
  done <<EOF
$rows
EOF
  local unlisted=0 known; known="$(rsql "SELECT name FROM sessions")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$known" | grep -qxF -- "$n" || { echo "UNLISTED: live session '$n' has no row"; unlisted=$((unlisted+1)); }
  done <<EOF
$live
EOF
  echo "sweep: $missing missing, $unlisted unlisted, $unchecked not checkable from here (other host, or no handle)"
  if [ $apply -eq 1 ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      sql "UPDATE sessions SET last_seen=$(lit "$ts"),updated_at=$(lit "$ts"),updated_by=$(lit "$ROUTE_ACTOR") WHERE name=$(lit "$n")"
    done <<EOF
$alive_names
EOF
    echo "sweep: last_seen stamped on live rows"
  fi
  return 0
}

copy_one() { # target file name ; returns 0 on success
  local target="$1" file="$2" name="$3" dir host
  case "$target" in
    orca:*) err "orca: targets are not supported (orca has no file copy); use a local path or host:dir"; return 1 ;;
    *:*) host="${target%%:*}"; dir="${target#*:}"
      scp -q "$file" "$host:$dir/.$name.tmp" 2>/dev/null || { ssh "$host" "mkdir -p '$dir'" && scp -q "$file" "$host:$dir/.$name.tmp"; } || return 1
      ssh "$host" "chmod 444 '$dir/.$name.tmp' && mv -f '$dir/.$name.tmp' '$dir/$name'" ;;
    *) mkdir -p "$target" || return 1
      [ "$target/$name" -ef "$DB" ] && { err "replica target $target is the master's own database"; return 1; }
      rm -f "$target/.$name.tmp"
      cp "$file" "$target/.$name.tmp" && chmod 444 "$target/.$name.tmp" && mv -f "$target/.$name.tmp" "$target/$name" ;;
  esac
}

cmd_replicate() {
  [ "$(role_of)" = master ] || die "replicate runs on the master only (role: $(role_of))"
  [ -n "${ROUTE_REPLICAS:-}" ] || die "ROUTE_REPLICAS is empty (space-separated targets: /dir, host:dir)"
  local tmp t fail=0 dbn mdn
  tmp="$(mktemp -d)" || die "mktemp failed"
  dbn="$(basename "$DB")"; mdn="$(basename "$MD")"
  sql "VACUUM INTO '$(esc "$tmp/$dbn")'" || { rm -rf "$tmp"; die "snapshot failed"; }
  sqlite3 "$tmp/$dbn" "PRAGMA journal_mode=DELETE;" >/dev/null
  ( DB="$tmp/$dbn"; render_to "$tmp/$mdn" ) || { rm -rf "$tmp"; die "render failed"; }
  for t in $ROUTE_REPLICAS; do
    if copy_one "$t" "$tmp/$dbn" "$dbn" && copy_one "$t" "$tmp/$mdn" "$mdn"; then echo "replicated to $t"
    else err "FAILED to replicate to $t"; fail=1; fi
  done
  rm -rf "$tmp"
  return $fail
}

cmd_promote() {
  local yes=0 host=""
  while [ $# -gt 0 ]; do
    case "$1" in --yes) yes=1 ;; --host) host="${2:-}"; shift ;; *) die "promote: unknown option $1" ;; esac
    shift
  done
  case "$(role_of)" in
    none) die "no database at $DB; nothing to promote" ;;
    master) die "already the master" ;;
  esac
  need_actor
  [ -n "$host" ] || host="$(myhost)"
  if [ $yes -ne 1 ]; then
    cat >&2 <<EOF
!! PROMOTE is a disaster-failover step and it is the USER's decision, not the agent's.
!! Ask the user which host becomes the master, and confirm the old master is down or will be demoted
!! (route.sh demote) before it comes back. Two masters means split brain and lost rows.
!! This would make $host the master. To go ahead, re-run with --yes.
EOF
    return 1
  fi
  chmod u+w "$DB" || die "cannot make $DB writable"
  { master_change_sql "$host" "$ROUTE_ACTOR" promote; } | sql >/dev/null || die "promote failed"
  sql "PRAGMA journal_mode=WAL;" >/dev/null
  : > "$DB.master"
  echo "PROMOTED: this machine ($host) is now the master, chosen by $ROUTE_ACTOR."
  echo "Next: set ROUTE_REPLICAS and start route-replicator.sh here; demote the old master before it returns."
}

cmd_demote() {
  [ "$(role_of)" = master ] || die "not a master (role: $(role_of))"
  need_actor
  master_change_sql "" "$ROUTE_ACTOR" demote | sql >/dev/null || die "demote failed"
  sql "PRAGMA journal_mode=DELETE;" >/dev/null
  rm -f "$DB.master"; chmod 444 "$DB"
  echo "demoted: $DB is now a read-only replica. Point it at the new master's copy (or let replication overwrite it)."
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required"
case "$cmd" in
  init) cmd_init "$@" ;;
  set) cmd_set "$@" ;;
  retire) cmd_retire "$@" ;;
  get) cmd_get "$@" ;;
  list) cmd_list "$@" ;;
  who) cmd_who "$@" ;;
  history) cmd_history "$@" ;;
  render) cmd_render "$@" ;;
  import) cmd_import "$@" ;;
  sweep) cmd_sweep "$@" ;;
  replicate) cmd_replicate "$@" ;;
  role) cmd_role "$@" ;;
  promote) cmd_promote "$@" ;;
  demote) cmd_demote "$@" ;;
  ""|-h|--help|help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' (try: route.sh help)" ;;
esac
