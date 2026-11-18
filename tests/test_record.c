/*
 * test_record.c - unit tests for the record checks in src/record.c.
 *
 * Run with: make test
 */
#include "record.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                        \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

/* Builds a 72-character change record in `buf` (size RECORD_LEN + 1). */
static void make_record(char *buf, const char *reg, const char *type, const char *value,
                        const char *postcode, const char *date)
{
    snprintf(buf, RECORD_LEN + 1, "%-8.8s%-8.8s%-40.40s%-8.8s%-8.8s", reg, type, value, postcode,
             date);
}

static enum reject_reason check(const char *reg, const char *type, const char *value,
                                const char *postcode, const char *date)
{
    char buf[RECORD_LEN + 1];
    make_record(buf, reg, type, value, postcode, date);
    return validate_change(buf, strlen(buf));
}

static void test_good_records(void)
{
    CHECK(check("AB12 CDE", "KEEPER", "Jane Smith", "SA1 1AA", "20240115") == REASON_NONE);
    CHECK(check("AB12 CDE", "COLOUR", "RED", "", "20240115") == REASON_NONE);
    CHECK(check("AB12 CDE", "SCRAP", "", "", "20240115") == REASON_NONE);
}

static void test_length(void)
{
    char buf[RECORD_LEN + 2];
    make_record(buf, "AB12 CDE", "SCRAP", "", "", "20240115");
    CHECK(validate_change(buf, RECORD_LEN - 1) == REASON_BAD_LENGTH);
    /* A Windows line ending leaves a \r on the end: 73 characters. */
    strcat(buf, "\r");
    CHECK(validate_change(buf, strlen(buf)) == REASON_BAD_LENGTH);
}

static void test_bad_character(void)
{
    CHECK(check("AB12 CDE", "KEEPER", "Jane\tSmith", "SA1 1AA", "20240115") ==
          REASON_BAD_CHARACTER);
}

static void test_registration(void)
{
    CHECK(check("ab12 cde", "SCRAP", "", "", "20240115") == REASON_BAD_REG_FORMAT);
    CHECK(check("AB12CDE", "SCRAP", "", "", "20240115") == REASON_BAD_REG_FORMAT);
    CHECK(check("12AB CDE", "SCRAP", "", "", "20240115") == REASON_BAD_REG_FORMAT);
    CHECK(check("", "SCRAP", "", "", "20240115") == REASON_BAD_REG_FORMAT);
}

static void test_change_type(void)
{
    CHECK(check("AB12 CDE", "OWNER", "Jane Smith", "SA1 1AA", "20240115") ==
          REASON_BAD_CHANGE_TYPE);
    CHECK(check("AB12 CDE", "keeper", "Jane Smith", "SA1 1AA", "20240115") ==
          REASON_BAD_CHANGE_TYPE);
    CHECK(check("AB12 CDE", "SCRAPPED", "", "", "20240115") == REASON_BAD_CHANGE_TYPE);
}

static void test_dates(void)
{
    CHECK(is_valid_date("20240115"));
    CHECK(is_valid_date("20240229")); /* leap year */
    CHECK(is_valid_date("20000229")); /* divisible by 400: leap */
    CHECK(!is_valid_date("19000229")); /* divisible by 100: not leap */
    CHECK(!is_valid_date("20230229"));
    CHECK(!is_valid_date("20240230"));
    CHECK(!is_valid_date("20241301"));
    CHECK(!is_valid_date("20240000"));
    CHECK(!is_valid_date("2024AB01"));
    CHECK(!is_valid_date("18991231"));
    CHECK(check("AB12 CDE", "SCRAP", "", "", "20240230") == REASON_BAD_DATE);
}

static void test_missing_value(void)
{
    CHECK(check("AB12 CDE", "KEEPER", "", "SA1 1AA", "20240115") == REASON_MISSING_VALUE);
    CHECK(check("AB12 CDE", "KEEPER", "Jane Smith", "", "20240115") == REASON_MISSING_VALUE);
    CHECK(check("AB12 CDE", "COLOUR", "", "", "20240115") == REASON_MISSING_VALUE);
}

static void test_header_and_trailer(void)
{
    char buf[RECORD_LEN + 1];
    char date[DATE_LEN + 1];
    unsigned long count = 0;

    snprintf(buf, sizeof buf, "%-72s", "HDR20240115");
    CHECK(parse_header(buf, strlen(buf), date));
    CHECK(strcmp(date, "20240115") == 0);
    snprintf(buf, sizeof buf, "%-72s", "HDR20241301");
    CHECK(!parse_header(buf, strlen(buf), date));
    CHECK(!parse_header("HDR20240115", 11, date));

    snprintf(buf, sizeof buf, "%-72s", "TRL000001000");
    CHECK(parse_trailer(buf, strlen(buf), &count));
    CHECK(count == 1000);
    snprintf(buf, sizeof buf, "%-72s", "TRL0000010X0");
    CHECK(!parse_trailer(buf, strlen(buf), &count));
}

int main(void)
{
    test_good_records();
    test_length();
    test_bad_character();
    test_registration();
    test_change_type();
    test_dates();
    test_missing_value();
    test_header_and_trailer();

    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("record tests passed");
    return 0;
}
