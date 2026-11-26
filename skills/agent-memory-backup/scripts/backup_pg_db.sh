#!/usr/bin/env bash
# backup_pg_db.sh 2.2.0 - verified pg_dump of one database in agent-memory-postgres.
#
# Sibling of backup_agent_memory_pg.sh for the smaller databases that share the container (CRON_DBS lists
# them). agent_memory keeps its own job and script; this one never touches it unless DB_NAME=agent_memory is
# passed explicitly.
#
# Raw PostgreSQL tools only (pg_dump / pg_restore / psql inside the container). The dump and the restore
# test run as the container's own POSTGRES_USER through docker exec, so no credential is passed at all.
# With RECORD_RUN=1 each backup is also recorded as a run row through an external run-log CLI
# (`$LAB_PY $LAB_CLI log-run` in $LAB_DIR), which reads its credentials from the env file $LAB_ENV_FILE
# (mode 600) in a subshell. No secret is in this script or on a command line.
#
# 2.1.1 (2026-11-24): the machine's own values (local and NAS roots, pool state file, cache wrapper, database
# list, run-log CLI) moved out of this file into pg-db-backup.env beside it (see pg-db-backup.env.example). The
# defaults below are generic.
#
# Each run:
#   1. opens a REPEATABLE READ transaction, exports its snapshot and counts every table inside it
#   2. pg_dump --format=custom --snapshot=<that snapshot> into $DEST_ROOT/$DB_NAME/incoming, writes a
#      sha256 sidecar (<id>.dump.sha256, `sha256sum -c` format) and runs pg_restore --list
#   3. restores into <db>_restore_test and requires the same table set and the same row count for every
#      table as step 1 (exact: the dump and the counts read one snapshot); drops the test database
#   4. publishes dump + sidecar + manifest + restore list, prunes to KEEP_DAILY daily + KEEP_WEEKLY weekly
#   5. copies the published files to $MIRROR_ROOT/$DB_NAME (the NAS share the agent-memory backups use) and
#      re-checks the sidecar there; a full or missing share never fails the backup, it is logged and recorded
#   6. with RECORD_RUN=1, records one run row (project lab, kind other, run_key backup:pg:<backup_id>)
#
# 2.1.0 (2026-11-24, after a NAS outage): the NAS copy (step 5) gets the agent-memory job's protection. It writes
# only inside TRANSFER_WINDOW_UTC (07:00-13:00), at BWLIMIT_KBPS (6000 KiB/s), after reading the pool state line a
# probe on the NAS side writes onto the share (BUSY/missing/stale = wait PACE_BUSY_WAIT_SECONDS, up to the window
# end), and only while it holds SHARE_COPY_LOCK, which backup_agent_memory_pg.sh 3.2.1+ holds for its whole copy,
# so the two jobs never copy to the share at the same time. A copy that cannot start before the window ends is
# skipped (the local copy is the restore point) and the next run copies it (catch-up of the newest
# MIRROR_CATCHUP_MAX local backups missing on the share). No staging (dump) while / or the local backup drive has
# under 20 GB free. The gate, window, free-space and env-file helpers are copies of the ones in
# backup_agent_memory_pg.sh: change both.
#
# 2.2.0 (2026-11-25): before it blocks on SHARE_COPY_LOCK, the NAS copy takes SHARE_WAIT_LOCK shared and keeps it
# until it has released SHARE_COPY_LOCK. backup_agent_memory_pg.sh 3.2.3+ holds SHARE_COPY_LOCK only while it writes:
# it releases it for every pool wait, and at each step it sees this shared lock and hands the share over. flock
# wakes this job when the lock comes free, and it copies once its own pool gate reads OK. On 11-25 one database's
# copy waited 09:51-13:00Z for the lock and was skipped.
#
# 2.3.0 (2026-11-26): MIRROR_COPY=0 turns the NAS copy (step 5) off. The local copy is then the restore point, the
# job neither writes to nor reads from the share, the log's `backup complete` line ends in nas=off, and `mirror`
# exits 1 without touching the share (MIRROR_COPY=1 on its command line copies once). Steps 1-4 and 6 are unchanged.
set -Eeuo pipefail

VERSION="2.3.0"

# load_env_file <file>: the rules of load_env_file in backup_agent_memory_pg.sh (KEY=VALUE lines; a variable already
# set in the environment wins over the file; nothing is expanded or executed).
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
# Its own file: DEST_ROOT and CRON_SCHEDULE mean other things here than in backup_agent_memory_pg.sh.
BACKUP_ENV_FILE="${PG_DB_BACKUP_ENV:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pg-db-backup.env}"
load_env_file "$BACKUP_ENV_FILE"

