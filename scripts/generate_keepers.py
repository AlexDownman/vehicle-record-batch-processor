#!/usr/bin/env python3
"""Generate synthetic keepers for the vehicles in the MOT seed sample.

Writes one CSV row per keeper period: every vehicle gets a current keeper,
and some also get one or two previous keepers, so KEEPERS has history.
Names and postcodes come from Faker (en_GB). No real personal data is used.

The output is loaded into KEEPERS by sql/loader/keepers.ctl.

Usage:
    .venv/bin/python scripts/generate_keepers.py \
        data/seed/mot_sample.csv data/seed/keepers.csv
"""

import argparse
import csv
import random
import sys
from datetime import date, timedelta

from faker import Faker

from synthetic import fake_name, fake_postcode

# A fixed seed means the same keepers are generated on every run.
SEED = 20240101

# Keeper history runs up to this date; nightly changes come after it.
HISTORY_END = date(2023, 12, 31)


def latest_first_use_dates(seed_path):
    """Return {vehicle_id: first_use_date} taken from each vehicle's latest test.

    Uses the same rule as sql/04_seed_vehicles.sql (latest completed_date,
    then highest test_id), so keepers never start before the vehicle's
    first_use_date in VEHICLES.
    """
    latest = {}
    with open(seed_path, newline="", encoding="utf-8") as f:
        # DVSA escapes embedded quotes with a backslash, not CSV-standard "".
        reader = csv.DictReader(f, escapechar="\\")
        for row in reader:
            # The monthly files repeat the header part-way through.
            if row["test_id"] == "test_id":
                continue
            key = (row["completed_date"], int(row["test_id"]))
            vehicle_id = int(row["vehicle_id"])
            if vehicle_id not in latest or key > latest[vehicle_id][0]:
                latest[vehicle_id] = (key, date.fromisoformat(row["first_use_date"]))
    return {vehicle_id: first_use for vehicle_id, (_, first_use) in latest.items()}


def keeper_periods(first_use, rng):
    """Split first_use..HISTORY_END into 1-3 back-to-back keeper periods.

    Returns a list of (start_date, end_date) with end_date None for the
    current keeper. Each period ends the day before the next one starts.
    """
    span_days = (HISTORY_END - first_use).days
    count = rng.choice([1, 1, 2, 2, 3])
    if span_days < count:
        count = 1

    change_days = sorted(rng.sample(range(1, span_days + 1), count - 1))
    starts = [first_use] + [first_use + timedelta(days=d) for d in change_days]

    periods = []
    for i, start in enumerate(starts):
        end = starts[i + 1] - timedelta(days=1) if i + 1 < len(starts) else None
        periods.append((start, end))
    return periods


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("seed_csv", help="DVSA MOT CSV sample (data/seed/mot_sample.csv)")
    parser.add_argument("output_csv", help="keeper CSV to write (data/seed/keepers.csv)")
    args = parser.parse_args()

    Faker.seed(SEED)
    fake = Faker("en_GB")
    rng = random.Random(SEED)

    try:
        first_use_dates = latest_first_use_dates(args.seed_csv)
    except (OSError, KeyError, ValueError) as exc:
        sys.exit(f"ERROR: cannot read {args.seed_csv}: {exc}")

    rows_written = 0
    with open(args.output_csv, "w", newline="", encoding="utf-8") as f:
        # csv.writer defaults to Windows \r\n line endings; SQL*Loader on
        # Linux would read the \r as part of the last field.
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["vehicle_id", "keeper_name", "postcode", "start_date", "end_date"])
        for vehicle_id in sorted(first_use_dates):
            for start, end in keeper_periods(first_use_dates[vehicle_id], rng):
                writer.writerow([
                    vehicle_id,
                    fake_name(fake),
                    fake_postcode(fake),
                    start.isoformat(),
                    end.isoformat() if end else "",
                ])
                rows_written += 1

    print(f"Vehicles: {len(first_use_dates)}  Keeper rows: {rows_written}  -> {args.output_csv}")


if __name__ == "__main__":
    main()
