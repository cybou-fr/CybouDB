#!/usr/bin/env python3
"""CybouDB vs. SQLite Out-of-Cache Benchmarks (Phase 3.5).

Compares CybouDB's columnar zero-copy batch executor against SQLite's
row-oriented B-tree engine on datasets that strictly exceed CPU L3 cache.

Benchmark Modes:
 - FILTER (mode 0): Pure scan + predicate evaluation + popcount of active lanes.
 - MATERIALIZE (mode 1): Direct dereference of every projected cell value from
   mapped memory, folding each cell into a 64-bit FNV-1a checksum. CybouDB and
   SQLite read identical columns and compute identical checksums.

Both engines:
 - Open the database once outside the timed region.
 - Parse and bind / prepare the SQL statement once outside the timed region.
 - Perform warmup iterations outside the timed region.
 - Time executions in-process using monotonic nanoseconds and RDTSC.
 - Execute with memory mapping (CybouDB mmap, SQLite PRAGMA mmap_size).

Usage:
    python benchmarks/run_sqlite_benchmarks.py [--rows 1000000] [--mode both] [--iterations 10]
"""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import sqlite3
import statistics
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import datasets  # noqa: E402  (sibling module, path set above)

ROOT = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
DEFAULT_BINARY = ROOT / f"cyboudb{EXE}"
DEFAULT_CybouDB_HARNESS = ROOT / "build" / f"bench_harness{EXE}"
DEFAULT_SQLITE_HARNESS = ROOT / "build" / f"sqlite_harness{EXE}"

BENCH_RECORD_SIZE = 80
FIELDS = ["status", "domain", "iterations", "batches", "selected", "checksum",
          "ns", "tsc", "required", "row_bytes"]

# The structured dataset and its column list live in datasets.py, which also
# seeds DuckDB and defines the high entropy dataset; this runner measures CybouDB
# against SQLite only, on the structured one.
EVENTS_COLUMNS = [(name, kind, sql) for name, kind, sql, _ in datasets.EVENTS_COLUMNS]
event_tuple_sqlite = datasets.row_structured


def run_cmd(exe, *args):
    res = subprocess.run([str(exe), *map(str, args)], capture_output=True, timeout=1200)
    if res.returncode:
        raise RuntimeError(f"{Path(exe).name} {args[:2]} failed: {res.stdout[:200]!r} {res.stderr[:200]!r}")
    return res.stdout


def get_cyboudb_row_count(binary, db_path):
    """Check how many rows the CybouDB events table currently holds."""
    try:
        out = run_cmd(binary, "query", db_path, "SELECT COUNT(*) FROM events").decode()
        lines = out.strip().splitlines()
        counts = [int(line.strip()) for line in lines if line.strip().isdigit()]
        if len(counts) == 1:
            return counts[0]
    except Exception:
        pass
    return -1


def build_cyboudb_events(binary, bench_harness, db_path, target_rows):
    if db_path.exists():
        existing = get_cyboudb_row_count(binary, db_path)
        if existing == target_rows:
            print(f"[CybouDB] Using cached database {db_path.name} ({existing:,} rows)")
            return
        print(f"[CybouDB] Cached database has {existing} rows, expected {target_rows}. Recreating...")
        try:
            db_path.unlink()
        except OSError:
            pass

    print(f"[CybouDB] Generating {db_path.name} with {target_rows:,} rows via fast bulk seeder...")
    # Leaf holds 448 rows for events schema (4 pages = 16 KiB).
    # Generous page estimate with span-map + 2-level directory:
    needed_pages = max(12000, int((target_rows / 448) * 4 * 1.15) + 500)
    run_cmd(binary, "create-large", db_path, needed_pages, "--force")

    cyboudb_cols = ", ".join(f"{name} {kind}" for name, kind, _ in EVENTS_COLUMNS)
    run_cmd(binary, "query", db_path, f"CREATE TABLE events ({cyboudb_cols})")

    t0 = time.perf_counter()
    run_cmd(bench_harness, db_path, "--seed", target_rows)
    elapsed = time.perf_counter() - t0
    rate = target_rows / elapsed if elapsed > 0 else 0
    print(f"[CybouDB] Finished seeding {target_rows:,} rows in {elapsed:.2f}s ({rate:,.0f} rows/s)")


