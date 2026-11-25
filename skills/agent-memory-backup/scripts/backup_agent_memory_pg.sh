#!/usr/bin/env bash
# Agent-memory PostgreSQL backup with a one-verified-backup retention policy.
#
# The rule (2026-10-28): keep the live agent-memory database and one backup that
# is proven safe; older backups and partial or failed transfers are deleted.
#
# A run writes the new dump under incoming/<backup-id>/ (the temporary name),
# verifies the destination copy (size + SHA-256 against its manifest, and a
# complete pg_restore --list identical to the one taken at dump time), publishes
# it with same-filesystem renames plus an atomic latest_backup_id.txt swap, and
# only then deletes every other published backup. A failed or partial transfer
# is deleted once the run has confirmed the failure. If anything before
# publication fails, the previous backup is left untouched and an alert is raised.
#
# 3.2.0 (2026-11-24, after a NAS outage): the copy onto the NAS share (drive-managed SMR disks in the setup this
# was written for) is paced and gated. It runs in steps of PACE_STEP_SECONDS at BWLIMIT_KBPS (6000 KiB/s by
# default, about 3.7 GB per 10-minute step). Before each step the job reads the pool state line that a probe on the
# NAS side writes onto the share; while it says BUSY (or is missing or stale) nothing is written and the job waits
# PACE_BUSY_WAIT_SECONDS. No step writes outside TRANSFER_WINDOW_UTC (07:00-13:00 UTC). A copy that is not
# finished by the end of the window stops (exit 4) and keeps its partial and the verified stage; the next run
# resumes that same copy (after trimming RESUME_TRIM_BYTES off the end) before any new dump is taken. The dump,
# verify, publish and delete-after-publish steps are unchanged.
#
# 3.2.1 (2026-11-24): the copy holds SHARE_COPY_LOCK, which backup_pg_db.sh 2.1.0+ also takes for its NAS copy,
# so the two jobs never copy to the share at the same time.
#
# 3.2.2 (2026-11-24): the machine's own values (mount point, staging drive, pool state file, cache wrapper) moved
# out of this file into agent-memory-backup.env beside it (see agent-memory-backup.env.example). The defaults below
# are generic.
#
# 3.2.3 (2026-11-25): the copy holds SHARE_COPY_LOCK only while it writes. It releases the lock for every pool wait,
# and before each step it hands the share to a backup_pg_db.sh 2.2.0+ copy that is waiting for it (that job holds
# SHARE_WAIT_LOCK shared while it waits and copies), then takes it back once that copy has finished. Both sides block
# in flock, so the kernel wakes each one when the other releases. On 11-25 a backup_pg_db.sh copy waited from 09:51
# to 13:00Z for the lock while this job held it through nine 15-minute BUSY waits, and it never ran. The manifest and
# restore list are now copied under the lock as well; 3.2.2 wrote them after releasing it.
set -Eeuo pipefail

SCRIPT_VERSION="3.2.3"

# load_env_file <file>: set each KEY=VALUE of <file> that is not already set, so a variable from the environment (a
# cron line, a test, an operator's override) wins over the file. Blank lines and # comments are skipped, an
# optional "export " and one pair of surrounding quotes are removed, and nothing is expanded or executed.
# backup_runner.py, restore_test_agent_memory.sh and backup_pg_db.sh read their env files by the same rules.
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

CONTAINER_NAME="${CONTAINER_NAME:-agent-memory-postgres}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/nas}"
DEST_ROOT="${DEST_ROOT:-$MOUNTPOINT/backups/agent-memory-postgres}"
# 3.1.0 (2026-11-21): the dump is staged on a local drive with room for it, not on the root disk that holds the live
# Postgres. From 11-05 to 11-11 the root disk had too little room, and the cron line then overrode staging AND the
# destination to the local drive, so the one verified backup sat on the same machine as the live DB and status/list
# read the old path. Keep the nightly configuration in the env file, never on the cron line, so cron, status, list,
# verify, dry-run and install-cron agree.
LOCAL_STAGING="${LOCAL_STAGING:-$HOME/agent-memory-backup/staging}"
STATE_DIR="${STATE_DIR:-$HOME/agent-memory-backup/state}"
LOG_DIR="${LOG_DIR:-$HOME/agent-memory-backup/logs}"
LOCK_FILE="${LOCK_FILE:-$HOME/agent-memory-backup/backup-v2.lock}"
# The NAS write rule (2026-11-04): one stream, SHA-256 verified after close. 3.2.0: 6000 KiB/s (was 20000), below
# what the SMR drive sustained on 11-23 (5.9 MB/s average) and 11-05 (about 8 MB/s for 5 h).
BWLIMIT_KBPS="${BWLIMIT_KBPS:-6000}"
# 3.2.0 paced, gated, resumable transfer (see the header).
PACE_STEP_SECONDS="${PACE_STEP_SECONDS:-600}"
PACE_BUSY_WAIT_SECONDS="${PACE_BUSY_WAIT_SECONDS:-900}"
PACE_GATE="${PACE_GATE:-1}"
POOL_STATE_FILE="${POOL_STATE_FILE:-$MOUNTPOINT/.nas-tuning/pool_state}"
POOL_STATE_MAX_AGE_SECONDS="${POOL_STATE_MAX_AGE_SECONDS:-300}"
TRANSFER_WINDOW_UTC="${TRANSFER_WINDOW_UTC:-07:00-13:00}"
TRANSFER_DEADLINE_EPOCH="${TRANSFER_DEADLINE_EPOCH:-}"
RESUME_TRIM_BYTES="${RESUME_TRIM_BYTES:-67108864}"
STEP_KILL_GRACE_SECONDS="${STEP_KILL_GRACE_SECONDS:-60}"
# 3.2.0 (11-24, after the host's root disk filled up): no staging and no copy step while / (the live Postgres) or
# the staging drive has under 20 GB free. Checked at preflight and before every step.
MIN_SYSTEM_FREE_KB="${MIN_SYSTEM_FREE_KB:-19531250}"
FREE_CHECK_PATHS="${FREE_CHECK_PATHS:-/ $LOCAL_STAGING}"
# 3.2.1 (11-24): the two jobs that write to the share (this one and backup_pg_db.sh) never copy at the same time;
# both hold this lock while they copy.
SHARE_COPY_LOCK="${SHARE_COPY_LOCK:-$(dirname "$LOCK_FILE")/share-copy.lock}"
# 3.2.3: backup_pg_db.sh holds this one shared from before it asks for SHARE_COPY_LOCK until after it has released
# it; an exclusive try that fails tells this job that a copy is waiting.
SHARE_WAIT_LOCK="${SHARE_WAIT_LOCK:-${SHARE_COPY_LOCK%.lock}-wait.lock}"
SHARE_FD=""
CRON_SCHEDULE="${CRON_SCHEDULE:-20 2 * * *}"
# Cache discipline (a host memory policy, 2026-11-04): install-cron puts CACHE_WRAP in front of the runner when its
# first word is an executable, for example a wrapper that keeps the dump file and the rsync copy inside a MemoryHigh
# scope and reclaims the Postgres container's page cache from pg_dump afterwards. Set it in the env file; empty (the
# default) installs the plain line.
CACHE_WRAP="${CACHE_WRAP-}"
MIN_DEST_FREE_KB="${MIN_DEST_FREE_KB:-1048576}"
LOCAL_MIN_FREE_KB="${LOCAL_MIN_FREE_KB:-62914560}"
SIZE_HEADROOM_PERCENT="${SIZE_HEADROOM_PERCENT:-15}"
CAPACITY_PROBE_ATTEMPTS="${CAPACITY_PROBE_ATTEMPTS:-3}"
CAPACITY_PROBE_DELAY_SECONDS="${CAPACITY_PROBE_DELAY_SECONDS:-2}"
MOUNT_RETRY_ATTEMPTS="${MOUNT_RETRY_ATTEMPTS:-0}"
MOUNT_RETRY_DELAY_SECONDS="${MOUNT_RETRY_DELAY_SECONDS:-60}"
RSYNC_RETRY_ATTEMPTS="${RSYNC_RETRY_ATTEMPTS:-0}"
RSYNC_RETRY_DELAY_SECONDS="${RSYNC_RETRY_DELAY_SECONDS:-60}"
EAGAIN_RETRY_ATTEMPTS="${EAGAIN_RETRY_ATTEMPTS:-5}"
ALERT_SYSLOG="${ALERT_SYSLOG:-1}"
ALERT_COMMAND="${ALERT_COMMAND:-}"
DRY_RUN="${DRY_RUN:-0}"
DRY_RUN_HASH="${DRY_RUN_HASH:-1}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
PENDING_STAGE_FILE="$STATE_DIR/pending-stage.txt"
RETENTION_HOLD_FILE="$STATE_DIR/retention-hold"
ALERT_FILE="$STATE_DIR/alert.json"
ALERT_LOG="$STATE_DIR/alerts.log"
# 3.2.0: names the incoming copy a paused run left for the next run to resume.
PAUSED_FILE="$STATE_DIR/paused-transfer.txt"

# Exit codes: 0 published and exactly one backup kept; 1 failed, previous backup
# kept; 3 published and verified, but some superseded or stale paths could not
# be deleted; 4 the transfer stopped at the end of its window (or the pool stayed
# BUSY), partial and verified stage kept for the next run, previous backup kept;
# 75 another run holds the lock.
EXIT_CLEANUP_INCOMPLETE=3
EXIT_PAUSED=4

# Run state read by on_exit.
TMP_DIR=""
BACKUP_ID=""
DEST_INCOMING=""
TRANSFER_STARTED=0
PUBLISHED=0
PHASE="init"
CLEANUP_FAILURES=0
VERIFY_TMP=""
MANIFEST_FIELDS=()
PENDING_FIELDS=()
STEP_PID=""
STEP_TIMED_OUT=0
PAUSE_REASON=""
POOL_STATE_LINE=""

