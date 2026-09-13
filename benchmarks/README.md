# Benchmarks

For deterministic vector exact-search measurements:

```sh
sh build.sh --vector-bench          # Windows: build.bat --vector-bench
./build/vector_search_bench 20000 128 10 3
```

The fixture uses a fixed PRNG seed and prints order-sensitive result checksums
alongside scalar and runtime-dispatched cosine/L2 throughput. It exits with an
error if the rankings differ. Input generation and normalization are outside
the timed region.

```sh
sh build.sh --bench          # Windows: build.bat --bench
python3 benchmarks/run_benchmarks.py ./cyboudb ./build/bench_harness
```

For DELETE:

```sh
sh build.sh --bench && sh build.sh --delete-bench
python3 benchmarks/run_delete_benchmark.py --rows 1000000 --repeats 1 --headroom 6
```

`delete_bench.c` exists because a DELETE cannot be timed the way a SELECT
plan is: it runs once and the state it ran against is gone. The runner
restores a fresh copy of the seeded database before each measurement, and the
harness runs the statement inside an explicit transaction so that the commit -
a flush of the whole mapping, and the larger number on a large file - is timed
separately rather than folded into the statement. Results and what they say
about the rewrite's scaling are in
[results/2026-09-12-delete.md](results/2026-09-12-delete.md).

`append_probe.c`, built by the same target, is the diagnostic behind that
write-up: it appends chunks into one uncommitted transaction and times the
calls `db_pax_insert` makes before touching data, so a cost that grows with
staged state shows up against a control that does not. Its fourth argument
forces the scalar CRC-32C, which is how the growth was identified as checksum
work rather than merely located.

## What is measured

`bench_harness.asm` opens the database once, parses and binds the statement
once, warms up, and then times N executions of the already bound plan. The
result sink does O(1) work per batch - a population count and a hash of the
selection mask - so what falls between the two clock reads is the scan, the
predicate kernels and the batch delivery, and nothing else.

The arena is rewound to a mark taken after binding before each execution,
which is what an embedding would do; without it the batch view allocated per
execution would exhaust the arena within a few hundred iterations.

Timing comes from `os_monotonic_ns` - `clock_gettime(CLOCK_MONOTONIC)` on
Linux, `QueryPerformanceCounter` on Windows - and from `RDTSC`. The TSC figure
is labelled `tsc/row` rather than `cycles/row` on purpose: on any modern part
the TSC counts at a fixed reference frequency, not at the core clock, so it is
a stable proxy rather than a cycle count.

## What is deliberately not measured

Not `time cyboudb query ...`. That would measure process creation, the mapping
setup, decimal formatting and a write to a pipe, which together are far larger
than the work being studied. The point of a separate harness is to leave all
of it outside the timed region.

## Reading the output

| Column | Meaning |
| :--- | :--- |
| `sel/run` | rows selected per execution |
| `row/bat` | average rows per delivered batch; only nonempty selections are delivered |
| `B/row` | bytes per row actually mapped, summed over the columns the plan required |
| `ns/row`, `tsc/row` | per row **scanned**, not per row selected |
| `Mrow/s` | rows scanned per second, millions |
| `GB/s` | `B/row` x rows scanned per second |

`row/bat` is worth watching. Per-batch setup is a fixed cost, so when a leaf
holds few rows that cost is most of what the per-row figures report.

## Scope

`run_benchmarks.py` deliberately builds legacy single-level fixtures capped by
the 251-entry directory (about 112,000 rows at 448 rows per leaf run). This is
not the engine's current scalability limit: two-level directories already
support the 1M/5M/10M comparisons below. The small fixtures compare CybouDB layouts;
`run_sqlite_benchmarks.py` handles the large cross-engine comparison.

## What it found

Historical measurements identified two problems. Their original observations
are retained here; later results must be interpreted against their own code
revision and measurement conditions.

**A wide schema cost roughly 30x more per row - fixed.** A 32-column table
scanned at 90-100 ns/row against 2-5 for a 7-column one, and required-column
pruning did not change it: reading 1 of 32 columns cost the same as reading 32
of 32. A 32-column leaf held only 24 rows, so a single-column query still
faulted a whole 4 KiB page for every 24 rows it wanted. Making a leaf a run of
pages sized from the schema took that to 448 rows per leaf, ~14 ns/row and
full 64-row batches - see [../docs/PAX_CAPACITY.md](../docs/PAX_CAPACITY.md).