def build_sqlite_events(db_path, target_rows):
    if db_path.exists():
        try:
            conn = sqlite3.connect(str(db_path))
            cur = conn.cursor()
            cur.execute("SELECT count(*) FROM events")
            existing = cur.fetchone()[0]
            conn.close()
            if existing == target_rows:
                print(f"[SQLite] Using cached database {db_path.name} ({existing:,} rows)")
                return
        except Exception:
            pass
        try:
            db_path.unlink()
        except OSError:
            pass

    print(f"[SQLite] Generating {db_path.name} with {target_rows:,} rows...")
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    cur.execute("PRAGMA synchronous = OFF;")
    cur.execute("PRAGMA journal_mode = OFF;")
    cur.execute("PRAGMA page_size = 4096;")

    sqlite_cols = ", ".join(f"{name} {sql_type}" for name, _, sql_type in EVENTS_COLUMNS)
    cur.execute(f"CREATE TABLE events ({sqlite_cols})")

    t0 = time.perf_counter()
    chunk_size = 100000
    last_print = 0
    cur.execute("BEGIN TRANSACTION;")
    for chunk_start in range(0, target_rows, chunk_size):
        chunk_end = min(chunk_start + chunk_size, target_rows)
        rows = [event_tuple_sqlite(r) for r in range(chunk_start, chunk_end)]
        cur.executemany("INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?)", rows)
        if chunk_end - last_print >= 500000 or chunk_end == target_rows:
            elapsed = time.perf_counter() - t0
            rate = chunk_end / elapsed if elapsed > 0 else 0
            print(f"  [SQLite] {chunk_end:>8,} / {target_rows:,} rows ({chunk_end * 100 // target_rows}%) - {rate:,.0f} rows/s")
            last_print = chunk_end
    conn.commit()

    conn.close()
    elapsed = time.perf_counter() - t0
    rate = target_rows / elapsed if elapsed > 0 else 0
    print(f"[SQLite] Finished generating {target_rows:,} rows in {elapsed:.1f}s ({rate:,.0f} rows/s)")


def measure(harness, db_path, sql, iterations, warmup, mode, extra=None):
    cmd = [harness, db_path, sql, iterations, warmup, mode]
    if extra is not None:
        cmd.append(extra)
    out = run_cmd(*cmd)
    if len(out) != BENCH_RECORD_SIZE:
        raise RuntimeError(f"Bad record size {len(out)} from {Path(harness).name}: {out[:100]!r}")
    rec = dict(zip(FIELDS, struct.unpack("<10Q", out)))
    if rec["status"]:
        raise RuntimeError(f"{sql} failed with status {rec['status']} domain {rec['domain']}")
    return rec


def get_sqlite_harness_info(sqlite_harness, db_path):
    try:
        out = run_cmd(sqlite_harness, "--version", db_path).decode().strip().splitlines()
        if len(out) >= 3:
            return out[0].strip(), out[1].strip(), int(out[2].strip())
        elif len(out) >= 1:
            return out[0].strip(), "unknown", 0
    except Exception:
        pass
    return "unknown", "unknown", 0


def get_metadata(sqlite_harness=None, sqlite_db=None):
    meta = {}
    try:
        commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT).decode().strip()
        meta["commit"] = commit
    except Exception:
        meta["commit"] = "unknown"

    meta["os"] = f"{platform.system()} {platform.release()}"
    meta["python"] = sys.version.split()[0]

    if sqlite_harness and sqlite_db and sqlite_db.exists():
        ver, src, mmap = get_sqlite_harness_info(sqlite_harness, sqlite_db)
        meta["sqlite"] = ver
        meta["sqlite_src"] = src
        meta["sqlite_mmap"] = mmap
    else:
        meta["sqlite"] = sqlite3.sqlite_version
        meta["sqlite_src"] = "system"
        meta["sqlite_mmap"] = 0

    cpu_name = platform.processor()
    if os.name == "nt":
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")
            cpu_name, _ = winreg.QueryValueEx(key, "ProcessorNameString")
            winreg.CloseKey(key)
        except Exception:
            pass
    elif Path("/proc/cpuinfo").exists():
        try:
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    cpu_name = line.split(":", 1)[1].strip()
                    break
        except Exception:
            pass
    meta["cpu"] = cpu_name
    meta["utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    meta["dirty_paths"] = subprocess.check_output(
        ["git", "diff", "--name-only", "HEAD"], cwd=ROOT).decode().splitlines()
    return meta


