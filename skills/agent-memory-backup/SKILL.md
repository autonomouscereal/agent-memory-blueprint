---
name: agent-memory-backup
description: Back up, verify, schedule and restore-test the agent-memory PostgreSQL database (agent_memory in the agent-memory-postgres container), keeping exactly one verified backup on a NAS share. Use when asked to back up memory, make a restore point before a risky change, check the latest backup, run or schedule the nightly job, restore-test a dump, or back up the smaller databases in the same container.
---

# Agent Memory Backup

Nightly backup of the memory database with raw PostgreSQL tools only: `pg_dump`, `pg_restore` and `psql` inside
the database container, run as the container's own `POSTGRES_USER` through `docker exec`. No credential is passed
and none is stored. No ORM, SQLAlchemy, Pydantic, SQLite or Chroma.

| File (in `scripts/`) | What it does |
|---|---|
| `backup_agent_memory_pg.sh` | Dump `agent_memory`, copy it to the share in paced steps, verify, publish, then delete every other backup |
| `backup_runner.py` | Cron entrypoint: runs the script under a 10 h watchdog, writes an exit receipt, installs a schedule left for after the run |
| `restore_test_agent_memory.sh` | Weekly full restore of the published dump into a throwaway container, exact row counts against live |
| `backup_pg_db.sh` | The smaller databases in the same container: snapshot dump, restore test, local + NAS copies, daily/weekly rotation |
| `run_remote_backup.py` | Runs the deployed script on the database host over SSH from a workstation |
| `agent-memory-backup.env.example`, `pg-db-backup.env.example` | Templates for the two env files that hold a machine's own values |
| `tests/` | Both suites (Linux; temp dirs and fake `docker`/`rsync`/`df`/`crontab`; no real path is touched) |

## Install