**Historical shared-file slowdown, requiring a new measurement.**
The same `SELECT id FROM events` runs at 0.65 ns/row when `events` is alone in
its file and 13.5 ns/row when a second table shares the database - the same
statement, schema and 112 384 rows. Longer leaf runs were expected to help
here too and did not measurably. This predates the prepared-plan validation
fast path; it does not prove that allocation policy caused the slowdown.

That second finding is why `run_benchmarks.py` builds each dataset in its own
database and measures the sharing effect as an explicit scenario. Left
implicit, it silently moved every other number in the table by an order of
magnitude depending on what had been created before it.

---

## Out-of-cache comparison against SQLite (Phase 3.5)

```sh
sh build.sh --bench && sh build.sh --sqlite-bench      # Windows: build.bat
python3 benchmarks/run_sqlite_benchmarks.py --rows 10000000 --mode both
```

With the two-level directory (`CybouDB_FEATURE_PAX_TREE`), tables grow to 251 x 251
leaves (up to 28 million rows). On a machine with a 12 MB L3 cache (Intel Core Ultra
7 258V), datasets of 1M, 5M, and 10M rows test true out-of-cache memory scan speed:
- **1 000 000 rows**: ~47 MB CybouDB vs ~29 MB SQLite (~4x L3 cache)
- **5 000 000 rows**: ~203 MB CybouDB vs ~151 MB SQLite (~17x L3 cache)
- **10 000 000 rows**: ~403 MB CybouDB vs ~308 MB SQLite (~34x L3 cache)

### Rigorous methodology & parity verification

Both engines are measured in-process without process launch, CLI formatting, or
Python interpreter loop overhead:
- **CybouDB**: `bench_harness.asm` opens the database, binds the statement once, and
  measures repeated execution using `db_pax_scan_open_bound` (fast path bound to
  database generation, skipping catalog directory validation).
- **SQLite**: `sqlite_harness.c` opens the database, sets `PRAGMA mmap_size = 2147483648`
  (2 GB, covering the entire database in memory; effective mmap verified dynamically),
  sets `PRAGMA cache_size = -64000`, prepares the statement once, and steps `sqlite3_step()`
  in a tight C loop.

The harness evaluates two distinct modes:
1. **Mode 1 (MATERIALIZE)**: Primary mode. Scan -> Predicate kernels -> Active lane mask ->
   Cell dereference -> FNV-1a checksum. Every selected cell is read into CPU registers
   (as `int64_t`, `int32_t`, `float`, `bool`, or NULL sentinel) and folded into a canonical
   64-bit FNV-1a hash (basis `0xcbf29ce484222325ULL`, prime `1099511628211ULL`) with distinct
   1-byte cell tags (`0xBF` for NULL, `0x5A` for typed values) so NULL never collides with
   integer value 255.
   **Bit-for-bit checksum equality (`MATCH`) between CybouDB and SQLite is verified across all queries.**
2. **Mode 0 (FILTER)**: Secondary mode. Scan -> Predicate kernels -> Active lane mask ->
   Population count. Measures pure filter efficiency and vector lane creation.

### Historical scalar results at scale (Intel Core Ultra 7 258V, Windows 11)

#### 10,000,000 rows (403 MB CybouDB vs 308 MB SQLite, ~34x L3 cache)

##### Mode 1: Materialize (Scan + Filter + Cell Reads + Checksum)

| Scenario | Selected | CybouDB (ns/row) | SQLite (ns/row) | Speedup | CybouDB (Mrow/s) | SQLite (Mrow/s) | CybouDB (GB/s) | Parity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `int32 equality` | 1 250 000 | 1.93 | 24.22 | **12.54x** | 518.0 | 41.3 | 6.216 | MATCH |
| `int32 range` | 900 000 | 1.97 | 23.39 | **11.85x** | 506.6 | 42.7 | 6.079 | MATCH |
| `int64 range` | 9 999 666 | 3.78 | 66.22 | **17.51x** | 264.4 | 15.1 | 4.231 | MATCH |
| `float32 range` | 5 000 000 | 2.94 | 46.36 | **15.78x** | 340.5 | 21.6 | 4.086 | MATCH |
| `bool equality` | 5 000 000 | 2.71 | 41.36 | **15.25x** | 368.8 | 24.2 | 3.319 | MATCH |
| `two predicates, AND` | 150 000 | 3.34 | 20.18 | **6.05x** | 299.7 | 49.6 | 4.796 | MATCH |
| `two predicates, OR` | 2 000 000 | 3.81 | 33.84 | **8.89x** | 262.7 | 29.6 | 4.204 | MATCH |
| `nullable predicate` | 3 428 570 | 2.06 | 38.64 | **18.78x** | 486.0 | 25.9 | 5.832 | MATCH |
| `nullable IS NOT NULL` | 8 000 000 | 1.93 | 59.32 | **30.76x** | 518.6 | 16.9 | 6.223 | MATCH |
| `no predicate (full scan)`| 10 000 000 | 2.03 | 60.22 | **29.64x** | 492.2 | 16.6 | 3.937 | MATCH |
| `projection 1 of 7` | 4 900 000 | 2.65 | 41.26 | **15.54x** | 376.8 | 24.2 | 4.521 | MATCH |
| `projection 7 of 7` | 4 900 000 | 9.43 | 148.61 | **15.76x** | 106.1 | 6.7 | 3.501 | MATCH |

