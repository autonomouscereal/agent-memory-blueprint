#!/usr/bin/env bash
# Tests for backup_pg_db.sh 2.1.x's NAS-copy guards (2026-11-24): the copy window, the pool gate, the
# share-copy lock shared with backup_agent_memory_pg.sh (and 2.2.0's wait lock beside it), --bwlimit, the 20 GB
# free-space floor and the catch-up of skipped copies; 2.3.0's MIRROR_COPY=0 (no NAS copy) with `mirror`, a whole
# run and status (section 13, which has its own fuller fake docker). The hand-over between the two jobs is tested with both real
# scripts in test_backup_agent_memory_pg.sh, section 23. Uses the `mirror` command on a fake local backup tree with
# random dumps; a tiny fake docker serves the run path's first checks. Everything lives in a temp dir; no real backup
# path is touched.
#   bash scripts/tests/test_backup_pg_db.sh [path/to/backup_pg_db.sh]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(readlink -f "${1:-$HERE/../backup_pg_db.sh}")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pgdb-test.XXXXXX")"
REAL_RSYNC="$(command -v rsync)"
PASS=0
FAIL=0
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf -- "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/rsync" <<SHIM
#!/usr/bin/env bash
# rsync wrapper: records its arguments; FAKE_RSYNC_CORRUPT=1 flips the last byte of a copied .dump.
printf '%s\n' "\$*" >> "\$FAKE_STATE/rsync_args"
args=("\$@"); dst="\${args[-1]}"
"$REAL_RSYNC" "\$@" || exit \$?
if [[ -n "\${FAKE_RSYNC_CORRUPT:-}" ]]; then
  for a in "\${args[@]}"; do
    [[ "\$a" == *.dump ]] || continue
    f="\$dst/\$(basename "\$a")"; printf 'X' | dd of="\$f" bs=1 seek=\$(( \$(stat -c %s "\$f") - 1 )) conv=notrunc status=none
  done
fi
exit 0
SHIM
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
# Fake docker for the run path's first checks only: the container runs and the database exists.
case "$1" in
  inspect) echo true; exit 0 ;;
  exec) cat > /dev/null; echo 1; exit 0 ;;
esac
exit 2
SHIM
# Fake crontab for status: an empty crontab, so no test reads the real one.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/crontab"
chmod +x "$WORK/bin/rsync" "$WORK/bin/docker" "$WORK/bin/crontab"

new_env() {
  E="$WORK/env$1"
  mkdir -p "$E/local" "$E/mnt/backups" "$E/logs" "$E/locks" "$E/fake"
  export PATH="$WORK/bin:$PATH" FAKE_STATE="$E/fake" DB_NAME=labdb RECORD_RUN=0
  export DEST_ROOT="$E/local" MIRROR_ROOT="$E/mnt/backups/pg-db-postgres" LOG_DIR="$E/logs" LOG_FILE="$E/logs/pg.log"
  export LOCK_DIR="$E/locks" SHARE_COPY_LOCK="$E/share-copy.lock" MIN_MIRROR_FREE_KB=0
  export TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 86400 )) POOL_STATE_MAX_AGE_SECONDS=100000 PACE_BUSY_WAIT_SECONDS=1
  export MIN_SYSTEM_FREE_KB=0 FREE_CHECK_PATHS="/ $E/local"
  # 2.1.1: an empty env file, so a pg-db-backup.env beside the script under test never applies.
  : > "$WORK/empty.env"; export PG_DB_BACKUP_ENV="$WORK/empty.env"
  unset FAKE_RSYNC_CORRUPT TRANSFER_WINDOW_UTC PACE_GATE BWLIMIT_KBPS
  pool_state OK
}
pool_state() {
  mkdir -p "$E/mnt/.nas-tuning"
  printf '%s %s disk_med=18ms test\n' "$1" "${2:-$(date -u +%FT%TZ)}" > "$E/mnt/.nas-tuning/pool_state"
}
# make_backup <stamp>: a published local backup with a random dump, its sidecar, manifest and restore list
make_backup() {
  local id="labdb_$1" d="$DEST_ROOT/labdb"
  mkdir -p "$d/dumps" "$d/manifests" "$d/restore-lists"
  head -c 300000 /dev/urandom > "$d/dumps/$id.dump"
  (cd "$d/dumps" && sha256sum "$id.dump" > "$id.dump.sha256")
  printf '{"backup_id": "%s"}\n' "$id" > "$d/manifests/$id.manifest.json"
  printf ';\n; TOC Entries: 1\n' > "$d/restore-lists/$id.restore.list"
  printf '%s\n' "$id" > "$d/latest_backup_id.txt"
  LAST="$id"
}
on_share() { [[ -s "$MIRROR_ROOT/labdb/$1.dump" ]] && (cd "$MIRROR_ROOT/labdb" && sha256sum --quiet -c "$1.dump.sha256" 2>/dev/null); }
not_on_share() { [[ ! -e "$MIRROR_ROOT/labdb/$1.dump" ]]; }
run_cmd() { local name="$1" cmd="$2"; shift 2; env "$@" bash "$SCRIPT" "$cmd" > "$E/fake/$name.out" 2>&1; RC=$?; OUT="$E/fake/$name.out"; }
rc_is() { [[ "$RC" == "$1" ]]; }
check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $desc"
  else FAIL=$((FAIL + 1)); echo "FAIL - $desc"; [[ -n "${OUT:-}" ]] && sed 's/^/       | /' "$OUT" | tail -n 20; fi
}
logt() { date -u -d "$(grep -m1 "$1" "$OUT" | sed -n 's/^\[\([^]]*\)\].*/\1/p')" +%s 2>/dev/null || echo 0; }

