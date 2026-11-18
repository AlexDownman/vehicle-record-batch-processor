-- keepers.ctl
-- SQL*Loader control file: loads synthetic keepers into KEEPERS.
--
-- Generate the input first (on the host):
--   .venv/bin/python scripts/generate_keepers.py data/seed/mot_sample.csv data/seed/keepers.csv
-- Then load it, after sql/04_seed_vehicles.sql has filled VEHICLES:
--   docker/oracle.sh sqlldr vss@FREEPDB1 control=/sql/loader/keepers.ctl log=/data/logs/keepers_load.log
--
-- keeper_id is an identity column, so it is not listed: Oracle assigns it.
-- A keeper whose vehicle_id is not in VEHICLES fails the foreign key and
-- goes to the BADFILE.

OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE      '/data/seed/keepers.csv'
BADFILE     '/data/logs/keepers_load.bad'
TRUNCATE
INTO TABLE keepers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    vehicle_id,
    keeper_name,
    postcode,
    start_date  DATE "YYYY-MM-DD",
    -- Empty for the current keeper, which loads as NULL.
    end_date    DATE "YYYY-MM-DD"
)
