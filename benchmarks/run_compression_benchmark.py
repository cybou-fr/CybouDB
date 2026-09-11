"""RAW/CONST/FOR gate: separate fixtures, rotated processes and parity checks."""
import argparse
import collections
import json
import mmap
import platform
import statistics
import struct
from pathlib import Path
import datasets as ds
import run_3way_benchmark as bench


def storage(path):
    """Count only reachable current-generation PAX pages, never stale COW runs.

    Inputs are checked by `cyboudb check` first. This reader is benchmark-only.
    Encoded bytes include codec headers and alignment, exclude null bitmaps.
    """
    with path.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as b:
        q = lambda off: struct.unpack_from("<Q", b, off)[0]
        d = lambda off: struct.unpack_from("<I", b, off)[0]
        sb = max((4096, 8192), key=lambda off: q(off + 8))
        catalog = q(sb + 40) * 4096
        counts = collections.Counter({"RAW": 0, "CONST": 0, "FOR": 0})
        pages = leaves = encoded = raw = 0
        pending = [q(q(catalog + 72 + i * 16) * 4096 + 40)
                   for i in range(d(catalog + 36))]
        seen = set()
        while pending:
            page = pending.pop()
            if not page:
                continue
            assert page not in seen
            seen.add(page)
            off = page * 4096
            if b[off:off + 4] == b"ASQD":
                pages += 1
                pending.extend(q(off + 64 + i * 16) for i in range(d(off + 36)))
                continue
            assert b[off:off + 4] == b"ASQP"
            leaves += 1
            rows, columns, capacity = d(off + 32), d(off + 36), d(off + 40)
            end = 0
            for i in range(columns):
                col = off + 64 + i * 16
                kind, flags, _, values = struct.unpack_from("<4I", b, col)
                width = (0, 4, 8, 4, 1)[kind]
                codec = flags >> 8
                counts[("RAW", "CONST", "FOR")[codec]] += 1
                raw += rows * width
                encoded += (rows * width if codec == 0 else 8 if codec == 1
                            else (16 + (rows * b[off + values + 8] + 7) // 8 + 7) & ~7)
                end = max(end, values + ((capacity * width + 7) & ~7))
            pages += (end + 4 + 4095) // 4096
        total = sum(counts.values())
        return dict(logical_db_bytes=len(b), allocated_pax_pages=pages,
                    leaves=leaves, encoded_value_bytes=encoded,
                    raw_logical_value_bytes=raw, codec_columns=dict(counts),
                    codec_column_percent={k: 100 * v / total for k, v in counts.items()})


def read_metadata(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def fixtures(args, dataset):
    paths = {}
    for compressed in (False, True):
        # v2 records the writer policy that rounds FOR widths 1..8 to 8 and
        # 9..16 to 16.  Never reuse v1 fixtures when measuring direct-FOR.
        profile = "for-zone-v2" if compressed else "raw-zone-v1"
        path = args.db_dir / f"{dataset}_{args.rows}_{profile}.cdb"
        meta_path = path.with_suffix(".json")
        meta = ds.metadata(dataset, args.rows)
        meta.update(storage_profile=profile, required_features=1008 if compressed else 496,
                    forbidden_features=0 if compressed else 512)
        old = read_metadata(meta_path)
        if old != meta:
            path.unlink(missing_ok=True)
        ds.seed_cyboudb(args.cdb, bench.cdb_HARNESS, path, args.rows, dataset, compressed)
        ds.run_cmd(args.cdb, "check", path)
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")
        paths["compressed" if compressed else "raw"] = path
    path = args.db_dir / f"{dataset}_{args.rows}.duckdb"
    meta_path = path.with_suffix(".json")
    meta = ds.metadata(dataset, args.rows)
    if read_metadata(meta_path) != meta:
        path.unlink(missing_ok=True)
    assert ds.seed_duckdb(path, args.rows, dataset), "DuckDB is required for this gate"
    meta_path.write_text(json.dumps(meta, indent=2) + "\n")
    paths["duckdb"] = path
    return paths


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--rows", type=int, default=10_000_000)
    p.add_argument("--iters", type=int, default=10)
    p.add_argument("--warmup", type=int, default=2)
    p.add_argument("--repeats", type=int, default=5)
    p.add_argument("--dataset", choices=ds.DATASETS, action="append")
    p.add_argument("--db-dir", type=Path, default=ds.ROOT / "build/compressionbench")
    p.add_argument("--cyboudb", type=Path, default=ds.ROOT / f"cyboudb{ds.EXE}")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--duckdb-lib")
    args = p.parse_args()
    assert min(args.rows, args.iters, args.repeats) > 0 and args.warmup >= 0
    args.db_dir.mkdir(parents=True, exist_ok=True)
    lib = bench.find_duckdb_library(args.duckdb_lib)
    assert lib and bench.DUCKDB_HARNESS.exists(), "Build --duckdb-bench and install duckdb"
    env = bench.duckdb_env(lib)
    import duckdb
    report = dict(complete=False, host=platform.platform(), duckdb_version=duckdb.__version__,
                  rows=args.rows, iterations=args.iters, warmup=args.warmup,
                  repeats=args.repeats, datasets={})
    engines = ["raw", "compressed", "duckdb_1t", "duckdb_8t"]
    for dataset in args.dataset or ds.DATASETS:
        paths = fixtures(args, dataset)
        result = dict(storage={k: storage(paths[k]) for k in ("raw", "compressed")}, scenarios=[])
        report["datasets"][dataset] = result
        scenarios = [(name, bench.filter_sql(where), 0)
                     for name, where in bench.filter_scenarios(args.rows)]
        scenarios += [(name, f"SELECT {cols} FROM events {where}", 1)
                      for name, cols, where in bench.materialize_scenarios(args.rows)]
        for name, sql, mode in scenarios:
            samples = {e: [] for e in engines}
            oracle = None
            for repeat in range(args.repeats):
                for e in engines[repeat % 4:] + engines[:repeat % 4]:
                    is_cyboudb = e in ("raw", "compressed")
                    exe = bench.cdb_HARNESS if is_cyboudb else bench.DUCKDB_HARNESS
                    db = paths[e] if is_cyboudb else paths["duckdb"]
                    extra = [0, 0, 0] if is_cyboudb else (1 if e.endswith("1t") else 8)
                    rec = bench.run_harness(exe, db, sql, args.iters, args.warmup,
                                            mode, extra, None if is_cyboudb else env)
                    # Aggregate results live in a dedicated untimed diagnostic record.
                    if mode == 0:
                        count = (bench.cdb_count(args.cdb, db, sql) if is_cyboudb else
                                 bench.run_harness(exe, db, sql, 1, 0, 2, extra, env)["selected"])
                        signature = (count,)
                    else:
                        signature = (rec["selected"], rec["checksum"])
                    if oracle is None:
                        oracle = signature
                    # DuckDB 8T may reorder materialized rows; compare row counts
                    # there, and full ordered hashes for RAW, encoded and DuckDB 1T.
                    actual = signature[:1] if mode == 1 and e == "duckdb_8t" else signature
                    expected = oracle[:1] if mode == 1 and e == "duckdb_8t" else oracle
                    assert actual == expected, (dataset, sql, e, actual, expected)
                    samples[e].append(rec["ns"] / args.iters / args.rows)
            medians = {e: statistics.median(v) for e, v in samples.items()}
            result["scenarios"].append(dict(name=name, sql=sql, mode=mode, parity="MATCH",
                                           selected_rows=oracle[0] // args.iters if mode else oracle[0],
                                           ns_per_logical_row=medians, samples=samples,
                                           duckdb_8t_parity="count only" if mode else "aggregate"))
            print(dataset, name, medians, flush=True)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + "\n")
    report["complete"] = True
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
