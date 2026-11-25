#!/usr/bin/env bash
# Tests for backup_agent_memory_pg.sh's one-verified-backup policy.
#
# Runs on Linux (flock, findmnt, GNU stat) as a non-root user. Everything lives
# in a temp dir: a fake `docker` serves pg_dump/pg_restore/psql, and an rsync
# wrapper can corrupt or fail a transfer. No real backup path is touched.
#   bash scripts/tests/test_backup_agent_memory_pg.sh [path/to/backup_agent_memory_pg.sh]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(readlink -f "${1:-$HERE/../backup_agent_memory_pg.sh}")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/amb-test.XXXXXX")"
REAL_RSYNC="$(command -v rsync)"
REAL_DF="$(command -v df)"
PASS=0
FAIL=0

cleanup() {
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf -- "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'SHIM'
#!/usr/bin/env bash
# Fake docker: inspect, pg_dump, pg_restore --list, psql.
case "$1" in
  inspect) [[ "$2" == "-f" ]] && echo true; exit 0 ;;
  exec) ;;
  *) exit 2 ;;
esac
shift
[[ "$1" == "-i" ]] && shift
shift  # container name
cmd="$*"
if [[ "$cmd" == *pg_dump* ]]; then
  [[ -n "${FAKE_PG_DUMP_FAIL:-}" ]] && { echo "pg_dump: fake failure" >&2; exit 1; }
  printf 'PGDMP\nseed=%s\n' "${FAKE_DUMP_SEED:-0}"
  seq 1 "${FAKE_DUMP_LINES:-20000}"
  exit 0
fi
if [[ "$cmd" == *"pg_restore --list"* ]]; then
  count_file="${FAKE_STATE:?}/pg_restore_calls"
  calls=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  echo "$calls" > "$count_file"
  [[ "${FAKE_PG_RESTORE_FAIL_CALL:-0}" == "$calls" ]] && { cat >/dev/null; exit 1; }
  IFS= read -r first || exit 1
  [[ "$first" == "PGDMP" ]] || { echo "pg_restore: not a custom archive" >&2; exit 1; }
  IFS= read -r seed
  cat >/dev/null
  printf ';\n; Archive created at fake %s\n;     dbname: agent_memory\n;     TOC Entries: 5\n;\n' "$seed"
  printf '1; 0 0 TABLE public agent_memory_events agent_memory\n'
  printf '2; 0 0 TABLE DATA public agent_memory_events agent_memory\n'
  printf '3; 0 0 TABLE DATA public agent_memory_payload_archives agent_memory\n'
  [[ -n "${FAKE_LIST_DROP_ENTRY:-}" && "$calls" -ge 3 ]] || printf '4; 0 0 INDEX public events_pkey agent_memory\n'
  exit 0
fi
if [[ "$cmd" == *psql* ]]; then
  sql="$(cat)"
  if [[ "$sql" == *pg_size_pretty* ]]; then echo "1 MB"; else echo 42; fi
  exit 0
fi
exit 2
SHIM
cat > "$WORK/bin/rsync" <<SHIM
#!/usr/bin/env bash
# rsync wrapper: FAKE_RSYNC_CORRUPT=1 flips the last byte of a transferred .dump (same size);
# FAKE_RSYNC_FAIL=<code> copies half of a .dump then exits <code>.
# FAKE_RSYNC_LOG=<file> (3.2.3 tests): appends "start|end <epoch.ns> <destination> <.dump source or ->" around every
# call, a stopped step included, so a test can check that two jobs never wrote to the share at the same time.
args=("\$@"); src=""; dst="\${args[-1]}"
for a in "\${args[@]}"; do [[ "\$a" == *.dump ]] && src="\$a"; done
if [[ -n "\${FAKE_RSYNC_LOG:-}" ]]; then
  printf 'start %s %s %s\n' "\$(date +%s.%N)" "\$dst" "\${src:--}" >> "\$FAKE_RSYNC_LOG"
  trap 'printf "end %s %s %s\n" "\$(date +%s.%N)" "\$dst" "\${src:--}" >> "\$FAKE_RSYNC_LOG"' EXIT
  trap 'exit 143' TERM
fi
# FAKE_RSYNC_META_SLEEP=<s>: a call without a .dump (the manifest and restore list) takes <s> seconds longer.
if [[ -n "\${FAKE_RSYNC_META_SLEEP:-}" && -z "\$src" ]]; then sleep "\$FAKE_RSYNC_META_SLEEP"; fi
if [[ -n "\${FAKE_RSYNC_FAIL:-}" && -n "\$src" ]]; then
  head -c 1000 "\$src" > "\$dst/\$(basename "\$src")"; exit "\$FAKE_RSYNC_FAIL"
fi
if [[ -n "\${FAKE_RSYNC_EAGAIN_TIMES:-}" && -n "\$src" ]]; then
  # The CIFS share's EAGAIN on ftruncate (2026-11-24): exit 23 for the first N calls.
  n="\$(cat "\$FAKE_STATE/eagain_count" 2>/dev/null || echo 0)"
  if (( n < FAKE_RSYNC_EAGAIN_TIMES )); then
    echo "\$((n + 1))" > "\$FAKE_STATE/eagain_count"
    head -c 1000 "\$src" > "\$dst/\$(basename "\$src")"
    echo "rsync: [receiver] ftruncate failed on \"\$dst/\$(basename "\$src")\": Resource temporarily unavailable (11)" >&2
    echo "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1356) [sender=3.2.7]" >&2
    exit 23
  fi
fi
if [[ -n "\${FAKE_RSYNC_SLEEP:-}" && -n "\$src" ]]; then
  head -c 1000 "\$src" > "\$dst/\$(basename "\$src")"; sleep "\$FAKE_RSYNC_SLEEP"; exit 0
fi
"$REAL_RSYNC" "\$@" || exit \$?
if [[ -n "\${FAKE_RSYNC_CORRUPT:-}" && -n "\$src" ]]; then
  f="\$dst/\$(basename "\$src")"; printf 'X' | dd of="\$f" bs=1 seek=\$(( \$(stat -c %s "\$f") - 1 )) conv=notrunc status=none
fi
exit 0
SHIM
cat > "$WORK/bin/df" <<SHIM
#!/usr/bin/env bash
# df wrapper (3.2.0 free-space floor): when FAKE_STATE/df_low names the queried path, report 100 KiB available.
p="\${@: -1}"
if [[ -f "\${FAKE_STATE:-/nonexistent}/df_low" && "\$(cat "\$FAKE_STATE/df_low")" == "\$p" ]]; then
  printf "Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 1000000 999900 100 100%% %s\n" "\$p"; exit 0
fi
exec "$REAL_DF" "\$@"
SHIM
chmod +x "$WORK/bin/docker" "$WORK/bin/rsync" "$WORK/bin/df"

# pool_state <OK|BUSY> [utc-stamp]: the line the NAS-side probe writes onto the share (3.2.0 gate).
pool_state() {
  mkdir -p "$MOUNTPOINT/.nas-tuning"
  printf '%s %s disk_med=18ms test\n' "$1" "${2:-$(date -u +%FT%TZ)}" > "$MOUNTPOINT/.nas-tuning/pool_state"
}

new_env() {
  E="$WORK/env$1"
  mkdir -p "$E/mnt" "$E/staging" "$E/state" "$E/logs" "$E/fake"
  export PATH="$WORK/bin:$PATH" FAKE_STATE="$E/fake"
  # 3.2.2: an empty env file, so an agent-memory-backup.env beside the script under test never applies.
  : > "$WORK/empty.env"; export AGENT_MEMORY_BACKUP_ENV="$WORK/empty.env"
  export MOUNTPOINT="$E/mnt" DEST_ROOT="$E/mnt/backups/agent-memory-postgres" LOCAL_STAGING="$E/staging"
  export STATE_DIR="$E/state" LOG_DIR="$E/logs" LOCK_FILE="$E/backup.lock"
  export MIN_DEST_FREE_KB=0 LOCAL_MIN_FREE_KB=0 CAPACITY_PROBE_DELAY_SECONDS=0
  export MOUNT_RETRY_ATTEMPTS=1 RSYNC_RETRY_ATTEMPTS=1 RSYNC_RETRY_DELAY_SECONDS=0 ALERT_SYSLOG=0
  unset FAKE_PG_DUMP_FAIL FAKE_PG_RESTORE_FAIL_CALL FAKE_RSYNC_CORRUPT FAKE_RSYNC_FAIL FAKE_LIST_DROP_ENTRY FAKE_RSYNC_EAGAIN_TIMES FAKE_DUMP_LINES TRANSFER_WINDOW_UTC
  # 3.2.0 pacing: a fresh OK pool state, a deadline a day ahead and fast steps, so the cases above pacing behave
  # as before; the pacing cases (section 20) override these per run.
  export TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 86400 )) POOL_STATE_MAX_AGE_SECONDS=100000 PACE_GATE=1
  export PACE_STEP_SECONDS=600 PACE_BUSY_WAIT_SECONDS=1 RESUME_TRIM_BYTES=100 STEP_KILL_GRACE_SECONDS=2 BWLIMIT_KBPS=100000
  export MIN_SYSTEM_FREE_KB=0 FREE_CHECK_PATHS="/ $E/staging"
  rm -f "$E/fake/df_low"
  pool_state OK
  rm -f "$E/fake/pg_restore_calls" "$E/fake/eagain_count"
}

