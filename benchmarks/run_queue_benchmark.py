#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""A durable work queue: CybouDB's primitive against SQLite's table.

CybouDB has a queue in the storage engine. SQLite does not, so a service that
needs one builds it out of a table - which is the single most common way a
durable job queue gets written, and is what this measures.

Durability is the whole comparison at one transaction per message, so SQLite is
measured in three configurations and each is labelled with what it promises.
CybouDB has no such knob: it flushes the data pages and then the publication,
every commit, always.
"""

import argparse
import os
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
BENCH = ROOT / "build" / f"queue_bench{EXE}"

ENGINES = [
    ("CybouDB", "cyboudb", "two flushes per commit, no knob"),
    ("SQLite rollback+FULL", "sqlite-delete-full", "SQLite default durability"),
    ("SQLite WAL+FULL", "sqlite-wal-full", "WAL, every commit fsynced"),
    ("SQLite WAL+NORMAL", "sqlite-wal-normal", "WEAKER: may lose recent commits"),
]

WORKLOADS = [
    ("enqueue", "one message, one transaction"),
    ("dequeue", "one message, one transaction"),
    ("worker", "take a job and write its result, ONE transaction"),
    ("enqueue-batch", "100 messages per transaction"),
]


def measure(engine, workload, messages, payload, db_dir, repeats):
    runs = []
    for r in range(repeats):
        path = db_dir / f"{engine}-{workload}-{r}.db"
        for stale in db_dir.glob(f"{engine}-{workload}-{r}.db*"):
            stale.unlink(missing_ok=True)
        out = subprocess.run(
            [str(BENCH), engine, workload, str(messages), str(payload),
             str(path)], capture_output=True, text=True)
        if out.returncode != 0 or "RESULT" not in out.stdout:
            raise RuntimeError(f"{engine}/{workload} failed: "
                               f"{out.stdout}{out.stderr}")
        ops, ns = out.stdout.split("RESULT")[1].split()
        runs.append(int(ns) / int(ops))
        for stale in db_dir.glob(f"{engine}-{workload}-{r}.db*"):
            stale.unlink(missing_ok=True)
    return statistics.median(runs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--messages", type=int, default=5000)
    parser.add_argument("--payload", type=int, default=32,
                        help="bytes; CybouDB stores <= 32 inside the slot")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--db-dir", type=Path,
                        default=ROOT / "build" / "queuerun")
    args = parser.parse_args()

    if not BENCH.exists():
        print(f"error: {BENCH} not built", file=sys.stderr)
        return 2
    if args.db_dir.exists():
        shutil.rmtree(args.db_dir, ignore_errors=True)
    args.db_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 94)
    print(f"Durable work queue - {args.messages:,} messages, "
          f"{args.payload}-byte payload, median of {args.repeats} runs")
    print("  microseconds per message, lower is better")
    print("=" * 94)

    results = {}
    for label, engine, note in ENGINES:
        for workload, _ in WORKLOADS:
            try:
                results[(engine, workload)] = measure(
                    engine, workload, args.messages, args.payload,
                    args.db_dir, args.repeats)
            except RuntimeError as failure:
                print(f"  ! {failure}", file=sys.stderr)
                results[(engine, workload)] = None

    head = f"{'Engine':<24}" + "".join(f"{w:>16}" for w, _ in WORKLOADS)
    print()
    print(head)
    print("-" * len(head))
    for label, engine, note in ENGINES:
        row = f"{label:<24}"
        for workload, _ in WORKLOADS:
            value = results[(engine, workload)]
            row += f"{value / 1000:>15.2f}u" if value else f"{'-':>16}"
        print(row)
    print("-" * len(head))

    print()
    print("CybouDB against each SQLite configuration "
          "(above 1.00 means CybouDB is faster):")
    for label, engine, note in ENGINES[1:]:
        row = f"  vs {label:<21}"
        for workload, _ in WORKLOADS:
            mine = results[("cyboudb", workload)]
            theirs = results[(engine, workload)]
            row += f"{theirs / mine:>15.2f}x" if mine and theirs else f"{'-':>16}"
        print(row + f"   ({note})")

    print()
    for workload, description in WORKLOADS:
        print(f"  {workload:<14} {description}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
