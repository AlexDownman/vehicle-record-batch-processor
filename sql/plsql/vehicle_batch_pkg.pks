-- vehicle_batch_pkg.pks
-- Package specification: the public interface of the nightly batch.
--
-- A package has two parts. The specification (this file) declares what
-- callers can use; the body (vehicle_batch_pkg.pkb) holds the code. The
-- body can be changed and recompiled without invalidating callers, as
-- long as the specification stays the same.
--
-- Install with sql/06_install_pkg.sql.

CREATE OR REPLACE PACKAGE vehicle_batch_pkg AS

    -- Raised by process_file when a run cannot start.
    -- PRAGMA EXCEPTION_INIT ties a name to an error number, so callers
    -- can write WHEN e_run_in_progress instead of checking SQLCODE.
    e_run_in_progress    EXCEPTION;
    e_already_processed  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_run_in_progress,   -20001);
    PRAGMA EXCEPTION_INIT(e_already_processed, -20002);

    -- Processes the file currently loaded into BATCH_INPUT and
    -- BATCH_INPUT_REJECTS:
    --   1. records a RUNNING row in BATCH_RUNS (committed straight away)
    --   2. copies the validator's rejects into REJECTIONS
    --   3. applies each clean record in line order, rejecting any that
    --      break a business rule
    --   4. commits everything and marks the run COMPLETED
    -- On an unexpected error the work is rolled back, the run is marked
    -- FAILED, and the error is raised again for the caller to report.
    -- Returns the new batch_run_id.
    FUNCTION process_file(p_file_name IN VARCHAR2)
        RETURN batch_runs.batch_run_id%TYPE;

    -- Applies one change record. Returns NULL if it was applied, or the
    -- reason code if a business rule rejected it (nothing is changed).
    -- Does not commit. Public so a single record can be tested by hand.
    FUNCTION apply_update(
        p_batch_run_id IN batch_runs.batch_run_id%TYPE,
        p_input        IN batch_input%ROWTYPE
    ) RETURN VARCHAR2;

    -- Human-readable description of a reason code, for REJECTIONS and
    -- the morning report. Public so it can be called from SQL.
    FUNCTION reason_text(p_reason_code IN VARCHAR2) RETURN VARCHAR2;

END vehicle_batch_pkg;
/