1. Copy `scripts/` to the database host, for example `~/agent-memory-backup/bin/` (tests to `~/agent-memory-backup/tests/`).
2. `cp agent-memory-backup.env.example agent-memory-backup.env` beside the scripts and set the mount point,
   destination, staging drive and pool state file. Do the same with `pg-db-backup.env.example` if you back up
   other databases in the container. Neither copy is committed (the repo's `.gitignore` is an allowlist).
3. Run both suites there: `bash tests/test_backup_agent_memory_pg.sh bin/backup_agent_memory_pg.sh` and
   `bash tests/test_backup_pg_db.sh bin/backup_pg_db.sh`. They set their own empty env file, so the real one beside
   the scripts never applies to a test.
4. `bin/backup_agent_memory_pg.sh dry-run` against the real paths, then `bin/backup_agent_memory_pg.sh install-cron`
   (and `bin/backup_pg_db.sh install-cron`).

## Configuration

Every setting is an environment variable with a generic default in the script. A machine's own values go in the
env file beside the installed scripts:

- `agent-memory-backup.env`: read by `backup_agent_memory_pg.sh`, `backup_runner.py` and
  `restore_test_agent_memory.sh`. `AGENT_MEMORY_BACKUP_ENV=/path` names another file.
- `pg-db-backup.env`: read by `backup_pg_db.sh` only, because `DEST_ROOT` and `CRON_SCHEDULE` mean other things
  there. `PG_DB_BACKUP_ENV=/path` names another file.

A variable already set in the environment (a cron line, a test, a one-off override) wins over the file. Lines are
`KEY=VALUE`; blank lines and `#` comments are skipped; an optional `export ` and one pair of surrounding quotes are
removed; nothing is expanded or executed, so `$VAR`, `$(...)`, `~` and comments after a value do not work. A line
that is not `KEY=VALUE` is reported by number and ignored.

Keep the nightly configuration in the env file, never on the cron line. From 11-11 to 11-21 (2026) a cron line
overrode `LOCAL_STAGING`, `MOUNTPOINT` and `DEST_ROOT`: the one verified backup sat on the same machine as the live
DB, and `status` reported a stale dump on the share with "alert: none". With the values in the file, cron,
`status`, `list`, `verify`, `dry-run`, an on-demand `run` and `install-cron` all read the same paths.

| Variable | Default | Meaning |
|---|---|---|
| `MOUNTPOINT` | `/mnt/nas` | The share's mount point (an automount is fine) |
| `DEST_ROOT` | `$MOUNTPOINT/backups/agent-memory-postgres` | Where the one verified backup is published |
| `LOCAL_STAGING` | `$HOME/agent-memory-backup/staging` | Local stage for the dump; not the disk that holds the live Postgres |
| `POOL_STATE_FILE` | `$MOUNTPOINT/.nas-tuning/pool_state` | `OK\|BUSY <utc> ...` line written by a probe on the NAS side |
| `CACHE_WRAP` | empty | Command `install-cron` puts in front of the runner when its first word is executable |
| `BWLIMIT_KBPS` | `6000` | rsync throttle for the copy, KiB/s |
| `PACE_STEP_SECONDS` / `PACE_BUSY_WAIT_SECONDS` | `600` / `900` | Copy step length; wait before reading a BUSY pool state again |
| `PACE_GATE` | `1` | `0` copies without reading the pool state |
| `TRANSFER_WINDOW_UTC` | `07:00-13:00` | Copy steps only inside this UTC window (must not cross midnight) |
| `TRANSFER_DEADLINE_EPOCH` | empty | Replaces the window: steps only before this epoch second |
| `TRANSFER_START_EPOCH` | empty | With the deadline: steps only from this epoch second (the run waits for it) |
| `CRON_SCHEDULE` / `BACKUP_TIMEOUT_SECONDS` | `20 2 * * *` / `36000` | The nightly's start (server local time) and the runner's watchdog (see "Scheduling") |
| `MIN_SYSTEM_FREE_KB` / `FREE_CHECK_PATHS` | 20 GB / `/` and `LOCAL_STAGING` | No staging and no copy step below this free space |
| `LOCAL_MIN_FREE_KB` / `MIN_DEST_FREE_KB` | 60 GiB / 1 GiB | Free space kept beyond the expected dump on the stage and the share |
| `STATE_DIR`, `LOG_DIR`, `LOCK_FILE` | under `$HOME/agent-memory-backup/` | State, logs, the run lock `backup-v2.lock` |
| `SHARE_COPY_LOCK` / `SHARE_WAIT_LOCK` | `share-copy.lock` / `share-copy-wait.lock` beside `LOCK_FILE` | Held while a job writes to the share / held shared by a `backup_pg_db.sh` copy that waits for it |
| `STAGING_DRIVE` | `$HOME` | Restore test: the drive that holds `LOCAL_STAGING` (its image goes there) |
| `SERVING_UNIT` | empty | Restore test: a systemd unit whose answer speed it watches (see below) |

`backup_agent_memory_pg.sh --help` lists the rest (retries, alert command, dry-run hashing).

## Commands

```bash
bin/backup_agent_memory_pg.sh status        # mount, pointer, published backups, alert, pool state, free space, cron block
bin/backup_agent_memory_pg.sh list
bin/backup_agent_memory_pg.sh dry-run       # the next run's plan on the real paths; changes nothing
DRY_RUN_HASH=0 bin/backup_agent_memory_pg.sh dry-run   # the same without hashing the stage and the published dump
bin/backup_agent_memory_pg.sh verify [id]   # size + SHA-256 against the manifest, complete pg_restore --list
bin/backup_agent_memory_pg.sh run           # an immediate restore point; replaces the published one once it verifies
bin/backup_agent_memory_pg.sh install-cron  # saves the old crontab first
bin/backup_agent_memory_pg.sh install-cron --after-next-run   # the runner installs it when the next run ends
bin/backup_agent_memory_pg.sh restore-help
```

From a workstation, `run_remote_backup.py <command>` runs the same commands on the host through a server-manager
style `ssh_client.py` (`--server`, `--command-file`, `--command-timeout`). The server key, the server-manager folder
and the remote script come from `--server` / `AGENT_MEMORY_BACKUP_SERVER` (default `ai`), `--server-manager-dir` /
`SERVER_MANAGER_SKILL_DIR` (default `~/.agents/skills/server-manager`) and `--remote-script` /
`AGENT_MEMORY_BACKUP_REMOTE_SCRIPT` (default `~/agent-memory-backup/bin/backup_agent_memory_pg.sh`, `~` = the
remote home). `run` has no client timeout by default, so a slow share cannot kill a healthy backup; `dry-run` and
`verify` get one hour (they hash the dump over the share); the rest five minutes. `--command-timeout <s>` sets a
finite deadline, and the wrapper then puts a server-side `timeout` 30 s inside it.

The run lock is `backup-v2.lock`, taken with util-linux `flock --close`: the lock holder never passes its descriptor
to the dump, transfer or checksum processes, so a child stuck on a failed mount cannot keep the lock after its
controller is gone.

## Retention: exactly one verified backup

The rule (2026-10-28): keep the live database and one backup that is proven safe; older backups and partial or
failed transfers are deleted. Each `run` does this, in order:

1. Under the lock, delete failed or partial transfers left by earlier runs: every `incoming/agent_memory_*` entry
   and every local stage except the verified pending stage (and, since 3.2.0, the paused copy of that same backup).
   Nothing else in `incoming/` is touched.
2. Check capacity for the new copy while the old one still exists: the expected size (pending stage, else the
   current published dump) plus 15 % (`SIZE_HEADROOM_PERCENT`), plus `MIN_DEST_FREE_KB` on the share. A fresh dump
   also needs `LOCAL_MIN_FREE_KB` (60 GiB) left on the staging drive.
3. Dump into a local stage and verify the stage against its own manifest, or resume the stage named in
   `state/pending-stage.txt` after re-hashing it. A stage that fails that check is a confirmed failure: it is
   deleted and a fresh dump is taken.
4. Copy the stage to `incoming/<backup-id>/` (the temporary name).
5. Verify the destination copy: size and SHA-256 match the manifest; the copied manifest and restore list match the
   staged ones byte for byte; `pg_restore --list` exits 0 and shows the `TOC Entries` header and TABLE DATA for
   `agent_memory_events` and `agent_memory_payload_archives`; its header and every entry line match the list taken
   at dump time.
6. Publish with same-filesystem renames (restore list, manifest, dump), then swap `latest_backup_id.txt` atomically.
7. Only then delete every other published dump, manifest and restore list, then the local stage. Deletion refuses
   unless the pointer names the new backup and its dump is present at the verified size, so the job never deletes
   the only verified backup.

If anything fails before step 6 finishes, the previous backup and pointer stay untouched, this run's
`incoming/<id>/` and any half-finished publication are deleted, a verified stage stays pending for the next run,
and an alert is raised. A full share is a confirmed failure: rsync is not retried once the share is under
`MIN_DEST_FREE_KB` (one run retried ENOSPC for 6 hours before this rule).

`state/retention-hold` is a deliberate operator override: while it exists, a run publishes but keeps superseded
backups, and `status`, the log and the receipt say so. Create it only for a named reason (for example, keeping a
restore-proven backup until its replacement passes a full restore) and remove it afterwards. A hold left in place
for ten days once filled the share with 38 dumps.

| Exit | Meaning |
|---:|---|
| 0 | Published; exactly one verified backup kept; alert cleared |
| 1 | Failed; previous backup kept; alert raised |
| 3 | Published and verified, but a superseded or stale path could not be deleted; warning alert |
| 4 | The paced copy paused at the end of its window (or the pool stayed BUSY, free space fell under the floor, or a waiting `backup_pg_db.sh` copy kept the share); partial and verified stage kept for the next run; previous backup kept; warning alert |
| 75 | Another run holds `backup-v2.lock` |

Alerts go to `state/alert.json` (the current one; a clean run removes it), `state/alerts.log` (history), the
journal (`journalctl -t agent-memory-backup`) and `ALERT_COMMAND` if set (it receives the alert JSON path). Each
cron run writes `state/normal-run-<stamp>.public.json` and `state/reliability-run-exit.public.json`; if the script
dies without an alert (for example after a watchdog SIGKILL) the runner raises one.

## Transfer to the share

Rsync exits `10`, `11`, `12`, `30` and `35` are transient transport or file-I/O failures and are retried on the
kept partial (`RSYNC_RETRY_ATTEMPTS=0` = unlimited, 60 s apart). Exit `23` is retried only when every error line is
the CIFS share's EAGAIN ("Resource temporarily unavailable (11)", seen on `ftruncate`), at most
`EAGAIN_RETRY_ATTEMPTS` times. Other failures stay fatal so configuration, permission and selection errors show.
Mount activation and destination-directory failures are retried before a dump starts (`MOUNT_RETRY_ATTEMPTS=0` =
unlimited), so a scheduled run survives a temporary `ENODEV` or automount failure. The capacity gate touches the
automount and samples `df` up to three times, because during CIFS recovery the first sample can describe the autofs
stub instead of the share.

### Paced copy (3.2.0)

The setup this was written for had the share on drive-managed SMR disks. An unpaced 20000 KiB/s copy pushed one of
them into cache cleaning three nights in a row and stalled the whole NAS host. Since 3.2.0 only the copy step
changed; dump, verify, publish and delete-after-publish are as before.

- Steps of `PACE_STEP_SECONDS` at `BWLIMIT_KBPS` (6000 KiB/s, about 3.5 GiB per 10-minute step). Each step is one
  `rsync --append --inplace` in its own process group (`setsid`), so the step limit and a watchdog TERM stop the
  whole copy. `--append` writes from the receiver's current length and never rereads the prefix (rsync refuses it
  together with `--whole-file`).