# run_job <name> <command> [VAR=value ...]: runs the script, records status and output.
run_job() {
  local name="$1" cmd="$2"; shift 2
  rm -f "$E/fake/pg_restore_calls"
  sleep 1.1  # backup ids are per-second timestamps
  env "$@" bash "$SCRIPT" "$cmd" > "$E/fake/$name.out" 2>&1
  RC=$?
}

dumps() { find "$DEST_ROOT/dumps" -maxdepth 1 -name 'agent_memory_*.dump' -printf '%f\n' 2>/dev/null | sort; }
count_glob() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l; }
pointer() { tr -d '\n' < "$DEST_ROOT/latest_backup_id.txt" 2>/dev/null; }

check() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $desc"
  else FAIL=$((FAIL + 1)); echo "FAIL - $desc"; [[ -n "${OUT:-}" ]] && sed 's/^/       | /' "$OUT" | tail -n 25; fi
}

exactly_one_published() {
  [[ "$(count_glob "$DEST_ROOT/dumps" 'agent_memory_*')" == 1 &&
     "$(count_glob "$DEST_ROOT/manifests" 'agent_memory_*')" == 1 &&
     "$(count_glob "$DEST_ROOT/restore-lists" 'agent_memory_*')" == 1 &&
     "$(dumps)" == "$(pointer).dump" ]]
}
published_sha_matches() {
  local id; id="$(pointer)"
  [[ "$(sha256sum "$DEST_ROOT/dumps/$id.dump" | awk '{print $1}')" == \
     "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha256"])' "$DEST_ROOT/manifests/$id.manifest.json")" ]]
}
no_incoming() { [[ "$(count_glob "$DEST_ROOT/incoming" 'agent_memory_*')" == 0 ]]; }
no_stage() { [[ "$(count_glob "$LOCAL_STAGING" 'agent_memory_*')" == 0 && ! -e "$STATE_DIR/pending-stage.txt" ]]; }
alert_present() { [[ -s "$STATE_DIR/alert.json" ]]; }
no_alert() { [[ ! -e "$STATE_DIR/alert.json" ]]; }
rc_is() { [[ "$RC" == "$1" ]]; }
tree_snapshot() { (cd "$E" && find . -path ./fake -prune -o -printf '%p %s %T@ %m\n' | sort; find . -path ./fake -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }

echo "# script: $SCRIPT"
bash -n "$SCRIPT"; check "script parses" true

# 1. First run publishes one verified backup.
new_env 1
run_job first run FAKE_DUMP_SEED=1; OUT="$E/fake/first.out"
check "first run exits 0" rc_is 0
check "first run publishes exactly one backup and points at it" exactly_one_published
check "published dump matches its manifest sha256" published_sha_matches
check "first run leaves no incoming transfer" no_incoming
check "first run leaves no local stage or pending file" no_stage
check "manifest records the one-verified policy" grep -q '"retention": "one-verified"' "$DEST_ROOT/manifests/$(pointer).manifest.json"
FIRST="$(pointer)"

# 2. Second run replaces it: new one published, previous deleted only afterwards.
run_job second run FAKE_DUMP_SEED=2; OUT="$E/fake/second.out"
check "second run exits 0" rc_is 0
check "second run keeps exactly one backup" exactly_one_published
check "the kept backup is the new one" test "$(pointer)" != "$FIRST"
check "previous deleted after publication (log order)" bash -c "awk '/published verified backup/{p=NR} /deleted superseded backup/{d=NR} END{exit !(p && d && p<d)}' '$OUT'"
SECOND="$(pointer)"
SECOND_SHA="$(sha256sum "$DEST_ROOT/dumps/$SECOND.dump" | awk '{print $1}')"

# 3. Corrupted transfer: previous kept, partial deleted, alert raised, stage kept for retry.
run_job corrupt run FAKE_DUMP_SEED=3 FAKE_RSYNC_CORRUPT=1; OUT="$E/fake/corrupt.out"
check "corrupt transfer exits 1" rc_is 1
check "corrupt transfer keeps the previous backup as the only one" exactly_one_published
check "corrupt transfer leaves previous pointer and bytes unchanged" test "$(pointer)" = "$SECOND" -a "$(sha256sum "$DEST_ROOT/dumps/$SECOND.dump" | awk '{print $1}')" = "$SECOND_SHA"
check "corrupt transfer deletes the failed incoming copy" no_incoming
check "corrupt transfer raises an alert" alert_present
check "corrupt transfer keeps the verified stage pending" test -s "$STATE_DIR/pending-stage.txt"
check "failure is logged as sha256 mismatch" grep -q 'sha256 mismatch' "$OUT"
PENDING_ID="$(basename "$(cat "$STATE_DIR/pending-stage.txt")" | cut -d. -f1)"

# 4. Next run resumes the pending stage, publishes it, deletes previous and stage, clears the alert.
run_job resume run FAKE_DUMP_SEED=4; OUT="$E/fake/resume.out"
check "resume run exits 0" rc_is 0
check "resume publishes the pending backup id" test "$(pointer)" = "$PENDING_ID"
check "resume keeps exactly one backup" exactly_one_published
check "resume deletes the published local stage and pending file" no_stage
check "resume clears the alert" no_alert
check "alert history kept in alerts.log" grep -q 'error' "$STATE_DIR/alerts.log"

# 5. pg_restore --list fails on the destination copy (call 3: dump list, stage verify,
#    destination verify): previous kept.
KEEP="$(pointer)"
run_job listfail run FAKE_DUMP_SEED=5 FAKE_PG_RESTORE_FAIL_CALL=3; OUT="$E/fake/listfail.out"
check "destination list failure exits 1" rc_is 1
check "destination list failure keeps previous as the only backup" test "$(pointer)" = "$KEEP"
check "destination list failure: exactly one published" exactly_one_published
check "destination list failure deletes the incoming copy" no_incoming
check "destination list failure is logged" grep -q 'pg_restore --list failed' "$OUT"
run_job clear1 run FAKE_DUMP_SEED=51; OUT="$E/fake/clear1.out"
check "recovery run after list failure exits 0" rc_is 0

# 6. Incomplete list on the destination (entry missing): previous kept.
KEEP="$(pointer)"
run_job listshort run FAKE_DUMP_SEED=6 FAKE_LIST_DROP_ENTRY=1; OUT="$E/fake/listshort.out"
check "incomplete destination list exits 1" rc_is 1
check "incomplete destination list keeps previous" test "$(pointer)" = "$KEEP"
check "incomplete destination list is detected" grep -q 'differs from the list taken at dump time' "$OUT"
run_job clear2 run FAKE_DUMP_SEED=61; OUT="$E/fake/clear2.out"
check "recovery run after short list exits 0" rc_is 0

# 7. Fatal rsync failure with a partial written: partial deleted, previous kept.
KEEP="$(pointer)"
run_job rsyncfail run FAKE_DUMP_SEED=7 FAKE_RSYNC_FAIL=23; OUT="$E/fake/rsyncfail.out"
check "fatal rsync failure exits 1" rc_is 1
check "fatal rsync failure keeps previous" test "$(pointer)" = "$KEEP"
check "fatal rsync failure deletes the partial transfer" no_incoming
check "fatal rsync failure: exactly one published" exactly_one_published

# 8. pg_dump failure: stage removed, nothing pending, previous kept. The pending
#    stage from step 7 is discarded first so this run takes a fresh dump.
rm -rf "$LOCAL_STAGING"/agent_memory_* "$STATE_DIR/pending-stage.txt"
run_job dumpfail run FAKE_PG_DUMP_FAIL=1; OUT="$E/fake/dumpfail.out"
check "pg_dump failure exits 1" rc_is 1
check "pg_dump failure keeps previous" test "$(pointer)" = "$KEEP"
check "pg_dump failure leaves no stage" no_stage
check "pg_dump failure raises an alert" alert_present

# 9. Insufficient destination capacity: fails before dumping, previous kept.
run_job nospace run FAKE_DUMP_SEED=9 MIN_DEST_FREE_KB=999999999999 CAPACITY_PROBE_ATTEMPTS=1; OUT="$E/fake/nospace.out"
check "capacity failure exits 1" rc_is 1
check "capacity failure keeps previous" test "$(pointer)" = "$KEEP"
check "capacity failure creates no stage" no_stage
check "capacity failure never dumped" bash -c "! grep -q 'creating local custom-format' '$OUT'"

# 10. Stale failed transfers from killed runs are deleted at the start of the next run;
#     non-backup entries in incoming are untouched.
mkdir -p "$DEST_ROOT/incoming/agent_memory_20200101T000000Z" "$DEST_ROOT/incoming/transport-fixture-x" "$LOCAL_STAGING/agent_memory_20200101T000000Z.abcdef"
echo partial > "$DEST_ROOT/incoming/agent_memory_20200101T000000Z/agent_memory_20200101T000000Z.dump"
run_job stale run FAKE_DUMP_SEED=10; OUT="$E/fake/stale.out"
check "stale cleanup run exits 0" rc_is 0
check "stale incoming transfer deleted" test ! -e "$DEST_ROOT/incoming/agent_memory_20200101T000000Z"
check "stale local stage deleted" test ! -e "$LOCAL_STAGING/agent_memory_20200101T000000Z.abcdef"
check "non-backup incoming entry untouched" test -d "$DEST_ROOT/incoming/transport-fixture-x"

# 11. An undeletable superseded backup: new one still published, exit 3, alert.
OLD=agent_memory_20200102T000000Z
mkdir -p "$DEST_ROOT/dumps/$OLD.dump"            # rm -f cannot remove a directory
mkdir -p "$DEST_ROOT/incoming/agent_memory_20200103T000000Z/ro"; touch "$DEST_ROOT/incoming/agent_memory_20200103T000000Z/ro/f"
chmod 555 "$DEST_ROOT/incoming/agent_memory_20200103T000000Z/ro"
run_job undeletable run FAKE_DUMP_SEED=11; OUT="$E/fake/undeletable.out"
check "undeletable leftovers exit 3" rc_is 3
check "undeletable: new backup still published and verified" published_sha_matches
check "undeletable: warning alert raised" grep -q '"severity": "warning"' "$STATE_DIR/alert.json"
check "undeletable: other superseded files still deleted" test "$(count_glob "$DEST_ROOT/manifests" 'agent_memory_*')" = 1
chmod 755 "$DEST_ROOT/incoming/agent_memory_20200103T000000Z/ro"
rm -rf "$DEST_ROOT/dumps/$OLD.dump" "$DEST_ROOT/incoming/agent_memory_20200103T000000Z"

# 12. Retention hold: new one published, previous kept, exit 0.
touch "$STATE_DIR/retention-hold"
run_job hold run FAKE_DUMP_SEED=12; OUT="$E/fake/hold.out"
check "hold run exits 0" rc_is 0
check "hold keeps both backups" test "$(count_glob "$DEST_ROOT/dumps" 'agent_memory_*')" = 2
rm -f "$STATE_DIR/retention-hold"

# 13. Dry run changes nothing and reports the plan.
mkdir -p "$DEST_ROOT/incoming/agent_memory_20200104T000000Z"
BEFORE="$(tree_snapshot)"
run_job dry dry-run FAKE_DUMP_SEED=13; OUT="$E/fake/dry.out"
AFTER="$(tree_snapshot)"
check "dry-run exits 0" rc_is 0
check "dry-run changes no file, pointer, alert or state" test "$BEFORE" = "$AFTER"
check "dry-run verifies the published backup" grep -q 'verify published .*: ok' "$OUT"
check "dry-run reports the stale transfer" grep -q 'DRY-RUN would delete failed/partial transfer' "$OUT"
check "dry-run reports both superseded backups" test "$(grep -c 'DRY-RUN would delete superseded backup: .*\.dump' "$OUT")" = 2
check "dry-run never dumps" bash -c "! grep -q 'creating local custom-format' '$OUT'"

# 14. Dry-run with a pending stage re-verifies it and plans to resume it.
run_job corrupt2 run FAKE_DUMP_SEED=14 FAKE_RSYNC_CORRUPT=1
BEFORE="$(tree_snapshot)"
run_job dry2 dry-run; OUT="$E/fake/dry2.out"
AFTER="$(tree_snapshot)"
check "dry-run with pending stage exits 0" rc_is 0
check "dry-run with pending stage plans the resume" grep -q 'DRY-RUN would resume pending stage' "$OUT"
check "dry-run with pending stage changes nothing" test "$BEFORE" = "$AFTER"

# 15. A tampered pending stage is a confirmed failure: discarded, a fresh dump is taken.
STAGE="$(cat "$STATE_DIR/pending-stage.txt")"
printf 'Y' >> "$STAGE"/*.dump
run_job tampered run FAKE_DUMP_SEED=15; OUT="$E/fake/tampered.out"
check "tampered pending stage: run exits 0 with a fresh dump" rc_is 0
check "tampered pending stage discarded" grep -q 'discarding unusable pending stage' "$OUT"
check "tampered pending stage: exactly one backup" exactly_one_published
check "tampered pending stage: no stage left" no_stage

# 16. verify command: ok on the published backup, fails after corruption.
run_job verify verify; OUT="$E/fake/verify.out"
check "verify passes on the published backup" rc_is 0
printf 'Z' >> "$DEST_ROOT/dumps/$(pointer).dump"
run_job verifybad verify; OUT="$E/fake/verifybad.out"
check "verify fails on a corrupted published backup" rc_is 1

# 17. A run never deletes the only verified backup: with the published dump corrupt
#     and the new transfer also corrupt, the old (only) backup is left in place.
KEEP="$(pointer)"
run_job onlycopy run FAKE_DUMP_SEED=17 FAKE_RSYNC_CORRUPT=1; OUT="$E/fake/onlycopy.out"
check "only-copy case exits 1" rc_is 1
check "only-copy case leaves the published backup in place" test -f "$DEST_ROOT/dumps/$KEEP.dump" -a "$(pointer)" = "$KEEP"

# 17b. Watchdog TERM in the middle of a transfer: partial deleted, alert, previous kept.
run_job heal run FAKE_DUMP_SEED=171; OUT="$E/fake/heal.out"
check "healthy run before the TERM case exits 0" rc_is 0
KEEP="$(pointer)"
rm -f "$E/fake/pg_restore_calls"; sleep 1.1
FAKE_RSYNC_SLEEP=30 timeout -s TERM 4 bash "$SCRIPT" run > "$E/fake/term.out" 2>&1; RC=$?; OUT="$E/fake/term.out"
# timeout returns when the flock wrapper dies; the locked run is still cleaning up.
for _ in $(seq 1 100); do pgrep -f "$SCRIPT run-locked" >/dev/null || break; sleep 0.2; done
check "TERM during transfer reports the watchdog exit (124)" rc_is 124
check "TERM during transfer keeps previous" test "$(pointer)" = "$KEEP"
check "TERM during transfer deletes the partial transfer" no_incoming
check "TERM during transfer raises an alert" grep -q 'phase transfer' "$STATE_DIR/alert.json"
check "TERM during transfer: exactly one published" exactly_one_published

# 18. Lock: a second concurrent run exits 75 without touching anything.
new_env 2
exec 9>"$LOCK_FILE"; flock -n 9
run_job locked run FAKE_DUMP_SEED=18; OUT="$E/fake/locked.out"
exec 9>&-
check "concurrent run exits 75" rc_is 75
check "concurrent run publishes nothing" test -z "$(dumps)"

# 18b. The CIFS share's EAGAIN on ftruncate (rsync exit 23, 2026-11-24) is retried and publishes;
#      past EAGAIN_RETRY_ATTEMPTS it stays fatal. Exit 23 with any other cause stays fatal (step 7).
new_env 18b
run_job eagain run FAKE_DUMP_SEED=31 FAKE_RSYNC_EAGAIN_TIMES=2 RSYNC_RETRY_ATTEMPTS=0; OUT="$E/fake/eagain.out"
check "EAGAIN exit 23 is retried and the run exits 0" rc_is 0
check "EAGAIN retry publishes exactly one verified backup" exactly_one_published
check "EAGAIN retry: the published sha matches" published_sha_matches
check "EAGAIN retry logs the transient failure" grep -q 'transient rsync failure (exit=23' "$OUT"
KEEP="$(pointer)"
rm -f "$E/fake/eagain_count"
run_job eagain_cap run FAKE_DUMP_SEED=32 FAKE_RSYNC_EAGAIN_TIMES=9 RSYNC_RETRY_ATTEMPTS=0 EAGAIN_RETRY_ATTEMPTS=2; OUT="$E/fake/eagain_cap.out"
check "EAGAIN past its cap exits 1" rc_is 1
check "EAGAIN past its cap keeps the previous backup" test "$(pointer)" = "$KEEP"

# 20. 3.2.0: the paced, gated, resumable copy (design A after the 11-24 NAS outage).
new_env 20
paused_file() { [[ -s "$STATE_DIR/paused-transfer.txt" ]]; }
no_paused_file() { [[ ! -e "$STATE_DIR/paused-transfer.txt" ]]; }
pending_id() { basename "$(cat "$STATE_DIR/pending-stage.txt" 2>/dev/null)" | cut -d. -f1; }
inc_size() { stat -c %s "$DEST_ROOT/incoming/$1/$1.dump" 2>/dev/null || echo 0; }
stage_size() { stat -c %s "$(cat "$STATE_DIR/pending-stage.txt")/$1.dump" 2>/dev/null || echo 0; }
pointer_is() { [[ "$(pointer)" == "$1" ]]; }
no_step_ran() { ! grep -q 'pace step ' "$OUT"; }
no_new_dump() { ! grep -q 'creating local custom-format' "$OUT"; }
run_job p_base run FAKE_DUMP_SEED=40; OUT="$E/fake/p_base.out"
check "pacing: baseline run exits 0" rc_is 0
KEEP="$(pointer)"

# 20a. A slow copy runs in several steps; each cut step is trimmed and appended to; it publishes.
run_job p_steps run FAKE_DUMP_SEED=41 FAKE_DUMP_LINES=60000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2; OUT="$E/fake/p_steps.out"
check "pacing: multi-step copy exits 0" rc_is 0
check "pacing: the copy took at least 3 steps" test "$(grep -c 'pace step ' "$OUT")" -ge 3
check "pacing: a cut step is logged" grep -q 'step time used up' "$OUT"
check "pacing: the partial is trimmed before the next step" grep -q 'trimmed the partial copy from' "$OUT"
check "pacing: multi-step copy publishes exactly one backup" exactly_one_published
check "pacing: multi-step copy matches its sha256" published_sha_matches
check "pacing: no incoming copy left" no_incoming
check "pacing: no stage left" no_stage
check "pacing: no paused marker left" no_paused_file
KEEP="$(pointer)"

# 20b. While the pool is BUSY nothing is written; at the deadline the run pauses with exit 4.
pool_state BUSY
run_job p_busy run FAKE_DUMP_SEED=42 FAKE_DUMP_LINES=60000 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 5 )); OUT="$E/fake/p_busy.out"
P_ID="$(pending_id)"
check "gate: BUSY until the deadline exits 4 (paused)" rc_is 4
check "gate: BUSY is logged" grep -q 'pool not OK, no write: BUSY' "$OUT"
check "gate: no copy step ran while BUSY" no_step_ran
check "gate: no bytes copied while BUSY" test "$(inc_size "$P_ID")" = 0
check "gate: the paused marker names the incoming copy" grep -qx "$DEST_ROOT/incoming/$P_ID" "$STATE_DIR/paused-transfer.txt"
check "gate: the verified stage stays pending" test -s "$STATE_DIR/pending-stage.txt"
check "gate: the previous pointer is unchanged" pointer_is "$KEEP"
check "gate: exactly one published backup" exactly_one_published
check "gate: the alert is a warning" grep -q '"severity": "warning"' "$STATE_DIR/alert.json"
check "gate: the alert says paused" grep -q 'paused' "$STATE_DIR/alert.json"

# 20c. The next run resumes that same backup (no new dump); the deadline cuts it part way.
pool_state OK
run_job p_cut run FAKE_DUMP_SEED=43 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 5 )); OUT="$E/fake/p_cut.out"
P_SIZE="$(inc_size "$P_ID")"; FULL="$(stage_size "$P_ID")"
check "deadline: a copy cut by the deadline exits 4" rc_is 4
check "deadline: the run resumed the pending backup" grep -q "resuming verified unpublished backup $P_ID" "$OUT"
check "deadline: the run took no new dump" no_new_dump
check "deadline: a partial was copied and kept" test "$P_SIZE" -gt 0 -a "$P_SIZE" -lt "$FULL"
check "deadline: the pause is logged with the bytes copied" grep -q "transfer paused: the copy deadline .* has passed; $P_SIZE of $FULL bytes copied" "$OUT"
check "deadline: the previous pointer is unchanged" pointer_is "$KEEP"
check "deadline: exactly one published backup" exactly_one_published
check "deadline: the paused marker is kept" paused_file

# 20d. The following run trims the partial, appends the rest, verifies and publishes it.
run_job p_resume run FAKE_DUMP_SEED=44; OUT="$E/fake/p_resume.out"
check "resume: exits 0" rc_is 0
check "resume: resumes the paused copy" grep -qF "resuming the paused copy in $DEST_ROOT/incoming/$P_ID ($P_SIZE of $FULL bytes)" "$OUT"
check "resume: trims the partial first" grep -q "trimmed the partial copy from $P_SIZE to $(( P_SIZE > 100 ? P_SIZE - 100 : 0 )) bytes" "$OUT"
check "resume: took no new dump" no_new_dump
check "resume: publishes the paused backup" pointer_is "$P_ID"
check "resume: exactly one published backup" exactly_one_published
check "resume: the published copy matches its sha256" published_sha_matches
check "resume: no incoming copy left" no_incoming
check "resume: no stage left" no_stage
check "resume: no paused marker left" no_paused_file
check "resume: no alert left" no_alert
KEEP="$(pointer)"

# 20e. A bad byte inside a paused partial is caught by the final SHA-256: not published, partial and marker
#      deleted, stage kept, previous kept; the next run copies it again from the start and publishes.
run_job p_cut2 run FAKE_DUMP_SEED=45 FAKE_DUMP_LINES=60000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 5 )); OUT="$E/fake/p_cut2.out"
C_ID="$(pending_id)"
check "corrupt partial: setup run paused" rc_is 4
printf 'Q' | dd of="$DEST_ROOT/incoming/$C_ID/$C_ID.dump" bs=1 seek=10 conv=notrunc status=none
run_job p_corrupt run FAKE_DUMP_SEED=46; OUT="$E/fake/p_corrupt.out"
check "corrupt partial: exits 1" rc_is 1
check "corrupt partial: caught as sha256 mismatch" grep -q 'sha256 mismatch' "$OUT"
check "corrupt partial: the previous pointer is unchanged" pointer_is "$KEEP"
check "corrupt partial: exactly one published backup" exactly_one_published
check "corrupt partial: the bad copy is deleted" no_incoming
check "corrupt partial: the paused marker is deleted" no_paused_file
check "corrupt partial: the verified stage stays pending" test "$(pending_id)" = "$C_ID"
run_job p_recopy run FAKE_DUMP_SEED=47; OUT="$E/fake/p_recopy.out"
check "corrupt partial: the next run exits 0" rc_is 0
check "corrupt partial: the next run publishes that backup" pointer_is "$C_ID"
check "corrupt partial: the republished copy matches its sha256" published_sha_matches
KEEP="$(pointer)"

# 20f. After the copy window's end a run (a fresh dump here) writes nothing and pauses at once. (3.3.0: before the
#      window opens it would wait for it, so the window here must already have ended today.)
W="00:00-00:01"; [[ "$(date -u +%H:%M)" == "00:00" ]] && sleep 61
run_job p_window run FAKE_DUMP_SEED=48 TRANSFER_DEADLINE_EPOCH= TRANSFER_WINDOW_UTC="$W"; OUT="$E/fake/p_window.out"
W_ID="$(pending_id)"
check "window: outside the window exits 4" rc_is 4
check "window: the reason is logged" grep -q "outside the copy window $W UTC" "$OUT"
check "window: no step ran" no_step_ran
check "window: nothing was copied" test "$(inc_size "$W_ID")" = 0
check "window: the previous pointer is unchanged" pointer_is "$KEEP"
check "window: exactly one published backup" exactly_one_published
run_job p_badwin run TRANSFER_DEADLINE_EPOCH= TRANSFER_WINDOW_UTC="13:00-07:00"; OUT="$E/fake/p_badwin.out"
check "window: a window that crosses midnight is refused (exit 1)" rc_is 1
check "window: the refusal is logged" grep -q 'must not cross midnight' "$OUT"

# 20g. A stale pool state counts as BUSY; 20h. so does a missing one; 20i. PACE_GATE=0 skips the gate.
pool_state OK "$(date -u -d '-1 hour' +%FT%TZ)"
run_job p_stale run POOL_STATE_MAX_AGE_SECONDS=300 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 4 )); OUT="$E/fake/p_stale.out"
check "gate: a stale OK line pauses the run (exit 4)" rc_is 4
check "gate: a stale OK line counts as BUSY" grep -q 'pool not OK, no write: stale' "$OUT"
rm -f "$MOUNTPOINT/.nas-tuning/pool_state"
run_job p_missing run TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 4 )); OUT="$E/fake/p_missing.out"
check "gate: a missing state file pauses the run (exit 4)" rc_is 4
check "gate: a missing state file counts as BUSY" grep -q 'pool not OK, no write: missing or unreadable' "$OUT"
run_job p_gateoff run PACE_GATE=0; OUT="$E/fake/p_gateoff.out"
check "gate: PACE_GATE=0 copies without a state file (exit 0)" rc_is 0
check "gate: PACE_GATE=0 publishes the pending backup" pointer_is "$W_ID"
check "gate: PACE_GATE=0 keeps exactly one backup" exactly_one_published
check "gate: PACE_GATE=0 leaves no stage" no_stage
check "gate: PACE_GATE=0 leaves no paused marker" no_paused_file
pool_state OK
KEEP="$(pointer)"

# 20j. Dry-run with a paused copy plans the resume and changes nothing.
run_job p_cut3 run FAKE_DUMP_SEED=49 FAKE_DUMP_LINES=60000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 5 )); OUT="$E/fake/p_cut3.out"
check "dry-run: setup run paused" rc_is 4
BEFORE="$(tree_snapshot)"
run_job p_dry dry-run; OUT="$E/fake/p_dry.out"
AFTER="$(tree_snapshot)"
check "dry-run: exits 0" rc_is 0
check "dry-run: plans the resume of the paused copy" grep -q 'DRY-RUN would resume the paused copy' "$OUT"
check "dry-run: prints the copy plan" grep -q 'DRY-RUN copy plan: --bwlimit=100000 KiB/s, steps of 600s' "$OUT"
check "dry-run: with a paused copy changes nothing" test "$BEFORE" = "$AFTER"

# 20k. A paused marker that names another backup is stale: discarded, both incoming copies deleted, the pending
#      stage copied from the start and published.
printf '%s\n' "$DEST_ROOT/incoming/agent_memory_20200105T000000Z" > "$STATE_DIR/paused-transfer.txt"
mkdir -p "$DEST_ROOT/incoming/agent_memory_20200105T000000Z"
S_ID="$(pending_id)"
run_job p_stalemark run FAKE_DUMP_SEED=50; OUT="$E/fake/p_stalemark.out"
check "stale marker: the run exits 0" rc_is 0
check "stale marker: the pending backup is published" pointer_is "$S_ID"
check "stale marker: discarded with a warning" grep -q 'discarding a stale paused-transfer marker' "$OUT"
check "stale marker: no incoming copy left" no_incoming
check "stale marker: no marker left" no_paused_file
check "stale marker: exactly one published backup" exactly_one_published

# 20l. Free-space floor (11-24): with / or the staging drive under the floor the run refuses to stage or
#      copy, says so, and keeps the previous backup.
KEEP="$(pointer)"
run_job p_lowfree run FAKE_DUMP_SEED=51 MIN_SYSTEM_FREE_KB=999999999999; OUT="$E/fake/p_lowfree.out"
check "free space: preflight refusal exits 1" rc_is 1
check "free space: the refusal is logged" grep -q 'refusing to stage or copy: / has' "$OUT"
check "free space: nothing was dumped" no_new_dump
check "free space: no stage was made" no_stage
check "free space: the previous pointer is unchanged" pointer_is "$KEEP"
check "free space: exactly one published backup" exactly_one_published
check "free space: an alert is raised" alert_present

# 20m. Free space that drops under the floor during a copy stops it before the next step (exit 4, partial kept);
#      with space back the next run resumes and publishes.
( sleep 4; printf '%s\n' "$LOCAL_STAGING" > "$E/fake/df_low" ) &
run_job p_dropfree run FAKE_DUMP_SEED=52 FAKE_DUMP_LINES=60000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 MIN_SYSTEM_FREE_KB=1000; OUT="$E/fake/p_dropfree.out"
wait
M_ID="$(pending_id)"
check "free space: a drop during the copy pauses it (exit 4)" rc_is 4
check "free space: the drop is logged" grep -qF "free space below the floor, no write: $LOCAL_STAGING has 0 GB free" "$OUT"
check "free space: the partial is kept" test "$(inc_size "$M_ID")" -gt 0
check "free space: the alert gives the reason" grep -q 'not copying' "$STATE_DIR/alert.json"
check "free space: the previous pointer is unchanged" pointer_is "$KEEP"
rm -f "$E/fake/df_low"
run_job p_freeok run FAKE_DUMP_SEED=53 MIN_SYSTEM_FREE_KB=1000; OUT="$E/fake/p_freeok.out"
check "free space: with space back the run exits 0" rc_is 0
check "free space: it publishes the paused backup" pointer_is "$M_ID"
check "free space: the published copy matches its sha256" published_sha_matches

# 21. 3.2.1: the share-copy lock, shared with backup_pg_db.sh, is held while the copy writes (3.2.3: only then, 23).
new_env 21
run_job l_base run FAKE_DUMP_SEED=60; OUT="$E/fake/l_base.out"
check "share lock: baseline run exits 0" rc_is 0
check "share lock: the copy takes and releases the lock" grep -q 'share-copy lock taken' "$OUT"
check "share lock: the release is logged" grep -q 'share-copy lock released' "$OUT"
KEEP="$(pointer)"
( flock 8; date +%s > "$E/fake/holder_released.tmp"; sleep 4; date +%s > "$E/fake/holder_released" ) 8>>"$E/share-copy.lock" &
sleep 0.5
run_job l_wait run FAKE_DUMP_SEED=61; OUT="$E/fake/l_wait.out"
wait
TAKEN="$(date -u -d "$(grep -m1 'share-copy lock taken' "$OUT" | sed -n 's/^\[\([^]]*\)\].*/\1/p')" +%s 2>/dev/null || echo 0)"
check "share lock: a held lock makes the copy wait" grep -q 'waiting for the share-copy lock' "$OUT"
check "share lock: the copy starts only after the other job released it" test "$TAKEN" -ge "$(cat "$E/fake/holder_released" 2>/dev/null || echo 9999999999)"
check "share lock: then the run publishes (exit 0)" rc_is 0
check "share lock: the new backup is published" test "$(pointer)" != "$KEEP"
KEEP="$(pointer)"
# The deadline leaves 10 s to reach the copy (4 s were once too few on a loaded host); the holder keeps the lock
# past it.
( flock 8; sleep 16 ) 8>>"$E/share-copy.lock" &
sleep 0.5
run_job l_pause run FAKE_DUMP_SEED=62 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 10 )); OUT="$E/fake/l_pause.out"
L_ID="$(basename "$(cat "$STATE_DIR/pending-stage.txt" 2>/dev/null)" | cut -d. -f1)"
wait
check "share lock: held until the deadline pauses the run (exit 4)" rc_is 4
check "share lock: the pause names the lock" grep -q 'the share-copy lock stayed held until the end of the copy window' "$OUT"
check "share lock: no step ran" bash -c "! grep -q 'pace step ' '$OUT'"
check "share lock: nothing was copied" test ! -s "$DEST_ROOT/incoming/$L_ID/$L_ID.dump"
check "share lock: the previous pointer is unchanged" test "$(pointer)" = "$KEEP"
check "share lock: exactly one published backup" exactly_one_published
run_job l_after run FAKE_DUMP_SEED=63; OUT="$E/fake/l_after.out"
check "share lock: the next run resumes it and publishes" rc_is 0
check "share lock: it publishes the paused backup" test "$(pointer)" = "$L_ID"