usage() {
  cat <<'USAGE'
Usage: backup_agent_memory_pg.sh <command>

Commands:
  run             Dump, verify the destination copy, publish it, then delete every other backup
  dry-run         Show what run would do against the real paths, verify the published backup; change nothing
  verify [id]     Verify a published backup (default: latest): size + SHA-256 vs manifest, complete pg_restore --list
  status          Show media mount, latest pointer, published backups, alert, schedule
  list            List published dump files on media storage
  install-cron    Install or refresh the daily user crontab entry (saves the old crontab first)
  uninstall-cron  Remove this script's managed crontab block
  restore-help    Print restore command templates without running them

Retention: exactly one verified backup. The previous backup is deleted only after the
new one is verified and published. state/retention-hold suspends that deletion.

Exit codes: 0 published; 1 failed (previous kept); 3 published, cleanup incomplete;
4 transfer paused at the end of its window, partial + stage kept for the next run; 75 locked.

Configuration: environment variables, or KEY=VALUE lines in agent-memory-backup.env beside this
script (AGENT_MEMORY_BACKUP_ENV names another file). The environment wins over the file.
  MOUNTPOINT             The NAS share's mount point. Default: /mnt/nas
  BWLIMIT_KBPS           rsync throttle in KiB/s for the dump copy. Default: 6000
  PACE_STEP_SECONDS      Length of one paced copy step. Default: 600
  PACE_BUSY_WAIT_SECONDS Wait before re-reading a BUSY/missing/stale pool state. Default: 900
  PACE_GATE              1 reads POOL_STATE_FILE before each step; 0 skips the gate. Default: 1
  POOL_STATE_FILE        "OK|BUSY <utc>" line a probe on the NAS side writes. Default: $MOUNTPOINT/.nas-tuning/pool_state
  POOL_STATE_MAX_AGE_SECONDS A state line older than this counts as BUSY. Default: 300
  TRANSFER_WINDOW_UTC    Copy steps run only inside HH:MM-HH:MM UTC. Default: 07:00-13:00
  TRANSFER_DEADLINE_EPOCH If set, replaces the window: steps run only before this epoch second
  RESUME_TRIM_BYTES      Bytes cut off a partial before it is resumed. Default: 67108864
  MIN_SYSTEM_FREE_KB     No staging or copy step while a FREE_CHECK_PATHS entry has less free. Default: 19531250 (20 GB)
  FREE_CHECK_PATHS       Paths checked for MIN_SYSTEM_FREE_KB. Default: / and LOCAL_STAGING
  SHARE_COPY_LOCK        Held while a copy step writes; backup_pg_db.sh takes it too. Default: beside LOCK_FILE
  SHARE_WAIT_LOCK        Held shared by a waiting backup_pg_db.sh copy. Default: SHARE_COPY_LOCK with -wait.lock
  LOCAL_STAGING          Where the dump is staged. Default: $HOME/agent-memory-backup/staging
  DEST_ROOT              Where the verified backup is published. Default: $MOUNTPOINT/backups/agent-memory-postgres
  CRON_SCHEDULE          Cron schedule. Default: 20 2 * * *
  CACHE_WRAP             Command install-cron puts in front of the runner, if executable. Default: empty
  MIN_DEST_FREE_KB       Destination free space to keep beyond the new dump. Default: 1048576
  LOCAL_MIN_FREE_KB      Local staging free space to keep beyond the new dump. Default: 62914560 (60 GiB)
  SIZE_HEADROOM_PERCENT  Growth allowance on the expected dump size. Default: 15
  CAPACITY_PROBE_ATTEMPTS Number of capacity samples before failing. Default: 3
  MOUNT_RETRY_ATTEMPTS   Mount availability attempts. Default: 0 (unlimited)
  MOUNT_RETRY_DELAY_SECONDS Delay between mount attempts. Default: 60
  RSYNC_RETRY_ATTEMPTS   Transient rsync attempts. Default: 0 (unlimited)
  RSYNC_RETRY_DELAY_SECONDS Delay between transient rsync attempts. Default: 60
  EAGAIN_RETRY_ATTEMPTS  Retries of rsync exit 23 caused only by the share's EAGAIN. Default: 5
  ALERT_SYSLOG           1 sends alerts to the journal with logger. Default: 1
  ALERT_COMMAND          Optional command run with the alert JSON path as its argument
  DRY_RUN_HASH           dry-run: 1 hashes the pending stage and the published dump. Default: 1
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

init_dirs() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" "$LOCAL_STAGING"
}

ensure_base_tools() {
  require_cmd docker
  require_cmd rsync
  require_cmd flock
  require_cmd sha256sum
  require_cmd findmnt
  require_cmd awk
  require_cmd python3
}

ensure_container() {
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die "container not found: $CONTAINER_NAME"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$running" == "true" ]] || die "container is not running: $CONTAINER_NAME"
}

ensure_mount_once() {
  mkdir -p "$MOUNTPOINT" >/dev/null 2>&1 || return 1
  ls "$MOUNTPOINT" >/dev/null 2>&1 || return 1
  findmnt -T "$MOUNTPOINT" >/dev/null 2>&1 || return 1
  mkdir -p "$DEST_ROOT/dumps" "$DEST_ROOT/manifests" "$DEST_ROOT/restore-lists" "$DEST_ROOT/incoming" "$DEST_ROOT/logs" >/dev/null 2>&1 || return 1
  [[ -w "$DEST_ROOT" ]] || return 1
}