DB_NAME="${DB_NAME:-}"
CONTAINER_NAME="${CONTAINER_NAME:-agent-memory-postgres}"
DEST_ROOT="${DEST_ROOT:-$HOME/pg-db-backups}"
MIRROR_ROOT="${MIRROR_ROOT:-/mnt/nas/backups/pg-db-postgres}"
MIRROR_COPY="${MIRROR_COPY:-1}"                       # 2.3.0: 0 = no NAS copy; the local copy is the restore point
MIN_MIRROR_FREE_KB="${MIN_MIRROR_FREE_KB:-1048576}"   # free space the share must keep after the copy (1 GiB)
KEEP_DAILY="${KEEP_DAILY:-14}"                        # newest dump of each of the 14 most recent backup days
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"                       # newest dump of each of the 8 most recent ISO weeks
KEEP_RECENT_HOURS="${KEEP_RECENT_HOURS:-48}"          # every dump this young is kept (on-demand pre-migration points)
LOG_DIR="${LOG_DIR:-$HOME/agent-memory-backup/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/pg-db-backup.log}"
LOCK_DIR="${LOCK_DIR:-$HOME/agent-memory-backup}"
CRON_SCHEDULE="${CRON_SCHEDULE:-50 2 * * *}"
# Cache discipline (a host memory policy, 2026-11-04): install-cron puts CACHE_WRAP in front of the job when its
# first word is an executable, for example a wrapper that keeps the dump file and the rsync copy inside a MemoryHigh
# scope and reclaims the Postgres container's page cache from pg_dump afterwards. Empty (the default) installs the
# plain line.
CACHE_WRAP="${CACHE_WRAP-}"
CRON_DBS="${CRON_DBS:-}"                              # the databases run-all, status and install-cron cover
RECORD_RUN="${RECORD_RUN:-0}"                         # 1 records a run row per backup through the run-log CLI
LAB_DIR="${LAB_DIR:-}"                                # where the run-log CLI runs
LAB_PY="${LAB_PY:-python3}"                           # its interpreter
LAB_CLI="${LAB_CLI:-}"                                # the CLI script, given "log-run start|end ..."
LAB_ENV_FILE="${LAB_ENV_FILE:-}"                      # its credentials, sourced in a subshell (mode 600)
BACKUP_OWNER="${BACKUP_OWNER:-claude}"
# 2.1.0 NAS-copy protection (see the header)
BWLIMIT_KBPS="${BWLIMIT_KBPS:-6000}"
PACE_GATE="${PACE_GATE:-1}"
POOL_STATE_FILE="${POOL_STATE_FILE:-$(dirname "$(dirname "$MIRROR_ROOT")")/.nas-tuning/pool_state}"
POOL_STATE_MAX_AGE_SECONDS="${POOL_STATE_MAX_AGE_SECONDS:-300}"
PACE_BUSY_WAIT_SECONDS="${PACE_BUSY_WAIT_SECONDS:-900}"
TRANSFER_WINDOW_UTC="${TRANSFER_WINDOW_UTC:-07:00-13:00}"
TRANSFER_DEADLINE_EPOCH="${TRANSFER_DEADLINE_EPOCH:-}"
SHARE_COPY_LOCK="${SHARE_COPY_LOCK:-$HOME/agent-memory-backup/share-copy.lock}"
# 2.2.0: held shared while this job waits for and holds SHARE_COPY_LOCK (the same default as in the agent-memory job)
SHARE_WAIT_LOCK="${SHARE_WAIT_LOCK:-${SHARE_COPY_LOCK%.lock}-wait.lock}"
MIN_SYSTEM_FREE_KB="${MIN_SYSTEM_FREE_KB:-19531250}"
FREE_CHECK_PATHS="${FREE_CHECK_PATHS:-/ $DEST_ROOT}"
MIRROR_CATCHUP_MAX="${MIRROR_CATCHUP_MAX:-3}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# every user table in every non-system schema, "schema.table|count", one line each
COUNT_SQL="SELECT schemaname || '.' || tablename || '|' || (xpath('/row/n/text()',
         query_to_xml(format('SELECT count(*) AS n FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text
  FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;"

log() { printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${DB_NAME:-?}" "$*"; }
die() { log "ERROR: $*"; exit 1; }

psql_db() {
  # psql_db <database> <sql> -> tuples only, unaligned
  local db="$1" sql="$2"
  printf '%s\n' "$sql" | docker exec -i -e PGDB="$db" "$CONTAINER_NAME" sh -c \
    'psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d "$PGDB" -tA' | tr -d '\r'
}

drop_test_db() {
  docker exec -e T="$1" "$CONTAINER_NAME" sh -c 'dropdb -U "$POSTGRES_USER" --if-exists "$T"' 2>/dev/null
}

# ---- the snapshot session: one psql coprocess holds the transaction open until the dump has finished ----

SNAP_OPEN=0
snap_send() {
  # write lines to the snapshot psql; a dead psql gives an error here instead of a SIGPIPE that kills the script
  ( trap '' PIPE; printf '%s\n' "$@" >&"$SNAP_IN" ) 2>/dev/null
}

snap_open() {
  coproc SNAP { docker exec -i -e PGDB="$DB_NAME" "$CONTAINER_NAME" sh -c \
    'psql -v ON_ERROR_STOP=1 -X -q -U "$POSTGRES_USER" -d "$PGDB" -tA' 2>&1; }
  exec {SNAP_IN}>&"${SNAP[1]}" {SNAP_OUT}<&"${SNAP[0]}"
  SNAP_OPEN=1
  snap_send "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;" "SELECT 'SNAP|' || pg_export_snapshot();" \
    || die "snapshot psql did not start"
  local line=""
  read -r -t 60 line <&"$SNAP_OUT" || true
  line="${line%$'\r'}"
  [[ "$line" =~ ^SNAP\|([0-9A-Fa-f-]+)$ ]] || die "snapshot export failed: ${line:-no output from psql}"
  SNAPSHOT="${BASH_REMATCH[1]}"
}

snap_counts() {
  # snap_counts <file>: COUNT_SQL inside the open snapshot
  local out="$1" line
  snap_send "$COUNT_SQL" "SELECT '__END__';" || die "snapshot psql exited before the count"
  : > "$out"
  while :; do
    line=""
    read -r -t 1800 line <&"$SNAP_OUT" || die "snapshot count: psql exited or timed out"
    line="${line%$'\r'}"
    [[ "$line" == "__END__" ]] && break
    [[ "$line" =~ ^[^|]+\|[0-9]+$ ]] || die "snapshot count: unexpected psql output: $line"
    printf '%s\n' "$line" >> "$out"
  done
}

snap_close() {
  [[ "$SNAP_OPEN" == "1" ]] || return 0
  SNAP_OPEN=0
  snap_send "COMMIT;" '\q' || true
  exec {SNAP_IN}>&- {SNAP_OUT}<&-
  local pid="${SNAP_PID:-}"
  [[ -z "$pid" ]] || timeout 60 tail --pid="$pid" -f /dev/null 2>/dev/null || kill "$pid" 2>/dev/null || true
}

# ---- run row through the run-log CLI (RECORD_RUN=1; best effort: a database outage never fails the backup) ----

RUN_ID=""
lab_cli() {
  if [[ -z "$LAB_CLI" || -z "$LAB_DIR" ]]; then
    echo "RECORD_RUN=1 needs LAB_CLI and LAB_DIR"
    return 1
  fi
  ( set -a; [[ -z "$LAB_ENV_FILE" ]] || . "$LAB_ENV_FILE"; set +a; cd "$LAB_DIR" && exec timeout 90 "$LAB_PY" "$LAB_CLI" "$@" )
}

lab_start() {
  [[ "$RECORD_RUN" == "1" ]] || return 0
  local out
  if out="$(lab_cli log-run start --kind other --project lab --name "pg_dump $DB_NAME" --run-key "backup:pg:$1" \
              --owner "$BACKUP_OWNER" --log "$LOG_FILE" --run-dir "$2" --config "$3" \
              --notes "backup_pg_db.sh $VERSION: verified pg_dump of $DB_NAME" 2>&1)" \
     && [[ "$(printf '%s\n' "$out" | tail -n 1)" =~ ^[0-9]+$ ]]; then
    RUN_ID="$(printf '%s\n' "$out" | tail -n 1)"
    log "run row $RUN_ID (backup:pg:$1)"
  else
    log "WARNING: run row not written: $(printf '%s' "$out" | tail -n 1)"
  fi
}

lab_end() {
  # lab_end <status> <exit code> [receipt] [--metric name=value ...]
  [[ -n "$RUN_ID" ]] || return 0
  local status="$1" code="$2" receipt="${3:-}"
  shift 3 || shift $#
  local args=(log-run end "$RUN_ID" --status "$status" --exit-code "$code")
  [[ -z "$receipt" ]] || args+=(--receipt "$receipt")
  lab_cli "${args[@]}" "$@" >/dev/null 2>&1 || log "WARNING: run row $RUN_ID not finished ($status)"
  RUN_ID=""
}

# ---- retention: KEEP_DAILY daily + KEEP_WEEKLY weekly, by the UTC stamp in the backup id ----

prune_ids() {
  # prune_ids <dir>: print the backup ids in <dir> that fall outside the retention policy
  local dir="$1" id ts iso epoch day week now keep nd=0 nw=0
  local -A seen_day=() seen_week=()
  now="$(date -u +%s)"
  while IFS= read -r id; do
    ts="${id#"${DB_NAME}"_}"
    iso="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2} UTC"
    epoch="$(date -u -d "$iso" +%s)" || continue
    day="${ts:0:8}"
    week="$(date -u -d "$iso" +%G-W%V)"
    keep=0
    if (( now - epoch < KEEP_RECENT_HOURS * 3600 )); then keep=1; fi
    if [[ -z "${seen_day[$day]:-}" ]]; then
      seen_day[$day]=1; nd=$((nd + 1))
      if (( nd <= KEEP_DAILY )); then keep=1; fi
    fi
    if [[ -z "${seen_week[$week]:-}" ]]; then
      seen_week[$week]=1; nw=$((nw + 1))
      if (( nw <= KEEP_WEEKLY )); then keep=1; fi
    fi
    if (( keep == 0 )); then printf '%s\n' "$id"; fi
  done < <(find "$dir" -maxdepth 1 -type f -regextype posix-extended \
             -regex ".*/${DB_NAME}_[0-9]{8}T[0-9]{6}Z\\.dump" -printf '%f\n' | sed 's/\.dump$//' | sort -r)
}

prune_local() {
  local dest="$1" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    rm -f "$dest/dumps/$id.dump" "$dest/dumps/$id.dump.sha256" "$dest/manifests/$id.manifest.json" \
          "$dest/restore-lists/$id.restore.list"
    log "retention: removed $id from $dest"
  done < <(prune_ids "$dest/dumps")
}

prune_mirror() {
  local mdir="$1" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    timeout 120 rm -f "$mdir/$id.dump" "$mdir/$id.dump.sha256" "$mdir/$id.manifest.json" "$mdir/$id.restore.list" || true
    log "retention: removed $id from $mdir"
  done < <(prune_ids "$mdir" || true)
}

# ---- 2.1.0 NAS-copy guards (copies of backup_agent_memory_pg.sh 3.2.x: change both) ----

WINDOW_RE='^([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])$'
POOL_STATE_LINE=""

pool_state_ok() {
  POOL_STATE_LINE=""
  if [[ "$PACE_GATE" != "1" ]]; then POOL_STATE_LINE="gate off"; return 0; fi
  local line="" word="" stamp="" epoch age
  line="$(timeout 20 head -n 1 "$POOL_STATE_FILE" 2>/dev/null | tr -d '\r' || true)"
  POOL_STATE_LINE="${line:-missing or unreadable: $POOL_STATE_FILE}"
  read -r word stamp _ <<< "$line" || true
  [[ "$word" == "OK" ]] || return 1
  epoch="$(date -u -d "$stamp" +%s 2>/dev/null || echo 0)"
  age=$(( $(date +%s) - epoch ))
  if (( epoch == 0 || age > POOL_STATE_MAX_AGE_SECONDS )); then POOL_STATE_LINE="stale (${age}s old): $line"; return 1; fi
  return 0
}

transfer_window_end() {
  local now today start end
  now="$(date +%s)"
  if [[ -n "$TRANSFER_DEADLINE_EPOCH" ]]; then
    if [[ "$TRANSFER_DEADLINE_EPOCH" =~ ^[0-9]+$ ]] && (( now < TRANSFER_DEADLINE_EPOCH )); then echo "$TRANSFER_DEADLINE_EPOCH"; else echo 0; fi
    return 0
  fi
  if [[ ! "$TRANSFER_WINDOW_UTC" =~ $WINDOW_RE ]]; then echo 0; return 0; fi
  today="$(date -u +%F)"
  start="$(date -u -d "$today ${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" +%s)"
  end="$(date -u -d "$today ${BASH_REMATCH[3]}:${BASH_REMATCH[4]}" +%s)"
  if (( start < end && now >= start && now < end )); then echo "$end"; else echo 0; fi
}

low_free_space() {
  local p kb
  for p in $FREE_CHECK_PATHS; do
    kb="$(timeout 30 df -Pk "$p" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { v = $4 } END { print v }' || true)"
    if [[ ! "${kb:-}" =~ ^[0-9]+$ ]] || (( kb < MIN_SYSTEM_FREE_KB )); then
      echo "$p has $(( ${kb:-0} * 1024 / 1000000000 )) GB free (floor $(( MIN_SYSTEM_FREE_KB * 1024 / 1000000000 )) GB)"
      return 0
    fi
  done
  return 1
}

validate_guard_config() {
  [[ "$BWLIMIT_KBPS" =~ ^[1-9][0-9]*$ ]] || die "BWLIMIT_KBPS must be a positive integer"
  [[ "$PACE_GATE" == "0" || "$PACE_GATE" == "1" ]] || die "PACE_GATE must be 0 or 1"
  [[ "$PACE_BUSY_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "PACE_BUSY_WAIT_SECONDS must be a positive integer"
  [[ "$POOL_STATE_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] || die "POOL_STATE_MAX_AGE_SECONDS must be a non-negative integer"
  [[ "$MIN_SYSTEM_FREE_KB" =~ ^[0-9]+$ ]] || die "MIN_SYSTEM_FREE_KB must be a non-negative integer"
  [[ "$MIRROR_CATCHUP_MAX" =~ ^[1-9][0-9]*$ ]] || die "MIRROR_CATCHUP_MAX must be a positive integer"
  [[ "$MIRROR_COPY" == "0" || "$MIRROR_COPY" == "1" ]] || die "MIRROR_COPY must be 0 or 1"
  if [[ -n "$TRANSFER_DEADLINE_EPOCH" ]]; then
    [[ "$TRANSFER_DEADLINE_EPOCH" =~ ^[0-9]+$ ]] || die "TRANSFER_DEADLINE_EPOCH must be an epoch second"
  else
    [[ "$TRANSFER_WINDOW_UTC" =~ $WINDOW_RE ]] || die "TRANSFER_WINDOW_UTC must be HH:MM-HH:MM (UTC): $TRANSFER_WINDOW_UTC"
    [[ "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" < "${BASH_REMATCH[3]}${BASH_REMATCH[4]}" ]] ||
      die "TRANSFER_WINDOW_UTC must not cross midnight (start before end): $TRANSFER_WINDOW_UTC"
  fi
}

# ---- NAS copy ----

MIRROR_STATE="not-run"
SHARE_FD=""
WAIT_FD=""
# Release the share-copy lock, then (2.2.0) the wait lock, in that order: the agent-memory copy takes the share back
# once the wait lock is free, so the share-copy lock must be free by then.
share_lock_release() {
  if [[ -n "$SHARE_FD" ]]; then
    exec {SHARE_FD}>&-
    SHARE_FD=""
    log "share-copy lock released"
  fi
  if [[ -n "$WAIT_FD" ]]; then
    exec {WAIT_FD}>&-
    WAIT_FD=""
  fi
}

# The newest MIRROR_CATCHUP_MAX local backups (oldest first) whose dump is missing on the share or has another size.
mirror_missing_ids() {
  local dest="$1" mdir="$2" id lsize msize
  find "$dest/dumps" -maxdepth 1 -type f -regextype posix-extended -regex ".*/${DB_NAME}_[0-9]{8}T[0-9]{6}Z\\.dump" \
       -printf '%f\n' | sed 's/\.dump$//' | sort -r | head -n "$MIRROR_CATCHUP_MAX" | sort |
  while IFS= read -r id; do
    lsize="$(stat -c %s "$dest/dumps/$id.dump")"
    msize="$(timeout 30 stat -c %s "$mdir/$id.dump" 2>/dev/null || echo missing)"
    if [[ "$msize" != "$lsize" || ! -s "$mdir/$id.dump.sha256" ]]; then printf '%s\n' "$id"; fi
  done
}

# mirror_copy <id> <dest> <size>: copy <id> (and any of the newest MIRROR_CATCHUP_MAX local backups the share is
# missing) to the share. Never fails the backup; MIRROR_STATE says what happened to <id>.
mirror_copy() {
  local id="$1" dest="$2" size="$3" mdir="$MIRROR_ROOT/$DB_NAME" free_kb need_kb end now wait_s low cid ids
  local copied=0 failed=0
  # 2.3.0: with the NAS copy off nothing touches the share, not even a read.
  if [[ "$MIRROR_COPY" == "0" ]]; then
    MIRROR_STATE="off"
    log "NAS copy off (MIRROR_COPY=0); the local copy is the restore point"
    return 0
  fi
  end="$(transfer_window_end)"
  if (( end == 0 )); then
    MIRROR_STATE="skipped-window"
    log "NAS copy not started: outside the copy window ${TRANSFER_DEADLINE_EPOCH:+(deadline passed)}${TRANSFER_DEADLINE_EPOCH:-$TRANSFER_WINDOW_UTC UTC}; the next run inside the window copies it"
    return 0
  fi
  if low="$(low_free_space)"; then
    MIRROR_STATE="skipped-low-space"; log "WARNING: NAS copy skipped: $low"; return 0
  fi
  need_kb=$(( size / 1024 + MIN_MIRROR_FREE_KB ))
  free_kb="$(timeout 30 df -Pk "$(dirname "$MIRROR_ROOT")" 2>/dev/null | awk 'NR > 1 {print $4}' || true)"
  if ! [[ "${free_kb:-}" =~ ^[0-9]+$ ]]; then
    MIRROR_STATE="skipped-unavailable"; log "WARNING: NAS copy skipped: $(dirname "$MIRROR_ROOT") not readable"; return 0
  fi
  if (( free_kb <= need_kb )); then
    MIRROR_STATE="skipped-full"; log "WARNING: NAS copy skipped: free_kb=$free_kb <= needed $need_kb"; return 0
  fi
  if ! timeout 60 mkdir -p "$mdir"; then
    MIRROR_STATE="failed-mkdir"; log "WARNING: NAS copy failed: cannot create $mdir"; return 0
  fi
  # What to copy: recent local backups missing on the share, plus <id> unless its share copy already verifies.
  ids="$(mirror_missing_ids "$dest" "$mdir" || true)"
  if ! grep -qx "$id" <<< "$ids" && ! (cd "$mdir" && timeout 600 sha256sum --quiet -c "$id.dump.sha256" > /dev/null 2>&1); then
    ids="$(printf '%s\n%s\n' "$ids" "$id" | sed '/^$/d')"
  fi
  if [[ -z "$ids" ]]; then
    MIRROR_STATE="verified"; log "NAS copy result: $id verified (copied 0, failed 0): already on the share"
    return 0
  fi
  # Never at the same time as the agent-memory copy, which holds the share-copy lock while it writes. 2.2.0: the
  # shared wait lock, taken first, tells it that this copy is waiting; it releases the share-copy lock at its next
  # pool wait or step boundary and waits until both locks are free again.
  exec {WAIT_FD}>>"$SHARE_WAIT_LOCK"
  now="$(date +%s)"
  if (( end <= now )) || ! flock -s -w $(( end - now )) "$WAIT_FD"; then
    exec {WAIT_FD}>&-; WAIT_FD=""
    MIRROR_STATE="skipped-share-busy"
    log "WARNING: NAS copy skipped: the share-copy wait lock stayed held until the window end; the next run copies it"
    return 0
  fi
  exec {SHARE_FD}>>"$SHARE_COPY_LOCK"
  if ! flock -n "$SHARE_FD"; then
    now="$(date +%s)"
    log "waiting for the share-copy lock (the agent-memory copy holds it and hands it over at its next pool wait or step), up to $(date -u -d "@$end" '+%H:%MZ')"
    if (( end <= now )) || ! flock -w $(( end - now )) "$SHARE_FD"; then
      exec {SHARE_FD}>&-; SHARE_FD=""
      share_lock_release
      MIRROR_STATE="skipped-share-busy"
      log "WARNING: NAS copy skipped: the share-copy lock stayed held until the window end; the next run copies it"
      return 0
    fi
  fi
  log "share-copy lock taken; to copy: $(echo $ids)"
  for cid in $ids; do
    while :; do
      end="$(transfer_window_end)"
      if (( end == 0 )); then break; fi
      if low="$(low_free_space)"; then log "WARNING: NAS copy stopped: $low"; end=0; break; fi
      if pool_state_ok; then break; fi
      now="$(date +%s)"; wait_s=$(( end - now ))
      (( wait_s > PACE_BUSY_WAIT_SECONDS )) && wait_s="$PACE_BUSY_WAIT_SECONDS"
      log "pool not OK, no NAS write: $POOL_STATE_LINE; reading it again in ${wait_s}s"
      sleep "$wait_s"
    done
    if (( end == 0 )); then
      [[ "$cid" == "$id" ]] && MIRROR_STATE="skipped-window"
      log "NAS copy of $cid not started before the window end (last pool state: ${POOL_STATE_LINE:-not read}); the next run copies it"
      continue
    fi
    log "NAS copy of $cid at --bwlimit=$BWLIMIT_KBPS KiB/s (pool ${POOL_STATE_LINE%% *})"
    if ! timeout 1800 rsync -rt --partial --bwlimit="$BWLIMIT_KBPS" "$dest/dumps/$cid.dump" "$dest/dumps/$cid.dump.sha256" \
           "$dest/manifests/$cid.manifest.json" "$dest/restore-lists/$cid.restore.list" "$mdir/"; then
      [[ "$cid" == "$id" ]] && MIRROR_STATE="failed-copy"
      log "WARNING: NAS copy of $cid to $mdir failed; the local copy is the restore point"; failed=$((failed + 1)); continue
    fi
    if (cd "$mdir" && timeout 600 sha256sum --quiet -c "$cid.dump.sha256"); then
      [[ "$cid" == "$id" ]] && MIRROR_STATE="verified"
      log "NAS copy verified: $mdir/$cid.dump (sha256 sidecar matches)"; copied=$((copied + 1))
    else
      [[ "$cid" == "$id" ]] && MIRROR_STATE="failed-checksum"
      log "WARNING: NAS copy sha256 mismatch at $mdir/$cid.dump"; failed=$((failed + 1))
    fi
  done
  share_lock_release
  # $id may have been on the share already (a mirror-only rerun): check it.
  if [[ "$MIRROR_STATE" == "not-run" ]]; then
    if (cd "$mdir" && timeout 600 sha256sum --quiet -c "$id.dump.sha256" 2>/dev/null); then MIRROR_STATE="verified"; else MIRROR_STATE="failed-checksum"; fi
  fi
  (( copied > 0 && failed == 0 )) && prune_mirror "$mdir"
  log "NAS copy result: $id $MIRROR_STATE (copied $copied, failed $failed)"
}

# mirror: copy the latest local backup (and missing recent ones) to the share with the same guards, no dump.
mirror_only() {
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_NAME must be a plain identifier (got '$DB_NAME')"
  validate_guard_config
  local dest="$DEST_ROOT/$DB_NAME" id
  id="$(tr -d '\r\n' < "$dest/latest_backup_id.txt" 2>/dev/null || true)"
  [[ -n "$id" && -s "$dest/dumps/$id.dump" ]] || die "no local backup to copy in $dest"
  mirror_copy "$id" "$dest" "$(stat -c %s "$dest/dumps/$id.dump")"
  [[ "$MIRROR_STATE" == "verified" ]]
}

# ---- one backup ----

TEST_DB=""
INC=""
on_exit() {
  local rc=$?
  snap_close
  [[ -z "$TEST_DB" ]] || drop_test_db "$TEST_DB" || true
  if [[ "$rc" -ne 0 ]]; then
    [[ -z "$INC" || ! -d "$INC" ]] || rm -rf "$INC"
    lab_end fail "$rc" ""
  fi
}

run_locked() {
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_NAME must be a plain identifier (got '$DB_NAME')"
  [[ "$DB_NAME" != *_restore_test ]] || die "refusing to back up a restore-test database"
  docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true || die "container not running: $CONTAINER_NAME"
  [[ "$(psql_db postgres "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" == "1" ]] || die "database not found: $DB_NAME"
  validate_guard_config
  local low_space=""
  if low_space="$(low_free_space)"; then die "refusing to stage: $low_space; the previous backups are kept"; fi
  trap on_exit EXIT

  local dest="$DEST_ROOT/$DB_NAME" ts backup_id nas_copy="$MIRROR_ROOT/$DB_NAME"
  [[ "$MIRROR_COPY" == "1" ]] || nas_copy="off"
  mkdir -p "$dest/dumps" "$dest/manifests" "$dest/restore-lists" "$dest/incoming" "$LOG_DIR"
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup_id="${DB_NAME}_${ts}"
  INC="$dest/incoming/$backup_id"
  mkdir -p "$INC"

  log "exporting snapshot and counting every table in it"
  snap_open
  snap_counts "$INC/source_counts.txt"
  [[ -s "$INC/source_counts.txt" ]] || die "no tables counted in $DB_NAME"

  # the run row is inserted after the snapshot, so it is not part of this dump or its counts
  lab_start "$backup_id" "$dest" "$(printf '{"database": "%s", "backup_id": "%s", "tool": "backup_pg_db.sh %s", "container": "%s", "snapshot": "%s", "dest": "%s", "nas": "%s", "retention": {"daily": %s, "weekly": %s, "recent_hours": %s}}' \
    "$DB_NAME" "$backup_id" "$VERSION" "$CONTAINER_NAME" "$SNAPSHOT" "$dest" "$nas_copy" "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_RECENT_HOURS")"

  log "pg_dump --format=custom --snapshot=$SNAPSHOT -> $INC/$backup_id.dump"
  docker exec -e PGDB="$DB_NAME" -e SNAP="$SNAPSHOT" "$CONTAINER_NAME" sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$PGDB" --snapshot="$SNAP" --format=custom --compress=6 --no-owner --no-acl' \
    > "$INC/$backup_id.dump"
  snap_close
  [[ -s "$INC/$backup_id.dump" ]] || die "pg_dump produced an empty file"
  local size sha
  size="$(stat -c %s "$INC/$backup_id.dump")"
  (cd "$INC" && sha256sum "$backup_id.dump" > "$backup_id.dump.sha256")
  sha="$(awk '{print $1}' "$INC/$backup_id.dump.sha256")"
  docker exec -i "$CONTAINER_NAME" pg_restore --list < "$INC/$backup_id.dump" > "$INC/$backup_id.restore.list"
  [[ -s "$INC/$backup_id.restore.list" ]] || die "pg_restore --list produced no output"

  TEST_DB="${DB_NAME}_restore_test"
  log "restore test into $TEST_DB"
  drop_test_db "$TEST_DB"
  docker exec -e T="$TEST_DB" "$CONTAINER_NAME" sh -c 'createdb -U "$POSTGRES_USER" "$T"'
  local rc=0
  docker exec -i -e T="$TEST_DB" "$CONTAINER_NAME" sh -c \
    'pg_restore -U "$POSTGRES_USER" -d "$T" --no-owner --no-acl --exit-on-error' < "$INC/$backup_id.dump" || rc=$?
  [[ "$rc" -eq 0 ]] || die "pg_restore into $TEST_DB failed (exit $rc)"
  psql_db "$TEST_DB" "$COUNT_SQL" | sed '/^[[:space:]]*$/d' > "$INC/restore_counts.txt"
  drop_test_db "$TEST_DB"
  TEST_DB=""

  # same snapshot on both sides: every table must exist on both sides with the same count
  local t n_src n_rst bad=0
  printf '%-44s %12s %12s  %s\n' "table" "source" "restored" "check"
  while IFS='|' read -r t n_src; do
    n_rst="$(awk -F'|' -v t="$t" '$1 == t {print $2}' "$INC/restore_counts.txt")"
    if [[ "$n_rst" == "$n_src" ]]; then
      printf '%-44s %12s %12s  %s\n' "$t" "$n_src" "$n_rst" "ok"
    else
      printf '%-44s %12s %12s  %s\n' "$t" "$n_src" "${n_rst:-missing}" "MISMATCH"; bad=$((bad + 1))
    fi
  done < "$INC/source_counts.txt"
  while IFS='|' read -r t n_rst; do
    if ! awk -F'|' -v t="$t" '$1 == t {f = 1} END {exit !f}' "$INC/source_counts.txt"; then
      printf '%-44s %12s %12s  %s\n' "$t" "absent" "$n_rst" "EXTRA"; bad=$((bad + 1))
    fi
  done < "$INC/restore_counts.txt"
  local n_tables n_src_rows n_rst_rows
  n_tables="$(wc -l < "$INC/source_counts.txt" | tr -d ' ')"
  n_src_rows="$(awk -F'|' '{s += $2} END {print s + 0}' "$INC/source_counts.txt")"
  n_rst_rows="$(awk -F'|' '{s += $2} END {print s + 0}' "$INC/restore_counts.txt")"
  (( bad == 0 )) || die "restore test: $bad table(s) differ between the source snapshot and the restored database"
  log "restore test ok: $n_tables tables, $n_src_rows rows source = $n_rst_rows rows restored (exact, one snapshot)"

  {
    printf '{\n  "schema": "pg-db-backup.v2",\n  "tool": "backup_pg_db.sh %s",\n' "$VERSION"
    printf '  "backup_id": "%s",\n  "database": "%s",\n  "container": "%s",\n  "source_host": "%s",\n' \
      "$backup_id" "$DB_NAME" "$CONTAINER_NAME" "$(hostname)"
    printf '  "snapshot": "%s",\n  "completed_at_utc": "%s",\n' "$SNAPSHOT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "format": "pg_dump custom, compress 6, --no-owner --no-acl, --snapshot",\n'
    printf '  "size_bytes": %s,\n  "sha256": "%s",\n' "$size" "$sha"
    printf '  "restore_test": {"database": "%s", "tables": %s, "source_rows": %s, "restored_rows": %s, "verdict": "exact", "dropped": true},\n' \
      "${DB_NAME}_restore_test" "$n_tables" "$n_src_rows" "$n_rst_rows"
    printf '  "table_counts": {'
    awk -F'|' 'NR == FNR {r[$1] = $2; next}
               {gsub(/["\\]/, "_", $1); printf "%s\"%s\": {\"source\": %s, \"restored\": %s}", (n++ ? ", " : ""), $1, $2, r[$1]}' \
      "$INC/restore_counts.txt" "$INC/source_counts.txt"
    printf '},\n  "retention": {"daily": %s, "weekly": %s, "recent_hours": %s},\n' "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_RECENT_HOURS"
    if [[ "$MIRROR_COPY" == "1" ]]; then
      printf '  "copies": ["%s", "%s"]\n}\n' "$dest/dumps/$backup_id.dump" "$MIRROR_ROOT/$DB_NAME/$backup_id.dump"
    else
      printf '  "copies": ["%s"]\n}\n' "$dest/dumps/$backup_id.dump"
    fi
  } > "$INC/$backup_id.manifest.json"

  mv "$INC/$backup_id.dump" "$INC/$backup_id.dump.sha256" "$dest/dumps/"
  mv "$INC/$backup_id.manifest.json" "$dest/manifests/"
  mv "$INC/$backup_id.restore.list" "$dest/restore-lists/"
  rm -f "$INC/source_counts.txt" "$INC/restore_counts.txt"
  rmdir "$INC"
  INC=""
  (cd "$dest/dumps" && sha256sum --quiet -c "$backup_id.dump.sha256") || die "published dump checksum mismatch"
  printf '%s\n' "$backup_id" > "$dest/latest_backup_id.txt.tmp" && mv "$dest/latest_backup_id.txt.tmp" "$dest/latest_backup_id.txt"
  prune_local "$dest"

  mirror_copy "$backup_id" "$dest" "$size"

  local nas_ok=0 nas_metric=()
  [[ "$MIRROR_STATE" != "verified" ]] || nas_ok=1
  # 2.3.0: with the NAS copy off there is no copy to report as verified or not.
  [[ "$MIRROR_STATE" == "off" ]] || nas_metric=(--metric "nas_copy_verified=$nas_ok")
  lab_end pass 0 "$dest/manifests/$backup_id.manifest.json" \
    --metric "size_bytes=$size" --metric "tables=$n_tables" --metric "source_rows=$n_src_rows" \
    --metric "restored_rows=$n_rst_rows" --metric "tables_mismatched=0" "${nas_metric[@]}"
  log "backup complete: $dest/dumps/$backup_id.dump size=$size sha256=$sha nas=$MIRROR_STATE"
}

run() {
  mkdir -p "$LOCK_DIR"
  local status=0
  flock -n -o -E 75 "$LOCK_DIR/backup-pg-${DB_NAME:-none}.lock" env BACKUP_PG_DB_LOCKED=1 DB_NAME="$DB_NAME" "$SCRIPT_PATH" run-locked || status=$?
  [[ "$status" -ne 75 ]] || die "another backup of $DB_NAME is running"
  return "$status"
}

run_all() {
  local db rc=0
  [[ -n "${CRON_DBS//[[:space:]]/}" ]] || die "CRON_DBS is empty: list the databases in $BACKUP_ENV_FILE"
  for db in $CRON_DBS; do
    DB_NAME="$db" "$SCRIPT_PATH" run || rc=1
  done
  return "$rc"
}

install_cron() {
  local tmp
  local wrap=""
  [[ -n "${CRON_DBS//[[:space:]]/}" ]] || die "CRON_DBS is empty: list the databases in $BACKUP_ENV_FILE"
  [[ -n "$CACHE_WRAP" && -x "${CACHE_WRAP%% *}" ]] && wrap="$CACHE_WRAP "
  tmp="$(mktemp)"
  mkdir -p "$LOCK_DIR" "$LOG_DIR"
  crontab -l 2>/dev/null > "$LOCK_DIR/crontab.before-pg-db-backup-$(date -u '+%Y%m%dT%H%M%SZ').txt" || true
  {
    crontab -l 2>/dev/null | sed '/# BEGIN pg-db-backup/,/# END pg-db-backup/d' || true
    echo "# BEGIN pg-db-backup (backup_pg_db.sh $VERSION: $CRON_DBS -> $DEST_ROOT$([[ "$MIRROR_COPY" == "1" ]] && echo " + NAS $MIRROR_ROOT" || echo " (NAS copy off)"), ${KEEP_DAILY}d+${KEEP_WEEKLY}w)"
    printf '%s CRON_DBS="%s" %s%s run-all >> %s 2>&1\n' "$CRON_SCHEDULE" "$CRON_DBS" "$wrap" "$SCRIPT_PATH" "$LOG_FILE"
    echo '# END pg-db-backup'
  } > "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  log "installed cron: $CRON_SCHEDULE run-all ($CRON_DBS)"
}

status() {
  local db
  for db in $CRON_DBS; do
    echo "== $db"
    if [[ -f "$DEST_ROOT/$db/latest_backup_id.txt" ]]; then cat "$DEST_ROOT/$db/latest_backup_id.txt"; else echo "no backup yet"; fi
    ls -la "$DEST_ROOT/$db/dumps" 2>/dev/null | tail -n 6 || true
    if [[ "$MIRROR_COPY" == "1" ]]; then
      echo "-- NAS $MIRROR_ROOT/$db"
      timeout 30 ls -la "$MIRROR_ROOT/$db" 2>/dev/null | tail -n 6 || echo "unavailable"
    fi
  done
  crontab -l 2>/dev/null | sed -n '/# BEGIN pg-db-backup/,/# END pg-db-backup/p' || true
  if [[ "$MIRROR_COPY" == "1" ]]; then
    pool_state_ok || true
    echo "NAS copy: --bwlimit=$BWLIMIT_KBPS KiB/s, window ${TRANSFER_DEADLINE_EPOCH:-$TRANSFER_WINDOW_UTC UTC}, pool state: $POOL_STATE_LINE, share-copy lock: $SHARE_COPY_LOCK (wait lock $SHARE_WAIT_LOCK)"
  else
    echo "NAS copy: off (MIRROR_COPY=0); the local copies in $DEST_ROOT are the restore points"
  fi
}

restore_help() {
  cat <<EOF
# Restore into a scratch database first (never over the live one without the owner's go-ahead):
D=$DEST_ROOT/<db>/dumps/<backup_id>.dump
(cd "\$(dirname "\$D")" && sha256sum -c "\$(basename "\$D").sha256")
docker exec $CONTAINER_NAME sh -c 'createdb -U "\$POSTGRES_USER" <db>_scratch'
docker exec -i $CONTAINER_NAME sh -c 'pg_restore -U "\$POSTGRES_USER" -d <db>_scratch --no-owner --no-acl --exit-on-error' < "\$D"
# The dump carries no owner or grants: for a live replacement add --role=<db owner> and re-run the grant migration.
EOF
}

mirror() {
  mkdir -p "$LOCK_DIR"
  local status=0
  flock -n -o -E 75 "$LOCK_DIR/backup-pg-${DB_NAME:-none}.lock" env BACKUP_PG_DB_LOCKED=1 DB_NAME="$DB_NAME" "$SCRIPT_PATH" mirror-locked || status=$?
  [[ "$status" -ne 75 ]] || die "another backup of $DB_NAME is running"
  return "$status"
}

case "${1:-}" in
  run) run ;;
  run-locked) [[ "${BACKUP_PG_DB_LOCKED:-}" == "1" ]] || die "run-locked is internal"; run_locked ;;
  mirror) mirror ;;
  mirror-locked) [[ "${BACKUP_PG_DB_LOCKED:-}" == "1" ]] || die "mirror-locked is internal"; mirror_only ;;
  run-all) run_all ;;
  install-cron) install_cron ;;
  status) status ;;
  restore-help) restore_help ;;
  *) echo "usage: DB_NAME=<db> $0 run | DB_NAME=<db> $0 mirror | $0 run-all | install-cron | status | restore-help" >&2; exit 2 ;;
esac