# 22. 3.2.2: machine values come from agent-memory-backup.env beside the script (or AGENT_MEMORY_BACKUP_ENV); the
#     environment wins over the file; nothing in the file is expanded or executed.
new_env 22
cat > "$WORK/bin/crontab" <<'SHIM'
#!/usr/bin/env bash
# Fake crontab: -l prints FAKE_STATE/crontab, a file argument replaces it.
if [[ "${1:-}" == "-l" ]]; then cat "$FAKE_STATE/crontab" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_STATE/crontab"
SHIM
chmod +x "$WORK/bin/crontab"
EF="$E/fake/job.env"
printf '%s\n' "# the nightly configuration" "" \
  "export DEST_ROOT=\"$E/mnt/from-file/agent-memory-postgres\"" \
  "LOCAL_STAGING='$E/staging-from-file'" \
  "STATE_DIR=$E/state-from-file" \
  'BOGUS_EXPANSION=$(touch "'"$E"'/fake/pwned")' \
  "this line is not a setting" > "$EF"
printf 'MOUNT_RETRY_DELAY_SECONDS=0\r\n' >> "$EF"   # a CRLF line
mkdir -p "$E/staging-from-file"
OUT="$E/fake/f_file.out"
env -u DEST_ROOT -u LOCAL_STAGING -u STATE_DIR AGENT_MEMORY_BACKUP_ENV="$EF" FAKE_DUMP_SEED=70 bash "$SCRIPT" run > "$OUT" 2>&1; RC=$?
check "env file: a run configured by the file exits 0" rc_is 0
check "env file: it publishes under the file's DEST_ROOT" test -s "$E/mnt/from-file/agent-memory-postgres/latest_backup_id.txt"
check "env file: export and double quotes are removed" grep -q "dump=$E/mnt/from-file/agent-memory-postgres/dumps/" "$OUT"
check "env file: the file's STATE_DIR holds the state" test -s "$E/state-from-file/latest.json"
check "env file: a CRLF line is read without its CR" bash -c "! grep -q 'MOUNT_RETRY_DELAY_SECONDS must be' '$OUT'"
check "env file: a malformed line is reported by number" grep -q "job.env line 7 is not KEY=VALUE; ignored" "$OUT"
check "env file: nothing in the file is executed" test ! -e "$E/fake/pwned"
check "env file: the default paths were not used" test ! -e "$DEST_ROOT/latest_backup_id.txt"
OUT="$E/fake/f_status.out"
env -u DEST_ROOT -u LOCAL_STAGING -u STATE_DIR AGENT_MEMORY_BACKUP_ENV="$EF" bash "$SCRIPT" status > "$OUT" 2>&1; RC=$?
check "env file: status reads the same destination" grep -q "destination: $E/mnt/from-file/agent-memory-postgres (" "$OUT"
check "env file: single quotes are removed" grep -q "local staging: $E/staging-from-file (" "$OUT"
sleep 1.1
OUT="$E/fake/f_envwins.out"
env -u LOCAL_STAGING -u STATE_DIR AGENT_MEMORY_BACKUP_ENV="$EF" FAKE_DUMP_SEED=71 bash "$SCRIPT" run > "$OUT" 2>&1; RC=$?
check "env file: with DEST_ROOT in the environment the run exits 0" rc_is 0
check "env file: the environment's DEST_ROOT wins over the file" test -s "$DEST_ROOT/latest_backup_id.txt"
check "env file: the file's DEST_ROOT kept its one backup" test "$(count_glob "$E/mnt/from-file/agent-memory-postgres/dumps" 'agent_memory_*')" = 1
# The default file sits beside the script; install-cron puts the file's CACHE_WRAP (spaces kept) in front of the runner.
CP="$E/copy"; mkdir -p "$CP"
cp "$SCRIPT" "$CP/backup_agent_memory_pg.sh"; cp "$(dirname "$SCRIPT")/backup_runner.py" "$CP/" 2>/dev/null || : > "$CP/backup_runner.py"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$WORK/bin/fakewrap"; chmod +x "$WORK/bin/fakewrap"
printf '%s\n' "CACHE_WRAP=\"$WORK/bin/fakewrap --high 4G --keep 8 --\"" "CRON_SCHEDULE=\"20 2 * * *\"" > "$CP/agent-memory-backup.env"
printf '%s\n' "# BEGIN agent-memory-backup" "old line" "# END agent-memory-backup" "1 1 * * * other-job" > "$E/fake/crontab"
OUT="$E/fake/f_cron.out"
env -u AGENT_MEMORY_BACKUP_ENV -u CACHE_WRAP -u CRON_SCHEDULE bash "$CP/backup_agent_memory_pg.sh" install-cron > "$OUT" 2>&1; RC=$?
check "env file beside the script: install-cron exits 0" rc_is 0
check "env file beside the script: the cron line carries its CACHE_WRAP" grep -qxF "20 2 * * * BWLIMIT_KBPS=100000 $WORK/bin/fakewrap --high 4G --keep 8 -- /usr/bin/python3 $CP/backup_runner.py >> $LOG_DIR/cron.log 2>&1" "$E/fake/crontab"
check "env file beside the script: the old managed line is replaced" bash -c "! grep -q 'old line' '$E/fake/crontab'"
check "env file beside the script: other cron lines are kept" grep -qx "1 1 \* \* \* other-job" "$E/fake/crontab"
OUT="$E/fake/f_cron_env.out"
env -u AGENT_MEMORY_BACKUP_ENV CACHE_WRAP= bash "$CP/backup_agent_memory_pg.sh" install-cron > "$OUT" 2>&1; RC=$?
check "env file beside the script: CACHE_WRAP= in the environment installs the plain line" grep -qxF "20 2 * * * BWLIMIT_KBPS=100000 /usr/bin/python3 $CP/backup_runner.py >> $LOG_DIR/cron.log 2>&1" "$E/fake/crontab"
# 3.3.0: install-cron --after-next-run leaves the schedule for the runner and changes nothing now; a later plain
# install-cron installs it and removes the file; a schedule that is not five cron fields is refused.
cp "$E/fake/crontab" "$E/fake/crontab.before-deferred"
OUT="$E/fake/f_cron_after.out"
env -u AGENT_MEMORY_BACKUP_ENV CACHE_WRAP= CRON_SCHEDULE="10 22 * * *" bash "$CP/backup_agent_memory_pg.sh" install-cron --after-next-run > "$OUT" 2>&1; RC=$?
check "deferred cron: install-cron --after-next-run exits 0" rc_is 0
check "deferred cron: the crontab is unchanged" cmp -s "$E/fake/crontab" "$E/fake/crontab.before-deferred"
check "deferred cron: the schedule is left for the runner" grep -qx "10 22 \* \* \*" "$STATE_DIR/install-cron-after-run.txt"
OUT="$E/fake/f_cron_bad.out"
env -u AGENT_MEMORY_BACKUP_ENV CACHE_WRAP= CRON_SCHEDULE='10 22 * * * ; touch /tmp/x' bash "$CP/backup_agent_memory_pg.sh" install-cron > "$OUT" 2>&1; RC=$?
check "cron: a schedule that is not five cron fields is refused (exit 1)" rc_is 1
check "cron: the refused schedule changed nothing" cmp -s "$E/fake/crontab" "$E/fake/crontab.before-deferred"
OUT="$E/fake/f_cron_now.out"
env -u AGENT_MEMORY_BACKUP_ENV CACHE_WRAP= CRON_SCHEDULE="10 22 * * *" bash "$CP/backup_agent_memory_pg.sh" install-cron > "$OUT" 2>&1; RC=$?
check "deferred cron: a plain install-cron installs the schedule" grep -qxF "10 22 * * * BWLIMIT_KBPS=100000 /usr/bin/python3 $CP/backup_runner.py >> $LOG_DIR/cron.log 2>&1" "$E/fake/crontab"
check "deferred cron: and removes the file it left" test ! -e "$STATE_DIR/install-cron-after-run.txt"
# Without any env file the defaults are generic.
OUT="$E/fake/f_defaults.out"
env -u MOUNTPOINT -u DEST_ROOT AGENT_MEMORY_BACKUP_ENV="$E/fake/missing.env" bash "$SCRIPT" restore-help > "$OUT" 2>&1; RC=$?
check "no env file: restore-help exits 0" rc_is 0
check "no env file: DEST_ROOT defaults to /mnt/nas/backups/agent-memory-postgres" grep -q '/mnt/nas/backups/agent-memory-postgres/latest_backup_id.txt' "$OUT"