ensure_mount() {
  [[ "$MOUNT_RETRY_ATTEMPTS" =~ ^[0-9]+$ ]] || die "MOUNT_RETRY_ATTEMPTS must be a non-negative integer"
  [[ "$MOUNT_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die "MOUNT_RETRY_DELAY_SECONDS must be a non-negative integer"

  local attempt=1 mount_identity
  while true; do
    if ensure_mount_once; then
      return 0
    fi

    mount_identity="$(findmnt -T "$MOUNTPOINT" -n -o SOURCE,TARGET,FSTYPE 2>/dev/null | tail -n 1 | tr -s '[:space:]' ' ' || true)"
    if [[ "$MOUNT_RETRY_ATTEMPTS" -gt 0 && "$attempt" -ge "$MOUNT_RETRY_ATTEMPTS" ]]; then
      die "media mount remained unavailable after $attempt attempts: $MOUNTPOINT (mount=${mount_identity:-unknown})"
    fi

    log "media mount unavailable (attempt=$attempt mount=${mount_identity:-unknown}); retrying in ${MOUNT_RETRY_DELAY_SECONDS}s"
    sleep "$MOUNT_RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
}

available_kb_of() {
  df -Pk "$1" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { value = $4 } END { print value }'
}

# Expected size in KiB with growth headroom: the dump being resumed, else the
# latest published dump, else 0 (first run).
expected_dump_kb() {
  local size_bytes="${1:-0}"
  [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes=0
  echo $(( size_bytes / 1024 * (100 + SIZE_HEADROOM_PERCENT) / 100 ))
}

probe_destination_capacity() {
  local required_kb="$1"
  [[ "$MIN_DEST_FREE_KB" =~ ^[0-9]+$ ]] || die "MIN_DEST_FREE_KB must be a non-negative integer"
  [[ "$CAPACITY_PROBE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "CAPACITY_PROBE_ATTEMPTS must be a positive integer"
  [[ "$CAPACITY_PROBE_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die "CAPACITY_PROBE_DELAY_SECONDS must be a non-negative integer"

  local attempt=1 available_kb mount_identity
  while (( attempt <= CAPACITY_PROBE_ATTEMPTS )); do
    # Touch the automount before sampling. During CIFS recovery, the first df
    # result can describe the transient autofs layer instead of the mounted share.
    ls "$MOUNTPOINT" >/dev/null 2>&1 || true
    mount_identity="$(findmnt -T "$DEST_ROOT" -n -o SOURCE,TARGET,FSTYPE 2>/dev/null | tail -n 1 | tr -s '[:space:]' ' ' || true)"
    available_kb="$(available_kb_of "$DEST_ROOT")"

    if [[ "${available_kb:-}" =~ ^[0-9]+$ ]] && (( available_kb > required_kb )); then
      log "destination capacity verified: available_kb=$available_kb required_kb=$required_kb mount=${mount_identity:-unknown}" >&2
      printf '%s\n' "$available_kb"
      return 0
    fi

    log "destination capacity probe $attempt/$CAPACITY_PROBE_ATTEMPTS was not usable: available_kb=${available_kb:-unknown} required_kb=$required_kb mount=${mount_identity:-unknown}" >&2
    attempt=$((attempt + 1))
    if (( attempt <= CAPACITY_PROBE_ATTEMPTS )); then
      sleep "$CAPACITY_PROBE_DELAY_SECONDS"
    fi
  done

  return 1
}

rsync_with_retry() {
  [[ "$RSYNC_RETRY_ATTEMPTS" =~ ^[0-9]+$ ]] || die "RSYNC_RETRY_ATTEMPTS must be a non-negative integer"
  [[ "$RSYNC_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die "RSYNC_RETRY_DELAY_SECONDS must be a non-negative integer"
  [[ "$EAGAIN_RETRY_ATTEMPTS" =~ ^[0-9]+$ ]] || die "EAGAIN_RETRY_ATTEMPTS must be a non-negative integer"

  local attempt=1 status=0 available_kb errfile eagain_attempts=0
  errfile="$(mktemp)"
  while true; do
    status=0
    rsync "$@" 2>"$errfile" || status=$?
    cat "$errfile" >&2
    if [[ "$status" -eq 0 ]]; then
      rm -f "$errfile"
      return 0
    fi

    # Retry only transport/file-I/O classes that can be produced by a busy
    # soft NFS/CIFS path. Syntax, selection, and permission failures stay fatal.
    # Exit 23 is retried only when every error line is the CIFS share's EAGAIN
    # ("Resource temporarily unavailable (11)", seen on ftruncate 2026-11-24),
    # at most EAGAIN_RETRY_ATTEMPTS times; any other partial-transfer cause stays fatal.
    case "$status" in
      10|11|12|30|35) ;;
      23)
        if grep -q 'Resource temporarily unavailable (11)' "$errfile" \
          && ! grep -E '^rsync: ' "$errfile" | grep -vq 'Resource temporarily unavailable (11)' \
          && (( eagain_attempts < EAGAIN_RETRY_ATTEMPTS )); then
          eagain_attempts=$((eagain_attempts + 1))
        else
          rm -f "$errfile"
          return "$status"
        fi
        ;;
      *) rm -f "$errfile"; return "$status" ;;
    esac

    # A full destination is a confirmed failure, not a transient one: the
    # 2026-10-23 run retried ENOSPC for six hours before its watchdog fired.
    available_kb="$(available_kb_of "$DEST_ROOT")"
    if [[ "${available_kb:-}" =~ ^[0-9]+$ ]] && (( available_kb < MIN_DEST_FREE_KB )); then
      log "rsync failed with the destination below MIN_DEST_FREE_KB (available_kb=$available_kb exit=$status); not retrying"
      rm -f "$errfile"
      return "$status"
    fi

    if [[ "$RSYNC_RETRY_ATTEMPTS" -gt 0 && "$attempt" -ge "$RSYNC_RETRY_ATTEMPTS" ]]; then
      log "transient rsync failure persisted after $attempt attempts (exit=$status)"
      rm -f "$errfile"
      return "$status"
    fi

    log "transient rsync failure (exit=$status attempt=$attempt); retrying in ${RSYNC_RETRY_DELAY_SECONDS}s"
    sleep "$RSYNC_RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
}

# 3.2.0: may the copy write now? Reads the pool state line the NAS-side probe writes onto the share
# ("OK|BUSY <utc> ..."). Sets POOL_STATE_LINE. A missing, unreadable, non-OK or stale line counts as BUSY.
pool_state_ok() {
  POOL_STATE_LINE=""
  if [[ "$PACE_GATE" != "1" ]]; then
    POOL_STATE_LINE="gate off"
    return 0
  fi
  local line="" word="" stamp="" epoch age
  line="$(timeout 20 head -n 1 "$POOL_STATE_FILE" 2>/dev/null | tr -d '\r' || true)"
  POOL_STATE_LINE="${line:-missing or unreadable: $POOL_STATE_FILE}"
  read -r word stamp _ <<< "$line" || true
  [[ "$word" == "OK" ]] || return 1
  epoch="$(date -u -d "$stamp" +%s 2>/dev/null || echo 0)"
  age=$(( $(date +%s) - epoch ))
  if (( epoch == 0 || age > POOL_STATE_MAX_AGE_SECONDS )); then
    POOL_STATE_LINE="stale (${age}s old): $line"
    return 1
  fi
  return 0
}

WINDOW_RE='^([01][0-9]|2[0-3]):([0-5][0-9])-([01][0-9]|2[0-3]):([0-5][0-9])$'

# 3.2.0: prints "<path> has N GB free (floor M GB)" for the first FREE_CHECK_PATHS entry under MIN_SYSTEM_FREE_KB
# (or unreadable) and returns 0; returns 1 when every path is above the floor.
low_free_space() {
  local p kb
  for p in $FREE_CHECK_PATHS; do
    kb="$(available_kb_of "$p")"
    if [[ ! "${kb:-}" =~ ^[0-9]+$ ]] || (( kb < MIN_SYSTEM_FREE_KB )); then
      echo "$p has $(( ${kb:-0} * 1024 / 1000000000 )) GB free (floor $(( MIN_SYSTEM_FREE_KB * 1024 / 1000000000 )) GB)"
      return 0
    fi
  done
  return 1
}

free_space_summary() {
  local p kb out=""
  for p in $FREE_CHECK_PATHS; do
    kb="$(available_kb_of "$p")"
    out="$out$p $(( ${kb:-0} * 1024 / 1000000000 )) GB; "
  done
  echo "${out}floor $(( MIN_SYSTEM_FREE_KB * 1024 / 1000000000 )) GB"
}

# 3.2.0: checked once at preflight, where die can stop the run (paced_copy runs in an || context).
validate_pacing_config() {
  [[ "$BWLIMIT_KBPS" =~ ^[1-9][0-9]*$ ]] || die "BWLIMIT_KBPS must be a positive integer"
  [[ "$PACE_STEP_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "PACE_STEP_SECONDS must be a positive integer"
  [[ "$PACE_BUSY_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "PACE_BUSY_WAIT_SECONDS must be a positive integer"
  [[ "$POOL_STATE_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] || die "POOL_STATE_MAX_AGE_SECONDS must be a non-negative integer"
  [[ "$RESUME_TRIM_BYTES" =~ ^[0-9]+$ ]] || die "RESUME_TRIM_BYTES must be a non-negative integer"
  [[ "$STEP_KILL_GRACE_SECONDS" =~ ^[0-9]+$ ]] || die "STEP_KILL_GRACE_SECONDS must be a non-negative integer"
  [[ "$PACE_GATE" == "0" || "$PACE_GATE" == "1" ]] || die "PACE_GATE must be 0 or 1"
  [[ "$MIN_SYSTEM_FREE_KB" =~ ^[0-9]+$ ]] || die "MIN_SYSTEM_FREE_KB must be a non-negative integer"
  if [[ -n "$TRANSFER_DEADLINE_EPOCH" ]]; then
    [[ "$TRANSFER_DEADLINE_EPOCH" =~ ^[0-9]+$ ]] || die "TRANSFER_DEADLINE_EPOCH must be an epoch second"
  else
    [[ "$TRANSFER_WINDOW_UTC" =~ $WINDOW_RE ]] || die "TRANSFER_WINDOW_UTC must be HH:MM-HH:MM (UTC): $TRANSFER_WINDOW_UTC"
    [[ "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" < "${BASH_REMATCH[3]}${BASH_REMATCH[4]}" ]] ||
      die "TRANSFER_WINDOW_UTC must not cross midnight (start before end): $TRANSFER_WINDOW_UTC"
  fi
}

# 3.2.0: the end of the current copy window as an epoch second, or 0 when now is outside it
# (also 0 for a malformed setting, which validate_pacing_config has refused at preflight).
transfer_window_end() {
  local now today start end
  now="$(date +%s)"
  if [[ -n "$TRANSFER_DEADLINE_EPOCH" ]]; then
    if [[ "$TRANSFER_DEADLINE_EPOCH" =~ ^[0-9]+$ ]] && (( now < TRANSFER_DEADLINE_EPOCH )); then
      echo "$TRANSFER_DEADLINE_EPOCH"
    else
      echo 0
    fi
    return 0
  fi
  if [[ ! "$TRANSFER_WINDOW_UTC" =~ $WINDOW_RE ]]; then echo 0; return 0; fi
  today="$(date -u +%F)"
  start="$(date -u -d "$today ${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" +%s)"
  end="$(date -u -d "$today ${BASH_REMATCH[3]}:${BASH_REMATCH[4]}" +%s)"
  if (( start < end && now >= start && now < end )); then echo "$end"; else echo 0; fi
}

# 3.2.0: cut <bytes> off the end of a partial copy before it is resumed (a step that was stopped, a transient
# failure, or the previous night's pause may have left an unflushed tail). The final SHA-256 still decides.
trim_partial() {
  local file="$1" size new tries=0
  [[ -e "$file" ]] || return 0
  size="$(stat -c '%s' "$file")"
  (( size > 0 )) || return 0
  new=$(( size > RESUME_TRIM_BYTES ? size - RESUME_TRIM_BYTES : 0 ))
  sync -f "$file" 2>/dev/null || log "WARN: flushing the partial copy reported an error; trimming it anyway"
  until truncate -s "$new" "$file" 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries >= 5 )); then
      log "could not trim the partial copy $file"
      return 1
    fi
    sleep 5
  done
  log "trimmed the partial copy from $size to $new bytes before resuming"
}

# 3.2.0: run one rsync step for at most <seconds>, in its own process group so the step limit, a watchdog TERM
# (through on_exit) and rsync's own --stop-after backstop all stop the whole copy. Sets STEP_TIMED_OUT.
#   run_step <seconds> <errfile> <rsync args...>
run_step() {
  local secs="$1" errfile="$2" end killed_at="" status=0
  shift 2
  STEP_TIMED_OUT=0
  setsid --wait rsync "$@" 2>"$errfile" &
  STEP_PID=$!
  end=$(( $(date +%s) + secs ))
  while kill -0 "$STEP_PID" 2>/dev/null; do
    if [[ -z "$killed_at" ]] && (( $(date +%s) >= end )); then
      STEP_TIMED_OUT=1
      killed_at="$(date +%s)"
      kill -TERM -- "-$STEP_PID" "$STEP_PID" 2>/dev/null || true
    elif [[ -n "$killed_at" ]] && (( $(date +%s) >= killed_at + STEP_KILL_GRACE_SECONDS )); then
      kill -KILL -- "-$STEP_PID" "$STEP_PID" 2>/dev/null || true
    fi
    sleep 1
  done
  wait "$STEP_PID" 2>/dev/null || status=$?
  STEP_PID=""
  return "$status"
}

# 3.2.3: release the share-copy lock if this job holds it, by closing its descriptor (a copy step's rsync, which
# inherits it, has exited by then). A backup_pg_db.sh copy blocked in flock on the lock wakes at once.
#   share_lock_release [why]
share_lock_release() {
  [[ -n "$SHARE_FD" ]] || return 0
  exec {SHARE_FD}>&-
  SHARE_FD=""
  log "share-copy lock released${1:+ $1}"
}

# 3.2.3: hold the share-copy lock for the next step, unless a backup_pg_db.sh copy is waiting for the share: then
# release it, block until that copy has finished, and let the caller read the window, free space and pool state
# again. The waiting copy holds SHARE_WAIT_LOCK shared from before it asks for the share-copy lock until after it
# has released it, so the exclusive try below fails exactly while one waits or copies. This job never blocks on
# SHARE_WAIT_LOCK while it holds the share-copy lock, so the two jobs cannot deadlock.
#   share_turn <end of the copy window, epoch>
# Returns 0 holding the lock, 2 after a waiting copy had its turn, or 1 when the window ended first (PAUSE_REASON
# says why).
share_turn() {
  local end="$1" now wait_fd
  exec {wait_fd}>>"$SHARE_WAIT_LOCK"
  if ! flock -n -x "$wait_fd"; then
    share_lock_release "for a waiting backup_pg_db.sh copy"
    now="$(date +%s)"
    log "a backup_pg_db.sh copy is waiting for the share; it goes first (this copy waits up to $(date -u -d "@$end" '+%H:%MZ'))"
    if (( end <= now )) || ! flock -x -w $(( end - now )) "$wait_fd"; then
      exec {wait_fd}>&-
      PAUSE_REASON="a waiting backup_pg_db.sh copy kept the share until the end of the copy window"
      return 1
    fi
    exec {wait_fd}>&-
    log "the waiting backup_pg_db.sh copy has finished"
    return 2
  fi
  exec {wait_fd}>&-
  [[ -z "$SHARE_FD" ]] || return 0
  exec {SHARE_FD}>>"$SHARE_COPY_LOCK"
  if ! flock -n "$SHARE_FD"; then
    now="$(date +%s)"
    log "waiting for the share-copy lock (backup_pg_db.sh's NAS copy holds it), up to $(date -u -d "@$end" '+%H:%MZ')"
    if (( end <= now )) || ! flock -w $(( end - now )) "$SHARE_FD"; then
      exec {SHARE_FD}>&-; SHARE_FD=""
      PAUSE_REASON="the share-copy lock stayed held until the end of the copy window"
      return 1
    fi
  fi
  log "share-copy lock taken"
}

# 3.2.1: the share-copy lock, shared with backup_pg_db.sh 2.1.0+, keeps the two jobs from copying to the share at
# the same time. 3.2.3: it is held only while this job writes. share_turn takes it before each step, paced_copy_inner
# releases it for each pool wait, and paced_copy releases it when the copy pauses or fails. After a complete copy
# the caller keeps it for the manifest and restore list and then releases it (3.2.2 wrote those two files after it
# had released the lock).
paced_copy() {
  local rc=0
  paced_copy_inner "$@" || rc=$?
  (( rc == 0 )) || share_lock_release
  return "$rc"
}

# 3.2.0: copy <src> into <dest_dir>/ in paced, gated steps.
#   paced_copy_inner <src> <dest_dir> <resume: 1 when the partial there comes from a paused run>
# Returns 0 when rsync reports the copy complete, EXIT_PAUSED when the window ended first (PAUSE_REASON says
# why), or the rsync status of a fatal failure. 3.2.3: every write to the partial, the first trim included, happens
# after share_turn has returned 0.
paced_copy_inner() {
  local src="$1" dest_dir="$2" resume="$3"
  local dest src_size dest_size before after end now secs wait_s step=0 status errfile t0 eagain=0 transient=0
  local first=1 turn
  dest="$dest_dir/$(basename "$src")"
  src_size="$(stat -c '%s' "$src")"
  errfile="$(mktemp)"
  while true; do
    end="$(transfer_window_end)"
    if (( end == 0 )); then
      if [[ -n "$TRANSFER_DEADLINE_EPOCH" ]]; then
        PAUSE_REASON="the copy deadline $(date -u -d "@$TRANSFER_DEADLINE_EPOCH" '+%FT%TZ') has passed"
      else
        PAUSE_REASON="outside the copy window $TRANSFER_WINDOW_UTC UTC"
      fi
      [[ -n "$POOL_STATE_LINE" && "$POOL_STATE_LINE" != OK* && "$POOL_STATE_LINE" != "gate off" ]] &&
        PAUSE_REASON="$PAUSE_REASON (last pool state: $POOL_STATE_LINE)"
      break
    fi
    local low=""
    if low="$(low_free_space)"; then
      PAUSE_REASON="not copying: $low"
      log "free space below the floor, no write: $low"
      break
    fi
    now="$(date +%s)"
    if ! pool_state_ok; then
      wait_s=$(( end - now ))
      (( wait_s > PACE_BUSY_WAIT_SECONDS )) && wait_s="$PACE_BUSY_WAIT_SECONDS"
      # 3.2.3: a waiting backup_pg_db.sh copy may use the share during the wait; it reads the pool state itself.
      share_lock_release "for the pool wait"
      log "pool not OK, no write: $POOL_STATE_LINE; reading it again in ${wait_s}s"
      sleep "$wait_s"
      continue
    fi
    turn=0
    share_turn "$end" || turn=$?
    (( turn == 2 )) && continue
    (( turn == 0 )) || break
    if (( first == 1 )); then
      first=0
      if [[ -e "$dest" ]]; then
        dest_size="$(stat -c '%s' "$dest")"
        if (( dest_size > src_size )); then
          log "the partial copy is larger than the source ($dest_size > $src_size bytes); starting it over"
          rm -f -- "$dest"
        elif [[ "$resume" == "1" ]] && (( dest_size < src_size )); then
          trim_partial "$dest" || { rm -f "$errfile"; return 1; }
        fi
      fi
    fi
    now="$(date +%s)"
    secs=$(( end - now ))
    (( secs > 0 )) || continue
    (( secs > PACE_STEP_SECONDS )) && secs="$PACE_STEP_SECONDS"
    step=$((step + 1))
    before="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
    t0="$now"
    status=0
    run_step "$secs" "$errfile" -a --inplace --append --bwlimit="$BWLIMIT_KBPS" \
      --stop-after=$(( secs / 60 + 2 )) "$src" "$dest_dir/" || status=$?
    # A step stopped on purpose makes rsync print "received SIGINT, SIGTERM, or SIGHUP (code 20)"; keep that out of
    # the log. Any other rsync output is shown.
    [[ "$STEP_TIMED_OUT" == "1" ]] || cat "$errfile" >&2
    after="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
    local cut=""
    [[ "$STEP_TIMED_OUT" == "1" ]] && cut="; step time used up"
    log "pace step $step: pool ${POOL_STATE_LINE%% *}; $(( (after - before) / 1048576 )) MiB in $(( $(date +%s) - t0 ))s; $after of $src_size bytes ($(( src_size > 0 ? after * 100 / src_size : 100 ))%)$cut"
    if (( status == 0 )); then
      rm -f "$errfile"
      return 0
    fi
    if (( STEP_TIMED_OUT == 1 )); then
      trim_partial "$dest" || { rm -f "$errfile"; return 1; }
      continue
    fi
    # Same classes as rsync_with_retry: transport/file-I/O failures of a busy soft NFS/CIFS path are retried,
    # exit 23 only for the share's EAGAIN (capped), everything else is fatal. 30 includes rsync's own
    # --stop-after backstop.
    case "$status" in
      10|11|12|30|35) ;;
      23)
        if grep -q 'Resource temporarily unavailable (11)' "$errfile" \
          && ! grep -E '^rsync: ' "$errfile" | grep -vq 'Resource temporarily unavailable (11)' \
          && (( eagain < EAGAIN_RETRY_ATTEMPTS )); then
          eagain=$((eagain + 1))
        else
          rm -f "$errfile"
          return "$status"
        fi
        ;;
      *) rm -f "$errfile"; return "$status" ;;
    esac
    local available_kb
    available_kb="$(available_kb_of "$DEST_ROOT")"
    if [[ "${available_kb:-}" =~ ^[0-9]+$ ]] && (( available_kb < MIN_DEST_FREE_KB )); then
      log "rsync failed with the destination below MIN_DEST_FREE_KB (available_kb=$available_kb exit=$status); not retrying"
      rm -f "$errfile"
      return "$status"
    fi
    transient=$((transient + 1))
    if [[ "$RSYNC_RETRY_ATTEMPTS" -gt 0 && "$transient" -ge "$RSYNC_RETRY_ATTEMPTS" ]]; then
      log "transient rsync failure persisted after $transient attempts (exit=$status)"
      rm -f "$errfile"
      return "$status"
    fi
    log "transient rsync failure (exit=$status attempt=$transient); retrying in ${RSYNC_RETRY_DELAY_SECONDS}s"
    sleep "$RSYNC_RETRY_DELAY_SECONDS"
    trim_partial "$dest" || { rm -f "$errfile"; return 1; }
  done
  rm -f "$errfile"
  return "$EXIT_PAUSED"
}

psql_scalar() {
  local sql="$1"
  printf '%s\n' "$sql" | docker exec -i "$CONTAINER_NAME" sh -lc \
    'psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-agent_memory}" -d "${POSTGRES_DB:-agent_memory}" -tA' |
    tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n 1
}

# Validate a manifest and load its fields into MANIFEST_FIELDS:
# size_bytes sha256 event_count payload_archive_count latest_event_id database_size started_at_utc
read_manifest() {
  local manifest="$1" backup_id="$2"
  MANIFEST_FIELDS=()
  [[ -s "$manifest" ]] || return 1
  mapfile -t MANIFEST_FIELDS < <(python3 - "$manifest" "$backup_id" <<'PY' 2>/dev/null
import datetime,json,re,sys
m=json.load(open(sys.argv[1]))
assert m['backup_id']==sys.argv[2] and m['database']=='agent_memory' and m['format']=='pg_dump custom'
assert re.fullmatch('[0-9a-f]{64}',m['sha256'])
assert all(isinstance(m[k],int) and m[k]>=0 for k in ('size_bytes','event_count','payload_archive_count','latest_event_id'))
assert m['size_bytes']>0 and re.fullmatch(r'[0-9.]+ [A-Za-z]+',m['database_size'])
datetime.datetime.fromisoformat(m['started_at_utc'].replace('Z','+00:00'))
for key in ('size_bytes','sha256','event_count','payload_archive_count','latest_event_id','database_size','started_at_utc'):print(m[key])
PY
)
  [[ "${#MANIFEST_FIELDS[@]}" == "7" ]]
}

# The comparable part of a pg_restore --list: the archive's TOC header count and
# every entry line. Header comments that pg_restore formats itself are ignored.
restore_list_entries() {
  grep -E '^;[[:space:]]+TOC Entries:|^[0-9]+;' "$1" || true
}

# Verify one copy of a backup. Prints the reason and returns 1 on any mismatch.
#   verify_backup_copy <label> <dump> <manifest> <backup_id> <reference_restore_list>
verify_backup_copy() {
  local label="$1" dump="$2" manifest="$3" backup_id="$4" reference_list="$5"
  local expected_size expected_sha actual_size actual_sha status=0

  if ! read_manifest "$manifest" "$backup_id"; then
    log "verify $label: manifest missing or invalid: $manifest"
    return 1
  fi
  expected_size="${MANIFEST_FIELDS[0]}"; expected_sha="${MANIFEST_FIELDS[1]}"

  if [[ ! -s "$dump" ]]; then
    log "verify $label: dump missing or empty: $dump"
    return 1
  fi
  actual_size="$(stat -c '%s' "$dump" 2>/dev/null || echo unknown)"
  if [[ "$actual_size" != "$expected_size" ]]; then
    log "verify $label: size mismatch: manifest=$expected_size actual=$actual_size"
    return 1
  fi

  actual_sha="$(sha256sum "$dump" | awk '{print $1}')" || status=$?
  if [[ "$status" -ne 0 || "$actual_sha" != "$expected_sha" ]]; then
    log "verify $label: sha256 mismatch: manifest=$expected_sha actual=${actual_sha:-unreadable}"
    return 1
  fi

  VERIFY_TMP="$(mktemp "${TMPDIR:-/tmp}/agent-memory-verify.XXXXXX")"
  status=0
  docker exec -i "$CONTAINER_NAME" pg_restore --list < "$dump" > "$VERIFY_TMP" 2>/dev/null || status=$?
  if [[ "$status" -ne 0 ]]; then
    log "verify $label: pg_restore --list failed (exit=$status)"
    rm -f -- "$VERIFY_TMP"; VERIFY_TMP=""
    return 1
  fi
  if ! grep -qE '^;[[:space:]]+TOC Entries:[[:space:]]*[0-9]+' "$VERIFY_TMP" ||
     ! grep -qE '^[0-9]+;.* TABLE DATA public agent_memory_events ' "$VERIFY_TMP" ||
     ! grep -qE '^[0-9]+;.* TABLE DATA public agent_memory_payload_archives ' "$VERIFY_TMP"; then
    log "verify $label: pg_restore --list is incomplete (no TOC count or core TABLE DATA entries)"
    rm -f -- "$VERIFY_TMP"; VERIFY_TMP=""
    return 1
  fi
  if [[ ! -s "$reference_list" ]] || ! cmp -s <(restore_list_entries "$VERIFY_TMP") <(restore_list_entries "$reference_list"); then
    log "verify $label: pg_restore --list differs from the list taken at dump time: $reference_list"
    rm -f -- "$VERIFY_TMP"; VERIFY_TMP=""
    return 1
  fi
  log "verify $label: ok size_bytes=$actual_size sha256=$actual_sha toc_entries=$(grep -cE '^[0-9]+;' "$VERIFY_TMP")"
  rm -f -- "$VERIFY_TMP"; VERIFY_TMP=""
  return 0
}

json_write() {
  # json_write <path> <key=value>... ; values are strings, written atomically.
  local path="$1"; shift
  python3 - "$path" "$@" <<'PY'
import json,os,sys
path=sys.argv[1]
data=dict(item.split('=',1) for item in sys.argv[2:])
tmp=path+'.tmp'
with open(tmp,'w') as f: json.dump(data,f,indent=2); f.write('\n')
os.replace(tmp,path)
PY
}

raise_alert() {
  local severity="$1" message="$2"
  local previous
  previous="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt" 2>/dev/null || true)"
  log "ALERT($severity): $message"
  printf '[%s] %s %s backup_id=%s phase=%s published_backup=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$severity" "$message" "${BACKUP_ID:-none}" "$PHASE" "${previous:-none}" >> "$ALERT_LOG" 2>/dev/null || true
  json_write "$ALERT_FILE" "severity=$severity" "message=$message" "backup_id=${BACKUP_ID:-}" "phase=$PHASE" \
    "published_backup=${previous:-}" "raised_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "script_version=$SCRIPT_VERSION" 2>/dev/null || true
  if [[ "$ALERT_SYSLOG" == "1" ]] && command -v logger >/dev/null 2>&1; then
    logger -t agent-memory-backup -p user.err -- "$severity: $message (backup_id=${BACKUP_ID:-none} phase=$PHASE published=${previous:-none})" || true
  fi
  if [[ -n "$ALERT_COMMAND" ]]; then
    $ALERT_COMMAND "$ALERT_FILE" || log "alert command failed: $ALERT_COMMAND"
  fi
}

# remove_path <file|tree> <description> <path>. Honours DRY_RUN; a failure is
# counted, never fatal, so cleanup cannot undo a verified publication.
remove_path() {
  local mode="$1" what="$2" path="$3" err=""
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would delete $what: $path"
    return 0
  fi
  if [[ "$mode" == "tree" ]]; then
    err="$(rm -rf -- "$path" 2>&1)" || true
  else
    err="$(rm -f -- "$path" 2>&1)" || true
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
    log "WARN: could not delete $what: $path (${err:-still present})"
    return 1
  fi
  log "deleted $what: $path"
}

# Unpublished transfers and local stages left by earlier runs are confirmed
# failures: this run holds the lock, so no other run owns them. The verified
# pending stage (if any) is kept for this run to publish, and (3.2.0) so is the
# paused copy of that same backup, which this run resumes.
cleanup_stale_transfers() {
  local keep_stage="$1" keep_incoming="${2:-}" entry
  shopt -s nullglob
  for entry in "$DEST_ROOT"/incoming/agent_memory_*; do
    [[ -n "$keep_incoming" && "$entry" == "$keep_incoming" ]] && continue
    remove_path tree "failed/partial transfer" "$entry" || true
  done
  for entry in "$LOCAL_STAGING"/agent_memory_*; do
    [[ -n "$keep_stage" && "$entry" == "$keep_stage" ]] && continue
    remove_path tree "failed local stage" "$entry" || true
  done
  shopt -u nullglob
}

published_ids() {
  local file
  shopt -s nullglob
  for file in "$DEST_ROOT"/dumps/agent_memory_*.dump "$DEST_ROOT"/manifests/agent_memory_*.manifest.json "$DEST_ROOT"/restore-lists/agent_memory_*.restore.list; do
    file="$(basename "$file")"
    printf '%s\n' "${file%%.*}"
  done | sort -u
  shopt -u nullglob
}

# Delete every published backup except <keep_id>. Refuses unless keep_id is the
# published pointer and its dump is present at the verified size, so the job
# can never delete the only verified backup.
prune_superseded_backups() {
  local keep_id="$1" keep_size="$2" pointer actual id file
  if [[ "$DRY_RUN" != "1" ]]; then
    pointer="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt" 2>/dev/null || true)"
    actual="$(stat -c '%s' "$DEST_ROOT/dumps/${keep_id}.dump" 2>/dev/null || true)"
    if [[ "$pointer" != "$keep_id" || "$actual" != "$keep_size" ]]; then
      raise_alert error "refusing to delete older backups: pointer=${pointer:-none} keep=$keep_id size=${actual:-missing}/$keep_size"
      CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
      return 1
    fi
    if [[ -f "$RETENTION_HOLD_FILE" ]]; then
      log "WARN: retention hold present ($RETENTION_HOLD_FILE); superseded backups kept: $(published_ids | grep -vx "$keep_id" | tr '\n' ' ')"
      return 0
    fi
  fi

  while IFS= read -r id; do
    [[ -n "$id" && "$id" != "$keep_id" ]] || continue
    for file in "$DEST_ROOT/dumps/${id}.dump" "$DEST_ROOT/manifests/${id}.manifest.json" "$DEST_ROOT/restore-lists/${id}.restore.list"; do
      [[ -e "$file" || -L "$file" ]] || continue
      remove_path file "superseded backup" "$file" || true
    done
  done < <(published_ids)
}

# Validate state/pending-stage.txt. Returns 0 with TMP_DIR/BACKUP_ID set when a
# verified unpublished stage exists; otherwise discards an invalid stage
# (a confirmed failure) and returns 1.
load_pending_stage() {
  [[ -s "$PENDING_STAGE_FILE" ]] || return 1
  local stage reason="" id=""
  stage="$(head -n 1 "$PENDING_STAGE_FILE")"
  if [[ "$(readlink -f "$stage" 2>/dev/null)" != "$LOCAL_STAGING"/agent_memory_* ]]; then
    reason="pending staging path is outside $LOCAL_STAGING: $stage"
    stage=""
  elif [[ ! -d "$stage" || ! "$(basename "$stage")" =~ ^(agent_memory_[0-9]{8}T[0-9]{6}Z)\. ]]; then
    reason="pending staging dir missing or misnamed: $stage"
  else
    id="${BASH_REMATCH[1]}"
    if [[ ! -s "$stage/${id}.dump" || ! -s "$stage/${id}.restore.list" ]]; then
      reason="pending staging is incomplete: $stage"
    elif ! read_manifest "$stage/${id}.manifest.json" "$id"; then
      reason="pending manifest invalid: $stage/${id}.manifest.json"
    elif [[ "$(stat -c '%s' "$stage/${id}.dump")" != "${MANIFEST_FIELDS[0]}" ]]; then
      reason="pending dump size mismatch: $stage"
    elif [[ "$DRY_RUN" != "1" || "$DRY_RUN_HASH" == "1" ]] &&
         [[ "$(sha256sum "$stage/${id}.dump" | awk '{print $1}')" != "${MANIFEST_FIELDS[1]}" ]]; then
      reason="pending dump checksum mismatch: $stage"
    fi
  fi

  if [[ -z "$reason" ]]; then
    TMP_DIR="$stage"; BACKUP_ID="$id"
    PENDING_FIELDS=("${MANIFEST_FIELDS[@]}")
    return 0
  fi

  log "WARN: discarding unusable pending stage: $reason"
  if [[ -n "$stage" && -d "$stage" ]]; then
    remove_path tree "unusable pending stage" "$stage" || true
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    rm -f -- "$PENDING_STAGE_FILE"
    printf '[%s] warning discarded pending stage: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$reason" >> "$ALERT_LOG" 2>/dev/null || true
  fi
  return 1
}

latest_published_size() {
  local latest
  latest="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt" 2>/dev/null || true)"
  [[ -n "$latest" ]] || { echo 0; return 0; }
  stat -c '%s' "$DEST_ROOT/dumps/${latest}.dump" 2>/dev/null || echo 0
}

on_exit() {
  local status=$?
  set +e
  # Finish cleanup even if the watchdog signals again; its --kill-after bounds a hang.
  trap '' HUP INT TERM
  # 3.2.0: a copy step runs in its own process group; stop it before anything is cleaned up.
  if [[ -n "$STEP_PID" ]]; then
    kill -TERM -- "-$STEP_PID" "$STEP_PID" 2>/dev/null
    local waited=0
    while kill -0 "$STEP_PID" 2>/dev/null && (( waited < STEP_KILL_GRACE_SECONDS )); do sleep 1; waited=$((waited + 1)); done
    kill -KILL -- "-$STEP_PID" "$STEP_PID" 2>/dev/null
    wait "$STEP_PID" 2>/dev/null
    log "stopped the running copy step (pid $STEP_PID) after ${waited}s"
    STEP_PID=""
  fi
  [[ -n "$VERIFY_TMP" ]] && rm -f -- "$VERIFY_TMP"
  if [[ "$DRY_RUN" == "1" ]]; then
    exit "$status"
  fi

  if [[ "$PUBLISHED" == "1" ]]; then
    # The local stage is a second copy of the published backup; remove it.
    if [[ -n "$TMP_DIR" && "$TMP_DIR" == "$LOCAL_STAGING"/agent_memory_* && -d "$TMP_DIR" ]]; then
      remove_path tree "published local stage" "$TMP_DIR"
    fi
    rm -f -- "$PENDING_STAGE_FILE" "$PAUSED_FILE"
  elif [[ "$PHASE" == "transfer-paused" && "$status" -eq "$EXIT_PAUSED" ]]; then
    # 3.2.0: the window ended first. The partial copy and the verified stage both stay for the next run.
    log "kept the paused copy for the next run: $DEST_INCOMING"
    log "kept verified unpublished stage for the next run: $TMP_DIR"
  else
    # A publication interrupted before the pointer swap is rolled back: the
    # previous backup stays the published one and the stage is retried later.
    if [[ "$PHASE" == "publish" && -n "$BACKUP_ID" ]]; then
      local moved
      for moved in "$DEST_ROOT/dumps/${BACKUP_ID}.dump" "$DEST_ROOT/manifests/${BACKUP_ID}.manifest.json"                    "$DEST_ROOT/restore-lists/${BACKUP_ID}.restore.list" "$DEST_ROOT/latest_backup_id.txt.tmp"; do
        [[ -e "$moved" ]] && remove_path file "unfinished publication" "$moved"
      done
    fi
    # Unpublished: this run's destination copy is a confirmed failed transfer.
    if [[ "$TRANSFER_STARTED" == "1" && -n "$DEST_INCOMING" && "$DEST_INCOMING" == "$DEST_ROOT"/incoming/agent_memory_* && -e "$DEST_INCOMING" ]]; then
      remove_path tree "failed transfer" "$DEST_INCOMING"
    fi
    [[ "$TRANSFER_STARTED" == "1" ]] && rm -f -- "$PAUSED_FILE"
    # Keep a verified stage named in pending-stage.txt for the next run; any
    # other stage of this run (dump or listing failed) is deleted.
    if [[ -n "$TMP_DIR" && "$TMP_DIR" == "$LOCAL_STAGING"/agent_memory_* && -d "$TMP_DIR" ]]; then
      if [[ -f "$PENDING_STAGE_FILE" && "$(head -n 1 "$PENDING_STAGE_FILE")" == "$TMP_DIR" ]]; then
        log "kept verified unpublished stage for the next run: $TMP_DIR"
      else
        remove_path tree "failed local stage" "$TMP_DIR"
      fi
    fi
  fi

  if [[ "$status" -eq 0 && "$CLEANUP_FAILURES" -gt 0 ]]; then
    status="$EXIT_CLEANUP_INCOMPLETE"
  fi
  case "$status" in
    0) rm -f -- "$ALERT_FILE" ;;
    "$EXIT_CLEANUP_INCOMPLETE")
      raise_alert warning "backup ${BACKUP_ID:-?} is verified and published, but $CLEANUP_FAILURES superseded or stale path(s) could not be deleted" ;;
    "$EXIT_PAUSED")
      raise_alert warning "transfer of ${BACKUP_ID:-?} paused: ${PAUSE_REASON:-window ended}; $(stat -c '%s' "$DEST_INCOMING/${BACKUP_ID}.dump" 2>/dev/null || echo 0) bytes copied so far; the next run resumes it; the previously published backup was kept" ;;
    *)
      if [[ "$PUBLISHED" == "1" ]]; then
        raise_alert error "backup ${BACKUP_ID:-?} was verified and published, then the run stopped in phase $PHASE (exit=$status); older backups may remain"
      else
        raise_alert error "backup run failed in phase $PHASE (exit=$status); the previously published backup was kept"
      fi ;;
  esac
  exit "$status"
}

write_latest_state() {
  local backup_id="$1"
  local dump_path="$2"
  local manifest_path="$3"
  local size_bytes="$4"
  local sha256="$5"
  local event_count="$6"
  local archive_count="$7"
  local latest_event_id="$8"
  local db_size="$9"
  local state_tmp="$STATE_DIR/latest.json.tmp"

  cat > "$state_tmp" <<EOF
{
  "backup_id": "$backup_id",
  "completed_at_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "dump_path": "$dump_path",
  "manifest_path": "$manifest_path",
  "size_bytes": $size_bytes,
  "sha256": "$sha256",
  "event_count": $event_count,
  "payload_archive_count": $archive_count,
  "latest_event_id": $latest_event_id,
  "database_size": "$db_size",
  "bwlimit_kbps": $BWLIMIT_KBPS,
  "retention": "one-verified",
  "script_version": "$SCRIPT_VERSION"
}
EOF
  mv "$state_tmp" "$STATE_DIR/latest.json"
}

run_backup_locked() {
  [[ "${AGENT_MEMORY_BACKUP_LOCKED:-}" == "1" ]] || die "run-locked is an internal command"
  init_dirs
  trap on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ "$DRY_RUN" == "1" ]] && log "DRY-RUN: no file, pointer, alert or state is changed (script $SCRIPT_VERSION)"
  PHASE="preflight"
  ensure_base_tools
  ensure_container
  ensure_mount
  validate_pacing_config
  local low_space=""
  if low_space="$(low_free_space)"; then
    die "refusing to stage or copy: $low_space; the previously published backup and any pending stage are kept"
  fi
  log "free space ok: $(free_space_summary)"

  local resumed=0 keep_incoming="" resume_partial=0
  if load_pending_stage; then
    resumed=1
  fi
  # 3.2.0: a paused copy of the pending backup is resumed; any other paused marker is stale.
  if [[ "$resumed" == "1" && -s "$PAUSED_FILE" && "$(head -n 1 "$PAUSED_FILE")" == "$DEST_ROOT/incoming/$BACKUP_ID" &&
        -d "$DEST_ROOT/incoming/$BACKUP_ID" ]]; then
    keep_incoming="$DEST_ROOT/incoming/$BACKUP_ID"
    resume_partial=1
    log "$([[ "$DRY_RUN" == "1" ]] && echo 'DRY-RUN would resume' || echo 'resuming') the paused copy in $keep_incoming ($(stat -c '%s' "$keep_incoming/${BACKUP_ID}.dump" 2>/dev/null || echo 0) of ${PENDING_FIELDS[0]} bytes)"
  elif [[ -e "$PAUSED_FILE" && "$DRY_RUN" != "1" ]]; then
    log "WARN: discarding a stale paused-transfer marker: $(head -n 1 "$PAUSED_FILE" 2>/dev/null)"
    rm -f -- "$PAUSED_FILE"
  fi
  cleanup_stale_transfers "$TMP_DIR" "$keep_incoming"

  local expected_size required_kb local_available_kb available_kb
  if [[ "$resumed" == "1" ]]; then
    expected_size="${PENDING_FIELDS[0]}"
  else
    expected_size="$(latest_published_size)"
  fi
  required_kb=$(( $(expected_dump_kb "$expected_size") + MIN_DEST_FREE_KB ))
  if ! available_kb="$(probe_destination_capacity "$required_kb")"; then
    die "destination capacity remained unavailable or below ${required_kb} KiB after ${CAPACITY_PROBE_ATTEMPTS} probes: $DEST_ROOT"
  fi
  if [[ "$resumed" != "1" ]]; then
    local_available_kb="$(available_kb_of "$LOCAL_STAGING")"
    if [[ ! "${local_available_kb:-}" =~ ^[0-9]+$ ]] ||
       (( local_available_kb < $(expected_dump_kb "$expected_size") + LOCAL_MIN_FREE_KB )); then
      die "local staging would drop below LOCAL_MIN_FREE_KB=$LOCAL_MIN_FREE_KB KiB: available_kb=${local_available_kb:-unknown} expected_dump_kb=$(expected_dump_kb "$expected_size") ($LOCAL_STAGING)"
    fi
    log "local staging capacity verified: available_kb=$local_available_kb expected_dump_kb=$(expected_dump_kb "$expected_size")"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    dry_run_report "$resumed"
    return 0
  fi

  local backup_id tmp_dump tmp_manifest tmp_restore_list dest_incoming dest_dump dest_manifest dest_restore_list
  local event_count archive_count latest_event_id db_size started_at size_bytes source_sha256
  if [[ "$resumed" == "1" ]]; then
    backup_id="$BACKUP_ID"
    tmp_dump="$TMP_DIR/${backup_id}.dump"
    tmp_manifest="$TMP_DIR/${backup_id}.manifest.json"
    tmp_restore_list="$TMP_DIR/${backup_id}.restore.list"
    size_bytes="${PENDING_FIELDS[0]}"; source_sha256="${PENDING_FIELDS[1]}"
    event_count="${PENDING_FIELDS[2]}"; archive_count="${PENDING_FIELDS[3]}"; latest_event_id="${PENDING_FIELDS[4]}"
    db_size="${PENDING_FIELDS[5]}"; started_at="${PENDING_FIELDS[6]}"
    log "resuming verified unpublished backup $backup_id"
  else
    PHASE="dump"
    local timestamp
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    backup_id="agent_memory_${timestamp}"
    BACKUP_ID="$backup_id"
    TMP_DIR="$(mktemp -d "$LOCAL_STAGING/${backup_id}.XXXXXX")"

    tmp_dump="$TMP_DIR/${backup_id}.dump"
    tmp_manifest="$TMP_DIR/${backup_id}.manifest.json"
    tmp_restore_list="$TMP_DIR/${backup_id}.restore.list"

    log "collecting source database metadata"
    event_count="$(psql_scalar 'select count(*) from public.agent_memory_events;')"
    archive_count="$(psql_scalar "select case when to_regclass('public.agent_memory_payload_archives') is null then 0 else (select count(*) from public.agent_memory_payload_archives) end;")"
    latest_event_id="$(psql_scalar 'select coalesce(max(id), 0) from public.agent_memory_events;')"
    db_size="$(psql_scalar 'select pg_size_pretty(pg_database_size(current_database()));')"
    started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    log "creating local custom-format pg_dump for $backup_id"
    docker exec "$CONTAINER_NAME" sh -lc \
      'pg_dump -U "${POSTGRES_USER:-agent_memory}" -d "${POSTGRES_DB:-agent_memory}" --format=custom --compress=6 --no-owner --no-acl' \
      > "$tmp_dump"

    [[ -s "$tmp_dump" ]] || die "pg_dump produced an empty file"

    size_bytes="$(wc -c < "$tmp_dump" | tr -d ' ')"
    source_sha256="$(sha256sum "$tmp_dump" | awk '{print $1}')"
    log "verifying archive listing with pg_restore"
    docker exec -i "$CONTAINER_NAME" pg_restore --list < "$tmp_dump" > "$tmp_restore_list"
    [[ -s "$tmp_restore_list" ]] || die "pg_restore --list produced no output"

    cat > "$tmp_manifest" <<EOF
{
  "backup_id": "$backup_id",
  "started_at_utc": "$started_at",
  "completed_dump_at_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "source_host": "$(hostname)",
  "container": "$CONTAINER_NAME",
  "database": "agent_memory",
  "format": "pg_dump custom",
  "compression": 6,
  "size_bytes": $size_bytes,
  "sha256": "$source_sha256",
  "event_count": $event_count,
  "payload_archive_count": $archive_count,
  "latest_event_id": $latest_event_id,
  "database_size": "$db_size",
  "destination_root": "$DEST_ROOT",
  "bwlimit_kbps": $BWLIMIT_KBPS,
  "retention": "one-verified",
  "script_version": "$SCRIPT_VERSION"
}
EOF
    # The stage must verify against its own manifest before it is worth keeping.
    PHASE="verify-stage"
    verify_backup_copy "local stage" "$tmp_dump" "$tmp_manifest" "$backup_id" "$tmp_restore_list" ||
      die "the new local dump failed verification"
  fi

  dest_incoming="$DEST_ROOT/incoming/$backup_id"
  dest_dump="$DEST_ROOT/dumps/${backup_id}.dump"
  dest_manifest="$DEST_ROOT/manifests/${backup_id}.manifest.json"
  dest_restore_list="$DEST_ROOT/restore-lists/${backup_id}.restore.list"
  [[ ! -e "$dest_dump" && ! -e "$dest_manifest" && ! -e "$dest_restore_list" ]] || die "refusing to overwrite an existing published backup"
  printf '%s\n' "$TMP_DIR" > "$PENDING_STAGE_FILE.tmp"
  mv "$PENDING_STAGE_FILE.tmp" "$PENDING_STAGE_FILE"

  PHASE="transfer"
  DEST_INCOMING="$dest_incoming"
  TRANSFER_STARTED=1
  mkdir -p "$dest_incoming"
  log "copying $backup_id to $dest_incoming with rsync --bwlimit=$BWLIMIT_KBPS KiB/s in steps of ${PACE_STEP_SECONDS}s (pool gate $([[ "$PACE_GATE" == "1" ]] && echo "on: $POOL_STATE_FILE" || echo off), window ${TRANSFER_DEADLINE_EPOCH:+deadline }${TRANSFER_DEADLINE_EPOCH:-$TRANSFER_WINDOW_UTC UTC})"
  # Copy only the unpublished incoming dump sequentially: CIFS delta reconstruction
  # rereads/rebuilds the retained prefix. Keep the throttle and verify the full SHA-256.
  # 3.2.0: paced, gated steps that append to the partial; a pause keeps it for the next run. --append writes from
  # the receiver's current length and never rereads the prefix (rsync refuses it together with --whole-file).
  local copy_status=0
  paced_copy "$tmp_dump" "$dest_incoming" "$resume_partial" || copy_status=$?
  if [[ "$copy_status" -eq "$EXIT_PAUSED" ]]; then
    PHASE="transfer-paused"
    printf '%s\n%s\n' "$dest_incoming" "paused $(date -u '+%Y-%m-%dT%H:%M:%SZ'): $PAUSE_REASON" > "$PAUSED_FILE.tmp"
    mv "$PAUSED_FILE.tmp" "$PAUSED_FILE"
    log "transfer paused: $PAUSE_REASON; $(stat -c '%s' "$dest_incoming/${backup_id}.dump" 2>/dev/null || echo 0) of $size_bytes bytes copied; the next run resumes $dest_incoming"
    exit "$EXIT_PAUSED"
  elif [[ "$copy_status" -ne 0 ]]; then
    die "transfer of the dump failed"
  fi
  rm -f -- "$PAUSED_FILE"
  rsync_with_retry -a --inplace --whole-file --ignore-times "$tmp_manifest" "$tmp_restore_list" "$dest_incoming/" ||
    die "transfer of the manifest/restore list failed"
  # 3.2.3: every file of the backup is on the share; the verify below only reads it.
  share_lock_release

  PHASE="verify-destination"
  cmp -s "$tmp_manifest" "$dest_incoming/${backup_id}.manifest.json" || die "destination manifest differs from the staged manifest"
  cmp -s "$tmp_restore_list" "$dest_incoming/${backup_id}.restore.list" || die "destination restore list differs from the staged list"
  verify_backup_copy "destination" "$dest_incoming/${backup_id}.dump" "$dest_incoming/${backup_id}.manifest.json" "$backup_id" "$tmp_restore_list" ||
    die "destination copy failed verification; not publishing"

  PHASE="publish"
  [[ ! -e "$dest_dump" && ! -e "$dest_manifest" && ! -e "$dest_restore_list" ]] || die "refusing to overwrite an existing published backup"
  # Same-filesystem renames. The restore list and manifest land first so a
  # published dump is never without them; the pointer swap is the commit.
  mv "$dest_incoming/${backup_id}.restore.list" "$dest_restore_list"
  mv "$dest_incoming/${backup_id}.manifest.json" "$dest_manifest"
  mv "$dest_incoming/${backup_id}.dump" "$dest_dump"
  rmdir "$dest_incoming" 2>/dev/null || true
  [[ "$(stat -c '%s' "$dest_dump")" == "$size_bytes" ]] || die "published dump size changed during rename"
  printf '%s\n' "$backup_id" > "$DEST_ROOT/latest_backup_id.txt.tmp"
  mv "$DEST_ROOT/latest_backup_id.txt.tmp" "$DEST_ROOT/latest_backup_id.txt"
  PUBLISHED=1
  write_latest_state "$backup_id" "$dest_dump" "$dest_manifest" "$size_bytes" "$source_sha256" "$event_count" "$archive_count" "$latest_event_id" "$db_size" ||
    log "WARN: could not write $STATE_DIR/latest.json"
  log "published verified backup: $backup_id"

  PHASE="retention"
  prune_superseded_backups "$backup_id" "$size_bytes" || true

  PHASE="done"
  log "backup complete: $backup_id"
  log "events=$event_count latest_event_id=$latest_event_id payload_archives=$archive_count size_bytes=$size_bytes sha256=$source_sha256"
  log "dump=$dest_dump"
  log "manifest=$dest_manifest"
}

