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
args=("\$@"); src=""; dst="\${args[-1]}"
for a in "\${args[@]}"; do [[ "\$a" == *.dump ]] && src="\$a"; done
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

# 20f. Outside the copy window a run (a fresh dump here) writes nothing and pauses at once.
W="00:00-00:01"; [[ "$(date -u +%H:%M)" == "00:00" ]] && W="12:00-12:01"
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

# 21. 3.2.1: the share-copy lock, shared with backup_pg_db.sh, is held for the whole copy.
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
( flock 8; sleep 8 ) 8>>"$E/share-copy.lock" &
sleep 0.5
run_job l_pause run FAKE_DUMP_SEED=62 TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 4 )); OUT="$E/fake/l_pause.out"
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
# Without any env file the defaults are generic.
OUT="$E/fake/f_defaults.out"
env -u MOUNTPOINT -u DEST_ROOT AGENT_MEMORY_BACKUP_ENV="$E/fake/missing.env" bash "$SCRIPT" restore-help > "$OUT" 2>&1; RC=$?
check "no env file: restore-help exits 0" rc_is 0
check "no env file: DEST_ROOT defaults to /mnt/nas/backups/agent-memory-postgres" grep -q '/mnt/nas/backups/agent-memory-postgres/latest_backup_id.txt' "$OUT"

# 19. Runner: receipts for every run; an alert when the script dies without one.
RUNNER_SRC="$(dirname "$SCRIPT")/backup_runner.py"
if [[ -f "$RUNNER_SRC" ]]; then
  RD="$WORK/runner"; mkdir -p "$RD/bin" "$RD/state" "$RD/logs"
  cp "$RUNNER_SRC" "$RD/bin/backup_runner.py"
  printf '#!/usr/bin/env bash
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
fi

echo "# passed $PASS failed $FAIL"
[[ "$FAIL" == 0 ]]
