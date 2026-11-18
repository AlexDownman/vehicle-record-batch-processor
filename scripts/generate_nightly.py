#!/usr/bin/env python3
"""Generate a fixed-width nightly update file with planted bad records.

Builds KEEPER, COLOUR and SCRAP change records for real vehicles taken from
the vehicle extract (sql/extract_vehicles.sql), then plants a small share of
bad records for the C validator and the PL/SQL package to catch. The layout
is documented in docs/file-format.md.

Writes two files to the output folder:
    nightly_YYYYMMDD.dat       the update file
    nightly_YYYYMMDD.expected  CSV of every planted bad record and the
                               reason it should be rejected with

Usage:
    .venv/bin/python scripts/generate_nightly.py \
        --extract data/seed/vehicle_extract.csv --date 20240115
"""

import argparse
import csv
import os
import random
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

from faker import Faker

from synthetic import fake_name, fake_postcode

RECORD_LEN = 72

# Keeper history in KEEPERS ends here, so changes must be effective after it.
HISTORY_END = date(2023, 12, 31)

# Good records are effective on the file date or up to this many days before.
MAX_BACKDATE_DAYS = 6

# Colours seen in the DVSA data.
COLOURS = [
    "BEIGE", "BLACK", "BLUE", "BRONZE", "BROWN", "CREAM", "GOLD", "GREEN",
    "GREY", "MAROON", "MULTI-COLOUR", "ORANGE", "PINK", "PURPLE", "RED",
    "SILVER", "TURQUOISE", "WHITE", "YELLOW",
]

# Relative share of each change type among the records.
CHANGE_WEIGHTS = {"KEEPER": 70, "COLOUR": 20, "SCRAP": 10}

# Planted faults and the stage that should reject them. The reason codes
# are the ones the validator and vehicle_batch_pkg will write to REJECTIONS.
FAULT_STAGE = {
    "BAD_LENGTH":       "VALIDATOR",
    "BAD_REG_FORMAT":   "VALIDATOR",
    "BAD_CHANGE_TYPE":  "VALIDATOR",
    "BAD_DATE":         "VALIDATOR",
    "MISSING_VALUE":    "VALIDATOR",
    "UNKNOWN_REG":      "PLSQL",
    "ALREADY_SCRAPPED": "PLSQL",
    "BAD_POSTCODE":     "PLSQL",
}

PLATE_LETTERS = "ABCDEFGHJKLMNOPRSTUVWXY"


@dataclass
class Vehicle:
    registration: str
    colour: str
    status: str


@dataclass
class Change:
    registration: str
    change_type: str
    value: str = ""
    postcode: str = ""
    effective: str = ""
    fault: str | None = None       # planted reason code; None = good record
    truncate_to: int | None = None  # only for BAD_LENGTH

    def render(self):
        # :<8.8 means left-align, pad with spaces to 8, and cut at 8.
        line = (f"{self.registration:<8.8}{self.change_type:<8.8}"
                f"{self.value:<40.40}{self.postcode:<8.8}{self.effective:<8.8}")
        return line[:self.truncate_to] if self.truncate_to else line


def read_extract(path):
    with open(path, newline="", encoding="utf-8") as f:
        return [Vehicle(row["REGISTRATION"], row["COLOUR"], row["STATUS"])
                for row in csv.DictReader(f)]


def good_change(vehicle, change_type, file_date, fake, rng):
    backdate = timedelta(days=rng.randint(0, MAX_BACKDATE_DAYS))
    effective = (file_date - backdate).strftime("%Y%m%d")
    if change_type == "KEEPER":
        return Change(vehicle.registration, "KEEPER", fake_name(fake),
                      fake_postcode(fake), effective)
    if change_type == "COLOUR":
        new_colour = rng.choice([c for c in COLOURS if c != vehicle.colour])
        return Change(vehicle.registration, "COLOUR", new_colour, "", effective)
    return Change(vehicle.registration, "SCRAP", "", "", effective)


