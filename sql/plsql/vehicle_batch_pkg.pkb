-- vehicle_batch_pkg.pkb
-- Package body: business rules and bookkeeping for the nightly batch.
--
-- Transactions: each record is applied after a SAVEPOINT, so a rejected
-- record is rolled back on its own without losing the others. The whole
-- file is committed once at the end. If the run fails part-way, nothing
-- from the file is applied, so it is always safe to rerun.

CREATE OR REPLACE PACKAGE BODY vehicle_batch_pkg AS

    -- Reason codes for business-rule rejections (docs/file-format.md).
    c_unknown_reg       CONSTANT VARCHAR2(30) := 'UNKNOWN_REG';
    c_already_scrapped  CONSTANT VARCHAR2(30) := 'ALREADY_SCRAPPED';
    c_bad_postcode      CONSTANT VARCHAR2(30) := 'BAD_POSTCODE';
    c_date_conflict     CONSTANT VARCHAR2(30) := 'DATE_CONFLICT';
    c_bad_colour        CONSTANT VARCHAR2(30) := 'BAD_COLOUR';
    c_db_error          CONSTANT VARCHAR2(30) := 'DB_ERROR';

    -- Same pattern as keepers_postcode_ck in sql/02_tables.sql.
    c_postcode_pattern  CONSTANT VARCHAR2(60) :=
        '^[A-Z]{1,2}[0-9][A-Z0-9]? [0-9][A-Z]{2}$';

    -- Width of VEHICLES.colour; the file's value field is wider.
    c_max_colour_len    CONSTANT PLS_INTEGER := 20;

    -- A cursor with a RETURN type gives rows of exactly batch_input%ROWTYPE,
    -- so each one can be passed straight to apply_update.
    CURSOR c_input RETURN batch_input%ROWTYPE IS
        SELECT line_number, registration, change_type, new_value,
               postcode, effective_date
        FROM   batch_input
        ORDER  BY line_number;

    -- -----------------------------------------------------------------------
    FUNCTION reason_text(p_reason_code IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_reason_code
            WHEN 'BAD_LENGTH'       THEN 'Record is not 72 characters long'
            WHEN 'BAD_CHARACTER'    THEN 'Record contains a tab, control or non-ASCII character'
            WHEN 'BAD_REG_FORMAT'   THEN 'Registration is not in the format AB12 CDE'
            WHEN 'BAD_CHANGE_TYPE'  THEN 'Change type is not KEEPER, COLOUR or SCRAP'
            WHEN 'BAD_DATE'         THEN 'Effective date is not a real YYYYMMDD date'
            WHEN 'MISSING_VALUE'    THEN 'Keeper name, postcode or colour is missing'
            WHEN c_unknown_reg      THEN 'No vehicle has this registration'
            WHEN c_already_scrapped THEN 'Vehicle has already been scrapped'
            WHEN c_bad_postcode     THEN 'Postcode is not a valid UK postcode format'
            WHEN c_date_conflict    THEN 'Effective date is not after the current keeper''s start date'
            WHEN c_bad_colour       THEN 'Colour is longer than 20 characters'
            WHEN c_db_error         THEN 'Unexpected database error'
            ELSE 'Unknown reason code'
        END;
    END reason_text;

    -- -----------------------------------------------------------------------
    -- Rebuilds the 72-character record from its fields, for REJECTIONS.
    FUNCTION rebuild_record(p_input IN batch_input%ROWTYPE) RETURN VARCHAR2 IS
    BEGIN
        RETURN RPAD(p_input.registration, 8)
            || RPAD(p_input.change_type, 8)
            || RPAD(NVL(p_input.new_value, ' '), 40)
            || RPAD(NVL(p_input.postcode, ' '), 8)
            || TO_CHAR(p_input.effective_date, 'YYYYMMDD');
    END rebuild_record;

    -- -----------------------------------------------------------------------
    PROCEDURE log_rejection(
        p_batch_run_id IN batch_runs.batch_run_id%TYPE,
        p_input        IN batch_input%ROWTYPE,
        p_reason_code  IN VARCHAR2,
        p_reason_text  IN VARCHAR2
    ) IS
        -- Private functions cannot be called inside SQL (PLS-00231),
        -- so build the value first.
        v_raw rejections.raw_record%TYPE := rebuild_record(p_input);
    BEGIN
        INSERT INTO rejections (
            batch_run_id, line_number, stage, reason_code, reason_text,
            registration, change_type, raw_record
        ) VALUES (
            p_batch_run_id, p_input.line_number, 'PLSQL', p_reason_code,
            SUBSTR(p_reason_text, 1, 200), p_input.registration,
            p_input.change_type, v_raw
        );
    END log_rejection;

    -- -----------------------------------------------------------------------
    -- Starts a run. Commits, so the RUNNING row is visible to anyone
    -- checking on the batch even while the file is being processed.
    FUNCTION start_run(p_file_name IN VARCHAR2)
        RETURN batch_runs.batch_run_id%TYPE
    IS
        v_count   PLS_INTEGER;
        v_run_id  batch_runs.batch_run_id%TYPE;
    BEGIN
        -- Take an exclusive lock so two sessions cannot both pass the
        -- checks below at the same moment. COMMIT releases it.
        LOCK TABLE batch_runs IN EXCLUSIVE MODE;

        SELECT COUNT(*) INTO v_count FROM batch_runs WHERE status = 'RUNNING';
        IF v_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20001,
                'Another batch run is still RUNNING. If no batch is active, it '
                || 'crashed: investigate, then set its status to FAILED.');
        END IF;

        SELECT COUNT(*) INTO v_count
        FROM   batch_runs
        WHERE  file_name = p_file_name
        AND    status = 'COMPLETED';
        IF v_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
                'File ' || p_file_name || ' has already been processed.');
        END IF;

        INSERT INTO batch_runs (file_name)
        VALUES (p_file_name)
        RETURNING batch_run_id INTO v_run_id;
        COMMIT;
        RETURN v_run_id;
    END start_run;

    -- -----------------------------------------------------------------------
    PROCEDURE finish_run(
        p_batch_run_id IN batch_runs.batch_run_id%TYPE,
        p_status       IN VARCHAR2,
        p_read         IN PLS_INTEGER,
        p_applied      IN PLS_INTEGER,
        p_rejected     IN PLS_INTEGER
    ) IS
    BEGIN
        UPDATE batch_runs
        SET    status           = p_status,
               finished_at      = SYSTIMESTAMP,
               records_read     = p_read,
               records_applied  = p_applied,
               records_rejected = p_rejected
        WHERE  batch_run_id = p_batch_run_id;
    END finish_run;

    -- -----------------------------------------------------------------------
    -- Copies the validator's rejects into REJECTIONS. Returns the count.
    FUNCTION copy_validator_rejects(p_batch_run_id IN batch_runs.batch_run_id%TYPE)
        RETURN PLS_INTEGER
    IS
    BEGIN
        INSERT INTO rejections (
            batch_run_id, line_number, stage, reason_code, reason_text,
            registration, change_type, raw_record
        )
        SELECT p_batch_run_id, line_number, 'VALIDATOR', reason_code,
               reason_text(reason_code),
               TRIM(SUBSTR(raw_record, 1, 8)), TRIM(SUBSTR(raw_record, 9, 8)),
               raw_record
        FROM   batch_input_rejects;
        RETURN SQL%ROWCOUNT;
    END copy_validator_rejects;

    -- -----------------------------------------------------------------------
    FUNCTION apply_update(
        p_batch_run_id IN batch_runs.batch_run_id%TYPE,
        p_input        IN batch_input%ROWTYPE
    ) RETURN VARCHAR2
    IS
        v_vehicle_id    vehicles.vehicle_id%TYPE;
        v_status        vehicles.status%TYPE;
        v_keeper_start  keepers.start_date%TYPE;
    BEGIN
        -- FOR UPDATE locks the vehicle row until the transaction ends, so
        -- nothing else can change it between these checks and the update.
        BEGIN
            SELECT vehicle_id, status
            INTO   v_vehicle_id, v_status
            FROM   vehicles
            WHERE  registration = p_input.registration
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RETURN c_unknown_reg;
        END;

        -- Includes vehicles scrapped by an earlier line of this same file:
        -- that change is not committed yet, but this session can see it.
        IF v_status = 'SCRAPPED' THEN
            RETURN c_already_scrapped;
        END IF;

        CASE p_input.change_type
            WHEN 'KEEPER' THEN
                IF NOT REGEXP_LIKE(p_input.postcode, c_postcode_pattern) THEN
                    RETURN c_bad_postcode;
                END IF;

                BEGIN
                    SELECT start_date
                    INTO   v_keeper_start
                    FROM   keepers
                    WHERE  vehicle_id = v_vehicle_id
                    AND    end_date IS NULL
                    FOR UPDATE;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        v_keeper_start := NULL;  -- no current keeper to end
                END;

                -- The old keeper's period ends the day before the new one
                -- starts, so the new start must be after the old start.
                IF p_input.effective_date <= v_keeper_start THEN
                    RETURN c_date_conflict;
                END IF;

                UPDATE keepers
                SET    end_date = p_input.effective_date - 1
                WHERE  vehicle_id = v_vehicle_id
                AND    end_date IS NULL;

                INSERT INTO keepers (vehicle_id, keeper_name, postcode, start_date)
                VALUES (v_vehicle_id, p_input.new_value, p_input.postcode,
                        p_input.effective_date);

            WHEN 'COLOUR' THEN
                IF LENGTH(p_input.new_value) > c_max_colour_len THEN
                    RETURN c_bad_colour;
                END IF;

                UPDATE vehicles
                SET    colour = p_input.new_value
                WHERE  vehicle_id = v_vehicle_id;

            WHEN 'SCRAP' THEN
                UPDATE vehicles
                SET    status        = 'SCRAPPED',
                       scrapped_date = p_input.effective_date
                WHERE  vehicle_id = v_vehicle_id;

            -- No ELSE: the validator only passes the three types. Anything
            -- else raises CASE_NOT_FOUND, which is logged as DB_ERROR.
        END CASE;

        UPDATE vehicles
        SET    last_updated      = SYSTIMESTAMP,
               last_batch_run_id = p_batch_run_id
        WHERE  vehicle_id = v_vehicle_id;

        RETURN NULL;
    END apply_update;

    -- -----------------------------------------------------------------------
    FUNCTION process_file(p_file_name IN VARCHAR2)
        RETURN batch_runs.batch_run_id%TYPE
    IS
        v_run_id    batch_runs.batch_run_id%TYPE;
        v_reason    VARCHAR2(30);
        v_read      PLS_INTEGER := 0;
        v_applied   PLS_INTEGER := 0;
        v_rejected  PLS_INTEGER := 0;
    BEGIN
        v_run_id := start_run(p_file_name);
        DBMS_OUTPUT.PUT_LINE('Batch run ' || v_run_id || ' started for ' || p_file_name);

        v_rejected := copy_validator_rejects(v_run_id);
        v_read := v_rejected;

        FOR r IN c_input LOOP
            v_read := v_read + 1;
            SAVEPOINT before_record;
            BEGIN
                v_reason := apply_update(v_run_id, r);
                IF v_reason IS NULL THEN
                    v_applied := v_applied + 1;
                ELSE
                    ROLLBACK TO before_record;
                    log_rejection(v_run_id, r, v_reason, reason_text(v_reason));
                    v_rejected := v_rejected + 1;
                END IF;
            EXCEPTION
                -- An unexpected error on one record (e.g. a constraint
                -- violation) rejects that record with the Oracle message,
                -- so it is recorded for investigation rather than lost.
                WHEN OTHERS THEN
                    ROLLBACK TO before_record;
                    log_rejection(v_run_id, r, c_db_error, SQLERRM);
                    v_rejected := v_rejected + 1;
                    DBMS_OUTPUT.PUT_LINE('Line ' || r.line_number || ': ' || SQLERRM);
            END;
        END LOOP;

        finish_run(v_run_id, 'COMPLETED', v_read, v_applied, v_rejected);
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('Batch run ' || v_run_id || ' COMPLETED: ' || v_read
            || ' read, ' || v_applied || ' applied, ' || v_rejected || ' rejected');
        RETURN v_run_id;
    EXCEPTION
        WHEN OTHERS THEN
            -- Undo the file's changes, record the failure, and re-raise so
            -- the caller (run_batch.sh) sees it and exits non-zero.
            ROLLBACK;
            IF v_run_id IS NOT NULL THEN
                finish_run(v_run_id, 'FAILED', v_read, 0, 0);
                COMMIT;
                DBMS_OUTPUT.PUT_LINE('Batch run ' || v_run_id || ' FAILED: ' || SQLERRM);
            END IF;
            RAISE;
    END process_file;

END vehicle_batch_pkg;
/