- Before each step the job reads `POOL_STATE_FILE`. BUSY, missing, unreadable or older than
  `POOL_STATE_MAX_AGE_SECONDS` (300) means no write; it reads again after `PACE_BUSY_WAIT_SECONDS`.
- No step writes outside `TRANSFER_WINDOW_UTC`. Since 3.3.0 a run that reaches the copy before the window opens (a
  fresh dump done early, or a run that only resumes a paused copy) waits once, until the window opens, and then
  copies; it never pauses for being early. A copy not finished by the window's end stops with exit 4: the
  partial in `incoming/<id>/`, the verified stage and `state/paused-transfer.txt` are kept and a warning alert is
  raised. The next run resumes that same backup (no new dump) after cutting `RESUME_TRIM_BYTES` (64 MiB) off the
  partial; the final SHA-256 and `pg_restore --list` still decide, and a bad partial is deleted and copied again.
- No staging and no copy step while `/` or the staging drive has under `MIN_SYSTEM_FREE_KB` (20 GB) free: exit 1 at
  preflight (naming the path), a pause with exit 4 during a copy.
- 37 GB at 6000 KiB/s is about 1 h 45 min of copy.

### Share-copy lock and `backup_pg_db.sh` (3.2.3)

The two jobs never write to the share at the same time: each writes only while it holds `SHARE_COPY_LOCK`
(`share-copy.lock` beside the run lock). Since 3.2.3 (and `backup_pg_db.sh` 2.2.0) the memory copy holds it only
while it writes, so the small copy runs in the memory copy's waits:

- The memory copy releases the lock for every pool wait. A `backup_pg_db.sh` copy blocked on it wakes at once,
  reads the pool state itself and copies once it reads OK.
- A waiting `backup_pg_db.sh` copy takes `SHARE_WAIT_LOCK` (`share-copy-wait.lock`) shared before it asks for the
  share-copy lock, and drops it only after it has released the share-copy lock. Before each step the memory copy
  tries `SHARE_WAIT_LOCK` exclusively. If the try fails, it releases the share-copy lock, blocks in `flock` until the
  other copy has finished, then reads the window, free space and pool state again and takes the lock back.
- Both sides block in `flock`, so neither one polls the other, and the memory copy never blocks on the wait lock
  while it holds the share-copy lock, so they cannot deadlock.
- After the last step the memory copy keeps the lock until the manifest and restore list are on the share too (3.2.2
  wrote them after releasing it). The verify that follows only reads the share.
- A waiting copy keeps its turn through its own pool waits. If it still holds it at the end of the window, the
  memory copy pauses (exit 4, "a waiting backup_pg_db.sh copy kept the share until the end of the copy window")
  and resumes the next night.
- On 11-25 each 10-minute step was followed by a BUSY read and a 15-minute wait. The 3.2.2 job held the lock
  through all nine waits, so a `backup_pg_db.sh` copy waited from 09:51 to 13:00Z and was skipped.

### Safety point when the share is down

If the share is unavailable and a database change cannot wait, take a verified safety dump on the host first, with
its own state, staging, lock and destination, and with the share's pacing switched off:

```bash
B="$HOME/agent-memory-backup"
MOUNTPOINT="$HOME" DEST_ROOT="$B/local-safety" STATE_DIR="$B/local-safety/state" \
LOCAL_STAGING=/var/tmp/agent-memory-backups-local-safety LOCK_FILE="$B/local-safety.lock" \
SHARE_COPY_LOCK="$B/local-safety/share-copy.lock" PACE_GATE=0 BWLIMIT_KBPS=1000000 \
TRANSFER_DEADLINE_EPOCH=$(( $(date +%s) + 21600 )) \
"$B/bin/backup_agent_memory_pg.sh" run
```

Since 3.2.0 `BWLIMIT_KBPS` must be a positive integer (`0` is refused), and without `PACE_GATE=0` and a deadline the
run would wait for a pool state and a window that do not apply to a local copy. Keep the separate `STATE_DIR`,
`LOCAL_STAGING` and `LOCK_FILE`: a run deletes the stale stages in its staging dir and resumes the stage named in its
`pending-stage.txt`, so with the nightly's directories a safety run would consume or delete the nightly's pending
stage. Staging and destination then sit on the same disk: check that it has two dumps plus `LOCAL_MIN_FREE_KB` free.
Each safety run keeps one dump in `local-safety`. Verify it, recover the share, run the normal job, and delete the
safety dump only after the share's backup has passed verification.

