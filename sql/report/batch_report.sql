-- batch_report.sql
-- Morning summary report for one nightly file: run status, totals,
-- rejections by stage and reason, rejection detail, and recent run history.
--
-- Run as VSS with two arguments, the file name and the report path inside
-- the container (run_batch.sh does this after every batch):
--   docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/report/batch_report.sql \
--       nightly_20240117.dat /data/reports/report_20240117.txt
--
-- Reports on the latest run of that file. SQL*Plus report commands used:
--   COLUMN ... NEW_VALUE  saves a query result in a substitution variable
--   COLUMN ... FORMAT     sets each column's width and number format
--   BREAK / COMPUTE       groups rows and prints subtotals and a total

WHENEVER SQLERROR EXIT FAILURE
SET VERIFY OFF
SET FEEDBACK OFF
SET TRIMSPOOL ON
SET LINESIZE 100
SET PAGESIZE 50000
SET TAB OFF

DEFINE file_name = '&1'
DEFINE report_path = '&2'

-- Stop with an error if the file has no batch run, rather than printing
-- an empty report that looks like a quiet night.
DECLARE
    v_count PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM batch_runs WHERE file_name = '&file_name';
    IF v_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20010, 'No batch run found for &file_name');
    END IF;
END;
/

-- Load the run's details into substitution variables for the header.
-- The hdr_ names are used nowhere else, so later queries cannot change them
-- (NEW_VALUE takes the value from the last row of any query using the name).
COLUMN hdr_run_id     NEW_VALUE v_run_id      NOPRINT
COLUMN hdr_status     NEW_VALUE v_status      NOPRINT
COLUMN hdr_started    NEW_VALUE v_started     NOPRINT
COLUMN hdr_finished   NEW_VALUE v_finished    NOPRINT
COLUMN hdr_duration   NEW_VALUE v_duration    NOPRINT
COLUMN hdr_read       NEW_VALUE v_read        NOPRINT
COLUMN hdr_applied    NEW_VALUE v_applied     NOPRINT
COLUMN hdr_rejected   NEW_VALUE v_rejected    NOPRINT
COLUMN hdr_reject_pct NEW_VALUE v_reject_pct  NOPRINT
COLUMN hdr_generated  NEW_VALUE v_generated   NOPRINT

-- Numbers are turned into text here: a NUMBER saved by NEW_VALUE keeps
-- its default column width, which would pad the header with spaces.
SELECT TO_CHAR(batch_run_id) AS hdr_run_id,
       status                AS hdr_status,
       TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') AS hdr_started,
       NVL(TO_CHAR(finished_at, 'YYYY-MM-DD HH24:MI:SS'), '(not finished)') AS hdr_finished,
       -- Subtracting timestamps gives an INTERVAL; EXTRACT turns it into seconds.
       NVL(TO_CHAR(EXTRACT(DAY    FROM finished_at - started_at) * 86400
                 + EXTRACT(HOUR   FROM finished_at - started_at) * 3600
                 + EXTRACT(MINUTE FROM finished_at - started_at) * 60
                 + EXTRACT(SECOND FROM finished_at - started_at), 'FM999990.0'), '-') AS hdr_duration,
       TO_CHAR(records_read)     AS hdr_read,
       TO_CHAR(records_applied)  AS hdr_applied,
       TO_CHAR(records_rejected) AS hdr_rejected,
       TO_CHAR(100 * records_rejected / NULLIF(records_read, 0), 'FM990.0') AS hdr_reject_pct,
       TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS hdr_generated
FROM   batch_runs
WHERE  batch_run_id = (SELECT MAX(batch_run_id) FROM batch_runs WHERE file_name = '&file_name');

SPOOL &report_path

PROMPT ====================================================================================================
PROMPT VEHICLE RECORDS NIGHTLY BATCH - MORNING SUMMARY
PROMPT ====================================================================================================
PROMPT File             : &file_name
PROMPT Batch run        : &v_run_id
PROMPT Status           : &v_status
PROMPT Started (UTC)    : &v_started
PROMPT Finished (UTC)   : &v_finished  (&v_duration seconds)
PROMPT
PROMPT Records read     : &v_read
PROMPT Records applied  : &v_applied
PROMPT Records rejected : &v_rejected  (&v_reject_pct%)
PROMPT