echo "# script: $SCRIPT"
bash -n "$SCRIPT"; check "script parses" true

# 1. Pool OK, window open: copied with --bwlimit under the share-copy lock, verified.
new_env 1
make_backup 20261101T095000Z; A="$LAST"
run_cmd ok mirror
check "mirror: exits 0" rc_is 0
check "mirror: the dump is on the share and its sidecar matches" on_share "$A"
check "mirror: verified is logged" grep -q "NAS copy verified: .*$A.dump" "$OUT"
check "mirror: rsync ran with --bwlimit=6000" grep -q -- '--bwlimit=6000' "$FAKE_STATE/rsync_args"
check "mirror: the share-copy lock was taken" grep -q 'share-copy lock taken' "$OUT"
check "mirror: and released" grep -q 'share-copy lock released' "$OUT"

# 2. Pool BUSY until the deadline: nothing is written; the result says so.
make_backup 20261102T095000Z; B="$LAST"
pool_state BUSY
run_cmd busy mirror TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 3 ))
check "gate: BUSY until the deadline exits 1 (not copied)" rc_is 1
check "gate: BUSY is logged" grep -q 'pool not OK, no NAS write: BUSY' "$OUT"
check "gate: nothing was written to the share" not_on_share "$B"
check "gate: the skip says the next run copies it" grep -q "NAS copy of $B not started before the window end" "$OUT"

# 3. Catch-up: the next run copies the skipped backup and the new one.
make_backup 20261103T095000Z; C="$LAST"
pool_state OK
run_cmd catchup mirror
check "catch-up: exits 0" rc_is 0
check "catch-up: the skipped backup is now on the share" on_share "$B"
check "catch-up: the new backup is on the share" on_share "$C"
check "catch-up: the skipped one was copied before the new one" test "$(grep -n "NAS copy of $B" "$OUT" | head -1 | cut -d: -f1)" -lt "$(grep -n "NAS copy of $C" "$OUT" | head -1 | cut -d: -f1)"

# 4. Another job holds the share-copy lock: the copy waits and starts only after the release.
make_backup 20261104T095000Z; D="$LAST"
( flock 8; sleep 3; date +%s > "$E/fake/released" ) 8>>"$SHARE_COPY_LOCK" &
sleep 0.5
run_cmd lockwait mirror
wait
check "lock: the copy waits for the share-copy lock" grep -q 'waiting for the share-copy lock' "$OUT"
check "lock: it takes the lock only after the release" test "$(logt 'share-copy lock taken')" -ge "$(cat "$E/fake/released")"
check "lock: then it copies (exit 0)" rc_is 0
check "lock: the dump is on the share" on_share "$D"

