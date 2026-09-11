#!/usr/bin/env python3
"""Legacy single-level scan and layout benchmarks for the batch executor.

Run: python benchmarks/run_benchmarks.py [cyboudb] [bench_harness]

Builds each dataset in its own database, then measures every scenario
in-process through benchmarks/bench_harness.asm: the database is opened once,
the statement is bound once, and only the scan, the predicate kernels and the
batch delivery fall between the two clock reads. Nothing here times the CLI -
that would measure process creation and decimal formatting instead of the
engine.

Each dataset gets its own file. The historical shared-file slowdown is measured
as an explicit scenario; an allocation-policy explanation is not assumed.

These fixtures deliberately use the older single-level directory (251 leaf
runs), although the engine supports larger two-level tables. Use
run_sqlite_benchmarks.py for large three-way comparisons, or
run_layout_benchmarks.py to repeat layout measurements without rebuilding.
"""
import os
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / f"cyboudb{EXE}"
HARNESS = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else ROOT / "build" / f"bench_harness{EXE}"

# Enough repetitions that a scenario runs for milliseconds, which keeps the
# clock's own resolution well below the measurement.
ITERATIONS = 200
WARMUP = 20

# The largest COW page count the CLI accepts, so that filling a table is
# limited by the 251-leaf directory rather than by the file.
PAGES = 16112

FIELDS = ["status", "domain", "iterations", "batches", "selected", "checksum",
          "ns", "tsc", "required", "row_bytes"]

HEADER = (f"{'scenario':<34} {'sel/run':>8} {'row/bat':>8} {'B/row':>6} "
          f"{'ns/row':>9} {'tsc/row':>9} {'Mrow/s':>9} {'GB/s':>8}")

EVENTS = [("id", "INT64"), ("category", "INT32"), ("score", "INT32"),
          ("amount", "INT64"), ("active", "BOOL"), ("weight", "FLOAT32"),
          ("tag", "INT32")]

WIDE = [(f"c{i}", "INT32") for i in range(32)]


def run(exe, *args):
    result = subprocess.run([str(exe), *map(str, args)], capture_output=True, timeout=900)
    if result.returncode:
        raise RuntimeError(f"{Path(exe).name} {args[:2]} failed: "
                           f"{result.stdout[:200]!r} {result.stderr[:200]!r}")
    return result.stdout


def event_cell(row, column):
    if column == 0:
        return str(row)
    if column == 1:
        return str(row % 8)
    if column == 2:
        return str(row % 100)
    if column == 3:
        return str(row * 3)
    if column == 4:
        return "TRUE" if row % 2 else "FALSE"
    if column == 5:
        return f"{row % 1000}.5"
    return "NULL" if row % 5 == 0 else str(row % 7)


def wide_cell(row, column):
    return str(row + column)


def fill(database, table, columns, cell):
    """Insert until the table's 251 pages are full, and report the row count.

    Capacity depends on the schema, so it is found by inserting until the
    engine refuses rather than by repeating the layout arithmetic here.
    """
    definition = ", ".join(f"{name} {kind}" for name, kind in columns)
    run(BINARY, "query", database, f"CREATE TABLE {table} ({definition})")
    inserted = 0
    while True:
        batch = ",".join("(" + ",".join(cell(i, c) for c in range(len(columns))) + ")"
                         for i in range(inserted, inserted + 256))
        result = subprocess.run(
            [str(BINARY), "query", str(database), f"INSERT INTO {table} VALUES {batch}"],
            capture_output=True, timeout=900)
        if result.returncode:
            break
        inserted += 256
    if not inserted:
        raise RuntimeError(f"{table}: no rows fit")
    return inserted


def build(directory, name, tables):
    """Create a fresh database holding exactly `tables`, in that order."""
    database = directory / f"{name}.cdb"
    run(BINARY, "create-pax-multi", database, PAGES, "--force")
    return database, {table: fill(database, table, columns, cell)
                      for table, columns, cell in tables}


def measure(database, sql, rows):
    output = run(HARNESS, database, sql, ITERATIONS, WARMUP)
    assert len(output) == 80, len(output)
    record = dict(zip(FIELDS, struct.unpack("<10Q", output)))
    if record["status"]:
        raise RuntimeError(f"{sql}: status {record['status']} domain {record['domain']}")
    record["rows"] = rows
    return record


