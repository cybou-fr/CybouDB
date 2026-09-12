#!/usr/bin/env python3
"""Measure DELETE on a large table, across table sizes and selectivities.

A predicated DELETE rewrites the rows the predicate does not select into a
fresh graph, so its cost tracks the survivors rather than the rows removed.
The unqualified form republishes the schema page with its roots back where
CREATE TABLE left them, which is O(1). The point of this benchmark is to put
numbers on both and on what the rewrite costs in pages.

Each measurement runs against a fresh copy of a seeded database, because a
DELETE consumes the state it ran against. Copying the file and counting rows
happen outside the timed region; benchmarks/delete_bench.c times the step
that executes the already bound statement and nothing else.

Usage:
    build.bat --bench           (Windows)   or  sh build.sh --bench
    build.bat --delete-bench                    sh build.sh --delete-bench
    python benchmarks/run_delete_benchmark.py --rows 1000000
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""

# One leaf of the seven-column events schema holds 448 rows across 4 pages.
ROWS_PER_LEAF = 448
PAGES_PER_LEAF = 4


def run(*args, check=True):
    res = subprocess.run([str(a) for a in args], capture_output=True, timeout=7200)
    if check and res.returncode:
        raise RuntimeError(f"{args[0]} failed: {res.stdout[:400]!r} {res.stderr[:400]!r}")
    return res.stdout.decode(errors="replace")


def db_info(binary, path):
    out = run(binary, "info", path)
    pages = re.search(r"Allocated Pages:\s+(\d+)", out)
    gen = re.search(r"Generation:\s+(\d+)", out)
    return {
        "allocated_pages": int(pages.group(1)) if pages else -1,
        "generation": int(gen.group(1)) if gen else -1,
    }


def row_count(binary, path, table="events"):
    out = run(binary, "query", path, f"SELECT COUNT(*) FROM {table}")
    counts = [int(l.strip()) for l in out.splitlines() if l.strip().isdigit()]
    return counts[0] if len(counts) == 1 else -1


def seed(binary, harness, path, rows, headroom, create="create-large"):
    """A rewrite stages a second copy of the survivors before anything is
    reclaimed, so the file needs room for the table twice over plus the
    per-chunk directory and catalog churn."""
    leaves = (rows + ROWS_PER_LEAF - 1) // ROWS_PER_LEAF
    pages = int(leaves * PAGES_PER_LEAF * headroom) + 4000
    print(f"  seeding {rows:,} rows into {pages:,} pages", flush=True)
    run(binary, create, path, pages, "--force")
    cols = ("id INT64, category INT32, score INT32, amount INT64, "
            "active BOOL, weight FLOAT32, tag INT32")
    run(binary, "query", path, f"CREATE TABLE events ({cols})")
    t0 = time.perf_counter()
    run(harness, path, "--seed", rows, 0)
    dt = time.perf_counter() - t0
    print(f"  seeded in {dt:.1f}s ({rows / max(dt, 1e-9):,.0f} rows/s)", flush=True)


def measure(binary, bench, pristine, working, sql):
    if working.exists():
        working.unlink()
    shutil.copyfile(pristine, working)
    before = db_info(binary, working)
    out = run(bench, working, sql)
    fields = dict(line.split("=", 1) for line in out.split() if "=" in line)
    if fields.get("rc") != "0":
        raise RuntimeError(f"delete_bench: {out}")
    after = db_info(binary, working)
    remaining = row_count(binary, working)
    return {
        "exec_ns": int(fields["exec_ns"]),
        "commit_ns": int(fields["commit_ns"]),
        "rows_before": int(fields["rows"]),
        "rows_after": remaining,
        "deleted": int(fields["rows"]) - remaining,
        "pages_before": before["allocated_pages"],
        "pages_after": after["allocated_pages"],
        "pages_staged": after["allocated_pages"] - before["allocated_pages"],
    }


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rows", type=int, default=1_000_000)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--headroom", type=float, default=3.0,
                   help="file size as a multiple of the table's own pages")
    p.add_argument("--binary", type=Path, default=ROOT / f"cyboudb{EXE}")
    p.add_argument("--harness", type=Path, default=ROOT / "build" / f"bench_harness{EXE}")
    p.add_argument("--bench", type=Path, default=ROOT / "build" / f"delete_bench{EXE}")
    p.add_argument("--db-dir", type=Path, default=ROOT / "build" / "deletebench")
    p.add_argument("--output", type=Path)
    p.add_argument("--only", help="substring: run only matching scenarios")
    p.add_argument("--create", default="create-large",
                   help="creation mode; create-pax-multi leaves out zone maps")
    args = p.parse_args()

    for tool in (args.binary, args.harness, args.bench):
        if not tool.exists():
            sys.exit(f"missing {tool}; build it first (see the module docstring)")

    args.db_dir.mkdir(parents=True, exist_ok=True)
    pristine = args.db_dir / f"events_{args.rows}_{args.create}.cdb"
    working = args.db_dir / "working.cdb"

    if not pristine.exists() or row_count(args.binary, pristine) != args.rows:
        seed(args.binary, args.harness, pristine, args.rows, args.headroom, args.create)

    n = args.rows
    # amount = row * 3 in the structured dataset, so a threshold on it selects
    # a known fraction of the table.
    scenarios = [
        ("delete 1%",     f"DELETE FROM events WHERE amount >= {int(n * 0.99) * 3}"),
        ("delete 10%",    f"DELETE FROM events WHERE amount >= {int(n * 0.90) * 3}"),
        ("delete 50%",    f"DELETE FROM events WHERE amount >= {int(n * 0.50) * 3}"),
        ("delete 90%",    f"DELETE FROM events WHERE amount >= {int(n * 0.10) * 3}"),
        ("delete 99%",    f"DELETE FROM events WHERE amount >= {int(n * 0.01) * 3}"),
        ("delete all (predicate)", "DELETE FROM events WHERE amount >= 0"),
        ("delete none",   f"DELETE FROM events WHERE amount >= {n * 4}"),
        ("delete all (unqualified)", "DELETE FROM events"),
    ]

    file_mib = pristine.stat().st_size / (1024 * 1024)
    print(f"\nCybouDB DELETE, {args.rows:,} rows, {file_mib:,.0f} MiB file, "
          f"{args.repeats} repeats (median)\n")
    header = (f"{'scenario':<26} {'deleted':>10} {'survivors':>10} {'exec ms':>9} "
              f"{'ns/surv':>9} {'commit ms':>10} {'pages':>9} {'x table':>8}")
    print(header)
    print("-" * len(header))

    if args.only:
        scenarios = [s for s in scenarios if args.only in s[0]]

    results = []
    for name, sql in scenarios:
        runs = [measure(args.binary, args.bench, pristine, working, sql)
                for _ in range(args.repeats)]
        ms = statistics.median(r["exec_ns"] for r in runs) / 1e6
        commit_ms = statistics.median(r["commit_ns"] for r in runs) / 1e6
        r = runs[0]
        surv = r["rows_after"]
        deleted = r["deleted"]
        pages = int(statistics.median(x["pages_staged"] for x in runs))
        table_pages = r["pages_before"]
        ns_surv = (ms * 1e6 / surv) if surv else 0.0
        ns_del = (ms * 1e6 / deleted) if deleted else 0.0
        print(f"{name:<26} {deleted:>10,} {surv:>10,} {ms:>9.2f} "
              f"{ns_surv:>9.1f} {commit_ms:>10.2f} {pages:>9,} "
              f"{pages / max(table_pages, 1):>8.2f}")
        results.append({"scenario": name, "sql": sql, "median_ms": ms,
                        "median_commit_ms": commit_ms,
                        "deleted": deleted, "survivors": surv,
                        "ns_per_survivor": ns_surv, "ns_per_deleted": ns_del,
                        "pages_staged": pages, "table_pages": table_pages,
                        "runs": runs})

    print("\nns/surv is the cost of the rewrite per row it had to carry over.")
    print("pages is what the statement staged before the commit; x table is that")
    print("against the pages the table itself occupied.")

    if args.output:
        args.output.write_text(json.dumps(
            {"rows": args.rows, "repeats": args.repeats,
             "file_bytes": pristine.stat().st_size, "results": results},
            indent=2), encoding="utf-8")
        print(f"\nwrote {args.output}")


if __name__ == "__main__":
    main()
