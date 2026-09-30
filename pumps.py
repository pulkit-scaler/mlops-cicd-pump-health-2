"""The pumps, simulated.

A water utility logs five readings from each pump once a day, and a week later it
knows which pumps failed. This file stands in for both: the pumps, and the
warehouse query that returns a week of labelled readings.

    python pumps.py 38          # week 38 as CSV on stdout

Everything comes from fixed seeds, so every machine sees the same numbers.

From week 39 a new station, eastgate, comes online. Its pumps run at higher
pressure, and its vibration sensors are a different make that reads about 0.4
of what the old ones read. The model never saw either.
"""
import csv
import sys
from pathlib import Path

import numpy as np

# The order the model sees its columns in. The service builds rows in this
# order, read from meta.json, so it never keeps its own copy of the list.
FEATURES = [
    "bearing_temp_c",
    "vibration_mm_s",
    "discharge_pressure_bar",
    "motor_current_a",
    "hours_since_service",
]
COLUMNS = ["week", "station", *FEATURES, "failed"]
OLD_STATIONS = ["riverside", "hillcrest"]
NEW_STATION_FROM_WEEK = 39


def make_readings(n: int = 20_000, seed: int = 7):
    """Readings from the old stations, and whether each pump failed within seven days."""
    rng = np.random.default_rng(seed)
    temp = rng.normal(62, 8, n)
    vibration = rng.lognormal(np.log(2.5), 0.35, n)
    pressure = rng.normal(6.0, 0.8, n)
    current = rng.normal(18, 2.5, n)
    hours = rng.uniform(0, 4000, n)
    logit = (
        -4.2
        + 0.11 * (temp - 62)
        + 0.95 * (vibration - 2.5)
        + 0.6 * np.abs(pressure - 6.0)
        + 0.12 * (current - 18)
        + 0.0007 * (hours - 2000)
    )
    fails = rng.random(n) < 1 / (1 + np.exp(-logit))
    X = np.column_stack([temp, vibration, pressure, current, hours]).round(2)
    return X, fails.astype(int)


def make_eastgate(n: int, seed: int):
    """The new station. Same physics, but the sensor reports 0.4 of the true vibration."""
    rng = np.random.default_rng(seed)
    temp = rng.normal(62, 8, n)
    vibration = rng.lognormal(np.log(2.5), 0.35, n)
    pressure = rng.normal(10.5, 0.6, n)
    current = rng.normal(18, 2.5, n)
    hours = rng.uniform(0, 4000, n)
    logit = (
        -3.5
        + 0.11 * (temp - 62)
        + 0.95 * (vibration - 2.5)
        + 0.6 * np.abs(pressure - 10.5)
        + 0.12 * (current - 18)
        + 0.0007 * (hours - 2000)
    )
    fails = rng.random(n) < 1 / (1 + np.exp(-logit))
    X = np.column_stack([temp, vibration * 0.4, pressure, current, hours]).round(2)
    return X, fails.astype(int)


def week(w: int, per_station: int = 1000):
    """One week of labelled readings: rows of (week, station, five readings, failed)."""
    rows = []
    for i, station in enumerate(OLD_STATIONS):
        X, y = make_readings(per_station, seed=1000 * w + i)
        rows += [[w, station, *x, int(f)] for x, f in zip(X.tolist(), y)]
    if w >= NEW_STATION_FROM_WEEK:
        X, y = make_eastgate(2 * per_station, seed=1000 * w + 9)
        rows += [[w, "eastgate", *x, int(f)] for x, f in zip(X.tolist(), y)]
    return rows


def read_csv(path):
    """Rows from a CSV written by write_csv, with numbers parsed."""
    with open(path) as f:
        return [[int(r["week"]), r["station"], *(float(r[c]) for c in FEATURES), int(r["failed"])]
                for r in csv.DictReader(f)]


def write_csv(rows, f):
    w = csv.writer(f)
    w.writerow(COLUMNS)
    w.writerows(rows)


def split(rows):
    """X, y and station arrays from rows."""
    X = np.array([r[2:7] for r in rows], dtype=float)
    y = np.array([r[7] for r in rows], dtype=int)
    stations = np.array([r[1] for r in rows])
    return X, y, stations


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python pumps.py WEEK")
    write_csv(week(int(sys.argv[1])), sys.stdout)
