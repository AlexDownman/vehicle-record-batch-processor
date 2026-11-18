/*
 * validator.c - structural pre-validation of the nightly update file.
 *
 * Usage: validator INPUT CLEAN_OUT REJECTS_OUT
 *
 * Reads a fixed-width nightly file (docs/file-format.md), checks the header
 * and trailer, and checks every change record's structure. Clean records go
 * to CLEAN_OUT and bad ones to REJECTS_OUT, each prefixed with its line
 * number in the input file. Business rules are left to vehicle_batch_pkg.
 *
 * Both outputs are written to "<name>.tmp" and renamed only when the whole
 * file passes, so a rejected file never leaves partial output behind.
 *
 * Exit codes:
 *   0  file processed (some records may have been rejected)
 *   1  usage or I/O error
 *   2  file rejected: bad header, missing or bad trailer, wrong count
 */
#include "record.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

enum exit_code {
    RC_OK = 0,
    RC_IO_ERROR = 1,
    RC_FILE_REJECTED = 2,
};

/* Longer lines are read in pieces and rejected as BAD_LENGTH. */
#define LINE_BUF_SIZE 256
/* Matches REJECTIONS.raw_record VARCHAR2(100). */
#define MAX_RAW_LEN 100

struct outputs {
    FILE *clean;
    FILE *rejects;
    char clean_tmp[FILENAME_MAX];
    char rejects_tmp[FILENAME_MAX];
};

struct stats {
    unsigned long records;
    unsigned long by_reason[REASON_COUNT];
};

/* Writes one log line to stderr, prefixed with an ISO-8601 UTC timestamp. */
static void log_msg(const char *fmt, ...)
{
    char stamp[sizeof "2024-01-01T00:00:00Z"];
    time_t now = time(NULL);
    va_list args;

    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", gmtime(&now));
    fprintf(stderr, "%s validator: ", stamp);
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
}

/*
 * Reads one line into `buf` without its newline. A line too long for the
 * buffer is kept truncated, with the rest discarded, and `*len` still
 * gives its full length so it fails the length check.
 * Returns false at end of file or on a read error.
 */
static bool read_line(FILE *in, char *buf, size_t size, size_t *len)
{
    if (fgets(buf, (int)size, in) == NULL)
        return false;

    size_t n = strlen(buf);
    if (n > 0 && buf[n - 1] == '\n') {
        buf[--n] = '\0';
    } else {
        int c;
        while ((c = fgetc(in)) != EOF && c != '\n')
            n++;
    }
    *len = n;
    return true;
}

/*
 * Gets the date from a file name of the form ".../nightly_YYYYMMDD.dat".
 * Returns false if the name does not follow that pattern.
 */
static bool date_from_file_name(const char *path, char date_out[DATE_LEN + 1])
{
    static const char prefix[] = "nightly_";
    static const char suffix[] = ".dat";
    const char *slash = strrchr(path, '/');
    const char *name = slash ? slash + 1 : path;
    size_t prefix_len = sizeof prefix - 1;
    size_t suffix_len = sizeof suffix - 1;

    if (strlen(name) != prefix_len + DATE_LEN + suffix_len)
        return false;
    if (strncmp(name, prefix, prefix_len) != 0)
        return false;
    if (strcmp(name + prefix_len + DATE_LEN, suffix) != 0)
        return false;

    memcpy(date_out, name + prefix_len, DATE_LEN);
    date_out[DATE_LEN] = '\0';
    return true;
}

/* Copies up to MAX_RAW_LEN characters, replacing unprintable ones with '?'. */
static void sanitise(const char *line, size_t len, char out[MAX_RAW_LEN + 1])
{
    size_t n = len < MAX_RAW_LEN ? len : MAX_RAW_LEN;
    for (size_t i = 0; i < n; i++)
        out[i] = (line[i] >= ' ' && line[i] <= '~') ? line[i] : '?';
    out[n] = '\0';
}

static void write_record(struct outputs *out, unsigned long line_no, const char *line, size_t len,
                         enum reject_reason reason)
{
    if (reason == REASON_NONE) {
        fprintf(out->clean, "%09lu%s\n", line_no, line);
    } else {
        char raw[MAX_RAW_LEN + 1];
        sanitise(line, len, raw);
        fprintf(out->rejects, "%09lu %-20s %s\n", line_no, reason_code(reason), raw);
    }
}

static int check_header(const char *line, size_t len, const char *path)
{
    char header_date[DATE_LEN + 1];
    char name_date[DATE_LEN + 1];

    if (!parse_header(line, len, header_date)) {
        /* Name the common cause, so whoever is on support knows where to look. */
        if (len > 0 && line[len - 1] == '\r')
            log_msg("line 1 ends in a carriage return: file has Windows (CRLF) line endings");
        else
            log_msg("line 1 is not a valid header record");
        return RC_FILE_REJECTED;
    }
    if (!date_from_file_name(path, name_date)) {
        log_msg("warning: file name is not nightly_YYYYMMDD.dat; header date not cross-checked");
    } else if (strcmp(header_date, name_date) != 0) {
        log_msg("header date %s does not match file name date %s", header_date, name_date);
        return RC_FILE_REJECTED;
    }
    log_msg("header OK, file date %s", header_date);
    return RC_OK;
}

