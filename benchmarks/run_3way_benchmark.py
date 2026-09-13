#!/usr/bin/env python3
"""Cross-engine benchmark: SQLite, DuckDB (1 and 8 threads), CybouDB scalar, CybouDB AVX2.

Two comparisons are measured, and they are deliberately kept apart because they
answer different questions:

  FILTER       every engine answers the identical aggregate

                   SELECT count(*) FROM events WHERE <predicate>

               so what is timed is scan plus predicate evaluation plus
               aggregation, with no result delivery on any side. CybouDB runs its
               own COUNT(*) plan here rather than a SELECT whose selection mask
               is population counted by the harness sink.

  MATERIALIZE  every engine really reads the same projected values out of its
               own storage and folds them into the same tagged FNV-1a hash, so
               the checksums are comparable bit for bit and no engine is
               credited for work it did not do.

Every engine is driven by an in-process C or assembly harness that opens the
database once, prepares once, warms up, and then times N executions; this
script only launches those processes and reads their 80-byte records. Nothing
is timed through Python, and no result row ever becomes a Python object.
"""

import argparse
import math
import os
from pathlib import Path
import statistics
import struct
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import datasets  # noqa: E402  (sibling module, path set above)

ROOT = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
CybouDB_HARNESS = ROOT / "build" / f"bench_harness{EXE}"
SQLITE_HARNESS = ROOT / "build" / f"sqlite_harness{EXE}"
DUCKDB_HARNESS = ROOT / "build" / f"duckdb_harness{EXE}"

MODE_FILTER = 0
MODE_MATERIALIZE = 1
MODE_AGGREGATE = 2

FIELDS = ["status", "domain", "iterations", "batches", "selected", "checksum",
          "ns", "tsc", "required", "row_bytes"]