SCENARIOS = [
    ("int32 equality",
     "SELECT id FROM events WHERE category = 3",
     "SELECT id FROM events WHERE category = 3"),
    ("int32 range",
     "SELECT id FROM events WHERE score > 90",
     "SELECT id FROM events WHERE score > 90"),
    ("int64 range",
     "SELECT id FROM events WHERE amount > 1000",
     "SELECT id FROM events WHERE amount > 1000"),
    ("float32 range",
     "SELECT id FROM events WHERE weight > 500.0",
     "SELECT id FROM events WHERE weight > 500.0"),
    ("bool equality",
     "SELECT id FROM events WHERE active = TRUE",
     "SELECT id FROM events WHERE active = 1"),
    ("two predicates, AND",
     "SELECT id FROM events WHERE score > 90 AND category = 3",
     "SELECT id FROM events WHERE score > 90 AND category = 3"),
    ("two predicates, OR",
     "SELECT id FROM events WHERE score > 90 OR category = 3",
     "SELECT id FROM events WHERE score > 90 OR category = 3"),
    ("nullable predicate",
     "SELECT id FROM events WHERE tag > 3",
     "SELECT id FROM events WHERE tag > 3"),
    ("nullable IS NOT NULL",
     "SELECT id FROM events WHERE tag IS NOT NULL",
     "SELECT id FROM events WHERE tag IS NOT NULL"),
    ("no predicate (full scan)",
     "SELECT id FROM events",
     "SELECT id FROM events"),
    ("count(*) filtered",
     "SELECT count(*) FROM events WHERE score > 90",
     "SELECT count(*) FROM events WHERE score > 90"),
    ("count(*) full scan",
     "SELECT count(*) FROM events",
     "SELECT count(*) FROM events"),
    ("projection 1 of 7",
     "SELECT id FROM events WHERE score > 50",
     "SELECT id FROM events WHERE score > 50"),
    ("projection 3 of 7",
     "SELECT id, score, weight FROM events WHERE score > 50",
     "SELECT id, score, weight FROM events WHERE score > 50"),
    ("projection 7 of 7",
     "SELECT id, category, score, amount, active, weight, tag FROM events WHERE score > 50",
     "SELECT id, category, score, amount, active, weight, tag FROM events WHERE score > 50"),
]


