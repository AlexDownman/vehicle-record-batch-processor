-- extract_vehicles.sql
-- Spools a CSV extract of every vehicle's registration, colour and status.
-- scripts/generate_nightly.py reads it to build realistic change records.
--
-- Run as VSS (rerun before generating a file, so scrapped vehicles and
-- colour changes from earlier batch runs are picked up):
--   docker/oracle.sh sqlplus -s vss@FREEPDB1 @/sql/extract_vehicles.sql
--
-- Output: /data/seed/vehicle_extract.csv (data/seed/ on the host)

WHENEVER SQLERROR EXIT SQL.SQLCODE

-- MARKUP CSV makes SQL*Plus print query results as CSV with one header
-- line. TERMOUT OFF stops the rows also being echoed to the screen.
SET MARKUP CSV ON QUOTE OFF
SET FEEDBACK OFF
SET TERMOUT OFF

SPOOL /data/seed/vehicle_extract.csv
SELECT registration, colour, status
FROM   vehicles
ORDER  BY registration;
SPOOL OFF

SET TERMOUT ON
PROMPT Extract written to /data/seed/vehicle_extract.csv
EXIT