def report(name, record):
    scanned = record["rows"] * record["iterations"]
    seconds = record["ns"] / 1e9
    # Only batches with a nonempty selection are delivered, so this is the
    # average size of a delivered batch. It earns a column because per-batch
    # setup is a fixed cost: when a leaf holds few rows, that cost is most of
    # what the per-row figures are measuring.
    per_batch = record["selected"] / record["batches"] if record["batches"] else 0
    print(f"{name:<34} {record['selected'] // record['iterations']:>8} "
          f"{per_batch:>8.1f} {record['row_bytes']:>6} "
          f"{record['ns'] / scanned:>9.2f} {record['tsc'] / scanned:>9.2f} "
          f"{scanned / seconds / 1e6:>9.1f} "
          f"{scanned * record['row_bytes'] / seconds / 1e9:>8.3f}")


def main():
    directory = ROOT / "build" / "benchrun"
    directory.mkdir(parents=True, exist_ok=True)

    events_db, counts = build(directory, "events", [("events", EVENTS, event_cell)])
    rows = counts["events"]
    print(f"dataset: events, {len(EVENTS)} columns, {rows} rows, "
          f"{ITERATIONS} iterations, {WARMUP} warmup")
    print(HEADER)
    for name, sql in [
        ("int32 equality", "SELECT id FROM events WHERE category = 3"),
        ("int32 range", "SELECT id FROM events WHERE score > 90"),
        ("int64 range", "SELECT id FROM events WHERE amount > 1000"),
        ("float32 range", "SELECT id FROM events WHERE weight > 500.0"),
        ("bool equality", "SELECT id FROM events WHERE active = TRUE"),
        ("two predicates, AND",
         "SELECT id FROM events WHERE score > 90 AND category = 3"),
        ("two predicates, OR",
         "SELECT id FROM events WHERE score > 90 OR category = 3"),
        ("nullable predicate", "SELECT id FROM events WHERE tag > 3"),
        ("nullable IS NOT NULL", "SELECT id FROM events WHERE tag IS NOT NULL"),
        ("no predicate", "SELECT id FROM events"),
        ("projection 1 of 7", "SELECT id FROM events WHERE score > 50"),
        ("projection 7 of 7",
         "SELECT id, category, score, amount, active, weight, tag "
         "FROM events WHERE score > 50"),
    ]:
        report(name, measure(events_db, sql, rows))

    wide_db, counts = build(directory, "wide", [("wide32", WIDE, wide_cell)])
    wide_rows = counts["wide32"]
    print(f"\ndataset: wide32, 32 columns, {wide_rows} rows")
    print(HEADER)
    for name, sql in [
        ("projection 1 of 32", "SELECT c0 FROM wide32 WHERE c0 >= 0"),
        ("projection 2 of 32", "SELECT c0, c31 FROM wide32 WHERE c0 >= 0"),
        ("projection 32 of 32",
         "SELECT " + ", ".join(f"c{i}" for i in range(32)) + " FROM wide32 WHERE c0 >= 0"),
    ]:
        report(name, measure(wide_db, sql, wide_rows))

    # Two tables in one database, measured against the same table alone. The
    # only difference is what else lives in the file.
    shared_db, counts = build(directory, "shared",
                              [("events", EVENTS, event_cell), ("wide32", WIDE, wide_cell)])
    print(f"\ndataset: events + wide32 in one database "
          f"({counts['events']} and {counts['wide32']} rows)")
    print(HEADER)
    report("events, alone in its file", measure(events_db, "SELECT id FROM events", rows))
    report("events, sharing with wide32",
           measure(shared_db, "SELECT id FROM events", counts["events"]))
    report("wide32, alone in its file",
           measure(wide_db, "SELECT c0 FROM wide32", wide_rows))
    report("wide32, sharing with events",
           measure(shared_db, "SELECT c0 FROM wide32", counts["wide32"]))

    print("\nThese legacy fixtures use a single-level directory capped at 251 leaf runs.")
    print("Use these to compare CybouDB against CybouDB, not against another engine.")


if __name__ == "__main__":
    main()
