#!/bin/bash
# route-test.sh: tests for route.sh and route-replicator.sh. Uses a temp dir only; touches nothing else.
# Run: bash tests/route-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
R="$HERE/scripts/route.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ROUTE_DB="$T/master/routing.db" ROUTE_MD="$T/master/ROUTING.md" ROUTE_ACTOR=tester ROUTE_HOST=hostA
export SESSION_BUS_DIR="$T/registry" ROUTE_NO_ORCA=1
mkdir -p "$SESSION_BUS_DIR"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
check() { # desc, command...
  local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi
}
refuses() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ko "$d"; else ok "$d"; fi; }
r() { bash "$R" "$@"; }
has() { grep -qF -- "$2" <<<"$1"; }

# init without --master gives a read-only replica that refuses writes
export ROUTE_DB_SAVE="$ROUTE_DB"
RD="$T/plain/routing.db"
out=$(ROUTE_DB="$RD" r init 2>&1); has "$out" "REPLICA" && ok "init without --master makes a replica" || ko "init without --master makes a replica"
[ "$(ROUTE_DB="$RD" r role | cut -d' ' -f1)" = replica ] && ok "plain init role is replica" || ko "plain init role is replica"
out=$(ROUTE_DB="$RD" r set x role=a 2>&1); has "$out" "replica: send the change to the master" && ok "plain-init replica refuses set" || ko "plain-init replica refuses set"
refuses "init --master refuses over an existing replica" env ROUTE_DB="$RD" bash "$R" init --master

# master init
refuses "init --master needs ROUTE_ACTOR" env -u ROUTE_ACTOR bash "$R" init --master
check "init --master" r init --master
[ -e "$ROUTE_DB.master" ] && ok "master marker exists" || ko "master marker exists"
has "$(r role)" "master (master host: hostA, chosen by tester" && ok "role shows master host and chooser" || ko "role shows master host and chooser"
[ "$(sqlite3 "$ROUTE_DB" 'PRAGMA journal_mode')" = wal ] && ok "WAL mode" || ko "WAL mode"
has "$(r history '*')" "init" && ok "history records master choice" || ko "history records master choice"

# set / get / list
check "set new row" r set lead-1 role="lead, ops" owner=alice reach=bus host=hostA agent=codex notes="it's | tricky"
check "set second row" r set worker-1 role=reviewer reach=pane pane=term_abc host=hostB
has "$(r get lead-1)" "owner = alice" && ok "get shows fields" || ko "get shows fields"
has "$(r get lead-1)" "updated_by = tester" && ok "updated_by stamped" || ko "updated_by stamped"
has "$(r get lead-1)" "it's | tricky" && ok "quotes and pipes stored intact" || ko "quotes and pipes stored intact"
[[ "$(r get lead-1)" =~ updated_at\ =\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2} ]] && ok "updated_at is ISO with offset" || ko "updated_at is ISO with offset"
has "$(r list)" "worker-1" && ok "list shows active rows" || ko "list shows active rows"
out=$(r list --where host=hostB); has "$out" worker-1 && ! has "$out" lead-1 && ok "list --where filters" || ko "list --where filters"
has "$(r who review)" worker-1 && ok "who matches role substring" || ko "who matches role substring"
refuses "set without ROUTE_ACTOR" env -u ROUTE_ACTOR bash "$R" set a role=b

# validation
refuses "bad reach rejected" r set lead-1 reach=carrier-pigeon
refuses "bad status rejected" r set lead-1 status=sleeping
refuses "unknown field rejected" r set lead-1 "role; DROP TABLE sessions;--=x"
refuses "malformed arg rejected" r set lead-1 justtext
[ "$(sqlite3 "$ROUTE_DB" 'select count(*) from sessions')" = 2 ] && ok "table intact after bad input" || ko "table intact after bad input"
refuses "CHECK constraint backs the enum" sqlite3 "$ROUTE_DB" "UPDATE sessions SET reach='x' WHERE name='lead-1'"
out=$(r set "o'brien" role=x 2>&1) && has "$(r get "o'brien")" "name = o'brien" && ok "quote in name handled" || ko "quote in name handled"

