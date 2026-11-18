-- extract_vehicles.sql
-- Spools a CSV extract of every vehicle's registration, colour, status and
-- current keeper start date.
-- scripts/generate_nightly.py reads it to build realistic change records.
--
-- Run as VSS (rerun before generating a file, so scrapped vehicles and
-- colour changes from earlier batch runs are picked up):
--   docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/extract_vehicles.sql
-- (Not with -s: silent mode also hides the password prompt, so it looks hung.)
--
-- Output: /data/seed/vehicle_extract.csv (data/seed/ on the host)

WHENEVER SQLERROR EXIT SQL.SQLCODE

-- MARKUP CSV makes SQL*Plus print query results as CSV with one header
-- line. TERMOUT OFF stops the rows also being echoed to the screen.
SET MARKUP CSV ON QUOTE OFF
SET FEEDBACK OFF
SET TERMOUT OFF

-- KEEPER_START is the current keeper's start date (YYYYMMDD), so the
-- generator can keep new keeper changes after it. LEFT JOIN keeps a
-- vehicle that has no current keeper, with KEEPER_START empty.
SPOOL /data/seed/vehicle_extract.csv
SELECT v.registration, v.colour, v.status,
       TO_CHAR(k.start_date, 'YYYYMMDD') AS keeper_start
FROM   vehicles v
LEFT   JOIN keepers k
       ON  k.vehicle_id = v.vehicle_id
       AND k.end_date IS NULL
ORDER  BY v.registration;
SPOOL OFF

SET TERMOUT ON
PROMPT Extract written to /data/seed/vehicle_extract.csv
EXIT