# 5. The lock stays held until the deadline: skipped, nothing written.
make_backup 20261105T095000Z; F5="$LAST"
( flock 8; sleep 7 ) 8>>"$SHARE_COPY_LOCK" &
sleep 0.5
run_cmd lockheld mirror TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 3 ))
wait
check "lock: held past the deadline exits 1" rc_is 1
check "lock: the skip is logged" grep -q 'the share-copy lock stayed held until the window end' "$OUT"
check "lock: nothing was written" not_on_share "$F5"

# 6. Outside the copy window: nothing written.
W="00:00-00:01"; [[ "$(date -u +%H:%M)" == "00:00" ]] && W="12:00-12:01"
run_cmd window mirror TRANSFER_DEADLINE_EPOCH= TRANSFER_WINDOW_UTC="$W"
check "window: outside the window exits 1" rc_is 1
check "window: the reason is logged" grep -q "outside the copy window $W UTC" "$OUT"
check "window: nothing was written" not_on_share "$F5"
run_cmd badwin mirror TRANSFER_DEADLINE_EPOCH= TRANSFER_WINDOW_UTC="13:00-07:00"
check "window: a window across midnight is refused" grep -q 'must not cross midnight' "$OUT"

# 7. Free space under the floor: no NAS copy; a run refuses to stage (dump) at all.
run_cmd lowfree mirror MIN_SYSTEM_FREE_KB=999999999999
check "free space: the NAS copy is skipped (exit 1)" rc_is 1
check "free space: the reason is logged" grep -q 'NAS copy skipped: / has' "$OUT"
check "free space: nothing was written" not_on_share "$F5"
run_cmd lowrun run MIN_SYSTEM_FREE_KB=999999999999
check "free space: a run refuses to stage (exit 1)" rc_is 1
check "free space: the refusal is logged" grep -q 'refusing to stage: / has' "$OUT"
check "free space: no new dump was made" test "$(ls "$DEST_ROOT/labdb/dumps" | grep -c '\.dump$')" = 5

# 8. A missing or stale pool state counts as BUSY.
rm -f "$E/mnt/.nas-tuning/pool_state"
run_cmd missing mirror TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 3 ))
check "gate: a missing state file counts as BUSY" grep -q 'pool not OK, no NAS write: missing or unreadable' "$OUT"
check "gate: nothing was written" not_on_share "$F5"
pool_state OK "$(date -u -d '-1 hour' +%FT%TZ)"
run_cmd stale mirror POOL_STATE_MAX_AGE_SECONDS=300 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 3 ))
check "gate: a stale OK line counts as BUSY" grep -q 'pool not OK, no NAS write: stale' "$OUT"

# 9. A copy that arrives corrupt is reported, and the next clean run copies it again.
pool_state OK
run_cmd corrupt mirror FAKE_RSYNC_CORRUPT=1
check "checksum: a corrupt copy exits 1" rc_is 1
check "checksum: the mismatch is logged" grep -q "sha256 mismatch at .*$F5.dump" "$OUT"
run_cmd recopy mirror
check "checksum: the next run copies it again (exit 0)" rc_is 0
check "checksum: now verified on the share" on_share "$F5"

# 10. Nothing missing: a rerun copies nothing and still reports verified.
: > "$FAKE_STATE/rsync_args"
run_cmd noop mirror
check "rerun: exits 0" rc_is 0
check "rerun: no rsync ran" test ! -s "$FAKE_STATE/rsync_args"
check "rerun: the result is verified" grep -q "NAS copy result: $F5 verified (copied 0, failed 0)" "$OUT"