dry_run_report() {
  local resumed="$1" latest new_id
  latest="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt" 2>/dev/null || true)"
  if [[ "$resumed" == "1" ]]; then
    new_id="$BACKUP_ID"
    log "DRY-RUN would resume pending stage $TMP_DIR (backup $new_id, size_bytes=${PENDING_FIELDS[0]}, sha256=${PENDING_FIELDS[1]}$([[ "$DRY_RUN_HASH" == "1" ]] && echo ', stage hash re-verified'))"
  else
    new_id="agent_memory_$(date -u '+%Y%m%dT%H%M%SZ')"
    log "DRY-RUN would create a fresh dump ($new_id) in $LOCAL_STAGING"
  fi
  log "DRY-RUN would copy it to $DEST_ROOT/incoming/$new_id/, verify size + sha256 vs manifest and a complete pg_restore --list, then publish"
  local wend
  pool_state_ok || true
  wend="$(transfer_window_end)"
  log "DRY-RUN copy plan: --bwlimit=$BWLIMIT_KBPS KiB/s, steps of ${PACE_STEP_SECONDS}s, window ${TRANSFER_DEADLINE_EPOCH:+deadline }${TRANSFER_DEADLINE_EPOCH:-$TRANSFER_WINDOW_UTC UTC} ($([[ "$wend" != 0 ]] && echo "open until $(date -u -d "@$wend" '+%H:%MZ')" || echo 'closed now: a run would pause without writing')), pool state now: $POOL_STATE_LINE"
  log "DRY-RUN share: $SHARE_COPY_LOCK is held only while a step writes and is released for each pool wait; a backup_pg_db.sh copy waiting on $SHARE_WAIT_LOCK goes first at the next step"
  if [[ -n "$latest" ]]; then
    if [[ "$DRY_RUN_HASH" == "1" ]]; then
      PHASE="verify-published"
      if verify_backup_copy "published $latest" "$DEST_ROOT/dumps/${latest}.dump" "$DEST_ROOT/manifests/${latest}.manifest.json" "$latest" "$DEST_ROOT/restore-lists/${latest}.restore.list"; then
        log "DRY-RUN current published backup $latest is verified; it stays until $new_id is verified and published"
      else
        log "DRY-RUN WARN: current published backup $latest did not verify; a run would still keep it until $new_id is verified and published"
      fi
    fi
  else
    log "DRY-RUN no published backup pointer yet"
  fi
  log "DRY-RUN after publishing $new_id, retention would remove:"
  if [[ -f "$RETENTION_HOLD_FILE" ]]; then
    log "DRY-RUN (retention hold present: nothing would be removed)"
  else
    prune_superseded_backups "$new_id" 0
  fi
  [[ "$resumed" == "1" ]] && log "DRY-RUN would delete published local stage after publication: $TMP_DIR"
  log "DRY-RUN complete; nothing was changed"
}