def run_benchmark_mode(args, cyboudb_db, sqlite_db, mode_id, mode_label):
    print("\n" + "=" * 118)
    print(f"MODE: {mode_label.upper()} (mode {mode_id}) - 3-WAY COMPARISON: SQLite vs CybouDB Scalar vs CybouDB AVX2")
    if mode_id == 0:
        print("Workload: Scan -> Predicate kernels -> Active lane mask -> Population count")
    else:
        print("Workload: Scan -> Predicate kernels -> Active lane mask -> Materialize cell values -> FNV-1a checksum")
    print("=" * 118)

    header = (f"{'Scenario':<24} {'Selected':>9} "
              f"{'SQLite ns':>10} {'Scalar ns':>10} {'AVX2 ns':>9} "
              f"{'vs SQLt':>8} {'vs Scal':>8} "
              f"{'AVX2 M/s':>9} {'AVX2 GB/s':>10} {'Check':>7}")
    print(header)
    print("-" * len(header))

    total_avx2_time = 0.0
    total_scalar_time = 0.0
    total_sqlite_time = 0.0
    speedups_vs_sqlite = []
    speedups_vs_scalar = []
    all_matched = True
    results = []

    for name, cyboudb_sql, sqlite_sql in SCENARIOS:
        samples = {engine: [] for engine in ("avx2", "scalar", "sqlite")}
        engines = list(samples)
        for repeat in range(args.repeats):
            # Rotate engine order across independent process runs.
            order = engines[repeat % 3:] + engines[:repeat % 3]
            for engine in order:
                if engine == "sqlite":
                    rec = measure(args.sqlite_harness, sqlite_db, sqlite_sql, args.iterations, args.warmup, mode_id)
                else:
                    rec = measure(args.bench_harness, cyboudb_db, cyboudb_sql, args.iterations, args.warmup, mode_id,
                                  1 if engine == "scalar" else 0)
                samples[engine].append(rec)
        avx2_rec, scalar_rec, sqlite_rec = [
            sorted(samples[engine], key=lambda rec: rec["ns"])[len(samples[engine]) // 2]
            for engine in engines]

        avx2_sel = avx2_rec["selected"] // args.iterations
        scalar_sel = scalar_rec["selected"] // args.iterations
        sqlite_sel = sqlite_rec["selected"] // args.iterations

        scanned = args.rows * args.iterations
        avx2_ns_row = avx2_rec["ns"] / scanned
        scalar_ns_row = scalar_rec["ns"] / scanned
        sqlite_ns_row = sqlite_rec["ns"] / scanned

        speedup_sqlite = sqlite_ns_row / avx2_ns_row if avx2_ns_row > 0 else 1.0
        speedup_scalar = scalar_ns_row / avx2_ns_row if avx2_ns_row > 0 else 1.0
        speedups_vs_sqlite.append(speedup_sqlite)
        speedups_vs_scalar.append(speedup_scalar)

        avx2_sec = avx2_rec["ns"] / 1e9
        scalar_sec = scalar_rec["ns"] / 1e9
        sqlite_sec = sqlite_rec["ns"] / 1e9
        total_avx2_time += avx2_sec
        total_scalar_time += scalar_sec
        total_sqlite_time += sqlite_sec

        avx2_mrow_s = scanned / avx2_sec / 1e6

        row_bytes = avx2_rec["row_bytes"]
        avx2_gb_s = (scanned * row_bytes) / avx2_sec / 1e9

        chk_str = "OK"
        all_records = [rec for records in samples.values() for rec in records]
        counts_match = len({rec["selected"] for rec in all_records}) == 1
        checksums_match = len({rec["checksum"] for rec in all_records}) == 1 if mode_id == 1 else None
        if not counts_match:
            chk_str = "MISMATCH"
            all_matched = False
        elif mode_id == 1:
            if not checksums_match:
                chk_str = "DIFF"
                all_matched = False
            else:
                chk_str = "MATCH"

        results.append({"scenario": name, "cyboudb_sql": cyboudb_sql, "sqlite_sql": sqlite_sql,
                        "samples": samples, "ns_per_input_row": {
                            "avx2": avx2_ns_row, "scalar": scalar_ns_row, "sqlite": sqlite_ns_row},
                        "counts_match": counts_match, "checksums_match": checksums_match})

        print(f"{name:<24} {avx2_sel:>9,} "
              f"{sqlite_ns_row:>10.2f} {scalar_ns_row:>10.2f} {avx2_ns_row:>9.2f} "
              f"{speedup_sqlite:>7.2f}x {speedup_scalar:>7.2f}x "
              f"{avx2_mrow_s:>9.1f} {avx2_gb_s:>10.3f} {chk_str:>7}")

    print("-" * len(header))
    avg_vs_sqlite = total_sqlite_time / total_avx2_time if total_avx2_time > 0 else 1.0
    geo_vs_sqlite = math.exp(sum(math.log(s) for s in speedups_vs_sqlite) / len(speedups_vs_sqlite)) if speedups_vs_sqlite else 1.0
    med_vs_sqlite = statistics.median(speedups_vs_sqlite) if speedups_vs_sqlite else 1.0

    avg_vs_scalar = total_scalar_time / total_avx2_time if total_avx2_time > 0 else 1.0
    geo_vs_scalar = math.exp(sum(math.log(s) for s in speedups_vs_scalar) / len(speedups_vs_scalar)) if speedups_vs_scalar else 1.0
    med_vs_scalar = statistics.median(speedups_vs_scalar) if speedups_vs_scalar else 1.0

    status_note = ("All result counts and materialized cell checksums match." if mode_id == 1
                   else "Result counts match; FILTER does not verify cell values.") if all_matched else "WARNING: Verification discrepancies detected."
    print(f"CybouDB AVX2 vs SQLite ({len(speedups_vs_sqlite)} scenarios):")
    print(f"  Geometric mean: {geo_vs_sqlite:>6.2f}x | Median: {med_vs_sqlite:>6.2f}x | Weighted (sum): {avg_vs_sqlite:>6.2f}x (AVX2 {total_avx2_time:.3f}s vs SQLite {total_sqlite_time:.3f}s)")
    print(f"CybouDB AVX2 vs CybouDB Scalar ({len(speedups_vs_scalar)} scenarios):")
    print(f"  Geometric mean: {geo_vs_scalar:>6.2f}x | Median: {med_vs_scalar:>6.2f}x | Weighted (sum): {avg_vs_scalar:>6.2f}x (AVX2 {total_avx2_time:.3f}s vs Scalar {total_scalar_time:.3f}s)")
    print(f"Status: {status_note}")
    return {"mode": mode_id, "verified": all_matched, "scenarios": results,
            "geomean_avx2_vs_sqlite": geo_vs_sqlite, "geomean_avx2_vs_scalar": geo_vs_scalar}


def main():
    parser = argparse.ArgumentParser(description="Compare CybouDB vs. SQLite on large out-of-cache datasets")
    parser.add_argument("--rows", type=int, default=1000000, help="Number of rows (default 1,000,000)")
    parser.add_argument("--mode", choices=["filter", "materialize", "both"], default="both",
                        help="Benchmark mode: filter (mode 0), materialize (mode 1), or both (default both)")
    parser.add_argument("--iterations", type=int, default=10, help="Measurement iterations (default 10)")
    parser.add_argument("--warmup", type=int, default=2, help="Warmup iterations (default 2)")
    parser.add_argument("--repeats", type=int, default=3, help="Odd number of independent runs; report median timing")
    parser.add_argument("--output", type=Path, help="Save metadata and all timing/checksum records as JSON")
    parser.add_argument("--cyboudb", type=Path, default=DEFAULT_BINARY, help="Path to cyboudb binary")
    parser.add_argument("--bench-harness", type=Path, default=DEFAULT_CybouDB_HARNESS, help="Path to bench_harness")
    parser.add_argument("--sqlite-harness", type=Path, default=DEFAULT_SQLITE_HARNESS, help="Path to sqlite_harness")
    args = parser.parse_args()
    if args.rows <= 0 or args.iterations <= 0 or args.warmup < 0 or args.repeats <= 0 or args.repeats % 2 == 0:
        parser.error("rows/iterations must be positive, warmup nonnegative, repeats positive and odd")

    bench_dir = ROOT / "build" / "benchrun"
    bench_dir.mkdir(parents=True, exist_ok=True)

    cyboudb_db = bench_dir / f"events_{args.rows}.cdb"
    sqlite_db = bench_dir / f"events_{args.rows}.sqlite"

    build_cyboudb_events(args.cdb, args.bench_harness, cyboudb_db, args.rows)
    build_sqlite_events(sqlite_db, args.rows)

    cyboudb_size_mb = cyboudb_db.stat().st_size / (1024 * 1024)
    sqlite_size_mb = sqlite_db.stat().st_size / (1024 * 1024)

    meta = get_metadata(args.sqlite_harness, sqlite_db)
    meta["binary_sha256"] = {str(path.name): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in (args.cdb, args.bench_harness, args.sqlite_harness)}
    mmap_mb = meta["sqlite_mmap"] / (1024 * 1024)
    mmap_desc = f"PRAGMA mmap_size={mmap_mb:.0f} MB" if mmap_mb > 0 else "mmap=OFF"

    print("\n" + "=" * 106)
    print(f"CybouDB vs. SQLite Out-of-Cache Benchmark Suite (Phase 3.5)")
    print(f"Host CPU:      {meta['cpu']}")
    print(f"Platform:      {meta['os']} | Python {meta['python']}")
    print(f"Engines:       CybouDB commit {meta['commit']} | SQLite v{meta['sqlite']} ({meta['sqlite_src']})")
    print(f"Dataset:       events table ({len(EVENTS_COLUMNS)} columns, {args.rows:,} rows)")
    print(f"CybouDB file:     {cyboudb_size_mb:.1f} MB (PAX columnar, 2-level directory, memory-mapped)")
    print(f"SQLite file:   {sqlite_size_mb:.1f} MB (Row B-tree, {mmap_desc}, synchronous=OFF)")
    print(f"Iterations:    {args.iterations} runs, {args.warmup} warmup runs")
    print(f"Repeats:       {args.repeats} independent runs; median ns, rotating engine order")
    print("=" * 106)

    # Primary mode: Materialize (reads projected cell values, verifies FNV-1a checksum parity)
    modes = []
    if args.mode in ("materialize", "both"):
        modes.append(run_benchmark_mode(args, cyboudb_db, sqlite_db, 1, "Materialize (scan + predicate + cell reads + checksum)"))

    # Secondary mode: Filter (predicate evaluation + lane popcount)
    if args.mode in ("filter", "both"):
        modes.append(run_benchmark_mode(args, cyboudb_db, sqlite_db, 0, "Filter (scan + predicate + popcount)"))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"metadata": meta, "rows": args.rows,
            "iterations": args.iterations, "warmup": args.warmup, "repeats": args.repeats,
            "file_bytes": {"cyboudb": cyboudb_db.stat().st_size, "sqlite": sqlite_db.stat().st_size},
            "modes": modes}, indent=2) + "\n", encoding="utf-8")
    if not all(mode["verified"] for mode in modes):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
