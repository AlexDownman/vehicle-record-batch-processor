-- mot.ctl
-- SQL*Loader control file: loads the DVSA MOT CSV sample into MOT_STAGING.
--
-- Run inside the container as VSS (the log must go to a writable folder,
-- because /sql is mounted read-only):
--   docker/oracle.sh sqlldr vss@FREEPDB1 control=/sql/loader/mot.ctl log=/data/logs/mot_load.log
--
-- Where rejected rows go:
--   BADFILE      rows Oracle could not convert or insert (bad date, value
--                too wide, unbalanced quotes). Each reason is in the .log.
--   DISCARDFILE  rows that failed the WHEN clause (repeated header lines).

OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE      '/data/seed/mot_sample.csv'
BADFILE     '/data/logs/mot_load.bad'
DISCARDFILE '/data/logs/mot_load.dsc'
-- TRUNCATE empties the table first, so a rerun does not double the data.
TRUNCATE
INTO TABLE mot_staging
-- The monthly files are several files joined together, so the header line
-- appears again part-way through. SKIP=1 only skips the first one.
WHEN (test_id != 'test_id')
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    test_id,
    vehicle_id,
    test_date          DATE "YYYY-MM-DD",
    test_class_id,
    test_type,
    test_result,
    test_mileage,
    postcode_area,
    make,
    model,
    colour,
    fuel_type,
    cylinder_capacity,
    first_use_date     DATE "YYYY-MM-DD",
    -- e.g. 2024-01-02T10:19:28.000Z. Literal text in an Oracle format mask
    -- goes in double quotes, which must be backslash-escaped here.
    completed_date     TIMESTAMP "YYYY-MM-DD\"T\"HH24:MI:SS.FF3\"Z\""
)