def unknown_registration(known, rng):
    """Return a well-formed registration that no vehicle has."""
    while True:
        reg = (rng.choice(PLATE_LETTERS) + rng.choice(PLATE_LETTERS)
               + f"{rng.randint(2, 73):02d} "
               + "".join(rng.choice(PLATE_LETTERS) for _ in range(3)))
        if reg not in known:
            return reg


def plant_fault(change, fault, file_date, known, fake, rng):
    """Damage a good change so it should be rejected with reason `fault`.

    ALREADY_SCRAPPED is not handled here: it depends on where the record
    sits in the file, so main() builds it.
    """
    change.fault = fault
    reg = change.registration
    if fault == "BAD_LENGTH":
        # A line cut short, as if the file was truncated mid-write.
        change.truncate_to = rng.randint(20, RECORD_LEN - 10)
    elif fault == "BAD_REG_FORMAT":
        change.registration = rng.choice([
            reg.replace(" ", ""),       # AB12CDE  (no space)
            reg.lower(),                # ab12 cde
            reg[2:4] + reg[:2] + reg[4:],  # 12AB CDE
        ])
    elif fault == "BAD_CHANGE_TYPE":
        change.change_type = rng.choice(["OWNER", "COLOR", "DELETE"])
    elif fault == "BAD_DATE":
        year = file_date.year
        change.effective = rng.choice([f"{year}0230", f"{year}1301", f"{year}0000"])
    elif fault == "MISSING_VALUE":
        # KEEPER without a name, or COLOUR without a colour.
        change.change_type = rng.choice(["KEEPER", "COLOUR"])
        change.value = ""
        change.postcode = fake_postcode(fake) if change.change_type == "KEEPER" else ""
    elif fault == "UNKNOWN_REG":
        change.registration = unknown_registration(known, rng)
    elif fault == "BAD_POSTCODE":
        # Present but not a valid UK postcode format.
        change.change_type = "KEEPER"
        change.value = fake_name(fake)
        change.postcode = rng.choice(["SW1A1AA", "12345", "SA1", "A1 1A"])
    return change


def write_atomically(path, lines):
    """Write via a .tmp file and rename, so a reader never sees half a file.

    Encoded as ASCII so every character is one byte and the fixed-width
    positions hold; a non-ASCII character raises an error instead.
    """
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="ascii", newline="") as f:
        for line in lines:
            f.write(line + "\n")
    os.replace(tmp, path)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--extract", required=True,
                        help="vehicle extract CSV (data/seed/vehicle_extract.csv)")
    parser.add_argument("--date", default=date.today().strftime("%Y%m%d"),
                        help="file date, YYYYMMDD (default: today)")
    parser.add_argument("--records", type=int, default=1000,
                        help="number of change records (default: 1000)")
    parser.add_argument("--bad-rate", type=float, default=0.015,
                        help="share of records to make bad (default: 0.015)")
    parser.add_argument("--seed", type=int,
                        help="random seed (default: the file date, so reruns match)")
    parser.add_argument("--out-dir", type=Path, default=Path("data/inbound"),
                        help="output folder (default: data/inbound)")
    parser.add_argument("--force", action="store_true",
                        help="overwrite an existing file for the same date")
    return parser.parse_args()