run_backup() {
  init_dirs
  require_cmd flock

  local status=0
  flock -n -o -E 75 "$LOCK_FILE" \
    env AGENT_MEMORY_BACKUP_LOCKED=1 DRY_RUN="$DRY_RUN" "$SCRIPT_PATH" run-locked || status=$?
  if [[ "$status" -eq 75 ]]; then
    log "ERROR: another memory backup is already running"
    return 75
  fi
  return "$status"
}

verify_published() {
  init_dirs
  ensure_base_tools
  ensure_container
  ensure_mount
  local id="${1:-}"
  [[ -n "$id" ]] || id="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt" 2>/dev/null || true)"
  [[ "$id" =~ ^agent_memory_[0-9]{8}T[0-9]{6}Z$ ]] || die "no valid backup id to verify: ${id:-none}"
  trap '[[ -n "$VERIFY_TMP" ]] && rm -f -- "$VERIFY_TMP"' EXIT
  verify_backup_copy "published $id" "$DEST_ROOT/dumps/${id}.dump" "$DEST_ROOT/manifests/${id}.manifest.json" "$id" "$DEST_ROOT/restore-lists/${id}.restore.list"
}

show_status() {
  init_dirs
  ensure_base_tools
  ensure_container
  ensure_mount

  log "script_version: $SCRIPT_VERSION (retention: one verified backup)"
  log "container: $CONTAINER_NAME"
  log "mount: $(findmnt -T "$MOUNTPOINT" -n -o SOURCE,TARGET,FSTYPE,OPTIONS | sed 's/[[:space:]]\\+/ /g')"
  log "destination: $DEST_ROOT (available_kb=$(available_kb_of "$DEST_ROOT"))"
  log "local staging: $LOCAL_STAGING (available_kb=$(available_kb_of "$LOCAL_STAGING"))"
  log "bwlimit_kbps: $BWLIMIT_KBPS (steps of ${PACE_STEP_SECONDS}s, window ${TRANSFER_DEADLINE_EPOCH:-$TRANSFER_WINDOW_UTC UTC}, pool gate ${PACE_GATE})"
  pool_state_ok || true
  log "pool state: $POOL_STATE_LINE"
  log "free space: $(free_space_summary)"
  [[ -s "$PAUSED_FILE" ]] && log "paused copy: $(head -n 2 "$PAUSED_FILE" | tr '\n' ' ')"
  log "event_count: $(psql_scalar 'select count(*) from public.agent_memory_events;')"
  log "latest_event_id: $(psql_scalar 'select coalesce(max(id), 0) from public.agent_memory_events;')"

  if [[ -f "$DEST_ROOT/latest_backup_id.txt" ]]; then
    local latest
    latest="$(tr -d '\r\n' < "$DEST_ROOT/latest_backup_id.txt")"
    log "latest_backup_id: $latest"
    [[ -f "$DEST_ROOT/manifests/${latest}.manifest.json" ]] && sed -n '1,80p' "$DEST_ROOT/manifests/${latest}.manifest.json"
  else
    log "latest_backup_id: none"
  fi
  local ids count
  ids="$(published_ids | tr '\n' ' ')"
  count="$(published_ids | grep -c . || true)"
  log "published backups: $count ($ids)"
  [[ "$count" -le 1 ]] || log "WARN: more than one published backup; the next successful run deletes all but the newest"
  [[ -f "$RETENTION_HOLD_FILE" ]] && log "WARN: retention hold present: $RETENTION_HOLD_FILE"
  [[ -s "$PENDING_STAGE_FILE" ]] && log "pending stage: $(head -n 1 "$PENDING_STAGE_FILE")"
  if [[ -f "$ALERT_FILE" ]]; then
    log "ALERT present: $ALERT_FILE"
    cat "$ALERT_FILE"
  else
    log "alert: none"
  fi

  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | sed -n '/# BEGIN agent-memory-backup/,/# END agent-memory-backup/p' || true
  fi
}

