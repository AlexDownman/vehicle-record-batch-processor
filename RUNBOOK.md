# Runbook: nightly vehicle records batch

For whoever is on support when the batch fails or the morning report looks
wrong. Part 1 is how to start any investigation. Part 2 is the incidents
seen so far, each with its symptom, investigation, root cause, fix and how
to reproduce it.

All symptoms below are real output from this system, unless an entry says
otherwise.

---

## Part 1: First response

### 1. Read the exit code and the report

`run_batch.sh` exits with a code that says which stage failed. The morning
report folder always has something for the night:

- `data/reports/report_YYYYMMDD.txt` if the batch completed
- `data/reports/report_YYYYMMDD_FAILED_<time>_<pid>.txt` if it did not

| Exit | Meaning | Were changes applied? | Safe to rerun? |
|---|---|---|---|
| 0 | Completed (rejected records are normal) | Yes | No, see INC-04 |
| 1 | Usage or environment problem | No | Yes, after the fix |
| 2 | Lock held, or a stale lock | No | Yes, after INC-06 |
| 3 | No inbound file | No | Yes, once the file arrives |
| 4 | Validator rejected the file | No | Only with a corrected file |
| 5 | SQL*Loader failed | No | Yes, after the fix |
| 6 | Database down, or PL/SQL failed | Usually no (check the message) | See the message |
| 7 | Applied, but file not archived | **Yes** | **No**, archive by hand |
| 8 | Applied and archived, report failed | **Yes** | **No**, rebuild the report |

The rule behind exit 6: `vehicle_batch_pkg` commits once per file, so a
failed run applies **nothing**. The exceptions are the two run guards
(INC-04, INC-05), where a previous run is the issue.

### 2. Where to look

| What | Where |
|---|---|
| Batch log (every stage, timestamped UTC) | `data/logs/run_batch_YYYYMMDD_<time>_<pid>.log` |
| SQL*Loader logs and bad files | `data/logs/nightly_YYYYMMDD_batch_input.log` / `.bad`, `..._batch_rejects.log` / `.bad` |
| Validator output | `data/work/nightly_YYYYMMDD.clean`, `data/rejects/nightly_YYYYMMDD.rej` |
| Files the validator rejected | `data/rejects/nightly_YYYYMMDD.dat` |
| Processed files | `data/archive/` |
| Run history and counts | `BATCH_RUNS` table |
| Every rejected record, with reason | `REJECTIONS` table |
| File layout and reason codes | `docs/file-format.md` |

### 3. Useful queries

Connect with `docker/oracle.sh sqlplus vss@FREEPDB1`, then:

```sql
-- Recent runs
SELECT batch_run_id, file_name, status, started_at, finished_at,
       records_read, records_applied, records_rejected
FROM   batch_runs ORDER BY batch_run_id DESC FETCH FIRST 10 ROWS ONLY;

-- Rejections for a run, by reason
SELECT stage, reason_code, COUNT(*) FROM rejections
WHERE  batch_run_id = :run GROUP BY stage, reason_code ORDER BY 3 DESC;

-- One vehicle and its keeper history
SELECT v.registration, v.status, v.colour, v.last_batch_run_id,
       k.keeper_name, k.postcode, k.start_date, k.end_date
FROM   vehicles v JOIN keepers k ON k.vehicle_id = v.vehicle_id
WHERE  v.registration = 'AB12 CDE' ORDER BY k.start_date;

-- Is the package compiled and valid?
SELECT object_type, status, last_ddl_time FROM user_objects
WHERE  object_name = 'VEHICLE_BATCH_PKG';

-- An error says: ORA-06512: at "VSS.VEHICLE_BATCH_PKG", line 295.
-- Show that line of the package body:
SELECT line, text FROM user_source
WHERE  name = 'VEHICLE_BATCH_PKG' AND type = 'PACKAGE BODY'
AND    line BETWEEN 290 AND 300 ORDER BY line;
```

### 4. Reproducing a night

For a test file, compare what the batch rejected with what the generator
planted. In `docker/oracle.sh sqlplus vss@FREEPDB1`:

```sql
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON
SPOOL /data/work/actual_rejections.csv
SELECT line_number || ',' || stage || ',' || reason_code || ',' || registration
FROM   rejections
WHERE  batch_run_id = (SELECT MAX(batch_run_id) FROM batch_runs
                       WHERE file_name = 'nightly_YYYYMMDD.dat')
ORDER  BY line_number;
SPOOL OFF
```