# 11. 2.1.1: machine values come from pg-db-backup.env beside the script (or PG_DB_BACKUP_ENV); the environment
#     wins; an empty CRON_DBS is refused; without a file the defaults are generic.
new_env 11
make_backup 20261111T095000Z; G="$LAST"
printf '%s\n' "# NAS copy root for this test" "MIRROR_ROOT=\"$E/mnt/backups/from-file\"" > "$E/fake/pg.env"
run_cmd envfile mirror -u MIRROR_ROOT PG_DB_BACKUP_ENV="$E/fake/pg.env"
check "env file: a mirror configured by the file exits 0" rc_is 0
check "env file: the copy lands under the file's MIRROR_ROOT" test -s "$E/mnt/backups/from-file/labdb/$G.dump"
run_cmd envwins mirror PG_DB_BACKUP_ENV="$E/fake/pg.env"
check "env file: the environment's MIRROR_ROOT wins" on_share "$G"
CP="$E/copy"; mkdir -p "$CP"; cp "$SCRIPT" "$CP/backup_pg_db.sh"
printf '%s\n' "CRON_DBS=\"alpha beta\"" > "$CP/pg-db-backup.env"
OUT="$E/fake/envbeside.out"; env -u PG_DB_BACKUP_ENV -u CRON_DBS bash "$CP/backup_pg_db.sh" status > "$OUT" 2>&1; RC=$?
check "env file beside the script: status lists its CRON_DBS" bash -c "grep -qx '== alpha' '$OUT' && grep -qx '== beta' '$OUT'"
run_cmd nodbs run-all -u CRON_DBS PG_DB_BACKUP_ENV="$E/fake/missing.env"
check "no databases: run-all refuses an empty CRON_DBS (exit 1)" rc_is 1
check "no databases: the refusal names the env file" grep -q "CRON_DBS is empty: list the databases in $E/fake/missing.env" "$OUT"
run_cmd defaults restore-help -u DEST_ROOT PG_DB_BACKUP_ENV="$E/fake/missing.env"
check "no env file: DEST_ROOT defaults under \$HOME" grep -q "D=$HOME/pg-db-backups/<db>/dumps/<backup_id>.dump" "$OUT"

# 12. 2.2.0: while the copy waits for the share-copy lock it holds the wait lock shared (the agent-memory copy reads
#     that as "hand the share over"), and both are free once it is done. A wait lock held exclusively past the
#     deadline skips the copy without a write.
new_env 12
WL="$E/share-copy-wait.lock"
make_backup 20261112T095000Z; H="$LAST"
( flock 8; sleep 3 ) 8>>"$SHARE_COPY_LOCK" &
HOLDER=$!
sleep 0.5
OUT="$E/fake/waitlock.out"
bash "$SCRIPT" mirror > "$OUT" 2>&1 &
MIRROR=$!
for _ in $(seq 1 50); do grep -q 'waiting for the share-copy lock' "$OUT" && break; sleep 0.1; done
check "wait lock: held while the copy waits for the share-copy lock" bash -c "! flock -n -x '$WL' true"
check "wait lock: held shared (a second shared holder gets it)" flock -n -s "$WL" true
wait "$MIRROR"; RC=$?
wait "$HOLDER"
check "wait lock: the copy then runs (exit 0)" rc_is 0
check "wait lock: the dump is on the share" on_share "$H"
check "wait lock: free once the copy is done" flock -n -x "$WL" true
check "wait lock: the share-copy lock is free too" flock -n -x "$SHARE_COPY_LOCK" true
make_backup 20261113T095000Z; H2="$LAST"
( flock -x 8; sleep 6 ) 8>>"$WL" &
sleep 0.5
run_cmd waitheld mirror TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 3 ))
wait
check "wait lock: held exclusively past the deadline exits 1" rc_is 1
check "wait lock: the skip is logged" grep -q 'the share-copy wait lock stayed held until the window end' "$OUT"
check "wait lock: nothing was written" not_on_share "$H2"

# 13. 2.3.0: MIRROR_COPY=0 turns the NAS copy off. `mirror` exits 1 and leaves the share as it was (no write, no
#     rsync); a full run publishes the local backup, logs nas=off and lists only the local copy in its manifest. With
#     the default (MIRROR_COPY=1) the same run still copies and logs nas=verified.
new_env 13
mkdir -p "$WORK/bin13"
cat > "$WORK/bin13/docker" <<'SHIM'
#!/usr/bin/env bash
# Fake docker for a whole run: the snapshot psql session, the table count, pg_dump, pg_restore (--list and into the
# test database), createdb and dropdb. One table, public.t, with 3 rows on both sides.
case "$1" in inspect) echo true; exit 0 ;; exec) ;; *) exit 2 ;; esac
shift; args="$*"
if [[ "$args" == *"pg_dump "* ]]; then printf 'PGDMP fake dump\n'; seq 1 2000; exit 0; fi
if [[ "$args" == *"pg_restore --list"* ]]; then cat > /dev/null; printf ';\n; TOC Entries: 2\n1; 0 0 TABLE public t x\n'; exit 0; fi
if [[ "$args" == *pg_restore* ]]; then cat > /dev/null; exit 0; fi
if [[ "$args" == *createdb* || "$args" == *dropdb* ]]; then exit 0; fi
if [[ "$args" == *psql* ]]; then
  while IFS= read -r line; do
    case "$line" in
      *pg_export_snapshot*) echo "SNAP|00000003-0000001B-1" ;;
      *"FROM pg_tables"*) echo "public.t|3" ;;
      *__END__*) echo "__END__" ;;
      *"FROM pg_database"*) echo 1 ;;
      '\q') exit 0 ;;
    esac
  done
  exit 0