def main():
    args = parse_args()

    try:
        file_date = datetime.strptime(args.date, "%Y%m%d").date()
    except ValueError:
        sys.exit(f"ERROR: --date must be YYYYMMDD, got {args.date!r}")
    if file_date - timedelta(days=MAX_BACKDATE_DAYS) <= HISTORY_END:
        sys.exit(f"ERROR: --date must be after {HISTORY_END + timedelta(days=MAX_BACKDATE_DAYS)}"
                 " so changes fall after the seeded keeper history")
    if not 0 <= args.bad_rate <= 1 or args.records < 1:
        sys.exit("ERROR: --records must be >= 1 and --bad-rate between 0 and 1")

    dat_path = args.out_dir / f"nightly_{args.date}.dat"
    expected_path = args.out_dir / f"nightly_{args.date}.expected"
    if dat_path.exists() and not args.force:
        sys.exit(f"ERROR: {dat_path} already exists (use --force to overwrite)")

    seed = args.seed if args.seed is not None else int(args.date)
    Faker.seed(seed)
    fake = Faker("en_GB")
    rng = random.Random(seed)

    try:
        vehicles = read_extract(args.extract)
    except (OSError, KeyError) as exc:
        sys.exit(f"ERROR: cannot read {args.extract}: {exc}")
    known = {v.registration for v in vehicles}
    active = [v for v in vehicles if v.status == "ACTIVE"]

    n_bad = round(args.records * args.bad_rate)
    n_good = args.records - n_bad
    if args.records > len(active):
        sys.exit(f"ERROR: only {len(active)} active vehicles; ask for fewer records")

    # One vehicle per record, so no vehicle has two good changes in a file.
    chosen = rng.sample(active, args.records)
    types = rng.choices(list(CHANGE_WEIGHTS), weights=CHANGE_WEIGHTS.values(), k=args.records)
    changes = [good_change(v, t, file_date, fake, rng)
               for v, t in zip(chosen[:n_good], types[:n_good])]

    # Cycle through the fault kinds in a shuffled order, so every kind
    # appears once there are at least as many bad records as kinds.
    kinds = list(FAULT_STAGE)
    rng.shuffle(kinds)
    for i, (vehicle, change_type) in enumerate(zip(chosen[n_good:], types[n_good:])):
        fault = kinds[i % len(kinds)]
        if fault == "ALREADY_SCRAPPED":
            # A change for a vehicle that a SCRAP earlier in the same file
            # has already scrapped, so it must come after that SCRAP.
            scraps = [j for j, c in enumerate(changes) if c.change_type == "SCRAP" and not c.fault]
            if not scraps:
                # Small files may have no SCRAP yet: turn this slot's
                # vehicle into one, and plant the fault on the next record.
                changes.append(good_change(vehicle, "SCRAP", file_date, fake, rng))
                scraps = [len(changes) - 1]
            scrap_at = rng.choice(scraps)
            bad = good_change(Vehicle(changes[scrap_at].registration, "", "ACTIVE"),
                              rng.choice(["KEEPER", "COLOUR"]), file_date, fake, rng)
            bad.fault = fault
            changes.insert(rng.randint(scrap_at + 1, len(changes)), bad)
        else:
            bad = plant_fault(good_change(vehicle, change_type, file_date, fake, rng),
                              fault, file_date, known, fake, rng)
            changes.insert(rng.randint(0, len(changes)), bad)

    header = f"HDR{args.date}".ljust(RECORD_LEN)
    trailer = f"TRL{len(changes):09d}".ljust(RECORD_LEN)
    lines = [header] + [c.render() for c in changes] + [trailer]

    # Line numbers count the header as line 1, matching REJECTIONS.line_number.
    expected = [["line_number", "stage", "reason_code", "registration"]]
    for line_number, change in enumerate(changes, start=2):
        if change.fault:
            expected.append([line_number, FAULT_STAGE[change.fault],
                             change.fault, change.registration])

    try:
        args.out_dir.mkdir(parents=True, exist_ok=True)
        write_atomically(expected_path, [",".join(map(str, row)) for row in expected])
        write_atomically(dat_path, lines)
    except OSError as exc:
        sys.exit(f"ERROR: cannot write output: {exc}")

    by_type = {t: sum(c.change_type == t and not c.fault for c in changes) for t in CHANGE_WEIGHTS}
    print(f"Wrote {dat_path}: {len(changes)} records "
          f"({', '.join(f'{t} {n}' for t, n in by_type.items())}, bad {len(expected) - 1})")
    print(f"Wrote {expected_path}")


if __name__ == "__main__":
    main()