list_backups() {
  init_dirs
  ensure_base_tools
  ensure_mount
  find "$DEST_ROOT/dumps" -maxdepth 1 -name 'agent_memory_*.dump' -printf '%TY-%Tm-%Td %TH:%TM %s %p\n' |
    sort -r |
    sed -n '1,30p'
}

install_cron() {
  init_dirs
  require_cmd crontab
  require_cmd readlink
  mkdir -p "$LOG_DIR"

  local runner
  runner="$(dirname "$SCRIPT_PATH")/backup_runner.py"
  [[ -f "$runner" ]] || die "runner not found beside the script: $runner"

  local wrap=""
  [[ -n "$CACHE_WRAP" && -x "${CACHE_WRAP%% *}" ]] && wrap="$CACHE_WRAP "
  local cron_tmp backup
  backup="$STATE_DIR/crontab-before-install-$(date -u '+%Y%m%dT%H%M%SZ').private.txt"
  crontab -l > "$backup" 2>/dev/null || true
  chmod 600 "$backup"
  cron_tmp="$(mktemp)"
  {
    crontab -l 2>/dev/null | sed '/# BEGIN agent-memory-backup/,/# END agent-memory-backup/d' || true
    echo '# BEGIN agent-memory-backup'
    printf '%s BWLIMIT_KBPS=%s %s/usr/bin/python3 %s >> %s/cron.log 2>&1\n' \
      "$CRON_SCHEDULE" "$BWLIMIT_KBPS" "$wrap" "$runner" "$LOG_DIR"
    echo '# END agent-memory-backup'
  } > "$cron_tmp"
  crontab "$cron_tmp"
  rm -f "$cron_tmp"
  log "installed cron schedule: $CRON_SCHEDULE via $runner (previous crontab saved to $backup)"
}