/* Reads the whole input, writing each change record to the right output. */
static int validate_file(FILE *in, const char *path, struct outputs *out, struct stats *st)
{
    char line[LINE_BUF_SIZE];
    size_t len;
    unsigned long line_no = 0;
    unsigned long trailer_count = 0;
    bool have_trailer = false;

    while (read_line(in, line, sizeof line, &len)) {
        line_no++;

        if (line_no == 1) {
            int rc = check_header(line, len, path);
            if (rc != RC_OK)
                return rc;
            continue;
        }
        if (have_trailer) {
            log_msg("line %lu: data after the trailer record", line_no);
            return RC_FILE_REJECTED;
        }
        if (len >= 3 && memcmp(line, "TRL", 3) == 0) {
            if (!parse_trailer(line, len, &trailer_count)) {
                log_msg("line %lu: invalid trailer record", line_no);
                return RC_FILE_REJECTED;
            }
            have_trailer = true;
            continue;
        }

        enum reject_reason reason = validate_change(line, len);
        st->records++;
        st->by_reason[reason]++;
        write_record(out, line_no, line, len, reason);
    }

    if (ferror(in)) {
        log_msg("error reading %s: %s", path, strerror(errno));
        return RC_IO_ERROR;
    }
    if (line_no == 0) {
        log_msg("file is empty");
        return RC_FILE_REJECTED;
    }
    if (!have_trailer) {
        log_msg("no trailer record: file may be truncated (%lu lines read)", line_no);
        return RC_FILE_REJECTED;
    }
    if (trailer_count != st->records) {
        log_msg("trailer count %lu does not match %lu change records", trailer_count, st->records);
        return RC_FILE_REJECTED;
    }
    return RC_OK;
}

static int open_outputs(struct outputs *out, const char *clean_path, const char *rejects_path)
{
    int n1 = snprintf(out->clean_tmp, sizeof out->clean_tmp, "%s.tmp", clean_path);
    int n2 = snprintf(out->rejects_tmp, sizeof out->rejects_tmp, "%s.tmp", rejects_path);
    if (n1 < 0 || (size_t)n1 >= sizeof out->clean_tmp || n2 < 0 ||
        (size_t)n2 >= sizeof out->rejects_tmp) {
        log_msg("output path too long");
        return RC_IO_ERROR;
    }

    out->clean = fopen(out->clean_tmp, "w");
    if (out->clean == NULL) {
        log_msg("cannot create %s: %s", out->clean_tmp, strerror(errno));
        return RC_IO_ERROR;
    }
    out->rejects = fopen(out->rejects_tmp, "w");
    if (out->rejects == NULL) {
        log_msg("cannot create %s: %s", out->rejects_tmp, strerror(errno));
        fclose(out->clean);
        remove(out->clean_tmp);
        return RC_IO_ERROR;
    }
    return RC_OK;
}

/*
 * Closes both outputs. If everything succeeded they are renamed into
 * place; otherwise the .tmp files are removed. Returns the final code.
 */
static int close_outputs(struct outputs *out, int rc, const char *clean_path,
                         const char *rejects_path)
{
    /* fclose flushes buffered writes, so a full disk shows up here. */
    bool write_failed = ferror(out->clean) || ferror(out->rejects);
    write_failed |= fclose(out->clean) != 0;
    write_failed |= fclose(out->rejects) != 0;
    if (write_failed && rc == RC_OK) {
        log_msg("error writing output files");
        rc = RC_IO_ERROR;
    }

    if (rc == RC_OK) {
        if (rename(out->clean_tmp, clean_path) != 0) {
            log_msg("cannot rename %s: %s", out->clean_tmp, strerror(errno));
            rc = RC_IO_ERROR;
        } else if (rename(out->rejects_tmp, rejects_path) != 0) {
            log_msg("cannot rename %s: %s", out->rejects_tmp, strerror(errno));
            /* Never leave a clean file without its matching rejects file. */
            remove(clean_path);
            rc = RC_IO_ERROR;
        }
    }
    if (rc != RC_OK) {
        remove(out->clean_tmp);
        remove(out->rejects_tmp);
    }
    return rc;
}

static void log_summary(const struct stats *st)
{
    unsigned long clean = st->by_reason[REASON_NONE];

    log_msg("%lu change records: %lu clean, %lu rejected", st->records, clean,
            st->records - clean);
    for (int r = REASON_NONE + 1; r < REASON_COUNT; r++) {
        if (st->by_reason[r] > 0)
            log_msg("  %-20s %lu", reason_code((enum reject_reason)r), st->by_reason[r]);
    }
}

int main(int argc, char *argv[])
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s INPUT CLEAN_OUT REJECTS_OUT\n", argv[0]);
        return RC_IO_ERROR;
    }
    const char *in_path = argv[1];
    const char *clean_path = argv[2];
    const char *rejects_path = argv[3];

    FILE *in = fopen(in_path, "r");
    if (in == NULL) {
        log_msg("cannot open %s: %s", in_path, strerror(errno));
        return RC_IO_ERROR;
    }
    log_msg("validating %s", in_path);

    struct outputs out;
    int rc = open_outputs(&out, clean_path, rejects_path);
    if (rc != RC_OK) {
        fclose(in);
        return rc;
    }

    struct stats st = {0};
    rc = validate_file(in, in_path, &out, &st);
    fclose(in);
    rc = close_outputs(&out, rc, clean_path, rejects_path);

    if (rc == RC_OK)
        log_summary(&st);
    else if (rc == RC_FILE_REJECTED)
        log_msg("FILE REJECTED: no output written");
    return rc;
}