# 23. 3.2.3: this job holds the share-copy lock only while it writes, so a backup_pg_db.sh copy that waits for the
#     share runs during this job's pool wait (23a) or at its next step boundary (23b), and the two never write to
#     the share at the same time. A waiting copy that keeps the share until the deadline pauses this job without a
#     write, and the next run resumes it (23c). Both real scripts, one share, one pair of locks, one pool state file.
PGDB_SCRIPT="$(dirname "$SCRIPT")/backup_pg_db.sh"
if [[ -f "$PGDB_SCRIPT" ]]; then
  new_env 23
  BD="$E/pgdb"; mkdir -p "$BD/local/labdb/dumps" "$BD/local/labdb/manifests" "$BD/local/labdb/restore-lists" \
    "$BD/locks" "$BD/logs" "$MOUNTPOINT/backups"
  RL="$E/fake/rsync.log"; : > "$RL"
  # pgdb_backup <stamp>: a published local labdb backup (random dump, sidecar, manifest, restore list) for the mirror
  pgdb_backup() {
    local id="labdb_$1" d="$BD/local/labdb"
    head -c 300000 /dev/urandom > "$d/dumps/$id.dump"
    (cd "$d/dumps" && sha256sum "$id.dump" > "$id.dump.sha256")
    printf '{"backup_id": "%s"}\n' "$id" > "$d/manifests/$id.manifest.json"
    printf ';\n; TOC Entries: 1\n' > "$d/restore-lists/$id.restore.list"
    printf '%s\n' "$id" > "$d/latest_backup_id.txt"
    PG_ID="$id"
  }
  pg_on_share() { (cd "$MOUNTPOINT/backups/pg-db-postgres/labdb" 2>/dev/null && sha256sum --quiet -c "$1.dump.sha256" 2>/dev/null); }
  # pgdb_mirror <name> [VAR=value ...]: `backup_pg_db.sh mirror` in the background on this env's share, locks and pool
  # state; its exit code lands in fake/<name>.rc
  pgdb_mirror() {
    local name="$1"; shift
    ( env PG_DB_BACKUP_ENV="$WORK/empty.env" DB_NAME=labdb RECORD_RUN=0 DEST_ROOT="$BD/local" \
        MIRROR_ROOT="$MOUNTPOINT/backups/pg-db-postgres" LOG_DIR="$BD/logs" LOG_FILE="$BD/logs/pg.log" \
        LOCK_DIR="$BD/locks" SHARE_COPY_LOCK="$E/share-copy.lock" POOL_STATE_FILE="$MOUNTPOINT/.nas-tuning/pool_state" \
        MIN_MIRROR_FREE_KB=0 FREE_CHECK_PATHS=/ PACE_BUSY_WAIT_SECONDS=1 BWLIMIT_KBPS=6000 FAKE_RSYNC_LOG="$RL" "$@" \
        bash "$PGDB_SCRIPT" mirror > "$E/fake/$name.out" 2>&1; echo $? > "$E/fake/$name.rc" ) &
    PG_BG=$!
  }
  # am_run <name> [VAR=value ...]: this script's run in the background; its exit code lands in fake/<name>.rc
  am_run() {
    local name="$1"; shift
    rm -f "$E/fake/pg_restore_calls"; sleep 1.1
    ( env FAKE_RSYNC_LOG="$RL" "$@" bash "$SCRIPT" run > "$E/fake/$name.out" 2>&1; echo $? > "$E/fake/$name.rc" ) &
    AM_BG=$!
  }
  # wait_line <file> <text> [seconds]: until a job's output has the line (the suites' short wait loop)
  wait_line() { local i; for i in $(seq 1 $(( ${3:-30} * 10 ))); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
  rc_file_is() { [[ "$(cat "$E/fake/$1.rc" 2>/dev/null)" == "$2" ]]; }
  # log_epoch <file> <text> [nth]: the time of the nth line with <text> in a job's output (0 when absent)
  log_epoch() {
    date -u -d "$(grep -F -- "$2" "$1" | sed -n "${3:-1}p" | sed -n 's/^\[\([^]]*\)\].*/\1/p')" +%s 2>/dev/null || echo 0
  }
  # pg_took_in_pool_wait: the pg-db copy took the lock between this job's release for its pool wait and its next take
  pg_took_in_pool_wait() {
    local rel took back
    rel="$(log_epoch "$E/fake/h_busy.out" 'share-copy lock released for the pool wait')"
    back="$(log_epoch "$E/fake/h_busy.out" 'share-copy lock taken' 2)"
    took="$(log_epoch "$E/fake/h_busy_pg.out" 'share-copy lock taken')"
    (( rel > 0 && took >= rel && back > took ))
  }
  # no_overlap [from line]: no rsync into the pg-db share dir ran while one into incoming/ ran (FAKE_RSYNC_LOG
  # intervals, from line <n> on)
  no_overlap() {
    tail -n +"${1:-1}" "$RL" | sort -k2,2n | awk '{ c = ($3 ~ /\/incoming\//) ? "am" : (($3 ~ /pg-db-postgres/) ? "pg" : "") }
      c == "" { next }
      $1 == "start" { o = (c == "am") ? "pg" : "am"; if (open[o] > 0) bad = 1; open[c]++ }
      $1 == "end" { open[c]-- }
      END { exit bad }'
  }
  # pg_before_am_end <from line>: the pg-db copy logged after line <n> ended before this job's last dump step started
  pg_before_am_end() {
    tail -n +"$1" "$RL" | awk '$1 == "end" && $3 ~ /pg-db-postgres/ && $2 > pe { pe = $2 }
      $1 == "start" && $3 ~ /\/incoming\// && $4 ~ /\.dump$/ && $2 > as { as = $2 }
      END { exit !(pe > 0 && as > pe) }'
  }

  # 23a. The pool reads BUSY after a step: this job releases the lock for its wait, the pg-db copy (started during
  #      the wait) takes it at once, waits out one BUSY read itself, copies when the pool reads OK, and this job
  #      takes the lock back after its wait and publishes. (The trim after a cut step runs `sync -f`, which took 35 s
  #      on a busy root disk once, hence the long waits for log lines.)
  FROM=$(( $(wc -l < "$RL") + 1 ))
  am_run h_busy FAKE_DUMP_SEED=80 FAKE_DUMP_LINES=60000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 PACE_BUSY_WAIT_SECONDS=6
  wait_line "$E/fake/h_busy.out" 'share-copy lock taken' 120
  pool_state BUSY
  wait_line "$E/fake/h_busy.out" 'pool not OK, no write: BUSY' 120
  pgdb_backup 20261125T095001Z; PG_A="$PG_ID"
  pgdb_mirror h_busy_pg
  wait_line "$E/fake/h_busy_pg.out" 'pool not OK, no NAS write: BUSY' 120
  pool_state OK
  wait "$PG_BG" "$AM_BG"
  OUT="$E/fake/h_busy.out"
  check "hand-over (pool wait): the agent-memory run exits 0" rc_file_is h_busy 0
  check "hand-over (pool wait): it publishes exactly one backup" exactly_one_published
  check "hand-over (pool wait): the published copy matches its sha256" published_sha_matches
  check "hand-over (pool wait): the lock is released for the pool wait" grep -q 'share-copy lock released for the pool wait' "$OUT"
  check "hand-over (pool wait): the lock is taken back after it" test "$(grep -c 'share-copy lock taken' "$OUT")" -ge 2
  OUT="$E/fake/h_busy_pg.out"
  check "hand-over (pool wait): the pg-db copy exits 0" rc_file_is h_busy_pg 0
  check "hand-over (pool wait): the pg-db copy took the lock during the agent-memory pool wait" pg_took_in_pool_wait
  check "hand-over (pool wait): the pg-db dump is verified on the share" pg_on_share "$PG_A"
  check "hand-over (pool wait): the pg-db copy ended before the last agent-memory step started" pg_before_am_end "$FROM"
  check "hand-over (pool wait): the two jobs never wrote at the same time" no_overlap

  # 23b. The pool stays OK: the pg-db copy blocks on the lock during a step; at the step boundary this job sees the
  #      waiting copy, hands the share over, and continues once that copy is done.
  FROM=$(( $(wc -l < "$RL") + 1 ))
  am_run h_step FAKE_DUMP_SEED=81 FAKE_DUMP_LINES=100000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=3
  wait_line "$E/fake/h_step.out" 'share-copy lock taken' 120
  pgdb_backup 20261126T095001Z; PG_B="$PG_ID"
  pgdb_mirror h_step_pg
  wait "$PG_BG" "$AM_BG"
  OUT="$E/fake/h_step.out"
  check "hand-over (step): the agent-memory run exits 0" rc_file_is h_step 0
  check "hand-over (step): it publishes exactly one backup" exactly_one_published
  check "hand-over (step): the published copy matches its sha256" published_sha_matches
  check "hand-over (step): it hands the share to the waiting copy" grep -q 'a backup_pg_db.sh copy is waiting for the share; it goes first' "$OUT"
  check "hand-over (step): it continues once that copy has finished" grep -q 'the waiting backup_pg_db.sh copy has finished' "$OUT"
  OUT="$E/fake/h_step_pg.out"
  check "hand-over (step): the pg-db copy exits 0" rc_file_is h_step_pg 0
  check "hand-over (step): the pg-db copy waited for a step" grep -q 'waiting for the share-copy lock' "$OUT"
  check "hand-over (step): the pg-db dump is verified on the share" pg_on_share "$PG_B"
  check "hand-over (step): the pg-db copy ended before the last agent-memory step started" pg_before_am_end "$FROM"
  check "hand-over (step): the two jobs never wrote at the same time" no_overlap
  KEEP="$(pointer)"

  # 23c. The pg-db copy holds the share and reads BUSY (its own state file here) until after this job's deadline:
  #      this job finds it waiting at its first turn, waits for it, pauses with exit 4 without writing, and the next
  #      run resumes and publishes. The pg-db copy starts first, so no step (and no trim) comes before the hand-over.
  printf 'BUSY %s test\n' "$(date -u +%FT%TZ)" > "$E/fake/pool_busy"
  DL=$(( $(date +%s) + 20 ))
  FROM=$(( $(wc -l < "$RL") + 1 ))
  pgdb_backup 20261127T095001Z; PG_C="$PG_ID"
  pgdb_mirror h_keep_pg POOL_STATE_FILE="$E/fake/pool_busy" TRANSFER_DEADLINE_EPOCH=$(( DL + 4 ))
  wait_line "$E/fake/h_keep_pg.out" 'pool not OK, no NAS write: BUSY' 120
  am_run h_keep FAKE_DUMP_SEED=82 FAKE_DUMP_LINES=100000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 TRANSFER_DEADLINE_EPOCH="$DL"
  wait "$PG_BG" "$AM_BG"
  K_ID="$(pending_id)"
  OUT="$E/fake/h_keep.out"
  check "kept share: the agent-memory run pauses (exit 4)" rc_file_is h_keep 4
  check "kept share: the pause names the waiting copy" grep -q 'transfer paused: a waiting backup_pg_db.sh copy kept the share until the end of the copy window' "$OUT"
  check "kept share: the paused marker is kept" paused_file
  check "kept share: the previous pointer is unchanged" pointer_is "$KEEP"
  check "kept share: exactly one published backup" exactly_one_published
  OUT="$E/fake/h_keep_pg.out"
  check "kept share: the pg-db copy is skipped (exit 1)" rc_file_is h_keep_pg 1
  check "kept share: the pg-db copy wrote nothing" bash -c "! test -e '$MOUNTPOINT/backups/pg-db-postgres/labdb/$PG_C.dump'"
  check "kept share: the two jobs never wrote at the same time" no_overlap
  am_run h_keep_after FAKE_DUMP_SEED=83
  wait "$AM_BG"
  OUT="$E/fake/h_keep_after.out"
  check "kept share: the next run exits 0" rc_file_is h_keep_after 0
  check "kept share: it publishes the paused backup" pointer_is "$K_ID"
  check "kept share: the published copy matches its sha256" published_sha_matches

  # 23d. A pg-db copy that starts waiting during this job's last step gets the share only after the manifest and
  #      restore list are on it too: they are copied under the lock (here that copy takes 2 s longer).
  FROM=$(( $(wc -l < "$RL") + 1 ))
  am_run h_last FAKE_DUMP_SEED=84 FAKE_DUMP_LINES=60000 BWLIMIT_KBPS=100 PACE_STEP_SECONDS=30 FAKE_RSYNC_META_SLEEP=2
  wait_line "$E/fake/h_last.out" 'share-copy lock taken' 120
  pgdb_backup 20261128T095001Z; PG_D="$PG_ID"
  pgdb_mirror h_last_pg
  wait "$PG_BG" "$AM_BG"
  check "last step: the agent-memory run exits 0" rc_file_is h_last 0
  check "last step: it publishes exactly one backup" exactly_one_published
  check "last step: the pg-db copy exits 0" rc_file_is h_last_pg 0
  check "last step: the pg-db dump is verified on the share" pg_on_share "$PG_D"
  check "last step: the pg-db copy never wrote during the manifest copy" no_overlap "$FROM"
  check "last step: the two jobs never wrote at the same time" no_overlap
fi

# 24. 3.3.0: a run that reaches the copy before the window opens waits once for it, then copies; it never pauses
#     for being early, whether it took a fresh dump (24a) or only resumes a paused copy (24b). The window form's
#     opening time shows in the dry-run plan (24c).
new_env 24
# steps_from <rsync log> <epoch>: copy steps of the dump ran, and none started before <epoch>
steps_from() { awk -v t="$2" '$1 == "start" && $4 ~ /\.dump$/ { n++; if ($2 < t) bad = 1 } END { exit !(n > 0 && !bad) }' "$1"; }
# line_at_or_after <text> <epoch>: the first line with <text> in OUT is logged at or after <epoch>
line_at_or_after() {
  local at; at="$(date -u -d "$(grep -F -m1 -- "$1" "$OUT" | sed -n 's/^\[\([^]]*\)\].*/\1/p')" +%s 2>/dev/null || echo 0)"
  (( at >= $2 ))
}
run_job e_base run FAKE_DUMP_SEED=90; OUT="$E/fake/e_base.out"
check "early: baseline run exits 0" rc_is 0
KEEP="$(pointer)"

# 24a. A fresh dump done before the window opens: one wait, then the copy; published, no pause, no alert.
OPEN=$(( $(date +%s) + 10 ))
run_job e_fresh run FAKE_DUMP_SEED=91 TRANSFER_START_EPOCH="$OPEN" FAKE_RSYNC_LOG="$E/fake/rsync_e1.log"; OUT="$E/fake/e_fresh.out"
check "early: a fresh dump that reaches the copy early exits 0" rc_is 0
check "early: it logs when the window opens and waits for it" grep -q 'the copy window opens at .*; waiting [0-9]*s for it' "$OUT"
check "early: it waits once" test "$(grep -c 'the copy window opens at' "$OUT")" = 1
check "early: no copy step starts before the window opens" steps_from "$E/fake/rsync_e1.log" "$OPEN"
check "early: it publishes the new backup" bash -c "[[ '$(pointer)' != '$KEEP' ]]"
check "early: exactly one published backup" exactly_one_published
check "early: no paused marker" no_paused_file
check "early: no alert" no_alert

# 24b. A run that only resumes a paused copy (no dump) also waits for the window instead of exiting 4, and its
#      first write (the trim) comes after the window opens.
run_job e_cut run FAKE_DUMP_SEED=92 FAKE_DUMP_LINES=100000 BWLIMIT_KBPS=40 PACE_STEP_SECONDS=2 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 12 )); OUT="$E/fake/e_cut.out"
check "early resume: the setup run paused (exit 4)" rc_is 4
E_ID="$(pending_id)"; E_PART="$(inc_size "$E_ID")"
OPEN=$(( $(date +%s) + 10 ))
run_job e_resume run FAKE_DUMP_SEED=93 TRANSFER_START_EPOCH="$OPEN" FAKE_RSYNC_LOG="$E/fake/rsync_e2.log"; OUT="$E/fake/e_resume.out"
check "early resume: exits 0, not 4" rc_is 0
check "early resume: it resumes the paused copy" grep -qF "resuming the paused copy in $DEST_ROOT/incoming/$E_ID" "$OUT"
check "early resume: no new dump" no_new_dump
check "early resume: it waits for the window" grep -q 'the copy window opens at' "$OUT"
check "early resume: no copy step starts before the window opens" steps_from "$E/fake/rsync_e2.log" "$OPEN"
if (( E_PART > 0 )); then
  check "early resume: the trim of the partial comes after the window opens" line_at_or_after 'trimmed the partial copy from' "$OPEN"