- **Materialize Speedup Distribution**: Geometric mean = **15.11x**, Median = **15.65x**, Range = **6.05x .. 30.76x**
- **Materialize Total Query Time**: CybouDB = 1.157s, SQLite = 18.108s (**CybouDB is 15.65x faster weighted overall**).
- **Filter Mode Speedup Distribution**: Geometric mean = **18.63x**, Median = **15.97x**, Range = **6.14x .. 94.99x**
- **Filter Mode Total Query Time**: CybouDB = 0.664s, SQLite = 10.946s (**CybouDB is 16.49x faster weighted overall**).

#### Scaling Summary across 1M, 5M, and 10M Rows

| Dataset Size | CybouDB File | SQLite File | Filter GeoMean | Materialize GeoMean | Materialize Checksums |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1 000 000 rows** | 46.9 MB | 29.2 MB | **18.99x** | **14.84x** (Median 15.30x) | 12/12 MATCH |
| **5 000 000 rows** | 202.5 MB | 150.8 MB | **17.80x** | **15.20x** (Median 15.45x) | 12/12 MATCH |
| **10 000 000 rows** | 403.0 MB | 307.9 MB | **18.63x** | **15.11x** (Median 15.65x) | 12/12 MATCH |

### Architectural takeaways
1. **Column pruning in memory-mapped storage**: When a query accesses a subset of columns,
   CybouDB touches only the contiguous page runs containing those specific column arrays.
   SQLite's row B-tree must traverse every page of every row in the table, paying heavy
   cache line eviction and memory bandwidth penalties.
2. **Bitmask null handling**: `IS NOT NULL` evaluates directly against packed PAX null
   bitmasks using 64-row bitwise instructions, scanning ~700 million rows/s (1.4 ns/row).
   SQLite must decode the serial type header of each cell individually in its VDBE loop.
3. **Branch-free scalar kernels & bound-plan cursors**: 64-row batch kernels coupled with
   `db_pax_scan_open_bound` (which avoids catalog lookup overhead on bound queries) sustain
   300M-700M rows/s throughput on scalar CPU execution alone.

---

## Cross-engine comparison against DuckDB and SQLite (2026-09-09)

```sh
sh build.sh --bench && sh build.sh --sqlite-bench && sh build.sh --duckdb-bench
python3 benchmarks/run_3way_benchmark.py --rows 10000000
```

Five configurations - SQLite 3, DuckDB 1.5.5 at 1 and at 8 threads,
forced-scalar CybouDB and AVX2-dispatched CybouDB - over the same 10,000,000-row
dataset. Each is driven by its own in-process harness (`bench_harness.asm`,
`sqlite_harness.c`, `duckdb_harness.c`), so no engine is measured through a
Python loop and no result row becomes a Python object.

Two comparisons are kept apart, because they answer different questions:

| | Query | What is timed |
| :--- | :--- | :--- |
| FILTER | `SELECT count(*) FROM events WHERE <predicate>`, identical on every engine | scan, predicate evaluation, aggregation; no result delivery |
| MATERIALIZE | `SELECT <1, 3 or 7 columns> FROM events WHERE score > 50`, identical on every engine | the above plus reading every delivered value and checksumming it |

Parity is checked rather than assumed: FILTER compares the `COUNT` each engine
returns, MATERIALIZE compares tagged FNV-1a checksums bit for bit across CybouDB
AVX2, CybouDB scalar, SQLite and DuckDB-1T. DuckDB-8T is left out of the checksum
comparison only because a multi-threaded result need not arrive in table order.

Full tables: [results/2026-09-13-engines-10m.md](results/2026-09-13-engines-10m.md)
(the 2026-09-09 run is kept for history and is superseded).