def filter_scenarios(rows):
    thresh = 15000000 if rows == 10_000_000 else (rows // 2) * 3
    return [
        ("zone: all NONE", "WHERE amount < 0"),
        ("zone: half NONE/ALL", f"WHERE amount >= {thresh}"),
        ("zone: all UNKNOWN", "WHERE score > 90"),
        ("int32 equality", "WHERE category = 3"),
        ("int64 range", "WHERE amount > 1000"),
        ("float32 range", "WHERE weight > 500.0"),
        ("bool equality", "WHERE active = TRUE"),
        ("two predicates, AND", "WHERE score > 90 AND category = 3"),
        ("two predicates, OR", "WHERE score > 90 OR category = 3"),
        ("nullable predicate", "WHERE tag > 3"),
        ("nullable IS NOT NULL", "WHERE tag IS NOT NULL"),
        ("no predicate (full)", ""),
    ]


def materialize_scenarios(rows):
    thresh = 15000000 if rows == 10_000_000 else (rows // 2) * 3
    return [
        ("proj 1 of 7 (score>50)", "id", "WHERE score > 50"),
        ("proj 3 of 7 (score>50)", "id, score, weight", "WHERE score > 50"),
        ("proj 7 of 7 (score>50)", "id, category, score, amount, active, weight, tag", "WHERE score > 50"),
        ("zone mat: 3 of 7 (half)", "id, score, weight", f"WHERE amount >= {thresh}"),
    ]


def filter_sql(where):
    return f"SELECT count(*) FROM events {where}".strip()


def run_harness(exe, db, sql, iters, warmup, mode, extra=None, env=None):
    cmd = [str(exe), str(db), sql, str(iters), str(warmup), str(mode)]
    if extra is not None:
        if isinstance(extra, (list, tuple)):
            cmd.extend(map(str, extra))
        else:
            cmd.append(str(extra))
    res = subprocess.run(cmd, capture_output=True, env=env)
    if len(res.stdout) < 80:
        raise RuntimeError(
            f"{Path(exe).name} produced no record for {sql!r}: "
            f"{res.stderr.decode(errors='replace').strip()}")
    rec = dict(zip(FIELDS, struct.unpack("<10Q", res.stdout[:80])))
    if rec["status"] != 0:
        raise RuntimeError(
            f"{Path(exe).name} failed with status {rec['status']} for {sql!r}: "
            f"{res.stderr.decode(errors='replace').strip()}")
    return rec


def run_zone_diagnostics(exe, db, sql, mode):
    cmd = [str(exe), str(db), sql, "1", "0", str(mode), "0", "0", "1"]
    res = subprocess.run(cmd, capture_output=True)
    if len(res.stdout) < 128:
        raise RuntimeError(
            f"{Path(exe).name} produced no diagnostic record for {sql!r}: "
            f"{res.stderr.decode(errors='replace').strip()}")
    fields = ["leaf_total", "leaf_none", "leaf_all", "leaf_unknown", "batch_total", "col_mask"]
    return dict(zip(fields, struct.unpack("<6Q", res.stdout[80:128])))


def find_duckdb_library(explicit):
    """Locate a shared library exporting the DuckDB C API.

    The published wheel's extension module exports the whole C API, so a
    `pip install duckdb` in any interpreter is enough; no separate libduckdb
    download is required.
    """
    if explicit:
        return explicit
    if os.environ.get("DUCKDB_DLL"):
        return os.environ["DUCKDB_DLL"]
    for interpreter in (sys.executable, "python3", "python"):
        try:
            out = subprocess.run(
                [interpreter, "-c",
                 "import _duckdb, sys; sys.stdout.write(_duckdb.__file__)"],
                capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    return None


def duckdb_env(library):
    """DuckDB's own dependencies resolve next to the interpreter that ships it."""
    env = dict(os.environ)
    env["DUCKDB_DLL"] = library
    home = Path(library).resolve()
    for parent in home.parents:
        if (parent / f"python{EXE}").exists() or (parent / "bin").exists():
            env["PATH"] = str(parent) + os.pathsep + env.get("PATH", "")
            break
    return env


class Engines:
    """One measurement callable per engine configuration."""

    def __init__(self, args, paths, duckdb_seeded):
        self.rows = args.rows
        self.iters = args.iters
        self.warmup = args.warmup
        self.dataset = args.dataset
        self.cdb_db = paths["cyboudb"]
        self.sqlite_db = paths["sqlite"]
        self.duckdb_db = paths["duckdb"]
        self.duckdb_library = find_duckdb_library(args.duckdb_lib)
        self.duckdb_env = duckdb_env(self.duckdb_library) if self.duckdb_library else None
        self.have_duckdb = (duckdb_seeded and bool(self.duckdb_library)
                            and DUCKDB_HARNESS.exists())

    def measure(self, engine, sql, mode):
        if engine == "sqlite":
            return run_harness(SQLITE_HARNESS, self.sqlite_db, sql,
                               self.iters, self.warmup, mode)
        if engine == "cyboudb_zone_on":
            return run_harness(CybouDB_HARNESS, self.cdb_db, sql,
                               self.iters, self.warmup, mode, extra=[0, 0, 0])
        if engine == "cyboudb_zone_off":
            return run_harness(CybouDB_HARNESS, self.cdb_db, sql,
                               self.iters, self.warmup, mode, extra=[0, 1, 0])
        if engine == "cyboudb_scalar_zone_on":
            return run_harness(CybouDB_HARNESS, self.cdb_db, sql,
                               self.iters, self.warmup, mode, extra=[1, 0, 0])
        if engine == "cyboudb_scalar_zone_off":
            return run_harness(CybouDB_HARNESS, self.cdb_db, sql,
                               self.iters, self.warmup, mode, extra=[1, 1, 0])
        if engine in ("duckdb_1t", "duckdb_8t"):
            threads = 1 if engine == "duckdb_1t" else 8
            return run_harness(DUCKDB_HARNESS, self.duckdb_db, sql,
                               self.iters, self.warmup, mode,
                               extra=threads, env=self.duckdb_env)
        raise ValueError(engine)

    def ns_per_row(self, engine, sql, mode):
        rec = self.measure(engine, sql, mode)
        return (rec["ns"] / self.iters) / self.rows, rec


def geomean(values):
    return math.exp(sum(math.log(v) for v in values) / len(values))


def cyboudb_count(cyboudb_exe, db, sql):
    """The count CybouDB itself reports, read outside any measured region."""
    res = subprocess.run([str(cyboudb_exe), "query", str(db), sql],
                         capture_output=True, text=True)
    for line in reversed(res.stdout.splitlines()):
        token = line.strip()
        if token.isdigit():
            return int(token)
    raise RuntimeError(f"could not read a count from: {res.stdout}{res.stderr}")


def run_scenario_with_repeats(engines, sql, mode, order, repeats):
    engine_keys = [e for _, e in order]
    runs = {e: [] for e in engine_keys}
    records = {}

    n = len(engine_keys)
    for r in range(repeats):
        offset = r % n
        rotated = engine_keys[offset:] + engine_keys[:offset]
        for e in rotated:
            rec = engines.measure(e, sql, mode)
            runs[e].append(rec["ns"])
            records[e] = rec

    medians = {}
    for e in engine_keys:
        med_ns = statistics.median(runs[e])
        medians[e] = (med_ns / engines.iters) / engines.rows

    return medians, records


def run_filter(engines, cyboudb_exe, order, repeats):
    print()
    print("FILTER - identical aggregate on every engine: "
          "SELECT count(*) FROM events WHERE ...")
    print("Scan, predicate evaluation and aggregation. No result delivery.")
    print("-" * 130)
    print(f"{'Scenario':<24} {'Selected':>10} | " +
          " ".join(f"{label:>10}" for label, _ in order) +
          f" | {'zON/SQLt':>8} {'zON/Dk1T':>8} {'zON/zOFF':>8} {'Parity':>8}")
    print("-" * 130)

    speedup_sqlite, ratio_duck, speedup_zone = [], [], []
    parity_ok = True
    diagnostics = []

    for name, where in filter_scenarios(engines.rows):
        sql = filter_sql(where)
        timings, records = run_scenario_with_repeats(engines, sql, MODE_FILTER, order, repeats)
        counts = {}
        for _, engine in order:
            if engine in ("sqlite", "duckdb_1t", "duckdb_8t"):
                agg = engines.measure(engine, sql, MODE_AGGREGATE)
                counts[engine] = agg["selected"] // engines.iters
        counts["cyboudb"] = cyboudb_count(cyboudb_exe, engines.cdb_db, sql)

        distinct = set(counts.values())
        parity = "MATCH" if len(distinct) == 1 else "MISMATCH"
        if parity != "MATCH":
            parity_ok = False

        zone_on = timings["cyboudb_zone_on"]
        sp_sqlite = timings["sqlite"] / zone_on
        speedup_sqlite.append(sp_sqlite)
        if "duckdb_1t" in timings:
            rd = timings["duckdb_1t"] / zone_on
            ratio_duck.append(rd)
            rd_text = f"{rd:>7.2f}x"
        else:
            rd_text = f"{'-':>8}"

        sp_zone = timings["cyboudb_zone_off"] / zone_on if zone_on > 0 else 0.0
        speedup_zone.append(sp_zone)

        # Separate diagnostic run: trace ON, 1 execution
        diag = run_zone_diagnostics(CybouDB_HARNESS, engines.cdb_db, sql, MODE_FILTER)
        diagnostics.append((name, diag))

        print(f"{name:<24} {counts['cyboudb']:>10,} | " +
              " ".join(f"{timings[e]:>9.2f}n" for _, e in order) +
              f" | {sp_sqlite:>7.1f}x {rd_text} {sp_zone:>7.2f}x {parity:>8}")

    print("-" * 130)
    print(f"CybouDB zone-ON vs SQLite:    {geomean(speedup_sqlite):>6.2f}x geomean "
          f"({len(speedup_sqlite)} scenarios)")
    if ratio_duck:
        print(f"CybouDB zone-ON vs DuckDB-1T: {geomean(ratio_duck):>6.2f}x geomean "
              f"(above 1.00 means CybouDB is faster)")
    print(f"CybouDB zone-ON vs zone-OFF:  {geomean(speedup_zone):>6.2f}x geomean "
          f"(above 1.00 means zone maps sped up the query)")
    print(f"Selected-row parity:       {'ALL MATCH' if parity_ok else 'MISMATCH'}")

    print()
    print("ZONE MAP FILTER DIAGNOSTICS (single diagnostic run with trace ON):")
    print(f"{'Scenario':<24} {'Leaves':>8} {'NONE':>8} {'ALL':>8} {'UNKNOWN':>8} {'NONE %':>8} {'ALL %':>8} {'Batches':>8} {'ColMask':>8}")
    print("-" * 106)
    for name, d in diagnostics:
        tot = max(d["leaf_total"], 1)
        none_pct = 100.0 * d["leaf_none"] / tot
        all_pct = 100.0 * d["leaf_all"] / tot
        print(f"{name:<24} {d['leaf_total']:>8} {d['leaf_none']:>8} {d['leaf_all']:>8} {d['leaf_unknown']:>8} "
              f"{none_pct:>7.1f}% {all_pct:>7.1f}% {d['batch_total']:>8} {d['col_mask']:>8x}")
    print("-" * 106)

    return parity_ok


def run_materialize(engines, order, repeats):
    print()
    print("MATERIALIZE - every engine reads the same projected values: "
          "SELECT <cols> FROM events WHERE ...")
    print("Scan, predicate evaluation, cell reads and a tagged FNV-1a checksum "
          "over every delivered value.")
    print("-" * 130)
    print(f"{'Scenario':<24} {'Selected':>10} | " +
          " ".join(f"{label:>10}" for label, _ in order) +
          f" | {'zON/SQLt':>8} {'zON/Dk1T':>8} {'zON/zOFF':>8} {'Checksum':>8}")
    print("-" * 130)

    speedup_sqlite, ratio_duck, speedup_zone = [], [], []
    checksums_ok = True
    diagnostics = []

    for name, columns, where in materialize_scenarios(engines.rows):
        sql = f"SELECT {columns} FROM events {where}".strip()
        timings, records = run_scenario_with_repeats(engines, sql, MODE_MATERIALIZE, order, repeats)

        selected = records["cyboudb_zone_on"]["selected"] // engines.iters
        # Single-threaded engines deliver rows in table order, so their
        # checksums must agree bit for bit. An 8-thread DuckDB result may
        # arrive in any order, so it is not part of this comparison.
        ordered = [records[e]["checksum"] for e in
                   ("cyboudb_zone_on", "cyboudb_zone_off", "sqlite", "duckdb_1t")
                   if e in records and records[e] is not None]
        match = "MATCH" if len(set(ordered)) == 1 else "MISMATCH"
        if match != "MATCH":
            checksums_ok = False

        zone_on = timings["cyboudb_zone_on"]
        sp_sqlite = timings["sqlite"] / zone_on
        speedup_sqlite.append(sp_sqlite)
        if "duckdb_1t" in timings:
            rd = timings["duckdb_1t"] / zone_on
            ratio_duck.append(rd)
            rd_text = f"{rd:>7.2f}x"
        else:
            rd_text = f"{'-':>8}"

        sp_zone = timings["cyboudb_zone_off"] / zone_on if zone_on > 0 else 0.0
        speedup_zone.append(sp_zone)

        # Separate diagnostic run
        diag = run_zone_diagnostics(CybouDB_HARNESS, engines.cdb_db, sql, MODE_MATERIALIZE)
        diagnostics.append((name, diag))

        print(f"{name:<24} {selected:>10,} | " +
              " ".join(f"{timings[e]:>9.2f}n" for _, e in order) +
              f" | {sp_sqlite:>7.1f}x {rd_text} {sp_zone:>7.2f}x {match:>8}")

    print("-" * 130)
    print(f"CybouDB zone-ON vs SQLite:    {geomean(speedup_sqlite):>6.2f}x geomean")
    if ratio_duck:
        print(f"CybouDB zone-ON vs DuckDB-1T: {geomean(ratio_duck):>6.2f}x geomean")
    print(f"CybouDB zone-ON vs zone-OFF:  {geomean(speedup_zone):>6.2f}x geomean")
    print(f"Checksum parity:           "
          f"{'ALL MATCH' if checksums_ok else 'MISMATCH - results differ'}")

    print()
    print("ZONE MAP MATERIALIZE DIAGNOSTICS (single diagnostic run with trace ON):")
    print(f"{'Scenario':<24} {'Leaves':>8} {'NONE':>8} {'ALL':>8} {'UNKNOWN':>8} {'NONE %':>8} {'ALL %':>8} {'Batches':>8} {'ColMask':>8}")
    print("-" * 106)
    for name, d in diagnostics:
        tot = max(d["leaf_total"], 1)
        none_pct = 100.0 * d["leaf_none"] / tot
        all_pct = 100.0 * d["leaf_all"] / tot
        print(f"{name:<24} {d['leaf_total']:>8} {d['leaf_none']:>8} {d['leaf_all']:>8} {d['leaf_unknown']:>8} "
              f"{none_pct:>7.1f}% {all_pct:>7.1f}% {d['batch_total']:>8} {d['col_mask']:>8x}")
    print("-" * 106)

    return checksums_ok


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=10_000_000)
    parser.add_argument("--dataset", choices=datasets.DATASETS, default="structured",
                        help="structured is highly compressible; high_entropy is not")
    parser.add_argument("--iters", type=int, default=5)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=5,
                        help="process-level repeats with rotated execution order")
    parser.add_argument("--db-dir", type=Path, default=ROOT / "build" / "benchrun")
    parser.add_argument("--cyboudb", type=Path, default=ROOT / f"cyboudb{EXE}")
    parser.add_argument("--duckdb-lib", default=None,
                        help="shared library exporting the DuckDB C API")
    parser.add_argument("--no-seed", action="store_true",
                        help="fail instead of generating a missing dataset")
    args = parser.parse_args()

    if args.no_seed:
        paths = datasets.db_paths(args.db_dir, args.dataset, args.rows)
        duckdb_seeded = paths["duckdb"].exists()
    else:
        paths, duckdb_seeded = datasets.ensure(
            args.db_dir, args.dataset, args.rows, args.cyboudb, CybouDB_HARNESS)

    engines = Engines(args, paths, duckdb_seeded)

    order = [("SQLite", "sqlite")]
    if engines.have_duckdb:
        order += [("DuckDB 1T", "duckdb_1t"), ("DuckDB 8T", "duckdb_8t")]
    order += [("CybouDB-off", "cyboudb_zone_off"), ("CybouDB-on", "cyboudb_zone_on")]

    print("=" * 130)
    print(f"Cross-engine benchmark - events table, 7 columns, {args.rows:,} rows")
    meta = datasets.metadata(args.dataset, args.rows)
    print(f"  dataset: {meta['dataset']} (generator v{meta['generator_version']}, "
          f"sha256 {meta['digest_sha256'][:16]} over the first "
          f"{meta['digest_rows']:,} rows)")
    for label, path in (("CybouDB  ", engines.cdb_db),
                        ("SQLite", engines.sqlite_db),
                        ("DuckDB", engines.duckdb_db)):
        if path.exists():
            print(f"  {label} file: {path.stat().st_size / 1e6:>8.1f} MB  {path.name}")
    if engines.have_duckdb:
        print(f"  DuckDB C API: {engines.duckdb_library}")
    else:
        print("  DuckDB: not measured (no C API library or no build/duckdb_harness)")
    print(f"  {args.iters} timed iterations, {args.warmup} warmup, {args.repeats} process repeats, "
          f"figures are ns/logical-row (median of process runs)")
    print("=" * 130)

    filter_ok = run_filter(engines, args.cyboudb, order, args.repeats)
    materialize_ok = run_materialize(engines, order, args.repeats)
    print()
    return 0 if (filter_ok and materialize_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
