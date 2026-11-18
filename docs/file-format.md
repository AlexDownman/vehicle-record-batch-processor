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
| `BAD_CHARACTER` | VALIDATOR | Line contains a tab, control or non-ASCII character |
| `BAD_REG_FORMAT` | VALIDATOR | Registration does not match `AB12 CDE` |
| `BAD_CHANGE_TYPE` | VALIDATOR | Change type is not `KEEPER`, `COLOUR` or `SCRAP` |
| `BAD_DATE` | VALIDATOR | Effective date is not a real `YYYYMMDD` date |
| `MISSING_VALUE` | VALIDATOR | `KEEPER` without a name or postcode, or `COLOUR` without a colour |
| `UNKNOWN_REG` | PLSQL | No vehicle has this registration |
| `ALREADY_SCRAPPED` | PLSQL | Vehicle is scrapped (in the database, or by an earlier line of the same file) |
| `BAD_POSTCODE` | PLSQL | Postcode is not a valid UK postcode format |
| `DATE_CONFLICT` | PLSQL | `KEEPER` effective date is not after the current keeper's start date |
| `BAD_COLOUR` | PLSQL | Colour is longer than `VEHICLES.colour` (20 characters) |
| `DB_ERROR` | PLSQL | Unexpected Oracle error on this record; `reason_text` holds the message |

Records are applied in file order, so a `SCRAP` followed later by a
`COLOUR` for the same vehicle rejects the `COLOUR`.

The validator applies its checks in the order listed and reports the
first one that fails. For a `SCRAP`, any value or postcode is ignored.

## Validator outputs

`build/validator INPUT CLEAN_OUT REJECTS_OUT` writes two files.

**Clean file:** one line per record that passed, for `vehicle_batch_pkg`.

| Field | Positions | Width | Content |
|---|---|---|---|
| Line number | 1–9 | 9 | line in the input file, zero-padded |
| Record | 10–81 | 72 | the change record, unchanged |

**Rejects file:** one line per record that failed, for `REJECTIONS`.

| Field | Positions | Width | Content |
|---|---|---|---|
| Line number | 1–9 | 9 | line in the input file, zero-padded |
| Separator | 10 | 1 | space |
| Reason code | 11–30 | 20 | from the table above, space-padded |
| Separator | 31 | 1 | space |
| Raw record | 32–131 | up to 100 | the line as received; unprintable characters shown as `?` |

Both are written as `<name>.tmp` and renamed when the whole file has
passed. If the file is rejected, neither output exists.

**Exit codes**

| Code | Meaning | Outputs |
|---|---|---|
| 0 | File processed; some records may have been rejected | both written |
| 1 | Usage or I/O error (cannot open input, cannot write output) | none |
| 2 | File rejected: empty, bad or missing header, header date not matching the file name, missing or bad trailer, wrong record count, data after the trailer | none |

The validator logs to stderr, one line per message, prefixed with an
ISO-8601 UTC timestamp.

## Generating a test file

```bash
# 1. Extract current vehicles (rerun after each batch, so scraps and new
#    keepers are seen: the generator avoids vehicles whose keeper changed
#    within the last MAX_BACKDATE_DAYS, which would cause DATE_CONFLICT)
docker/oracle.sh sqlplus vss@FREEPDB1 @/sql/extract_vehicles.sql

# 2. Generate the file (defaults: 1,000 records, 1.5% bad, today's date)
.venv/bin/python scripts/generate_nightly.py \
    --extract data/seed/vehicle_extract.csv --date 20240115
```

The generator also writes `nightly_YYYYMMDD.expected`, a CSV listing each
planted bad record (`line_number,stage,reason_code,registration`), so the
validator and PL/SQL results can be checked against it. The random seed
defaults to the file date, so the same date always gives the same file.
