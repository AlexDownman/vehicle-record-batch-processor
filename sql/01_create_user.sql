-- 01_create_user.sql
-- Creates the VSS schema owner in the FREEPDB1 pluggable database.
--
-- Run as SYSTEM, connected to the PDB (not the root container CDB$ROOT):
--   docker/oracle.sh sqlplus system@FREEPDB1 @/sql/01_create_user.sql
--
-- In Oracle a user and a schema are the same thing: every table VSS creates
-- lives in the VSS schema.

WHENEVER SQLERROR EXIT SQL.SQLCODE
SET VERIFY OFF

ACCEPT vss_password CHAR PROMPT 'Password for VSS: ' HIDE

CREATE USER vss IDENTIFIED BY "&vss_password"
    DEFAULT TABLESPACE users
    TEMPORARY TABLESPACE temp
    QUOTA UNLIMITED ON users;

-- CONNECT allows logging in; RESOURCE allows creating tables, sequences,
-- procedures, packages and triggers in its own schema.
GRANT CONNECT, RESOURCE TO vss;

PROMPT User VSS created.
EXIT