For CIFS trouble, read `findmnt -T "$MOUNTPOINT"` and bounded listings of the backup directories. Avoid a recursive
`du` across the share; it can turn a mount incident into a long, misleading scan. If a full-size copy fails on its
final close with `Host is down` and the NAS runs Samba 4.15, look for
`smbXsrv_client_connection_passed ... NT_STATUS_OBJECT_NAME_NOT_FOUND` in its per-client log: that is the
multichannel connection-passing race, and `server multi channel support = no` (check with
`testparm -s --parameter-name='server multi channel support'`, then remount the client) avoids it. A `dfree command`
cache on the NAS must stay writable for every user the share maps clients to.

## Scheduling

`install-cron` writes one tagged block (and saves the old crontab to `state/crontab-before-install-<stamp>.private.txt`):

```text
# BEGIN agent-memory-backup
20 2 * * * BWLIMIT_KBPS=6000 <CACHE_WRAP> /usr/bin/python3 ~/agent-memory-backup/bin/backup_runner.py >> ~/agent-memory-backup/logs/cron.log 2>&1
# END agent-memory-backup
```

The schedule is `CRON_SCHEDULE` (default `20 2 * * *`, server local time); keep it in the env file. `CACHE_WRAP` is
optional: a host that keeps backups out of the page cache can run the job inside a `MemoryHigh` scope and reclaim
the Postgres container's cache from `pg_dump` afterwards; `CACHE_WRAP=` installs the plain line.

Start the nightly early enough that the dump and the stage verify are done before `TRANSFER_WINDOW_UTC` opens, so
the copy gets the whole window. Since 3.3.0 the run waits once for the window when it gets there early. Measure the
dump on the real stage first, from the `creating local custom-format pg_dump` and `verify local stage: ok` lines of
`logs/cron.log`, and leave a margin. In the setup this was written for, 12 fresh dumps of 36-37 GB took 58-67 min
from the cron start, so a start at 05:10Z leaves about 40 min before a 07:00Z window. A start 2 h 20 min after the
window opened left room for only about 23 GB at the paced rate, so a 37 GB dump needed two nights. Cron runs in
server local time: with daylight saving time the start moves an hour earlier in UTC, and the run waits an hour
longer.

The runner wraps `backup_agent_memory_pg.sh run` in a watchdog (`BACKUP_TIMEOUT_SECONDS`, 10 h since runner 3.3.0;
it was 6 h). It has to cover the early start, the 6 h window and the verify after the last step. On TERM the script
deletes its unpublished transfer and raises an alert, so a watchdog that fires during the verify costs a whole copy.

To move the schedule without moving the run that is already due (it may be resuming a paused copy),
`install-cron --after-next-run` writes the new schedule to `state/install-cron-after-run.txt` and changes nothing
else. When the next run that held the lock ends, whatever its exit code, the runner installs that schedule and
deletes the file; a lock skip (exit 75) leaves it in place. A plain `install-cron` installs at once and replaces it.

## Restore

Do not restore over the live database casually. `restore-help` prints the command templates; restore into a scratch
database first. A live restore is destructive and needs the owner's explicit approval.

A throwaway restore container needs `/dev/shm` at least as large as `maintenance_work_mem`
(`docker run --shm-size 1600m ...`) or `max_parallel_maintenance_workers=0`; otherwise both HNSW `CREATE INDEX`
statements fail with `could not resize shared memory segment ... No space left on device`.

### Weekly full restore test

`restore_test_agent_memory.sh run` restores the dump named by `latest_backup_id.txt` into a throwaway container
(the live image, no network, 2 CPUs, `--cpu-shares 128`, 10 GiB memory) and proves it: the dump's SHA-256 against its
manifest, `pg_restore -j 2 --exit-on-error`, an exact `count(*)` of every restored table, and the same counts on the
live DB in one read-only snapshot, each table bounded by its restored maximum key (an integer primary key or `id`,
else `created_at` / `occurred_at` / `inserted_at`). The core tables (`agent_memory_events`,
`agent_memory_payload_archives`, `agent_coordination.events`, `agent_coordination.messages`) must match exactly and
hold at least the manifest counts.

