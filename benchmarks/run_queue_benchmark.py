#!/usr/bin/env python3
# Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
# SPDX-License-Identifier: Apache-2.0
"""A durable work queue: CybouDB's primitive against SQLite's table.

CybouDB has a queue in the storage engine. SQLite does not, so a service that
needs one builds it out of a table - which is the single most common way a
durable job queue gets written, and is what this measures.

Three different things are measured, because they are three different
questions and one number answers none of them:

  latency      one message, one durable commit
  throughput   the same work at 10 and 100 messages per transaction, which is
               what a queue consumer can usually afford to do
  scaling      the cost of a commit as the queue gets deeper

Durability decides the first, so SQLite is measured in three configurations
and each is labelled with what it promises. CybouDB has no such knob: it
flushes the data pages and then the publication, every commit, always.
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
    ("enqueue", "one message in"),
    ("dequeue", "one message out"),
    ("worker", "take a job and write its result, one transaction"),
]

BATCHES = (1, 10, 100)
DEPTHS = (500, 1000, 2000)


def measure(engine, workload, messages, payload, db_dir, repeats, batch):
    runs = []
    for r in range(repeats):
        path = db_dir / f"{engine}-{workload}-{batch}-{r}.db"
        for stale in db_dir.glob(path.name + "*"):
            stale.unlink(missing_ok=True)
        out = subprocess.run(
            [str(BENCH), engine, workload, str(messages), str(payload),
             str(path), str(batch)], capture_output=True, text=True)
        if out.returncode != 0 or "RESULT" not in out.stdout:
            raise RuntimeError(f"{engine}/{workload}/{batch} failed: "
                               f"{out.stdout}{out.stderr}")
        ops, ns = out.stdout.split("RESULT")[1].split()
        runs.append(int(ns) / int(ops))
        for stale in db_dir.glob(path.name + "*"):
            stale.unlink(missing_ok=True)
    return statistics.median(runs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--messages", type=int, default=2000)
    parser.add_argument("--payload", type=int, default=32,
                        help="bytes; CybouDB stores <= 32 inside the slot")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--db-dir", type=Path,
                        default=ROOT / "build" / "queuerun")
    parser.add_argument("--skip-scaling", action="store_true")
    args = parser.parse_args()

    if not BENCH.exists():
        print(f"error: {BENCH} not built", file=sys.stderr)
        return 2
    if args.db_dir.exists():
        shutil.rmtree(args.db_dir, ignore_errors=True)
    args.db_dir.mkdir(parents=True, exist_ok=True)

    def run(engine, workload, batch, messages=None):
        try:
            return measure(engine, workload, messages or args.messages,
                           args.payload, args.db_dir, args.repeats, batch)
        except RuntimeError as failure:
            print(f"  ! {failure}", file=sys.stderr)
            return None

    def cell(value):
        return f"{value / 1000:>13.2f}u" if value else f"{'-':>14}"

    print("=" * 92)
    print(f"Durable work queue - {args.messages:,} messages, "
          f"{args.payload}-byte payload, median of {args.repeats} runs")
    print("  microseconds per message, lower is better")
    print("=" * 92)

    # --- 1. latency and throughput, one table per workload -------------------
    for workload, description in WORKLOADS:
        print()
        print(f"{workload.upper()} - {description}")
        head = f"{'Engine':<24}" + "".join(f"{str(b) + ' per txn':>14}"
                                           for b in BATCHES)
        print(head)
        print("-" * len(head))
        rows = {}
        for label, engine, note in ENGINES:
            rows[engine] = [run(engine, workload, b) for b in BATCHES]
            print(f"{label:<24}" + "".join(cell(v) for v in rows[engine]))
        print("-" * len(head))
        mine = rows["cyboudb"]
        for label, engine, note in ENGINES[1:]:
            ratios = ""
            for a, b in zip(mine, rows[engine]):
                ratios += f"{b / a:>13.2f}x" if a and b else f"{'-':>14}"
            print(f"  vs {label:<21}" + ratios)
        print(f"  {'':24}(above 1.00 means CybouDB is faster)")

    # --- 2. how a commit scales with what the queue is holding ---------------
    if not args.skip_scaling:
        print()
        print("SCALING - enqueue at one message per transaction, by queue depth")
        head = f"{'Engine':<24}" + "".join(f"{'depth ' + str(d):>14}"
                                           for d in DEPTHS)
        print(head)
        print("-" * len(head))
        for label, engine, note in ENGINES:
            values = [run(engine, "enqueue", 1, messages=d) for d in DEPTHS]
            print(f"{label:<24}" + "".join(cell(v) for v in values))
        print("-" * len(head))
        print("  A flat row is a commit whose cost does not depend on what the")
        print("  queue is already holding. CybouDB's is not flat; see")
        print("  benchmarks/results/2026-09-13-queue.md for why.")

    print()
    for label, engine, note in ENGINES:
        print(f"  {label:<24} {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
