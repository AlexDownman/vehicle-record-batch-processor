/*
 * record.h - structural checks for lines of the nightly update file.
 *
 * The layout is documented in docs/file-format.md. These functions only
 * look at the shape of a line; business rules (does the vehicle exist?)
 * belong to the PL/SQL package.
 */
#ifndef VRBP_RECORD_H
#define VRBP_RECORD_H

#include <stdbool.h>
#include <stddef.h>

#define RECORD_LEN 72
#define DATE_LEN 8

/* Reason a change record is rejected. REASON_NONE means it is clean. */
enum reject_reason {
    REASON_NONE = 0,
    REASON_BAD_LENGTH,
    REASON_BAD_CHARACTER,
    REASON_BAD_REG_FORMAT,
    REASON_BAD_CHANGE_TYPE,
    REASON_BAD_DATE,
    REASON_MISSING_VALUE,
    REASON_COUNT /* number of reasons, not a reason */
};

/* Reason code as written to the rejects file, e.g. "BAD_DATE". */
const char *reason_code(enum reject_reason reason);

/* Checks one change record of `len` characters (without its newline). */
enum reject_reason validate_change(const char *line, size_t len);

/* True if `field` holds DATE_LEN digits forming a real YYYYMMDD date. */
bool is_valid_date(const char *field);

/* True if `line` is a valid header record; copies its date to `date_out`. */
bool parse_header(const char *line, size_t len, char date_out[DATE_LEN + 1]);

/* True if `line` is a valid trailer record; stores its record count. */
bool parse_trailer(const char *line, size_t len, unsigned long *count);

#endif /* VRBP_RECORD_H */