Then, on the host (no output means an exact match):

```bash
diff <(tail -n +2 data/archive/nightly_YYYYMMDD.expected) <(grep -E '^[0-9]+,' data/work/actual_rejections.csv)
```

---

## Part 2: Incidents

| ID | Summary | Exit |
|---|---|---|
| [INC-01](#inc-01-truncated-file) | Truncated file | 4 |
| [INC-02](#inc-02-windows-line-endings) | Windows (CRLF) line endings | 4 |
| [INC-03](#inc-03-header-date-does-not-match-file-name) | Header date does not match the file name | 4 |
| [INC-04](#inc-04-duplicate-delivery) | Duplicate delivery of a processed file | 6 |
| [INC-05](#inc-05-database-restarted-mid-batch-run-left-running) | Database restarted mid-batch; run left RUNNING | 6 |
| [INC-06](#inc-06-stale-lock) | Stale lock after a crash | 2 |
| [INC-07](#inc-07-database-login-refused) | Database login refused | 6 |
| [INC-08](#inc-08-database-container-not-running) | Database container not running | 6 |
| [INC-09](#inc-09-folder-not-writable) | Log or archive folder not writable | 1 / 7 |
| [INC-10](#inc-10-more-rejections-than-expected) | More rejections than expected | 0 |
| [INC-11](#inc-11-sqlplus-appears-to-hang) | SQL*Plus appears to hang | n/a |
| [INC-12](#inc-12-seed-load-rejects-rows-with-inch-marks) | Seed load rejects rows with inch marks | n/a |

---

### INC-01: Truncated file

**Symptom**
```
validator: header OK, file date 20240118
validator: no trailer record: file may be truncated (500 lines read)
validator: FILE REJECTED: no output written
Moved .../data/inbound/nightly_20240118.dat to .../data/rejects/nightly_20240118.dat
ERROR: file rejected by the validator. Ask the sender for a corrected file.
Batch FAILED (exit 4)
```

**Investigation**
- `tail -1 data/rejects/nightly_20240118.dat` shows a change record, not `TRL…`.
- `wc -l` compared with the sender's expected count shows lines are missing.

**Root cause:** the file was cut short in transit or while being written.
The last line is not the trailer, so the validator cannot trust the file.

**Fix:** ask the sender to resend. Put the new file in `data/inbound/` and
rerun. Nothing was applied, so a rerun is safe.

**Why the whole file is rejected:** applying the first 500 lines of a
truncated file would change the record of truth with nobody noticing that
the rest was missing. The trailer's record count is what catches this.

**Note:** a second rejected delivery with the same name does not overwrite
the first. It is saved as `nightly_YYYYMMDD.dat.<timestamp>`, so both are
kept as evidence.

**Reproduce**
```bash
head -n 500 data/archive/nightly_20240117.dat | sed 's/^HDR20240117/HDR20240118/' > data/inbound/nightly_20240118.dat
scripts/run_batch.sh 20240118
```

---

### INC-02: Windows line endings

**Symptom**
```
validator: line 1 ends in a carriage return: file has Windows (CRLF) line endings
validator: FILE REJECTED: no output written
Batch FAILED (exit 4)
```

**Investigation:** `head -1 data/rejects/nightly_YYYYMMDD.dat | od -c | tail -2`
shows `\r \n` at the end of the line.

**Root cause:** the file was produced or edited on Windows, or transferred
in FTP ASCII mode. Every line is 73 characters instead of 72.

**Fix:** ask the sender for a Unix (LF) file. For a one-off, if the change
owner approves, convert it with
`sed 's/\r$//' file > data/inbound/nightly_YYYYMMDD.dat` and rerun.

**Prevention:** the validator names this cause specifically. A generic
"bad header" message would send support looking in the wrong place.

**Reproduce:** `sed 's/$/\r/' data/archive/nightly_20240117.dat > data/inbound/nightly_20240119.dat`,
then fix the header date as in INC-01 and run.

---

### INC-03: Header date does not match file name

**Symptom**
```
validator: header date 20240115 does not match file name date 20240116
validator: FILE REJECTED: no output written
Batch FAILED (exit 4)
```

**Root cause:** the wrong night's file was renamed or copied into place.
Processing it would apply one night's changes under another night's name.

**Fix:** find the correct file. If it is a resend of a night already
processed, see INC-04.

**Reproduce:** `cp data/archive/nightly_20240117.dat data/inbound/nightly_20240119.dat`, then run for 20240119.

---

### INC-04: Duplicate delivery

**Symptom**
```
Stage apply: vehicle_batch_pkg.process_file('nightly_20240117.dat')
    ORA-20002: File nightly_20240117.dat has already been processed.
    ORA-06512: at "VSS.VEHICLE_BATCH_PKG", line 295
ERROR: this file was already applied by an earlier run (see BATCH_RUNS). Do NOT rerun.
       If it is a duplicate delivery, move it out of data/inbound/.
Batch FAILED (exit 6)
```

**Investigation**
```sql
SELECT batch_run_id, status, started_at FROM batch_runs
WHERE  file_name = 'nightly_20240117.dat';
```
A `COMPLETED` row confirms it. `cmp` against `data/archive/` shows whether
the file is identical or a changed resend.

**Root cause:** the sender resent a file, or someone copied an archived
file back into `inbound/`. Applying it again would add duplicate keeper
periods and reapply colour changes.

**Fix:** if identical, delete it from `inbound/`. If it differs, it is a
correction, which needs a new file date agreed with the sender. Never
delete the `BATCH_RUNS` row to force it through.

**Prevention:** `start_run` in `vehicle_batch_pkg` refuses any file name
with a `COMPLETED` run. `run_batch.sh` turns ORA-20002 into specific
advice. Before that change it said "rerun", which was exactly wrong.

**Reproduce:** `cp data/archive/nightly_20240117.dat data/inbound/ && scripts/run_batch.sh 20240117`

---

### INC-05: Database restarted mid-batch, run left RUNNING

> **Not yet reproduced on this system.** The symptoms below are what the
> code paths produce: the guard (ORA-20001) and the rollback behaviour were
> each tested separately. Replace this note with real output after running
> the steps under *Reproduce*.

**Symptom (first night):** the apply stage loses its connection, for example
`ORA-03113: end-of-file on communication channel`, and the batch exits 6.

**Symptom (next run)**
```
ORA-20001: Another batch run is still RUNNING. If no batch is active, it
crashed: investigate, then set its status to FAILED.
ERROR: a previous run is still marked RUNNING in BATCH_RUNS.
       If no batch is active it crashed: investigate, set it to FAILED, then rerun.
Batch FAILED (exit 6)
```

**Investigation**
1. Make sure no batch is actually running: `ls data/work/run_batch.lock`
   (absent) and `ps aux | grep run_batch`.
2. Find the row:
   ```sql
   SELECT batch_run_id, file_name, started_at FROM batch_runs WHERE status = 'RUNNING';
   ```
3. Confirm nothing from that run was applied (expect 0 for both):
   ```sql
   SELECT COUNT(*) FROM vehicles   WHERE last_batch_run_id = :run;
   SELECT COUNT(*) FROM rejections WHERE batch_run_id = :run;
   ```

**Root cause:** `start_run` commits the `RUNNING` row straight away, so it
can be seen while the file is processed. The rest of the run is one
transaction, so a crash rolls it back, but nothing is left to change the
status, because `process_file`'s exception handler never ran.

**Fix**
```sql
UPDATE batch_runs SET status = 'FAILED', finished_at = SYSTIMESTAMP
WHERE  batch_run_id = :run AND status = 'RUNNING';
COMMIT;
```
Then rerun the batch for the same date. The file is still in `inbound/`.

**Why it is not fixed automatically:** a `RUNNING` row could also be a
batch that really is still running. Only a person can tell the
difference safely.

**Reproduce**

Restarting the database by hand during a normal run does not work: run 24
applied 20,000 records in about 2.5 seconds and finished first. Instead,
hold a row lock on a vehicle in the file, so the batch waits at that
record (`apply_update` uses `SELECT ... FOR UPDATE`), then restart:

```bash
# Terminal 1
docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/extract_vehicles.sql
.venv/bin/python scripts/generate_nightly.py --extract data/seed/vehicle_extract.csv --date 20240123
sed -n 2p data/inbound/nightly_20240123.dat | cut -c1-8      # first registration
```
```sql
-- Terminal 2 (docker/oracle.sh sqlplus vss@FREEPDB1): lock it, do not COMMIT
SELECT vehicle_id, status FROM vehicles WHERE registration = 'AB12 CDE' FOR UPDATE;
```
```bash
scripts/run_batch.sh 20240123            # terminal 1: waits at "Stage apply"
docker restart vrbp-oracle               # terminal 3
docker/oracle.sh status                  # wait for: running (healthy)
scripts/run_batch.sh 20240123            # terminal 1: shows ORA-20001
```

While it waits, `SELECT sid, username, status, blocking_session, event,
seconds_in_wait FROM v$session WHERE username = 'VSS';` (as SYSTEM) shows
the batch session blocked by terminal 2's session. That blocking session is
itself a likely future incident: "batch stuck in apply".

---

### INC-06: Stale lock

**Symptom**
```
ERROR: stale lock .../data/work/run_batch.lock (PID 4959 is not running).
       Check the previous run's log and BATCH_RUNS, then remove the lock directory.
Batch FAILED (exit 2)
```
If the PID is still alive, the message is instead
`another run (PID nnnn) is still in progress`. Wait for that run to finish.

**Root cause:** a run was killed (`kill -9`, reboot, power loss) before
its exit trap could remove the lock.

**Investigation:** read the latest log for that date. Its last line shows
where the run stopped. Then check `BATCH_RUNS` for a `RUNNING` row (INC-05).

**Fix:** after checking, `rm -r data/work/run_batch.lock` and rerun.

**Why it is not removed automatically:** a run that died mid-batch may need
the INC-05 fix first. Removing the lock without checking hides that.

**Reproduce:** `mkdir data/work/run_batch.lock && echo 99999 > data/work/run_batch.lock/pid`

---

### INC-07: Database login refused

**Symptom**
```
    ORA-01017: invalid credential or not authorized; logon denied
ERROR: cannot log in to FREEPDB1 as vss (see the ORA- error above)
Batch FAILED (exit 6)
```

**Investigation:** check the credentials file's format without printing the password:
```bash
ls -l ~/.config/vrbp/credentials          # must be -rw-------
awk -F= '{ print $1, "length", length($0) - length($1) - 1 }' ~/.config/vrbp/credentials
```

**Root cause (seen):** the file still contained the placeholder
`YOUR_VSS_PASSWORD` from the set-up instructions. Other causes are a
changed or expired password, or the wrong user.

**Fix:** edit the file with an editor (not `echo`, which leaves the
password in shell history) and rerun. Nothing was applied: the login is
checked before any stage runs.

**Reproduce:** point `VRBP_CREDENTIALS` at a file with a wrong password.

---

### INC-08: Database container not running

**Symptom**
```
ERROR: database container vrbp-oracle is not healthy (status: not found)
Batch FAILED (exit 6)
```
(`not found` if the container was removed; `unhealthy` or `starting` if it
is still coming up.)

**Fix:** `docker/oracle.sh start` waits until the database reports healthy,
which can take several minutes after a host reboot. Then rerun. The file
was not touched.

**Reproduce:** `VRBP_CONTAINER=nope scripts/run_batch.sh 20240118`

---

### INC-09: Folder not writable

**Symptom: log folder (exit 1).** The message goes to stderr (cron.log),
because there is nowhere to write the log:
```
ERROR: log folder .../data/logs is missing or not writable
```

**Symptom: archive folder (exit 7)**
```
Stage archive: moving input to data/archive/
mv: rename .../inbound/nightly_20240121.dat to .../archive/nightly_20240121.dat: Permission denied
ERROR: batch APPLIED but .../inbound/nightly_20240121.dat could not be archived.
       Move it to data/archive/ by hand. Do not rerun the batch.
Batch FAILED (exit 7)
```
The failure report says `CHANGES APPLIED, but follow-up is needed`.

**Investigation:** `ls -ld data/logs data/archive`, `df -h .` (disk full
gives `No space left on device` in the same places).

**Fix:** restore the permission or free the space. For exit 7, move the
file by hand (`mv data/inbound/nightly_YYYYMMDD.dat data/archive/`). Do
**not** rerun: the changes are committed, and process_file would refuse it
anyway (INC-04). The report stage did not run, so build the report by hand.
This is the same command the exit 8 message gives:
```bash
docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/report/batch_report.sql \
    nightly_YYYYMMDD.dat /data/reports/report_YYYYMMDD.txt
```

**Reproduce:** `chmod u-w data/archive`, run a good file, then `chmod u+w data/archive`.

---

### INC-10: More rejections than expected

**Symptom:** run 21 (`nightly_20240116.dat`) reported 18 rejections when
15 faults were planted. The batch itself completed with exit 0.

**Investigation**
1. Compared `REJECTIONS` with the generator's `.expected` file (Part 1,
   section 4). All 15 planted faults were present, plus 3 extra
   `DATE_CONFLICT` rejections on lines 474, 520 and 676.
2. Looked at the keeper history of the three vehicles:
   ```
   KS53 YON  new keeper effective 15-JAN-24 (run 1), tonight's change effective 13 Jan
   WN67 FCP  new keeper effective 14-JAN-24 (run 1), tonight's change effective 11 Jan
   UR67 RVU  new keeper effective 14-JAN-24 (run 1), tonight's change effective 11 Jan
   ```
3. Read the rule in `apply_update`: a new keeper must start after the
   current keeper's start date. The rule was right: those records really
   did conflict.

**Root cause:** the test generator backdates changes by up to 6 days, so
consecutive nights' date windows overlap. It picked vehicles whose keeper
had changed the night before, with tonight's change dated earlier.

**Fix:** the extract now includes each vehicle's current keeper start
date, and the generator skips vehicles whose keeper changed within the
backdating window. It also plants `DATE_CONFLICT` deliberately, so the
`.expected` file covers it. Runs 22 and 23 matched exactly.

**Lesson:** when the counts are off, check the rule before changing it.
The PL/SQL was right; the test data was wrong. In production, a cluster
of `DATE_CONFLICT`s points at the sender's process (late notifications),
not the batch.

---

### INC-11: SQL*Plus appears to hang

**Symptom:** `docker/oracle.sh sqlplus -s vss@FREEPDB1 @/sql/extract_vehicles.sql`
prints nothing and never returns.

**Investigation:** `docker exec vrbp-oracle ps -eo pid,etime,args | grep sqlplus`
showed two `sqlplus` processes: the current one, and one left from an
earlier attempt cancelled with Ctrl+C.

**Root cause:** `-s` (silent) hides the `Enter password:` prompt as well
as the banner, so SQL*Plus is waiting for input nobody can see. Ctrl+C on
`docker exec -it` does not always stop the process inside the container.

**Fix:** type the password and press Enter, or run without `-s`. Clear
orphans with `docker exec vrbp-oracle kill <pid>`.

**Prevention:** the docs no longer suggest `-s` for interactive use.
`run_batch.sh` is not affected: it sends the password on stdin.

---

### INC-12: Seed load rejects rows with inch marks

**Symptom:** loading DVSA data with `sql/loader/mot.ctl` exits 2
(warning), and the log shows:
```
Record 1: Rejected - Error on table VSS.MOT_STAGING, column MODEL.
second enclosure string not present
...
  11 Rows not loaded due to data errors.
```
The bad file holds model names with inch marks:
```
...,PEUGEOT,"STREETZONE 50 2T 12\"",GREEN,...
...,LAND ROVER,"SWB 88\"",GREEN,...
```

**Root cause:** standard CSV writes a quote inside a quoted field as `""`.
DVSA writes `\"`. SQL*Loader reads `\""` as an escaped quote followed by
nothing, so it never finds the closing quote. (In January 2024: 11
affected rows out of 6,140,804 lines.)

**Investigation tip:** always check the totals in the SQL*Loader log, not
just its exit code. Exit 2 is only a warning, and it is easy to miss that
rows went to the bad file.

**Fix:** convert the escapes to the CSV standard before loading:
```bash
sed 's/\\"/""/g' sample.csv > data/seed/mot_sample.csv
```
Tested: all 20 quoted January rows then load, with the inch mark kept
(`SWB 88"`). Commas inside quotes (`"IVECO ,MOTORHOME"`) already load
correctly, without the fix.

**Related quirk:** each monthly file repeats its header line part-way
through (it is several files joined together). `SKIP=1` only skips the
first, so `mot.ctl` has `WHEN (test_id != 'test_id')`, which sends the
repeats to the discard file. Expect `Total logical records discarded: 1`
or more on a full month.

**Reproduce:** load lines containing `\"` from
`data/MOT testing data results (2024)/test_result_202401.csv`
(`grep '\\"'`) with `mot.ctl`.