- Disk: an ext4 image on `STAGING_DRIVE` (live DB size + 8 GiB), loop-mounted with direct I/O at
  `/mnt/agent-memory-restore-test`, deleted at the end even on failure. An image is needed when the staging drive is
  exFAT, which cannot hold a Postgres data directory. The loop mount needs passwordless `sudo -n`.
- Space: it refuses to start unless the staging drive keeps the nightly's need (dump + 15 % + 60 GiB) free after the
  image exists, so a leaked image cannot fail the nightly's preflight.
- Time: run it weekly at a quiet hour under `timeout 6h`; it holds `backup-v2.lock` for its whole run, so it never
  overlaps the nightly.
- Serving: with `SERVING_UNIT` set to a systemd unit that logs `done: N tokens in N s (R tok/s)`, it stops (status
  `aborted`, exit 2) when, over the last 20 minutes, at least 4 answers of 100+ tokens have a median under
  `WATCH_FRACTION` (70 %) of the unit's 24-hour median. Short answers and bursts of overlapping requests are slow
  with no test running, so they are not counted.
- Results: `state/restore-test-latest.json` (also copied to `$DEST_ROOT/restore-tests/`). `plan` prints the space
  math and changes nothing.

## Other databases in the same container

`backup_pg_db.sh` backs up the smaller databases that share `agent-memory-postgres` (`CRON_DBS` in
`pg-db-backup.env`); it never touches `agent_memory` unless `DB_NAME=agent_memory` is passed.

- Each run exports one REPEATABLE READ snapshot, counts every table in it, and dumps with
  `pg_dump --format=custom --snapshot=<it>` into `$DEST_ROOT/<db>/incoming`, with a `<id>.dump.sha256` sidecar
  (`sha256sum -c` format) and `pg_restore --list`.
- It restores the dump into `<db>_restore_test` and requires the same table set and the identical row count for
  every table (exact, because both sides read one snapshot), records both in the manifest (`pg-db-backup.v2`) and
  drops the test database.
- It publishes dump, sidecar, manifest and restore list, keeps the newest dump of each of the 14 most recent backup
  days (`KEEP_DAILY`), of the 8 most recent ISO weeks (`KEEP_WEEKLY`) and everything younger than 48 h
  (`KEEP_RECENT_HOURS`), on both copies.
- The NAS copy (`$MIRROR_ROOT/<db>`) has the agent-memory job's protection: only inside `TRANSFER_WINDOW_UTC`, at
  `BWLIMIT_KBPS`, after the pool gate, and only while holding `SHARE_COPY_LOCK`. Since 2.2.0 it holds
  `SHARE_WAIT_LOCK` shared while it waits and copies, so the agent-memory copy hands the share over at its next pool
  wait or step (see "Share-copy lock and `backup_pg_db.sh`" above). A copy that cannot start before the
  window ends is skipped (`nas=skipped-...` in the log; the local copy is the restore point) and the next run copies
  the newest `MIRROR_CATCHUP_MAX` (3) local backups the share is missing. A full or missing share never fails the
  backup. `DB_NAME=<db> backup_pg_db.sh mirror` runs only the NAS copy.
- With `RECORD_RUN=1` each backup is also a run row in an external run-log CLI (`LAB_DIR`, `LAB_PY`, `LAB_CLI`,
  credentials in `LAB_ENV_FILE`), best effort.
- A failed run deletes its `incoming/<id>` directory and drops the test database.

```bash
DB_NAME=<db> bin/backup_pg_db.sh run      # on demand, for example before a migration
bin/backup_pg_db.sh run-all               # what cron runs: every database in CRON_DBS
bin/backup_pg_db.sh status
bin/backup_pg_db.sh install-cron          # 50 2 * * *, the "# BEGIN pg-db-backup" block
bin/backup_pg_db.sh restore-help
```

The pool gate, window, free-space and env-file helpers are copied between the two scripts; change both.

## Changing the scripts

The scripts in this folder are the source of the installed copies; keep them identical.

1. Run both suites on the host (Linux), from this folder:
   `bash scripts/tests/test_backup_agent_memory_pg.sh` and `bash scripts/tests/test_backup_pg_db.sh`.
2. Back up each installed file as `bin/<name>.bak-<old version>-<stamp>`.
3. Copy the new files into `bin/` while no run holds the lock (outside the copy window), then run `dry-run` (with
   `DRY_RUN_HASH=0` by day) and `status`.
4. Run `install-cron` only if the runner path, schedule or `CACHE_WRAP` changed.
