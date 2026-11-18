-- 03_staging.sql
-- Creates MOT_STAGING, the landing table for the DVSA MOT test result CSV.
--
-- Run as VSS, connected to the PDB:
--   docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/03_staging.sql
--
-- A staging table mirrors the source file column for column and has no
-- business rules. SQL*Loader fills it, and later scripts read from it to
-- build VEHICLES. It is safe to drop and recreate at any time.
--
-- There is deliberately no primary key: the DVSA files contain exact
-- duplicate rows (the same test_id repeated), and staging must accept
-- the file as published.
--
-- Column widths come from profiling the full January 2024 file, not just
-- the 50,000-row sample (e.g. the longest MAKE is 44 characters).

WHENEVER SQLERROR EXIT SQL.SQLCODE

-- IF EXISTS is new in Oracle 23ai; older releases raise ORA-00942 instead.
DROP TABLE IF EXISTS mot_staging PURGE;

CREATE TABLE mot_staging (
    test_id            NUMBER(12)    CONSTRAINT mot_stg_test_id_nn    NOT NULL,
    vehicle_id         NUMBER(12)    CONSTRAINT mot_stg_vehicle_id_nn NOT NULL,
    test_date          DATE,
    test_class_id      VARCHAR2(2),
    test_type          VARCHAR2(2),
    test_result        VARCHAR2(3),
    test_mileage       NUMBER(9),
    postcode_area      VARCHAR2(2),
    make               VARCHAR2(50),
    model              VARCHAR2(50),
    colour             VARCHAR2(20),
    fuel_type          VARCHAR2(30),
    cylinder_capacity  NUMBER(6),
    first_use_date     DATE,
    completed_date     TIMESTAMP(3)
);

COMMENT ON TABLE  mot_staging                IS 'Raw DVSA MOT test results, loaded by SQL*Loader (sql/loader/mot.ctl)';
COMMENT ON COLUMN mot_staging.vehicle_id     IS 'DVSA anonymised vehicle identifier; one vehicle has many tests';
COMMENT ON COLUMN mot_staging.test_mileage   IS 'Published with a decimal suffix (71614.0); stored as a whole number';
COMMENT ON COLUMN mot_staging.fuel_type      IS 'Mixes codes (PE, DI) with words (Electric, Hybrid Electric (Clean))';
COMMENT ON COLUMN mot_staging.completed_date IS 'UTC; source is ISO-8601 with a Z suffix';

-- VEHICLES is built with GROUP BY vehicle_id, so index it.
CREATE INDEX mot_stg_vehicle_id_ix ON mot_staging (vehicle_id);

PROMPT Table MOT_STAGING created.
EXIT
