-- 05_batch_input.sql
-- Creates the per-run staging tables that hold the validator's output:
--   BATCH_INPUT          clean change records (sql/loader/batch_input.ctl)
--   BATCH_INPUT_REJECTS  records the validator rejected (sql/loader/batch_rejects.ctl)
--
-- Run as VSS:
--   docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/05_batch_input.sql
--
-- Both are emptied and reloaded for every nightly file, then read by
-- vehicle_batch_pkg.process_file. They hold one file at a time, which is
-- why run_batch.sh must never run twice at once.

WHENEVER SQLERROR EXIT SQL.SQLCODE

DROP TABLE IF EXISTS batch_input         PURGE;
DROP TABLE IF EXISTS batch_input_rejects PURGE;

CREATE TABLE batch_input (
    line_number     NUMBER(9)     CONSTRAINT batch_input_pk PRIMARY KEY,
    registration    VARCHAR2(8)   CONSTRAINT batch_input_reg_nn  NOT NULL,
    change_type     VARCHAR2(8)   CONSTRAINT batch_input_type_nn NOT NULL,
    new_value       VARCHAR2(40),
    postcode        VARCHAR2(8),
    effective_date  DATE          CONSTRAINT batch_input_date_nn NOT NULL
);

COMMENT ON TABLE batch_input IS 'Clean records from the validator for the file being processed';

CREATE TABLE batch_input_rejects (
    line_number  NUMBER(9)      CONSTRAINT batch_input_rejects_pk PRIMARY KEY,
    reason_code  VARCHAR2(30)   CONSTRAINT batch_input_rej_reason_nn NOT NULL,
    raw_record   VARCHAR2(100)
);

COMMENT ON TABLE batch_input_rejects IS 'Records the validator rejected for the file being processed';

PROMPT Tables BATCH_INPUT and BATCH_INPUT_REJECTS created.
EXIT