Summary on **high-entropy** data, CybouDB against each engine, geometric mean.
High entropy is the number to quote: the `structured` dataset is regular enough
that zone maps skip most of the file, which inflates every ratio and says more
about the data than the engine.

| | vs SQLite | vs DuckDB-1T | vs DuckDB-8T |
| :--- | ---: | ---: | ---: |
| FILTER (12 scenarios) | **34.6x faster** | **1.94x faster** | 0.55x (DuckDB faster) |
| MATERIALIZE (4 scenarios) | **22.0x faster** | **4.46x faster** | **4.34x faster** |

Where each engine wins:

- **CybouDB** leads every single-threaded comparison, and every materialization
  scenario against any thread count, by about 4-5x at all projection widths.
- **DuckDB with 8 threads beats CybouDB on filtering**, by roughly 3x on the
  simple integer predicates. CybouDB is single-threaded and has no parallel
  execution at all, so this is what seven more cores buy. Stating it the other
  way - CybouDB wins per core - is true but is not what a user with eight cores
  experiences.
- **Threads buy DuckDB nothing on materialization**: its 8-thread column is
  within 2% of its 1-thread column, because delivery rather than scanning is the
  limit there.
- CybouDB still wins three filter scenarios against 8 threads - `OR`, nullable
  predicates and `IS NOT NULL` - which are the cases where DuckDB's own
  per-thread cost is highest.

Storage sizes: on compressible data DuckDB is **8.3x smaller** (51.1 MB against
422.6 MB); on incompressible data the three are within 17% (360.5, 383.8, 422.6
MB). CybouDB writes uncompressed PAX and its file is the same size either way.
This is the clearest thing DuckDB does better, and on a laptop-sized dataset it
can matter more than a 2x scan difference.

Binary footprint, for context: `cyboudb.exe` is ~100 KB with no dependencies
against ~37 MB for the DuckDB library.

### Measurement flaws found and fixed

The first version of this comparison was wrong in two ways, both of which
flattered DuckDB, and both are worth recording because they are easy to repeat:

1. **Different work on different engines.** CybouDB and SQLite ran real
   projections while DuckDB was given `SELECT count(*)` for the same scenario,
   so DuckDB was credited for reading columns it never touched.
2. **Thread count set on the wrong object.** `SET threads` was issued per
   connection inside one process, but it is an instance-wide setting, so the
   "single-threaded" column was probably not single-threaded.

The runner now uses identical SQL everywhere and one process per engine
configuration, with DuckDB's thread count and read-only mode set on the
database at open time.

### Two datasets, because one answers only half the question

```sh
python3 benchmarks/run_3way_benchmark.py --dataset structured     # default
python3 benchmarks/run_3way_benchmark.py --dataset high_entropy
```

`datasets.py` defines both and seeds all three engines from the same generator,
so no engine gets its own data. Everything is a deterministic function of the
row index - no system randomness - and the runner records the dataset name,
generator version and a SHA-256 of the generated values alongside the database
files. `bench_harness.asm` implements the same two generators for the CybouDB
side; the checksum parity check is what keeps the two in step.

- **structured** - the original pattern (`category = row % 8`,
  `score = row % 100`, `amount = row * 3`). Short repeating cycles: close to
  the best case for run-length encoding, bit packing and zone maps.
- **high_entropy** - every column an independent splitmix64 stream of the row
  index, same value ranges so predicate selectivity is comparable, but nothing
  within a block to compress or summarise.

Storage, same 10,000,000 rows:

| Engine | structured | high entropy |
| :--- | ---: | ---: |
| DuckDB | 44.3 MB | 360.5 MB |
| SQLite | 322.8 MB | 383.8 MB |
| CybouDB (uncompressed) | 422.6 MB | 422.6 MB |

DuckDB's tenfold size advantage is mostly a property of the synthetic pattern.
On data without internal structure it is 15% smaller than CybouDB, not ten times
smaller, and its two structured wins disappear with it: `int64 range` reverses
from 0.37-against-0.79 to 1.05-against-0.85 once `amount` stops being
monotonic. Full tables in
[results/2026-09-09-high-entropy-10m.md](results/2026-09-09-high-entropy-10m.md);
CybouDB AVX2 comes out at 28.3x over SQLite and 1.71x over single-threaded DuckDB
on filters, and 23.5x / 4.17x on materialized projections.

The AVX2 path is also the part that does not care which dataset it is given -
`bool equality` costs 0.46 ns/row on one and 0.47 on the other - while the
scalar path slows by 2-3x on unpredictable predicates, where branches
mispredict. Any performance claim from these benchmarks should say which
dataset it came from.
