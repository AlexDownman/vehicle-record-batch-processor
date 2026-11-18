-- batch_input.ctl
-- SQL*Loader control file: loads the validator's clean file into BATCH_INPUT.
--
-- There is no INFILE: the file changes every night, so it is passed on
-- the command line with data=, along with the log and bad file:
--   docker/oracle.sh sqlldr vss@FREEPDB1 control=/sql/loader/batch_input.ctl \
--       data=/data/work/nightly_20240115.clean \
--       log=/data/logs/batch_input.log bad=/data/logs/batch_input.bad
--
-- The clean file is fixed-width (docs/file-format.md, "Validator outputs"),
-- so fields are cut out by POSITION(start:end) rather than by a delimiter.

LOAD DATA
CHARACTERSET US7ASCII
TRUNCATE
INTO TABLE batch_input
(
    line_number     POSITION(1:9)    INTEGER EXTERNAL,
    -- RTRIM removes the space padding; an all-blank field becomes NULL.
    registration    POSITION(10:17)  CHAR "RTRIM(:registration)",
    change_type     POSITION(18:25)  CHAR "RTRIM(:change_type)",
    new_value       POSITION(26:65)  CHAR "RTRIM(:new_value)",
    postcode        POSITION(66:73)  CHAR "RTRIM(:postcode)",
    effective_date  POSITION(74:81)  DATE "YYYYMMDD"
)
