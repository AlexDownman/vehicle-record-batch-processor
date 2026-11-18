-- 04_seed_vehicles.sql
-- Fills VEHICLES from MOT_STAGING: one row per vehicle_id, each with a
-- unique synthetic UK registration.
--
-- Run as VSS after the staging load:
--   docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/04_seed_vehicles.sql
--
-- Safe to rerun: it clears KEEPERS and VEHICLES first. Load keepers again
-- afterwards (sql/loader/keepers.ctl).

WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET SERVEROUTPUT ON

-- KEEPERS references VEHICLES, so it must be emptied first.
DELETE FROM keepers;
DELETE FROM vehicles;

-- An anonymous block: PL/SQL that runs once and is not stored in the
-- database. Its local functions exist only while the block runs.
DECLARE
    -- Letters used on real plates: I, Q and Z are left out because they
    -- are easily mistaken for 1, O and 2.
    c_letters      CONSTANT VARCHAR2(23) := 'ABCDEFGHJKLMNOPRSTUVWXY';
    -- The current plate format started in September 2001.
    c_format_start CONSTANT DATE := DATE '2001-09-01';
    c_max_attempts CONSTANT PLS_INTEGER := 10;

    v_inserted     PLS_INTEGER := 0;
    v_collisions   PLS_INTEGER := 0;
    v_attempts     PLS_INTEGER;
    v_registration vehicles.registration%TYPE;

    FUNCTION random_letters(p_count IN PLS_INTEGER) RETURN VARCHAR2 IS
        v_result VARCHAR2(10);
    BEGIN
        FOR i IN 1 .. p_count LOOP
            -- DBMS_RANDOM.VALUE(1, 24) returns 1 <= n < 24, so TRUNC gives 1..23.
            v_result := v_result
                     || SUBSTR(c_letters, TRUNC(DBMS_RANDOM.VALUE(1, 24)), 1);
        END LOOP;
        RETURN v_result;
    END random_letters;

    -- The two digits show when the vehicle was first registered:
    -- March-August uses the year (Mar 2024 -> 24), September-February
    -- uses the year + 50 (Sep 2024 -> 74, Jan 2025 -> 74).
    -- Simplification: vehicles older than the format are treated as
    -- September 2001 (51).
    FUNCTION age_identifier(p_first_use IN DATE) RETURN VARCHAR2 IS
        v_date  DATE        := GREATEST(p_first_use, c_format_start);
        v_year  PLS_INTEGER := EXTRACT(YEAR FROM v_date);
        v_month PLS_INTEGER := EXTRACT(MONTH FROM v_date);
    BEGIN
        IF v_month BETWEEN 3 AND 8 THEN
            RETURN TO_CHAR(MOD(v_year, 100), 'FM00');
        ELSIF v_month >= 9 THEN
            RETURN TO_CHAR(MOD(v_year, 100) + 50, 'FM00');
        ELSE
            -- January and February belong to the previous September's series.
            RETURN TO_CHAR(MOD(v_year - 1, 100) + 50, 'FM00');
        END IF;
    END age_identifier;

    FUNCTION make_registration(p_first_use IN DATE) RETURN VARCHAR2 IS
    BEGIN
        RETURN random_letters(2) || age_identifier(p_first_use)
            || ' ' || random_letters(3);
    END make_registration;
BEGIN
    -- A fixed seed gives the same registrations on every rerun, which
    -- makes test files and runbook examples repeatable.
    DBMS_RANDOM.SEED(20240101);

    -- A vehicle has many tests. KEEP (DENSE_RANK LAST ORDER BY ...) takes
    -- each value from the latest test only, because colour, model and even
    -- first_use_date can differ between a vehicle's tests.
    FOR v IN (
        SELECT vehicle_id,
               MAX(make)              KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS make,
               MAX(model)             KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS model,
               MAX(colour)            KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS colour,
               MAX(fuel_type)         KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS fuel_type,
               MAX(cylinder_capacity) KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS cylinder_capacity,
               MAX(first_use_date)    KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS first_use_date,
               MAX(test_mileage)      KEEP (DENSE_RANK LAST ORDER BY completed_date, test_id) AS latest_mileage
        FROM   mot_staging
        GROUP  BY vehicle_id
        ORDER  BY vehicle_id
    ) LOOP
        v_attempts := 0;
        -- Random registrations can collide. The unique constraint catches
        -- it (DUP_VAL_ON_INDEX) and we try another, up to a limit so a
        -- different duplicate (e.g. vehicle_id) cannot loop forever.
        LOOP
            BEGIN
                v_attempts := v_attempts + 1;
                -- Local functions cannot be called inside a SQL statement
                -- (PLS-00231), so build the value first and bind it.
                v_registration := make_registration(v.first_use_date);
                INSERT INTO vehicles (
                    vehicle_id, registration, make, model, colour, fuel_type,
                    cylinder_capacity, first_use_date, latest_mileage
                ) VALUES (
                    v.vehicle_id, v_registration, v.make,
                    v.model, v.colour, v.fuel_type, v.cylinder_capacity,
                    v.first_use_date, v.latest_mileage
                );
                EXIT;
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    IF v_attempts >= c_max_attempts THEN
                        RAISE;
                    END IF;
                    v_collisions := v_collisions + 1;
            END;
        END LOOP;
        v_inserted := v_inserted + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Vehicles inserted:       ' || v_inserted);
    DBMS_OUTPUT.PUT_LINE('Registration collisions: ' || v_collisions);
END;
/

EXIT
