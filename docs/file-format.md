# Nightly update file format

The nightly file carries vehicle-record changes into the batch. It is
produced by `scripts/generate_nightly.py` (standing in for an upstream
system) and read by the C validator, then by `vehicle_batch_pkg`.

## File

| Property | Value |
|---|---|
| Name | `nightly_YYYYMMDD.dat`, where `YYYYMMDD` is the file date |
| Location | `data/inbound/` |
| Encoding | ASCII only, so one character is one byte |
| Line ending | LF (`\n`), not CRLF |
| Record length | 72 characters on every line, trailing spaces kept |
| Structure | one header line, any number of change records, one trailer line |

The generator writes `nightly_YYYYMMDD.dat.tmp` and renames it when
complete, so a file with the `.dat` name is never half-written.

## Header record (line 1)

| Field | Positions | Width | Content |
|---|---|---|---|
| Record type | 1–3 | 3 | `HDR` |
| File date | 4–11 | 8 | `YYYYMMDD`, must match the date in the file name |
| Filler | 12–72 | 61 | spaces |

## Change record (lines 2 to n−1)

| Field | Positions | Width | Content |
|---|---|---|---|
| Registration | 1–8 | 8 | `AB12 CDE`: two letters, two digits, a space, three letters (uppercase) |
| Change type | 9–16 | 8 | `KEEPER`, `COLOUR` or `SCRAP`, left-aligned, space-padded |
| Value | 17–56 | 40 | `KEEPER`: new keeper's name. `COLOUR`: new colour. `SCRAP`: blank |
| Postcode | 57–64 | 8 | `KEEPER`: new keeper's postcode, left-aligned. Otherwise blank |
| Effective date | 65–72 | 8 | `YYYYMMDD`, a real calendar date |

All text fields are left-aligned and padded with spaces.

Example (`|` marks the end of the line):

```
SG12 JLGKEEPER  Chelsea Brooks                          E6B 3ZQ 20240111|
SG12 JLGCOLOUR  RED                                             20240111|
JV16 JDBSCRAP                                                   20240110|
```

## Trailer record (last line)

| Field | Positions | Width | Content |
|---|---|---|---|
| Record type | 1–3 | 3 | `TRL` |
| Record count | 4–12 | 9 | number of change records (excluding header and trailer), zero-padded |
| Filler | 13–72 | 60 | spaces |

A missing trailer, or a count that does not match, means the file was
truncated or damaged in transit. The whole file is rejected, not just
the faulty records.

## Line numbers

Line numbers are physical lines in the file, with the header as line 1.
`REJECTIONS.line_number` and the `.expected` file both use this.

## Rejection reasons

Each rejected change record gets one reason code. The **validator**
checks structure: is each field the right shape? **PL/SQL** checks
business rules against the database.

| Code | Stage | Meaning |
|---|---|---|
| `BAD_LENGTH` | VALIDATOR | Line is not 72 characters |
| `BAD_REG_FORMAT` | VALIDATOR | Registration does not match `AB12 CDE` |
| `BAD_CHANGE_TYPE` | VALIDATOR | Change type is not `KEEPER`, `COLOUR` or `SCRAP` |
| `BAD_DATE` | VALIDATOR | Effective date is not a real `YYYYMMDD` date |
| `MISSING_VALUE` | VALIDATOR | `KEEPER` without a name or postcode, or `COLOUR` without a colour |
| `UNKNOWN_REG` | PLSQL | No vehicle has this registration |
| `ALREADY_SCRAPPED` | PLSQL | Vehicle is scrapped (in the database, or by an earlier line of the same file) |
| `BAD_POSTCODE` | PLSQL | Postcode is not a valid UK postcode format |

Records are applied in file order, so a `SCRAP` followed later by a
`COLOUR` for the same vehicle rejects the `COLOUR`.

## Generating a test file

```bash
# 1. Extract current vehicles (rerun after each batch, so scraps are seen)
docker/oracle.sh sqlplus -s vss@FREEPDB1 @/sql/extract_vehicles.sql

# 2. Generate the file (defaults: 1,000 records, 1.5% bad, today's date)
.venv/bin/python scripts/generate_nightly.py \
    --extract data/seed/vehicle_extract.csv --date 20240115
```

The generator also writes `nightly_YYYYMMDD.expected`, a CSV listing each
planted bad record (`line_number,stage,reason_code,registration`), so the
validator and PL/SQL results can be checked against it. The random seed
defaults to the file date, so the same date always gives the same file.
