-- batch_rejects.ctl
-- SQL*Loader control file: loads the validator's rejects file into
-- BATCH_INPUT_REJECTS. vehicle_batch_pkg copies them into REJECTIONS.
--
-- Pass the file on the command line, as for batch_input.ctl:
--   docker/oracle.sh sqlldr vss@FREEPDB1 control=/sql/loader/batch_rejects.ctl \
--       data=/data/rejects/nightly_20240115.rej \
--       log=/data/logs/batch_rejects.log bad=/data/logs/batch_rejects.bad

LOAD DATA
CHARACTERSET US7ASCII
TRUNCATE
INTO TABLE batch_input_rejects
(
    line_number  POSITION(1:9)     INTEGER EXTERNAL,
    reason_code  POSITION(11:30)   CHAR "RTRIM(:reason_code)",
    raw_record   POSITION(32:131)  CHAR "RTRIM(:raw_record)"
)
