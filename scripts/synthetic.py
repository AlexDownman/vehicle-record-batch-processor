"""Synthetic personal data shared by the generator scripts.

Everything here comes from Faker (en_GB). No real personal data is used.
"""

import re

# Matches keepers_postcode_ck in sql/02_tables.sql.
POSTCODE_RE = re.compile(r"^[A-Z]{1,2}[0-9][A-Z0-9]? [0-9][A-Z]{2}$")

# Matches the width of KEEPERS.keeper_name and the nightly file's value field.
MAX_NAME_LEN = 40


def fake_postcode(fake):
    """Return a Faker postcode that passes the KEEPERS check constraint."""
    while True:
        postcode = fake.postcode()
        if POSTCODE_RE.match(postcode):
            return postcode


def fake_name(fake):
    return f"{fake.first_name()} {fake.last_name()}"[:MAX_NAME_LEN]