else  # a loaded host can reach the setup's deadline before any step: no partial, so nothing to trim
  check "early resume: (the setup copied nothing, so there is no trim to time)" true
fi
check "early resume: it publishes the paused backup" pointer_is "$E_ID"
check "early resume: exactly one published backup" exactly_one_published
check "early resume: no paused marker" no_paused_file
check "early resume: no alert" no_alert

# 24c. The window form: before today's window opens, the dry-run plan says the run would wait for it.
if [[ "$(date -u +%H%M)" < "2350" ]]; then
  run_job e_dry dry-run TRANSFER_DEADLINE_EPOCH= TRANSFER_WINDOW_UTC="23:58-23:59"; OUT="$E/fake/e_dry.out"
  check "window form: the dry-run exits 0" rc_is 0
  check "window form: the plan says when the window opens" grep -qF 'window 23:58-23:59 UTC (opens at 23:58Z: a run would wait for it, then copy)' "$OUT"
else
  check "window form: (not checked after 23:50 UTC)" true
  check "window form: (not checked after 23:50 UTC)" true
fi

# 19. Runner: receipts for every run; an alert when the script dies without one.
RUNNER_SRC="$(dirname "$SCRIPT")/backup_runner.py"
if [[ -f "$RUNNER_SRC" ]]; then
  RD="$WORK/runner"; mkdir -p "$RD/bin" "$RD/state" "$RD/logs"
  cp "$RUNNER_SRC" "$RD/bin/backup_runner.py"
  # The stub script: a run exits FAKE_EXIT; install-cron (3.3.0) records its schedule and exits FAKE_INSTALL_EXIT.
  printf '#!/usr/bin/env bash