uninstall_cron() {
  require_cmd crontab
  local cron_tmp
  cron_tmp="$(mktemp)"
  crontab -l 2>/dev/null | sed '/# BEGIN agent-memory-backup/,/# END agent-memory-backup/d' > "$cron_tmp" || true
  crontab "$cron_tmp"
  rm -f "$cron_tmp"
  log "removed managed cron block"
}

restore_help() {
  cat <<EOF
Restore templates only. Do not run against the live database without explicit approval.

Latest backup id:
  \$(cat "$DEST_ROOT/latest_backup_id.txt")

Inspect archive:
  docker exec -i "$CONTAINER_NAME" pg_restore --list < "$DEST_ROOT/dumps/<backup_id>.dump"

Restore into a scratch database first:
  docker exec "$CONTAINER_NAME" sh -lc 'createdb -U "\${POSTGRES_USER:-agent_memory}" agent_memory_restore_test'
  docker exec -i "$CONTAINER_NAME" sh -lc 'pg_restore -U "\${POSTGRES_USER:-agent_memory}" -d agent_memory_restore_test --no-owner --no-acl' < "$DEST_ROOT/dumps/<backup_id>.dump"

A throwaway restore container needs /dev/shm at least as large as maintenance_work_mem
(docker run --shm-size 1600m ...) or max_parallel_maintenance_workers=0; with Docker's
default 64 MB /dev/shm both HNSW CREATE INDEX statements fail with "No space left on device".

Destructive live restore shape, only after stopping writers and getting approval:
  docker exec -i "$CONTAINER_NAME" sh -lc 'pg_restore -U "\${POSTGRES_USER:-agent_memory}" -d "\${POSTGRES_DB:-agent_memory}" --clean --if-exists --no-owner --no-acl' < "$DEST_ROOT/dumps/<backup_id>.dump"
EOF
}

main() {
  local command="${1:-run}"
  case "$command" in
    run) DRY_RUN=0; run_backup ;;
    dry-run) DRY_RUN=1; run_backup ;;
    run-locked) run_backup_locked ;;
    verify) verify_published "${2:-}" ;;
    status) show_status ;;
    list) list_backups ;;
    install-cron) install_cron ;;
    uninstall-cron) uninstall_cron ;;
    restore-help) restore_help ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command: $command" ;;
  esac
}

main "$@"
