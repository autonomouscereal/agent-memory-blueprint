#!/usr/bin/env bash
# restore_test_agent_memory.sh 1.0.3 - weekly full restore test of the one verified agent_memory backup.
#
# The rule (2026-10-28): the live DB plus exactly one backup proven restorable. This test restores the dump named by
# DEST_ROOT/latest_backup_id.txt into a throwaway container (the live container's image, no network, CPUS cores,
# MEMORY memory), counts every restored table exactly, compares the id-keyed tables with the live DB in a read-only
# transaction, writes a JSON result, then removes the container and its disk image.
#
# Disk: the staging drive (STAGING_DRIVE) may be exFAT, which has no Unix owners or modes, so Postgres cannot keep a
# data directory on it directly. The data directory is an ext4 image on that drive, loop-mounted with direct I/O (no
# host page cache). Space: the nightly backup stages its dump there and needs (dump size + 15 %) + LOCAL_MIN_FREE_KB
# (60 GiB) free. This test refuses to start unless that much is still free after its image exists, so even a leaked
# image cannot fail the nightly's preflight. It also holds the nightly's lock (backup-v2.lock) for its whole run, and
# cron starts it at a quiet hour under a 6 h limit, so the two never run at the same time.
# Serving: when SERVING_UNIT names a systemd unit whose journal logs "done: N tokens in N s (R tok/s)" lines (a local
# inference server), the test stops early (status "aborted") if that service's speed falls below WATCH_FRACTION of
# its 24-hour median, measured as the median of at least 4 answers of 100+ tokens over the last 20 minutes.
# 1.0.3 (2026-11-24): the machine's own values (DEST_ROOT, STAGING_DRIVE, SERVING_UNIT) come from
# agent-memory-backup.env beside this script, the backup job's env file, by the same rules as backup_agent_memory_pg.sh.
#
#   restore_test_agent_memory.sh plan    space math and the steps, changes nothing
#   restore_test_agent_memory.sh run     the test (exit 0 pass, 1 fail, 2 aborted for serving, 75 lock busy)
set -Eeuo pipefail

VERSION="1.0.3"