if [[ "${1:-}" == install-cron ]]; then echo "install-cron ${CRON_SCHEDULE:-}" >> "${FAKE_INSTALL_LOG:-/dev/null}"; exit "${FAKE_INSTALL_EXIT:-0}"; fi
exit "${FAKE_EXIT:-0}"
' > "$RD/bin/backup_agent_memory_pg.sh"; chmod +x "$RD/bin/backup_agent_memory_pg.sh"
  runner() { env AGENT_MEMORY_BACKUP_ENV="$WORK/empty.env" AGENT_MEMORY_BACKUP_HOME="$RD" STATE_DIR="$RD/state" LOG_DIR="$RD/logs" ALERT_SYSLOG=0 "$@" python3 "$RD/bin/backup_runner.py"; RC=$?; sleep 1.1; }
  OUT=""
  runner FAKE_EXIT=0
  check "runner passes exit 0 through" rc_is 0
  check "runner writes a receipt with the meaning" grep -q '"meaning": "published; exactly one verified backup kept"' "$RD/state/reliability-run-exit.public.json"
  check "runner raises no alert on success" test ! -e "$RD/state/alert.json"
  runner FAKE_EXIT=137
  check "runner passes exit 137 through" rc_is 137
  check "runner raises an alert when the script left none" grep -q 'exited 137 without raising an alert' "$RD/state/alert.json"
  check "runner keeps one receipt per run" test "$(ls "$RD/state"/normal-run-*.public.json | wc -l)" = 2
  rm -f "$RD/state/alert.json"
  runner FAKE_EXIT=75
  check "runner raises no alert for a lock skip" test ! -e "$RD/state/alert.json"
  runner FAKE_EXIT=4
  check "runner passes exit 4 (paused) through" rc_is 4
  check "runner names exit 4 a pause" grep -q '"meaning": "paused: the paced copy stopped' "$RD/state/reliability-run-exit.public.json"
  # 3.2.1: the runner reads STATE_DIR from agent-memory-backup.env beside it; the environment wins.
  printf 'STATE_DIR="%s"\n' "$RD/state-from-file" > "$RD/bin/agent-memory-backup.env"
  env -u STATE_DIR -u AGENT_MEMORY_BACKUP_ENV AGENT_MEMORY_BACKUP_HOME="$RD" LOG_DIR="$RD/logs" ALERT_SYSLOG=0 FAKE_EXIT=0 python3 "$RD/bin/backup_runner.py"; RC=$?; sleep 1.1
  check "runner env file: exit 0 passes through" rc_is 0
  check "runner env file: the receipt lands in the file's STATE_DIR" test -s "$RD/state-from-file/reliability-run-exit.public.json"
  BEFORE_N="$(ls "$RD/state-from-file"/normal-run-*.public.json | wc -l)"
  env -u AGENT_MEMORY_BACKUP_ENV AGENT_MEMORY_BACKUP_HOME="$RD" STATE_DIR="$RD/state" LOG_DIR="$RD/logs" ALERT_SYSLOG=0 FAKE_EXIT=0 python3 "$RD/bin/backup_runner.py"; RC=$?; sleep 1.1
  check "runner env file: the environment's STATE_DIR wins" test "$(ls "$RD/state-from-file"/normal-run-*.public.json | wc -l)" = "$BEFORE_N"
  rm -f "$RD/bin/agent-memory-backup.env"
  # 3.3.0: a 10 h watchdog by default, and a schedule left by `install-cron --after-next-run` is installed after a
  # run that held the lock (not after a lock skip); a failed install keeps the file for the next run.
  check "runner: the default watchdog is 10 h" grep -q '"timeout_seconds": 36000' "$RD/state/reliability-run-exit.public.json"
  IL="$RD/install.log"; PENDING="$RD/state/install-cron-after-run.txt"
  printf '10 22 * * *\n' > "$PENDING"
  runner FAKE_EXIT=75 FAKE_INSTALL_LOG="$IL"
  check "runner: after a lock skip the schedule is not installed" test ! -s "$IL"
  check "runner: after a lock skip the file is kept" test -s "$PENDING"
  runner FAKE_EXIT=0 FAKE_INSTALL_LOG="$IL" FAKE_INSTALL_EXIT=1
  check "runner: a failed install-cron keeps the file for the next run" test -s "$PENDING"
  check "runner: the receipt says it failed" grep -q '"cron_after_run": "install-cron exited 1' "$RD/state/reliability-run-exit.public.json"
  : > "$IL"
  runner FAKE_EXIT=4 FAKE_INSTALL_LOG="$IL"
  check "runner: after a run it installs the schedule that was left" grep -qx "install-cron 10 22 \* \* \*" "$IL"
  check "runner: the exit code of the run still passes through" rc_is 4
  check "runner: the file is removed after the install" test ! -e "$PENDING"
  check "runner: the receipt names the installed schedule" grep -q '"cron_after_run": "installed cron schedule 10 22 \* \* \*"' "$RD/state/reliability-run-exit.public.json"
  : > "$IL"
  runner FAKE_EXIT=0 FAKE_INSTALL_LOG="$IL"
  check "runner: with no file left it installs nothing" test ! -s "$IL"
fi

echo "# passed $PASS failed $FAIL"
[[ "$FAIL" == 0 ]]
