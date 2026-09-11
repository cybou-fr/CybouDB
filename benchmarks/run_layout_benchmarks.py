#!/usr/bin/env python3
"""Repeat the historical alone/shared comparison using its original fixtures.

Build fixtures with run_benchmarks.py once if build/benchrun/{events,wide,shared}.cdb
are missing. This runner is read-only and checks row counts and materialized
checksums before reporting a layout ratio. No allocation-policy cause is assumed.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess

from run_sqlite_benchmarks import DEFAULT_BINARY, DEFAULT_CybouDB_HARNESS, ROOT, measure, run_cmd


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cyboudb", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--bench-harness", type=Path, default=DEFAULT_CybouDB_HARNESS)
    parser.add_argument("--directory", type=Path, default=ROOT / "build" / "benchrun")
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if min(args.iterations, args.repeats) < 1 or args.warmup < 0:
        parser.error("iterations/repeats must be positive, warmup nonnegative")
    cases = [("events", "alone", "events.cdb", "id"),
             ("events", "shared", "shared.cdb", "id"),
             ("wide32", "alone", "wide.cdb", "c0"),
             ("wide32", "shared", "shared.cdb", "c0")]
    rows = {}
    for table, layout, filename, _ in cases:
        path = args.directory / filename
        if not path.exists():
            parser.error(f"missing {path}; build the legacy fixtures with run_benchmarks.py")
        text = run_cmd(args.cdb, "query", path, f"SELECT COUNT(*) FROM {table}").decode()
        counts = [int(line.strip()) for line in text.splitlines() if line.strip().isdigit()]
        if len(counts) != 1 or counts[0] <= 0:
            raise RuntimeError(f"invalid row count for {table}/{layout}")
        rows[table, layout] = counts[0]
    for table in ("events", "wide32"):
        if rows[table, "alone"] != rows[table, "shared"]:
            raise RuntimeError(f"unequal row counts for {table}; cannot compare layout")

    output = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip(),
              "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": platform.platform(), "iterations": args.iterations,
              "warmup": args.warmup, "repeats": args.repeats,
              "harness_sha256": hashlib.sha256(args.bench_harness.read_bytes()).hexdigest(),
              "fixtures": {name: hashlib.sha256((args.directory / name).read_bytes()).hexdigest()
                           for name in ("events.cdb", "wide.cdb", "shared.cdb")}, "modes": []}
    for mode in (0, 1):
        samples = {(table, layout): [] for table, layout, _, _ in cases}
        for repeat in range(args.repeats):
            order = cases if repeat % 2 == 0 else list(reversed(cases))
            for table, layout, filename, column in order:
                rec = measure(args.bench_harness, args.directory / filename,
                              f"SELECT {column} FROM {table}", args.iterations, args.warmup, mode)
                if rec["selected"] != rows[table, layout] * args.iterations:
                    raise RuntimeError(f"unexpected selected count for {table}/{layout}")
                samples[table, layout].append(rec)
        results = []
        for table in ("events", "wide32"):
            count = rows[table, "alone"]
            alone = samples[table, "alone"]
            shared = samples[table, "shared"]
            if mode == 1 and len({r["checksum"] for r in alone + shared}) != 1:
                raise RuntimeError(f"materialized checksums differ for {table}")
            ns = {layout: [r["ns"] / (count * args.iterations) for r in samples[table, layout]]
                  for layout in ("alone", "shared")}
            ratio = statistics.median(ns["shared"]) / statistics.median(ns["alone"])
            print(f"mode={mode} {table}: {count:,} rows; alone {statistics.median(ns['alone']):.3f} ns/row; "
                  f"shared {statistics.median(ns['shared']):.3f} ns/row; shared/alone {ratio:.3f}x", flush=True)
            results.append({"table": table, "rows": count, "alone": alone, "shared": shared,
                            "ns_per_row": ns, "shared_over_alone": ratio,
                            "materialized_checksums_match": True if mode == 1 else None})
        output["modes"].append({"mode": mode, "tables": results})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