# history
r set lead-1 owner=bob >/dev/null
out=$(r history lead-1)
has "$out" owner && has "$out" alice && has "$out" bob && ok "history keeps old and new values" || ko "history keeps old and new values"
r retire worker-1 lead-1 >/dev/null
has "$(r get worker-1)" "status = retired" && has "$(r get worker-1)" "successor = lead-1" && ok "retire sets status and successor" || ko "retire sets status and successor"
! has "$(r list)" worker-1 && has "$(r list --all)" worker-1 && ok "list hides retired unless --all" || ko "list hides retired unless --all"
refuses "retire unknown row" r retire nobody

# render
check "render" r render
[ ! -w "$ROUTE_MD" ] && ok "markdown is read-only" || ko "markdown is read-only"
md=$(cat "$ROUTE_MD")
has "$md" "| lead-1 |" && has "$md" "it's \\| tricky" && has "$md" "Retired today" && has "$md" "Master host: hostA" && ok "markdown has rows, escaped pipe, retired section, master host" || ko "markdown content"
check "render overwrites a read-only file" r render

# import
cat > "$T/old.md" <<'MD'
# Old table

| Session | Role | Owner | Reached via | Pane handle | Environment | Agent/model | Custom |
|---|---|---|---|---|---|---|---|
| `imp-1` | planner | carol | native bus | — | hostA | claude | x1 |
| imp-2 | coder | dave | mailbox relay | term_9 | hostB | codex | |
| imp-3 | misc | erin | carrier pigeon | | | | |
|  | no name | | | | | | |

## Retired

| Name | Role |
| --- | --- |
| imp-old | gone |
MD
out=$(r import "$T/old.md" 2>&1); rc=$?
[ $rc -ne 0 ] && ok "import returns non-zero when rows had problems" || ko "import returns non-zero when problems"
has "$out" "carrier pigeon" && has "$out" "no name" && has "$out" "Custom" && ok "import reports unmappable bits" || ko "import reports unmappable bits"
has "$(r get imp-1)" "reach = bus" && has "$(r get imp-1)" "notes = Custom: x1" && ok "import maps headers and values" || ko "import maps headers and values"
has "$(r get imp-2)" "pane = term_9" && has "$(r get imp-old)" "status = retired" && ok "import handles pane and retired section" || ko "import pane and retired section"
refuses "import with no table fails loudly" bash -c "echo hello > '$T/none.md'; bash '$R' import '$T/none.md'"

# sweep
echo "{\"name\":\"imp-1\",\"pid\":$$,\"sessionId\":\"s1\"}" > "$SESSION_BUS_DIR/1.json"
echo "{\"name\":\"stranger\",\"pid\":$$,\"sessionId\":\"s2\"}" > "$SESSION_BUS_DIR/2.json"
echo "{\"name\":\"dead\",\"pid\":999999,\"sessionId\":\"s3\"}" > "$SESSION_BUS_DIR/3.json"
out=$(r sweep)
has "$out" "UNLISTED: live session 'stranger'" && ! has "$out" "'dead'" && has "$out" "MISSING: row 'lead-1'" && ! has "$out" "MISSING: row 'imp-1'" && ok "sweep reports mismatches" || { ko "sweep reports mismatches"; echo "$out"; }
! has "$(r get imp-1)" "last_seen = 20" && ok "sweep alone changes nothing" || ko "sweep alone changes nothing"
r sweep --apply >/dev/null
has "$(r get imp-1)" "last_seen = 20" && ok "sweep --apply stamps last_seen" || ko "sweep --apply stamps last_seen"