fi
exit 2
SHIM
chmod +x "$WORK/bin13/docker"
make_backup 20261126T095000Z; J="$LAST"
: > "$FAKE_STATE/rsync_args"
mnt_snap() { find "$E/mnt" -printf '%p %s %T@ %m\n' | sort; }
MNT_BEFORE="$(mnt_snap)"
run_cmd offmirror mirror MIRROR_COPY=0
check "NAS copy off: mirror exits 1" rc_is 1
check "NAS copy off: mirror says so" grep -q 'NAS copy off (MIRROR_COPY=0); the local copy is the restore point' "$OUT"
check "NAS copy off: mirror wrote nothing to the share" not_on_share "$J"
check "NAS copy off: no rsync ran" test ! -s "$FAKE_STATE/rsync_args"
check "NAS copy off: the share is exactly as it was" test "$MNT_BEFORE" = "$(mnt_snap)"
run_cmd badoff mirror MIRROR_COPY=maybe
check "NAS copy setting: a value other than 0 or 1 is refused (exit 1)" rc_is 1
check "NAS copy setting: the refusal names MIRROR_COPY" grep -q 'MIRROR_COPY must be 0 or 1' "$OUT"
sleep 1.1
run_cmd offrun run MIRROR_COPY=0 PATH="$WORK/bin13:$PATH"
OFF_ID="$(tr -d '\n' < "$DEST_ROOT/labdb/latest_backup_id.txt")"
check "NAS copy off: a run exits 0" rc_is 0
check "NAS copy off: the run publishes a new local backup" bash -c "[[ '$OFF_ID' != '$J' && -s '$DEST_ROOT/labdb/dumps/$OFF_ID.dump' ]]"
check "NAS copy off: its backup complete line ends in nas=off" grep -q "] backup complete: $DEST_ROOT/labdb/dumps/$OFF_ID.dump size=[0-9]* sha256=[0-9a-f]* nas=off$" "$E/logs/pg.log"
check "NAS copy off: the manifest lists only the local copy" grep -qxF "  \"copies\": [\"$DEST_ROOT/labdb/dumps/$OFF_ID.dump\"]" "$DEST_ROOT/labdb/manifests/$OFF_ID.manifest.json"
check "NAS copy off: the run wrote nothing to the share" test "$MNT_BEFORE" = "$(mnt_snap)"
check "NAS copy off: no rsync ran in the run" test ! -s "$FAKE_STATE/rsync_args"
sleep 1.1
run_cmd onrun run PATH="$WORK/bin13:$PATH"
ON_ID="$(tr -d '\n' < "$DEST_ROOT/labdb/latest_backup_id.txt")"
check "NAS copy on (default): a run exits 0" rc_is 0
check "NAS copy on (default): its backup complete line ends in nas=verified" grep -q "] backup complete: $DEST_ROOT/labdb/dumps/$ON_ID.dump .* nas=verified$" "$E/logs/pg.log"
check "NAS copy on (default): the dump is verified on the share" on_share "$ON_ID"
run_cmd offstatus status MIRROR_COPY=0 CRON_DBS=labdb
check "NAS copy off: status says the NAS copy is off" grep -q 'NAS copy: off (MIRROR_COPY=0)' "$OUT"
check "NAS copy off: status lists no NAS folder" bash -c "! grep -q -- '-- NAS ' '$OUT'"

echo "# passed $PASS failed $FAIL"
[[ "$FAIL" == 0 ]]