# Same rules as load_env_file in backup_agent_memory_pg.sh: KEY=VALUE lines, the environment wins over the file.
load_env_file() {
  local env_file="$1" env_line env_key env_value env_n=0
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r env_line || [[ -n "$env_line" ]]; do
    env_n=$((env_n + 1))
    env_line="${env_line%$'\r'}"
    [[ "$env_line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$env_line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      printf 'WARN: %s line %s is not KEY=VALUE; ignored\n' "$env_file" "$env_n" >&2
      continue
    fi
    env_key="${BASH_REMATCH[2]}"; env_value="${BASH_REMATCH[3]}"
    [[ -n "${!env_key+set}" ]] && continue
    if [[ "$env_value" =~ ^\"(.*)\"$ || "$env_value" =~ ^\'(.*)\'$ ]]; then env_value="${BASH_REMATCH[1]}"; fi
    printf -v "$env_key" '%s' "$env_value"
  done < "$env_file"
}
BACKUP_ENV_FILE="${AGENT_MEMORY_BACKUP_ENV:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/agent-memory-backup.env}"
load_env_file "$BACKUP_ENV_FILE"

MOUNTPOINT="${MOUNTPOINT:-/mnt/nas}"
DEST_ROOT="${DEST_ROOT:-$MOUNTPOINT/backups/agent-memory-postgres}"
LIVE_CONTAINER="${LIVE_CONTAINER:-agent-memory-postgres}"
# The drive that holds the nightly's LOCAL_STAGING: the image goes there, and the space math reads its free space.
STAGING_DRIVE="${STAGING_DRIVE:-$HOME}"
IMAGE_FILE="${IMAGE_FILE:-$STAGING_DRIVE/agent-memory-restore-test.ext4}"
MOUNT_DIR="${MOUNT_DIR:-/mnt/agent-memory-restore-test}"
STATE_DIR="${STATE_DIR:-$HOME/agent-memory-backup/state}"
LOCK_FILE="${LOCK_FILE:-$HOME/agent-memory-backup/backup-v2.lock}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-10800}"
RESTORE_TIMEOUT_SECONDS="${RESTORE_TIMEOUT_SECONDS:-18000}"
LOCAL_MIN_FREE_KB="${LOCAL_MIN_FREE_KB:-62914560}"
SIZE_HEADROOM_PERCENT="${SIZE_HEADROOM_PERCENT:-15}"
IMAGE_EXTRA_GIB="${IMAGE_EXTRA_GIB:-8}"
CPUS="${CPUS:-2}"
MEMORY="${MEMORY:-10g}"
WATCH_FRACTION="${WATCH_FRACTION:-0.70}"
SERVING_UNIT="${SERVING_UNIT:-}"
CORE_TABLES="public.agent_memory_events public.agent_memory_payload_archives agent_coordination.events agent_coordination.messages"

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
NAME="agent-memory-restore-test-$STAMP"
LOOP_DEV=""
CONTAINER_STARTED=0
MOUNTED=0
IMAGE_CREATED=0
WORK_TMP=""

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*"; FAIL_REASON="$*"; exit 1; }
FAIL_REASON=""

live_sql() {
  docker exec -i "$LIVE_CONTAINER" sh -c 'psql -U "${POSTGRES_USER:-agent_memory}" -d "${POSTGRES_DB:-agent_memory}" -At -F "|" -v ON_ERROR_STOP=1 -q' |
    tr -d '\r'
}
test_sql() {
  docker exec -i "$NAME" psql -U postgres -d agent_memory -At -F "|" -v ON_ERROR_STOP=1 -q | tr -d '\r'
}
available_kb_of() { df -Pk "$1" | awk 'NR > 1 { v = $4 } END { print v }'; }

serving_rates() {  # tok/s of finished SERVING_UNIT requests of >= 100 tokens since $1 (journal time), one per line
  # Short answers are dominated by prompt reading, and overlapping requests slow each other, so only long answers
  # are a fair speed sample (11-21: bursts of 10 requests in 34 s ran 20-50-token answers at 40-60 tok/s untouched).
  [[ -n "$SERVING_UNIT" ]] || return 0
  journalctl -u "$SERVING_UNIT" --since "$1" --no-pager -o cat 2>/dev/null |
    grep -oE 'done: [0-9]+ tokens in [0-9]+ s \([0-9.]+ tok/s\)' |
    awk '{ n = $2; r = $7; gsub(/\(/, "", r); if (n >= 100) print r }' || true
}

space_math() {
  LATEST_ID="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt")"
  [[ "$LATEST_ID" =~ ^agent_memory_[0-9]{8}T[0-9]{6}Z$ ]] || die "no valid backup pointer in $DEST_ROOT"
  DUMP="$DEST_ROOT/dumps/$LATEST_ID.dump"
  MANIFEST="$DEST_ROOT/manifests/$LATEST_ID.manifest.json"
  DUMP_BYTES="$(stat -c %s "$DUMP")"
  LIVE_DB_BYTES="$(echo "select pg_database_size(current_database());" | live_sql)"
  IMAGE_GIB=$(( (LIVE_DB_BYTES + 1073741823) / 1073741824 + IMAGE_EXTRA_GIB ))
  IMAGE_KB=$(( IMAGE_GIB * 1048576 ))
  NIGHTLY_NEED_KB=$(( DUMP_BYTES / 1024 * (100 + SIZE_HEADROOM_PERCENT) / 100 + LOCAL_MIN_FREE_KB ))
  STAGING_FREE_KB="$(available_kb_of "$STAGING_DRIVE")"
  [[ -e "$IMAGE_FILE" ]] && STAGING_FREE_KB=$(( STAGING_FREE_KB + $(stat -c %s "$IMAGE_FILE") / 1024 ))
  AFTER_KB=$(( STAGING_FREE_KB - IMAGE_KB ))
  log "space: staging_free=$((STAGING_FREE_KB / 1048576)) GiB image=$IMAGE_GIB GiB (live db $((LIVE_DB_BYTES / 1073741824)) GiB + $IMAGE_EXTRA_GIB) after=$((AFTER_KB / 1048576)) GiB nightly_need=$((NIGHTLY_NEED_KB / 1048576)) GiB (dump $((DUMP_BYTES / 1073741824)) GiB + ${SIZE_HEADROOM_PERCENT}% + floor $((LOCAL_MIN_FREE_KB / 1048576)) GiB)"
}

write_result() {
  local status="$1" detail="$2"
  local finished; finished="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$STATE_DIR/restore-tests"
  python3 - "$STATE_DIR/restore-tests/$STAMP.json" "$status" "$detail" "$finished" "${COUNTS_FILE:-}" <<PY
import json, os, sys
path, status, detail, finished, counts_file = sys.argv[1:6]
counts = json.load(open(counts_file)) if counts_file and os.path.exists(counts_file) else {}
out = {"status": status, "detail": detail, "backup_id": "${LATEST_ID:-}", "dump_bytes": int("${DUMP_BYTES:-0}" or 0),
       "dump_sha256_verified": "${SHA_OK:-no}" == "yes", "started_at_utc": "$STARTED_UTC", "finished_at_utc": finished,
       "image_gib": int("${IMAGE_GIB:-0}" or 0), "restored_db_bytes": int("${RESTORED_DB_BYTES:-0}" or 0),
       "pg_restore_seconds": int("${RESTORE_SECONDS:-0}" or 0), "serving_median_tok_s": "${SERVING_MEDIAN:-}",
       "script": "restore_test_agent_memory.sh $VERSION", "host": os.uname().nodename, **counts}
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(out, f, indent=2); f.write("\n")
os.replace(tmp, path)
PY
  cp -f "$STATE_DIR/restore-tests/$STAMP.json" "$STATE_DIR/restore-test-latest.json.tmp"
  mv -f "$STATE_DIR/restore-test-latest.json.tmp" "$STATE_DIR/restore-test-latest.json"
  mkdir -p "$DEST_ROOT/restore-tests" 2>/dev/null &&
    cp -f "$STATE_DIR/restore-tests/$STAMP.json" "$DEST_ROOT/restore-tests/$STAMP.json" 2>/dev/null &&
    cp -f "$STATE_DIR/restore-tests/$STAMP.json" "$DEST_ROOT/restore-tests/latest-restore.json" 2>/dev/null || true
  log "result: $status ($detail) -> $STATE_DIR/restore-test-latest.json"
}

cleanup() {
  local rc=$?
  set +e
  trap '' HUP INT TERM
  [[ "$CONTAINER_STARTED" == "1" ]] && docker rm -f "$NAME" >/dev/null 2>&1 && log "removed container $NAME"
  if [[ "$MOUNTED" == "1" ]]; then
    for _ in 1 2 3 4 5; do sudo -n umount "$MOUNT_DIR" 2>/dev/null && break; sleep 3; done
    mountpoint -q "$MOUNT_DIR" && log "WARN: $MOUNT_DIR is still mounted" || log "unmounted $MOUNT_DIR"
  fi
  [[ -n "$LOOP_DEV" ]] && sudo -n losetup -d "$LOOP_DEV" 2>/dev/null && log "detached $LOOP_DEV"
  if [[ "$IMAGE_CREATED" == "1" && -e "$IMAGE_FILE" ]]; then
    rm -f -- "$IMAGE_FILE" && log "deleted image $IMAGE_FILE" || log "WARN: could not delete $IMAGE_FILE"
  fi
  [[ -n "$WORK_TMP" ]] && rm -rf -- "$WORK_TMP"
  if [[ "$rc" -ne 0 && "$rc" -ne 2 && "$rc" -ne 75 && "${RESULT_WRITTEN:-0}" != "1" ]]; then
    write_result fail "${FAIL_REASON:-exit $rc}"
  fi
  exit "$rc"
}

run_locked() {
  STARTED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  trap cleanup EXIT
  trap 'FAIL_REASON="stopped by signal"; exit 143' HUP INT TERM
  log "restore test $VERSION start ($NAME)"
  docker inspect "$LIVE_CONTAINER" >/dev/null || die "live container missing: $LIVE_CONTAINER"
  local image_id pg_uid
  image_id="$(docker inspect -f '{{.Image}}' "$LIVE_CONTAINER")"
  pg_uid="$(docker exec "$LIVE_CONTAINER" id -u postgres)"
  ls "$DEST_ROOT" >/dev/null 2>&1 || die "destination not readable: $DEST_ROOT"
  space_math
  (( AFTER_KB >= NIGHTLY_NEED_KB )) || die "the staging drive $STAGING_DRIVE would keep $((AFTER_KB / 1048576)) GiB free, under the nightly's $((NIGHTLY_NEED_KB / 1048576)) GiB; not starting"
  [[ ! -e "$IMAGE_FILE" ]] || die "an earlier image is still present: $IMAGE_FILE (delete it after checking no test runs)"
  mountpoint -q "$MOUNT_DIR" && die "$MOUNT_DIR is already mounted"

  local manifest_size manifest_sha
  manifest_size="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["size_bytes"])' "$MANIFEST")"
  manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$MANIFEST")"
  [[ "$DUMP_BYTES" == "$manifest_size" ]] || die "dump size $DUMP_BYTES differs from the manifest $manifest_size"
  log "hashing $DUMP"
  [[ "$(sha256sum "$DUMP" | awk '{print $1}')" == "$manifest_sha" ]] || die "dump sha256 differs from the manifest"
  SHA_OK=yes
  log "dump sha256 matches the manifest"

  local threshold=""
  if [[ -n "$SERVING_UNIT" ]]; then
    SERVING_MEDIAN="$(serving_rates '-24 hours' | sort -n | awk '{ a[NR] = $1 } END { if (NR >= 20) print a[int(NR / 2) + 1]; else print 85 }')"
    threshold="$(awk -v m="$SERVING_MEDIAN" -v f="$WATCH_FRACTION" 'BEGIN { printf "%.1f", m * f }')"
    log "$SERVING_UNIT 24 h median ${SERVING_MEDIAN} tok/s (answers of 100+ tokens); the test stops if, over the last 20 minutes, at least 4 such answers have a median under $threshold tok/s"
  else
    log "serving watch off (SERVING_UNIT is not set)"
  fi

  WORK_TMP="$(mktemp -d /tmp/agent-memory-restore-test.XXXXXX)"
  truncate -s "${IMAGE_GIB}G" "$IMAGE_FILE"; IMAGE_CREATED=1
  mkfs.ext4 -F -q -m 0 -T largefile -J size=256 -E lazy_itable_init=1,lazy_journal_init=1 -L amrestoretest "$IMAGE_FILE"
  LOOP_DEV="$(sudo -n losetup --direct-io=on --find --show "$IMAGE_FILE")"
  sudo -n mkdir -p "$MOUNT_DIR"
  sudo -n mount -o noatime "$LOOP_DEV" "$MOUNT_DIR"; MOUNTED=1
  sudo -n install -d -o "$pg_uid" -g "$pg_uid" -m 700 "$MOUNT_DIR/pgdata"
  log "image $IMAGE_FILE (${IMAGE_GIB} GiB ext4 on $LOOP_DEV, direct I/O) mounted at $MOUNT_DIR"

  docker run -d --name "$NAME" --label agent-memory.restore-test=1 --network none --cpus "$CPUS" --cpu-shares 128 \
    --memory "$MEMORY" --memory-swap "$MEMORY" --shm-size 1g \
    -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=agent_memory \
    -v "$MOUNT_DIR/pgdata:/var/lib/postgresql/data" -v "$DUMP:/backup.dump:ro" "$image_id" \
    postgres -c listen_addresses= -c fsync=off -c synchronous_commit=off -c full_page_writes=off \
    -c wal_level=minimal -c max_wal_senders=0 -c max_wal_size=4GB -c shared_buffers=1GB \
    -c maintenance_work_mem=3GB -c max_parallel_maintenance_workers=0 -c autovacuum=off >/dev/null
  CONTAINER_STARTED=1
  # The image's entrypoint runs initdb and a temporary server, then restarts; wait for the final server.
  local ready=0
  for _ in $(seq 1 150); do
    if docker logs "$NAME" 2>&1 | grep -q 'PostgreSQL init process complete' &&
       [[ "$(echo 'select 1;' | test_sql 2>/dev/null)" == "1" ]]; then ready=1; break; fi
    sleep 2
  done
  [[ "$ready" == "1" ]] || die "the throwaway Postgres did not start"

  log "pg_restore -j 2 of $LATEST_ID into $NAME"
  local t0 watch_since restore_pid rc=0 slow window_start
  t0=$(date +%s); watch_since="$(date '+%Y-%m-%d %H:%M:%S')"
  docker exec "$NAME" pg_restore -U postgres -d agent_memory --no-owner --no-acl --exit-on-error -j 2 /backup.dump \
    > "$WORK_TMP/pg_restore.out" 2>&1 &
  restore_pid=$!
  while kill -0 "$restore_pid" 2>/dev/null; do
    sleep 60
    if (( $(date +%s) - t0 > RESTORE_TIMEOUT_SECONDS )); then
      kill "$restore_pid" 2>/dev/null; FAIL_REASON="pg_restore exceeded ${RESTORE_TIMEOUT_SECONDS}s"; die "$FAIL_REASON"
    fi
    # Window: the last 20 minutes, never earlier than the restore's start.
    window_start="$(date -d '-20 min' '+%Y-%m-%d %H:%M:%S')"
    [[ "$window_start" < "$watch_since" ]] && window_start="$watch_since"
    [[ -n "$SERVING_UNIT" ]] || continue
    slow="$(serving_rates "$window_start" | sort -n |
      awk -v t="$threshold" '{ a[NR] = $1 } END { if (NR >= 4 && a[int((NR + 1) / 2)] < t) print a[int((NR + 1) / 2)] " over " NR; else print "" }')"
    if [[ -n "$slow" ]]; then
      log "$SERVING_UNIT slowed: median $slow answers in 20 min, under $threshold tok/s; stopping the test"
      kill "$restore_pid" 2>/dev/null || true
      RESULT_WRITTEN=1; write_result aborted "$SERVING_UNIT slowed during the restore (median $slow answers of 100+ tokens, under $threshold tok/s)"
      exit 2
    fi
  done
  wait "$restore_pid" || rc=$?
  RESTORE_SECONDS=$(( $(date +%s) - t0 ))
  if [[ "$rc" -ne 0 ]]; then
    tail -n 20 "$WORK_TMP/pg_restore.out" | sed 's/^/  pg_restore: /'
    die "pg_restore exited $rc after ${RESTORE_SECONDS}s"
  fi
  log "pg_restore finished in ${RESTORE_SECONDS}s"

  RESTORED_DB_BYTES="$(echo 'select pg_database_size(current_database());' | test_sql)"
  # Exact count of every restored table, bounded by a key so rows written to live after the dump do not count:
  # a single-column integer primary key (any name) or an integer id, else an insert-time column (created_at,
  # occurred_at, inserted_at), at the restored maximum; else the whole table. (1.0.1 bounded only by a column named
  # id, so agent_coordination.events and messages were compared whole and failed on rows added after the dump.)
  echo "select n.nspname||'.'||c.relname,
               coalesce(
                 (select a.attname from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                   where i.indrelid = c.oid and i.indisprimary and i.indnatts = 1
                     and a.atttypid in ('int2'::regtype, 'int4'::regtype, 'int8'::regtype)),
                 (select a.attname from pg_attribute a where a.attrelid = c.oid and a.attname = 'id' and not a.attisdropped
                     and a.atttypid in ('int2'::regtype, 'int4'::regtype, 'int8'::regtype))),
               (select a.attname from pg_attribute a where a.attrelid = c.oid and not a.attisdropped
                   and a.attname in ('created_at', 'occurred_at', 'inserted_at')
                   and a.atttypid in ('timestamptz'::regtype, 'timestamp'::regtype)
                 order by array_position(array['created_at', 'occurred_at', 'inserted_at'], a.attname::text) limit 1)
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema','pg_toast') order by 1;" |
    test_sql > "$WORK_TMP/tables.txt"
  : > "$WORK_TMP/restored.txt"   # table|rows|key|kind|max
  while IFS='|' read -r table int_key ts_key; do
    [[ -n "$table" ]] || continue
    local q; q="$(printf '%s' "$table" | awk -F. '{ printf "\"%s\".\"%s\"", $1, $2 }')"
    if [[ -n "$int_key" ]]; then
      echo "select count(*), '$int_key', 'int', coalesce(max(\"$int_key\"), 0) from $q;" | test_sql | sed "s#^#$table|#" >> "$WORK_TMP/restored.txt"
    elif [[ -n "$ts_key" ]]; then
      echo "select count(*), '$ts_key', 'ts', coalesce(max(\"$ts_key\")::text, '') from $q;" | test_sql | sed "s#^#$table|#" >> "$WORK_TMP/restored.txt"
    else
      echo "select count(*), '', 'none', '' from $q;" | test_sql | sed "s#^#$table|#" >> "$WORK_TMP/restored.txt"
    fi
  done < "$WORK_TMP/tables.txt"
  # The same counts on the live DB in one read-only snapshot, with the same bounds. A table dropped from live since the
  # dump is skipped (reported with live_rows null).
  echo "select n.nspname||'.'||c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema','pg_toast');" |
    live_sql > "$WORK_TMP/live_tables.txt"
  {
    echo "begin transaction isolation level repeatable read read only;"
    while IFS='|' read -r table count key kind maxval; do
      grep -qxF "$table" "$WORK_TMP/live_tables.txt" || continue
      local q; q="$(printf '%s' "$table" | awk -F. '{ printf "\"%s\".\"%s\"", $1, $2 }')"
      if [[ "$kind" == "int" ]]; then
        echo "select '$table', count(*) from $q where \"$key\" <= $maxval;"
      elif [[ "$kind" == "ts" && -n "$maxval" ]]; then
        echo "select '$table', count(*) from $q where \"$key\" <= '$maxval';"
      elif [[ "$kind" == "ts" ]]; then
        echo "select '$table', count(*) from $q where \"$key\" is null;"
      else
        echo "select '$table', count(*) from $q;"
      fi
    done < "$WORK_TMP/restored.txt"
    echo "commit;"
  } | live_sql > "$WORK_TMP/live.txt"

  COUNTS_FILE="$WORK_TMP/counts.json"
  local verdict
  verdict="$(python3 - "$WORK_TMP/restored.txt" "$WORK_TMP/live.txt" "$MANIFEST" "$COUNTS_FILE" "$CORE_TABLES" <<'PY'
import json, sys
restored_path, live_path, manifest_path, out_path, core = sys.argv[1:6]
core = core.split()
m = json.load(open(manifest_path))
restored, live = {}, {}
for line in open(restored_path):
    t, c, key, kind, mx = (line.rstrip("\n").split("|") + ["", "", "", ""])[:5]
    restored[t] = {"rows": int(c), "key": key or None, "key_max": mx or None,
                   "basis": f"{key} <= restored max" if kind in ("int", "ts") and key else "whole table"}
for line in open(live_path):
    parts = line.rstrip("\n").split("|")
    if len(parts) == 2 and parts[1].isdigit():
        live[parts[0]] = int(parts[1])
tables, problems, notes = {}, [], []
for t, r in sorted(restored.items()):
    entry = dict(r, live_rows=live.get(t))
    entry["match"] = entry["live_rows"] == r["rows"]
    tables[t] = entry
    if not entry["match"]:
        (problems if t in core else notes).append(f"{t}: restored {r['rows']} live {entry['live_rows']} ({entry['basis']})")
for t in core:
    if t not in restored:
        problems.append(f"{t}: missing from the restore")
ev = restored.get("public.agent_memory_events", {}).get("rows", -1)
ar = restored.get("public.agent_memory_payload_archives", {}).get("rows", -1)
if ev < m["event_count"]: problems.append(f"events {ev} < manifest {m['event_count']}")
if ar < m["payload_archive_count"]: problems.append(f"payload archives {ar} < manifest {m['payload_archive_count']}")
out = {"tables": tables, "table_count": len(tables), "manifest_event_count": m["event_count"],
       "manifest_payload_archive_count": m["payload_archive_count"], "restored_event_count": ev,
       "restored_payload_archive_count": ar, "problems": problems, "notes": notes}
json.dump(out, open(out_path, "w"), indent=2)
print("pass" if not problems else "fail")
PY
)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("tables=%d events=%d (manifest %d) archives=%d (manifest %d)" % (d["table_count"], d["restored_event_count"], d["manifest_event_count"], d["restored_payload_archive_count"], d["manifest_payload_archive_count"])); [print("  problem:", p) for p in d["problems"]]; [print("  note:", n) for n in d["notes"]]' "$COUNTS_FILE"
  RESULT_WRITTEN=1
  if [[ "$verdict" == "pass" ]]; then
    write_result pass "full restore of $LATEST_ID; every core table matches the live DB exactly"
    return 0
  fi
  write_result fail "row counts differ on core tables"
  return 1
}

case "${1:-}" in
  plan)
    space_math
    (( AFTER_KB >= NIGHTLY_NEED_KB )) && log "plan: space ok" || log "plan: would refuse (the nightly's staging would not fit)"
    log "plan: would hash $DUMP, restore it into a throwaway container on a ${IMAGE_GIB} GiB ext4 image at $IMAGE_FILE, count every table, compare with live, delete the image"
    ;;
  run)
    mkdir -p "$STATE_DIR"
    rc=0
    flock -o -w "$LOCK_WAIT_SECONDS" -E 75 "$LOCK_FILE" "$(readlink -f "$0")" run-locked || rc=$?
    [[ "$rc" -eq 75 ]] && log "the nightly backup still held $LOCK_FILE after ${LOCK_WAIT_SECONDS}s; test skipped"
    exit "$rc"
    ;;
  run-locked) run_locked ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
