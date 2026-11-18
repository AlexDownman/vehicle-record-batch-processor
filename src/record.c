/*
 * record.c - structural checks for lines of the nightly update file.
 *
 * Field positions follow docs/file-format.md. Positions in the document
 * count from 1; offsets here count from 0.
 */
#include "record.h"

#include <string.h>

/* Change record fields: offset and width. */
#define REG_POS 0
#define REG_LEN 8
#define TYPE_POS 8
#define TYPE_LEN 8
#define VALUE_POS 16
#define VALUE_LEN 40
#define POSTCODE_POS 56
#define POSTCODE_LEN 8
#define DATE_POS 64

/* Header and trailer fields. */
#define TAG_LEN 3
#define COUNT_LEN 9

static const char *const reason_codes[REASON_COUNT] = {
    [REASON_NONE] = "NONE",
    [REASON_BAD_LENGTH] = "BAD_LENGTH",
    [REASON_BAD_CHARACTER] = "BAD_CHARACTER",
    [REASON_BAD_REG_FORMAT] = "BAD_REG_FORMAT",
    [REASON_BAD_CHANGE_TYPE] = "BAD_CHANGE_TYPE",
    [REASON_BAD_DATE] = "BAD_DATE",
    [REASON_MISSING_VALUE] = "MISSING_VALUE",
};

const char *reason_code(enum reject_reason reason)
{
    /* The cast also catches negative values from a bad caller. */
    if ((unsigned)reason >= REASON_COUNT)
        return "UNKNOWN";
    return reason_codes[reason];
}

/* Explicit ranges rather than isupper()/isdigit(), which depend on locale. */
static bool is_upper(char c)
{
    return c >= 'A' && c <= 'Z';
}

static bool is_digit(char c)
{
    return c >= '0' && c <= '9';
}

static bool is_blank(const char *field, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        if (field[i] != ' ')
            return false;
    }
    return true;
}

static bool is_printable(const char *line, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        if (line[i] < ' ' || line[i] > '~')
            return false;
    }
    return true;
}

/*
 * Matches `field` against `pattern`, one character each:
 * 'A' = uppercase letter, '9' = digit, anything else = itself.
 */
static bool matches_pattern(const char *field, const char *pattern)
{
    for (size_t i = 0; pattern[i] != '\0'; i++) {
        bool ok;
        switch (pattern[i]) {
        case 'A':
            ok = is_upper(field[i]);
            break;
        case '9':
            ok = is_digit(field[i]);
            break;
        default:
            ok = field[i] == pattern[i];
            break;
        }
        if (!ok)
            return false;
    }
    return true;
}

static bool is_leap_year(int year)
{
    return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

static int digits_to_int(const char *s, size_t len)
{
    int value = 0;
    for (size_t i = 0; i < len; i++)
        value = value * 10 + (s[i] - '0');
    return value;
}

bool is_valid_date(const char *field)
{
    static const int days_in_month[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

    if (!matches_pattern(field, "99999999"))
        return false;

    int year = digits_to_int(field, 4);
    int month = digits_to_int(field + 4, 2);
    int day = digits_to_int(field + 6, 2);

    if (year < 1900 || month < 1 || month > 12 || day < 1)
        return false;
    int max_day = days_in_month[month - 1];
    if (month == 2 && is_leap_year(year))
        max_day = 29;
    return day <= max_day;
}

/* Change type field, compared with its space padding. */
static bool is_change_type(const char *field, const char *type)
{
    char padded[TYPE_LEN + 1];
    size_t len = strlen(type);

    memset(padded, ' ', TYPE_LEN);
    memcpy(padded, type, len < TYPE_LEN ? len : TYPE_LEN);
    return memcmp(field, padded, TYPE_LEN) == 0;
}

/* Checks run in a fixed order; the first failure is the reason given. */
enum reject_reason validate_change(const char *line, size_t len)
{
    if (len != RECORD_LEN)
        return REASON_BAD_LENGTH;
    if (!is_printable(line, len))
        return REASON_BAD_CHARACTER;
    if (!matches_pattern(line + REG_POS, "AA99 AAA"))
        return REASON_BAD_REG_FORMAT;

    const char *type = line + TYPE_POS;
    bool keeper = is_change_type(type, "KEEPER");
    bool colour = is_change_type(type, "COLOUR");
    bool scrap = is_change_type(type, "SCRAP");
    if (!keeper && !colour && !scrap)
        return REASON_BAD_CHANGE_TYPE;

    if (!is_valid_date(line + DATE_POS))
        return REASON_BAD_DATE;

    bool no_value = is_blank(line + VALUE_POS, VALUE_LEN);
    bool no_postcode = is_blank(line + POSTCODE_POS, POSTCODE_LEN);
    if ((keeper && (no_value || no_postcode)) || (colour && no_value))
        return REASON_MISSING_VALUE;

    return REASON_NONE;
}

bool parse_header(const char *line, size_t len, char date_out[DATE_LEN + 1])
{
    if (len != RECORD_LEN || memcmp(line, "HDR", TAG_LEN) != 0)
        return false;
    if (!is_valid_date(line + TAG_LEN))
        return false;
    if (!is_blank(line + TAG_LEN + DATE_LEN, RECORD_LEN - TAG_LEN - DATE_LEN))
        return false;

    memcpy(date_out, line + TAG_LEN, DATE_LEN);
    date_out[DATE_LEN] = '\0';
    return true;
}

bool parse_trailer(const char *line, size_t len, unsigned long *count)
{
    if (len != RECORD_LEN || memcmp(line, "TRL", TAG_LEN) != 0)
        return false;
    if (!matches_pattern(line + TAG_LEN, "999999999"))
        return false;
    if (!is_blank(line + TAG_LEN + COUNT_LEN, RECORD_LEN - TAG_LEN - COUNT_LEN))
        return false;

    unsigned long value = 0;
    for (size_t i = 0; i < COUNT_LEN; i++)
        value = value * 10 + (unsigned long)(line[TAG_LEN + i] - '0');
    *count = value;
    return true;
}
