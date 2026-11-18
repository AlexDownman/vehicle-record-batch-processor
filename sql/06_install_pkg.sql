-- 06_install_pkg.sql
-- Compiles vehicle_batch_pkg (specification, then body).
--
-- Run as VSS:
--   docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/06_install_pkg.sql
--
-- Safe to rerun: CREATE OR REPLACE recompiles in place.

WHENEVER SQLERROR EXIT SQL.SQLCODE

@/sql/plsql/vehicle_batch_pkg.pks
SHOW ERRORS PACKAGE vehicle_batch_pkg
@/sql/plsql/vehicle_batch_pkg.pkb
SHOW ERRORS PACKAGE BODY vehicle_batch_pkg

-- Neither a compilation error ("created with compilation errors") nor a
-- missing script file (SP2-0310) stops WHENEVER SQLERROR, so check
-- explicitly that both the specification and the body exist and are
-- VALID. Counting INVALID objects instead would pass if neither existed.
DECLARE
    v_valid PLS_INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO   v_valid
    FROM   all_objects
    WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
    AND    object_name = 'VEHICLE_BATCH_PKG'
    AND    object_type IN ('PACKAGE', 'PACKAGE BODY')
    AND    status = 'VALID';
    IF v_valid <> 2 THEN
        RAISE_APPLICATION_ERROR(-20000,
            'vehicle_batch_pkg is missing or INVALID: see the messages above');
    END IF;
END;
/

PROMPT Package VEHICLE_BATCH_PKG installed and valid.
EXIT