# replicate
REP="$T/replica"
refuses "replicate needs targets" env -u ROUTE_REPLICAS bash "$R" replicate
check "replicate to local path" env ROUTE_REPLICAS="$REP $T/replica2" bash "$R" replicate
[ "$(sqlite3 "$REP/routing.db" 'select count(*) from sessions')" = "$(sqlite3 "$ROUTE_DB" 'select count(*) from sessions')" ] && ok "replica DB matches master" || ko "replica DB matches master"
[ ! -w "$REP/routing.db" ] && [ ! -w "$REP/ROUTING.md" ] && ok "replica files are read-only" || ko "replica files are read-only"
[ ! -e "$REP/routing.db.master" ] && ok "marker is not replicated" || ko "marker is not replicated"
has "$(cat "$REP/ROUTING.md")" "lead-1" && ok "replica markdown has rows" || ko "replica markdown has rows"
check "replicate again over read-only files" env ROUTE_REPLICAS="$REP" bash "$R" replicate

# replica role and refusal
export MASTER_DB="$ROUTE_DB"
RR="ROUTE_DB=$REP/routing.db"
[ "$(env $RR bash "$R" role | cut -d' ' -f1)" = replica ] && ok "replica role detected" || ko "replica role detected"
has "$(env $RR bash "$R" role)" "master host: hostA" && ok "replica role shows master host" || ko "replica role shows master host"
for c in "set a role=b" "retire lead-1" "import $T/old.md" "sweep --apply" "replicate"; do
  out=$(env $RR bash "$R" $c 2>&1); has "$out" "replica" && ok "replica refuses: ${c%% *}" || ko "replica refuses: ${c%% *}"
done
has "$(env $RR bash "$R" get lead-1)" "lead-1" && ok "replica reads work" || ko "replica reads work"

# replicator: one pass
ROUTE_REPLICAS="$T/replica3" ROUTE_REPLICATE_INTERVAL=1 ROUTE_REPLICATOR_LOG="$T/rep.log" bash "$HERE/scripts/route-replicator.sh" >/dev/null 2>&1 &
rp=$!; sleep 4; kill $rp 2>/dev/null; wait $rp 2>/dev/null
[ -e "$T/replica3/routing.db" ] && grep -q replicated "$T/rep.log" && ok "replicator replicates on change" || ko "replicator replicates on change"
n=$(grep -c replicated "$T/rep.log"); [ "$n" = 1 ] && ok "replicator skips unchanged database" || ko "replicator skips unchanged ($n runs)"

# promote / demote
refuses "promote without --yes" env $RR bash "$R" promote
[ "$(env $RR bash "$R" role | cut -d' ' -f1)" = replica ] && ok "still replica after refused promote" || ko "still replica after refused promote"
refuses "promote on a master" bash "$R" promote --yes
out=$(env $RR ROUTE_HOST=hostB bash "$R" promote --yes 2>&1); has "$out" PROMOTED && ok "promote --yes" || ko "promote --yes"
RDB="$REP/routing.db"
[ -e "$RDB.master" ] && [ -w "$RDB" ] && ok "promoted copy is writable with marker" || ko "promoted copy is writable with marker"
has "$(env $RR bash "$R" role)" "master host: hostB" && ok "role shows new master host" || ko "role shows new master host"
check "write works after promote" env $RR bash "$R" set post-promote role=x
has "$(env $RR bash "$R" history '*')" promote && ok "promotion recorded in history" || ko "promotion recorded in history"
check "demote old master" r demote
[ ! -e "$ROUTE_DB.master" ] && [ ! -w "$ROUTE_DB" ] && ok "demote removes marker and write bit" || ko "demote removes marker and write bit"
out=$(r set late role=x 2>&1); has "$out" replica && ok "demoted master refuses writes" || ko "demoted master refuses writes"
has "$(r history '*')" demote && ok "demotion recorded in history" || ko "demotion recorded in history"

echo; echo "passed: $pass  failed: $fail"
[ $fail -eq 0 ]