-- Only prints when the reject rate is unusually high (no rows = no line).
SET HEADING OFF
SELECT '*** WARNING: reject rate above 5%. Check the file with the sender before tonight''s run. ***'
FROM   batch_runs
WHERE  batch_run_id = &v_run_id
AND    records_rejected > 0.05 * records_read;
SELECT '*** WARNING: this run did not complete. Changes from this file were NOT applied. ***'
FROM   batch_runs
WHERE  batch_run_id = &v_run_id
AND    status <> 'COMPLETED';
SET HEADING ON

PROMPT ====================================================================================================
PROMPT REJECTIONS BY STAGE AND REASON
PROMPT   VALIDATOR = structural fault in the file (sender to correct)
PROMPT   PLSQL     = business rule failed against the vehicle record (review case by case)
PROMPT ====================================================================================================

COLUMN stage        HEADING 'Stage'       FORMAT A10
COLUMN reason_code  HEADING 'Reason'      FORMAT A17
COLUMN description  HEADING 'Description' FORMAT A60 TRUNCATED
COLUMN rejected     HEADING 'Count'       FORMAT 99999

-- BREAK ON stage prints each stage name once and leaves a blank line after
-- the group; COMPUTE adds a subtotal per stage and a total for the report.
BREAK ON stage SKIP 1 ON REPORT
COMPUTE SUM LABEL 'Subtotal' OF rejected ON stage
COMPUTE SUM LABEL 'Total'    OF rejected ON REPORT

SELECT stage,
       reason_code,
       vehicle_batch_pkg.reason_text(reason_code) AS description,
       COUNT(*) AS rejected
FROM   rejections
WHERE  batch_run_id = &v_run_id
GROUP  BY stage, reason_code
ORDER  BY stage DESC, rejected DESC, reason_code;

CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT ====================================================================================================
PROMPT REJECTION DETAIL (first 200, in file order)
PROMPT ====================================================================================================

COLUMN line_number  HEADING 'Line'   FORMAT 999999999
COLUMN registration HEADING 'Reg'    FORMAT A8
COLUMN change_type  HEADING 'Type'   FORMAT A8
COLUMN reason_code  HEADING 'Reason' FORMAT A17
COLUMN detail       HEADING 'Detail' FORMAT A52 TRUNCATED

-- For DB_ERROR the stored reason_text holds the Oracle message, which is
-- what support needs; for the others it repeats the description above,
-- so show the new value or postcode from the record instead.
SELECT line_number,
       registration,
       change_type,
       reason_code,
       CASE
           WHEN reason_code = 'DB_ERROR' THEN reason_text
           ELSE TRIM(TRIM(SUBSTR(raw_record, 17, 40)) || ' ' || TRIM(SUBSTR(raw_record, 57, 8)))
       END AS detail
FROM   rejections
WHERE  batch_run_id = &v_run_id
ORDER  BY line_number
FETCH  FIRST 200 ROWS ONLY;

SET HEADING OFF
SELECT '... and ' || (COUNT(*) - 200) || ' more: query REJECTIONS for batch_run_id &v_run_id'
FROM   rejections
WHERE  batch_run_id = &v_run_id
HAVING COUNT(*) > 200;
SET HEADING ON

PROMPT
PROMPT ====================================================================================================
PROMPT RECENT RUNS (last 7)
PROMPT ====================================================================================================

COLUMN batch_run_id     HEADING 'Run'           FORMAT 99999
COLUMN file_name        HEADING 'File'          FORMAT A22
COLUMN status           HEADING 'Status'        FORMAT A9
COLUMN started          HEADING 'Started (UTC)' FORMAT A19
COLUMN records_read     HEADING 'Read'          FORMAT 9999999
COLUMN records_applied  HEADING 'Applied'       FORMAT 9999999
COLUMN records_rejected HEADING 'Rejected'      FORMAT 9999999

SELECT batch_run_id,
       file_name,
       status,
       TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') AS started,
       records_read,
       records_applied,
       records_rejected
FROM   batch_runs
ORDER  BY batch_run_id DESC
FETCH  FIRST 7 ROWS ONLY;

PROMPT
PROMPT Report generated &v_generated UTC
PROMPT ====================================================================================================

SPOOL OFF
EXIT
