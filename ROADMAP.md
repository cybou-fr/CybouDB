# CybouDB Roadmap

Checkboxes describe the repository as it stands, not as it is meant to end up.
An item is only ticked when it exists in the code and is covered by the test
suite; anything partially done says so instead of borrowing credit from what
it will eventually become.

Design intent behind the phases is in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Where the project is

Phases 1 to 6 have their core implementations. Phase 4 line editing/history
and Phase 6 optional FMA3/AVX-512 extensions remain open. API and CPU hardening
are covered by local Windows and Linux regression runs; see
[docs/HARDENING.md](docs/HARDENING.md) for the completed work and release gates.
The legacy allocator still provides metadata publication without crash-safe
in-place page mutation. The separate persisted COW mode now protects allocation
maps, a typed catalog and bounded multi-page PAX tables, with complete graph
validation.

`cyboudb query` runs `CREATE TABLE`, `INSERT` and `SELECT ... WHERE` against real
pages. The executor scans in batches of 64 rows, reads only the columns the
plan asks for and evaluates predicates through AVX2 SIMD kernels with CPUID dispatch.
An interactive console (REPL) supports multiline statements, piped scripts,
and dot meta-commands.

A leaf is a run of contiguous pages sized from the schema, and a table
whose leaves outgrow one directory page grows a level above it, lifting the
ceiling to 28 million rows. The in-process benchmark harness validates both
filter and materialization paths against SQLite up to 10 million rows (403 MB,
34x L3 cache), and a cross-engine runner adds DuckDB 1.5.5 on the same data
with identical SQL on every engine. Against SQLite the AVX2 path is 23.4x
faster on filters and 21.7x on materialized projections (geometric means);
against single-threaded DuckDB it is 1.43x on filters and 4.02x on
materialization, losing only where DuckDB's per-block zone maps answer a wide
range predicate or a full scan without evaluating anything per row. On a second
dataset with no exploitable structure the same figures are 28.3x and 1.71x, and
DuckDB's file grows from 44.3 MB to 360.5 MB. Eight DuckDB threads win the
filter comparison outright and change nothing on materialization. Per-scenario results, checksum checks and measurement
conditions are recorded in [benchmarks/README.md](benchmarks/README.md);
performance depends on the query, execution mode and hardware.

Vectors, SQL transactions, and an ARM64 backend remain unimplemented. So do
`DROP TABLE`, `UPDATE` and `DELETE`: the MVP subset was deliberately narrowed
to the three statements above, and the rest is listed under Phase 3 as still outstanding.

## How the phases are ordered

Three constraints decide the sequence, and they are worth stating because the
order is not the obvious one:

* **Format before everything.** Adding execution kernels later is easy;
  changing an on-disk format or a crash model after users have data in it is
  not. Storage comes first.
* **A scalar path before a SIMD path.** A vectorised kernel needs a reference
  implementation to be validated against and a benchmark to justify it. That
  reference is the ordinary query executor, so the query layer precedes the
  SIMD work rather than following it.
* **Something to interpret before something to type into.** An interactive
  console with no query language is a prompt that can only run dot-commands,
  so the SQL front end comes first.

---

## Phase 1 - Portable storage foundation

**Implemented and verified in hosted CI.**

* [x] stable database header - immutable, checksummed, feature-flagged
* [x] architecture-neutral binary format - little-endian, fixed sizes,
      64-bit fields 8-byte aligned
* [x] 4 KiB logical page model
* [x] memory-mapped storage
* [x] Linux x86-64 - raw syscalls, no libc
* [x] Windows x86-64 - kernel32 only

Delivered beyond the original list, because the format needed them to be
worth committing to:

* [x] two superblock copies with generations and CRC-32C
* [x] commit protocol with an ordered flush between data and metadata
* [x] strict validation on open, with a distinct error per failure
* [x] page allocator with a self-chaining free list
* [x] non-destructive `create`, `--force` to override
* [x] read-only open, so an unwritable database can still be inspected
* [x] OS failures classified into no-such-file / permission / exists / other
* [x] test suite over healthy and damaged databases
* [x] verified green hosted CI on Linux and Windows
* [x] Apache-2.0 licence

---

## Phase 2 - Storage engine

*Was phase 4 in the original plan, moved ahead of the execution work.*

Everything above this phase needs somewhere to put rows and something to
describe them.

Storage safety gates and remaining extensions:

* [x] preserve and range-check `root_page` across open and commit
* [x] regression coverage for root preservation and malformed roots
* [x] confirm hosted Linux and Windows builds and tests are green
* [x] choose COW/shadow paging as the Phase 2 design direction
* [x] append-only COW allocation, page copy/write and staged root API
* [x] protect both superblock high-water marks and refuse legacy free in COW mode
* [x] failed-sync handle invalidation and generation-overflow guards
* [x] core harness: forced pre-commit writeback, sync errors and torn publication
* [x] persist a COW format capability that rejects legacy writers
* [x] generation-protected two-bit allocation map with payload/metadata states
* [ ] object-level ownership and multi-page allocation maps
* [x] fixed-height catalog root-path copying and complete graph validation
* [ ] directory splits and larger catalog trees
* [x] defer reclamation until neither recoverable superblock references a page
* [x] allocation-map corruption, fallback and rejected-generation regression tests
* [x] extend fault-injection coverage to catalog graphs

See [the COW decision](docs/COW.md). The existing allocator remains unsafe for
transactional payload writes until these gates pass.

* [x] legacy free-page management
* [x] single-page PAX format (whole 64-row groups, schema-dependent capacity)
* [x] fixed-width column types: INT32, INT64, FLOAT32, BOOL
* [x] reserve stable TEXT/BLOB catalog IDs and SQL type tokens
* [x] decode escaped TEXT and validated `X'...'` BLOB literals into arena byte slices
* [ ] COW-safe variable-width TEXT/BLOB extents and PAX descriptors
* [x] per-column NULL bitmaps
* [x] batch insertion into one PAX page through the internal API
* [x] scalar row materialization with NULL and bit-pattern preservation
* [x] multi-page table directory and cross-page batch insertion (251 leaves)
* [x] row lookup across pages and multi-page graph recovery tests
* [x] commit flush limited to the pages a transaction can have touched
* [x] paired multi-page allocation map (`create-large`, 63 GiB ceiling)
* [x] reclamation of pages no recoverable generation still references
* [x] validate only the generation being opened; `cyboudb check` reads everything
* [x] reserve a superblock extension root for encryption and vector metadata
* [x] scalar scan cursor (validate once, traverse leaves)
* [x] initial catalog: table names and column declarations stored in typed pages
      (251 tables, 64 columns per table; internal API, no SQL yet)
* [x] whole-page checksums for allocation maps and catalog pages
* [x] checksummed PAX pages and per-table data roots
* [x] PAX fault-injection, corruption and batch atomicity tests

See [the PAX contract](docs/PAX.md), [multi-page limits](docs/PAX_MULTI.md)
and [the span map](docs/SPAN_MAP.md).

---

## Phase 3 - SQL front end

The point of the project's name, and the layer that turns a page allocator
into a database. It ends with statements executing against real pages, one
shot per invocation:

```sh
cyboudb query demo.cyboudb "SELECT id, score FROM runs WHERE score > 90"
```

* [x] tokenizer, with source positions kept for error messages
* [x] expression parser with correct operator precedence
* [x] statement parser: `CREATE TABLE`, `INSERT`, `SELECT ... FROM ... WHERE`
* [ ] statement parser: `DROP TABLE`
* [x] a type system, and a decision on NULL semantics written down before it
      is implemented
* [x] binder: resolve names against the catalog, report unknown ones by
      position
* [x] scalar expression evaluator
* [x] scalar executor: sequential scan, filter, projection
* [x] required-column pruning, so an unprojected column is never read
* [x] predicate kernels resolved once at bind time and called through a
      pointer, rather than dispatched on type per row
* [x] result rows delivered as data, not printed by the executor
* [x] batch delivery of up to 64 rows per call, with the row-at-a-time
      callback kept as an adapter over it
* [x] `cyboudb query` for one-shot execution
* [x] errors that point at the offending token rather than at the statement
* [x] bounded expression nesting, so input cannot decide how much stack the
      recursive parser, binder and evaluator use
* [x] oversized statements refused rather than silently truncated

The subset is deliberately small. Joins, aggregation, ordering, indexes and
subqueries are not in this phase; they need a planner, and a planner needs a
working executor to plan for. `DROP TABLE`, `UPDATE` and `DELETE` were dropped
from the MVP for the same reason the rest were: they are not needed to answer
whether the execution architecture is sound.

---

## Phase 3.5 - Scale and performance validation

Inserted after the SQL MVP rather than planned from the start. The executor
is now the shape it should be, which makes the honest next question not "what
else can it parse" but "is any of this actually faster". Two things block an
answer.

A table is capped at 251 PAX data pages. In practice that is roughly 1000 rows
for 64 `INT64` columns, 16 000 for eight mixed columns, and 880 000 for a
single `BOOL` column - small enough that a whole database fits in cache, which
would make any comparison against a row store meaningless.

* [x] leaf capacity first, before the directory - see
      [docs/PAX_CAPACITY.md](docs/PAX_CAPACITY.md). A leaf is now a run of
      contiguous pages whose length comes from the schema, so a 32-column
      table holds 448 rows per leaf instead of 24 and a table of it reaches
      112 448 rows instead of 6 024. Measured: 92 -> 14 ns per row scanned,
      and full 64-row batches for every schema
* [x] two-level PAX directory: a root directory of directory pages, each
      holding PAX leaf runs, lifting the cap from 251 leaves to 251 x 251 -
      28 million rows for a 32-column table. A table small enough not to need
      it stays flat, and promotion keeps the old directory as the first child
* [x] COW publication across the deeper tree, leaf to root to catalog
* [x] a format version or feature bit for the tree, so existing single-level
      databases keep opening
* [x] benchmark harness: open once, bind once, warm up, then time N
      executions with the result consumed in-process
* [x] report TSC ticks per row, ns per row, rows per second and GB per second -
      never wall-clock around the CLI, which measures process start and
      formatting instead of the engine
* [x] scenarios: `INT32` equality and range, `INT64` range, `FLOAT32` range,
      two predicates under `AND` and under `OR`, a nullable predicate, and
      projections of 1, 2 and 32 of 32 columns
* [x] the same workloads against SQLite on identical data, at a size large
      enough that neither engine fits in cache (tested at 1M, 5M, and 10M rows,
      up to 403 MB CybouDB vs 308 MB SQLite, with bit-for-bit checksum parity
      and 15x-18x geometric mean speedup)
* [x] dual-mode measurement: filter mode (popcount) and materialization mode
      (dereferencing projected cells into registers and computing tagged FNV-1a checksum)
* [x] generation-bound scan open (`db_pax_scan_open_bound`) eliminating catalog
      revalidation on bound queries, hardened with connection context, base pointer,
      generation, root, and dirty write validation
* [x] fast in-process bulk seeder (50 000-row chunks with incremental COW commit,
      > 250 000 rows/s)
* [x] fair comparison against SQLite with 2 GB memory-mapping (`PRAGMA mmap_size = 2147483648`)
      and canonical tagged 64-bit FNV-1a checksum verification (`TAG_NULL = 0xBF`, `TAG_VALUE = 0x5A`)
* [x] minimal `SELECT COUNT(*) FROM table [WHERE expr]` aggregation support, bypassing
      column data pages on unpredicated full scans and validating bit-for-bit checksum
      parity against SQLite in both filter and materialization benchmark modes

Zone metadata is now written and published with the data that it describes -
per leaf, per column, min/max plus NULL, NaN and BOOL flags, in a side
structure hanging off a reserved schema field behind `CybouDB_FEATURE_ZONE_MAPS`
(see [docs/ZONEMAP.md](docs/ZONEMAP.md)). The structure is validated and SQL
now uses it once per leaf; the remaining gate is a fresh repeated benchmark:

* [x] per-leaf, per-column statistics computed from the insert's own batch and
      published by the same COW transaction, with a two-level directory that
      reaches every table PAX can address
* [x] validation of the statistics graph on open: allocation, headers, CRCs,
      exact PAX leaf coverage and per-type statistics semantics; `cyboudb check`
      additionally recomputes all statistics from actual PAX data
* [x] SQL zone evaluator for `=`, `<`, `<=`, `>`, `>=`, `AND`, `OR` and NULL
      predicates; NONE skips the leaf, ALL reads projections only and
      COUNT/ALL adds leaf rows without requesting a batch
* [x] ON/OFF result parity with scalar/automatic kernels, independent SQL 3VL
      oracle, FLOAT32 edge cases, COW recovery and per-leaf instrumentation
* [x] versioned benchmark fixtures, repeat/rotation medians and comparable
      structured, shuffled-structured and randomized zone-map measurements
      (see [benchmarks/results/2026-09-09-zonemaps-3way-10m.md](benchmarks/results/2026-09-09-zonemaps-3way-10m.md))

The DuckDB comparison identifies where the engine is actually behind, and it is
storage metadata rather than execution. Measuring a second, high-entropy
dataset separated the two candidate explanations:

* [x] per-block min/max zone maps, so range predicates and full scans can skip
      or accept whole leaf runs without touching column data. Completed and
      proven with 35x speedup on structured range queries (0.03 ns/row, 8.3x
      faster than DuckDB 1T) and negligible 1-4% overhead on unprunable data;
      see [benchmarks/results/2026-09-09-zonemaps-3way-10m.md](benchmarks/results/2026-09-09-zonemaps-3way-10m.md)
* [x] optional Compression V1: RAW/CONST/FOR in fixed-width PAX slots,
      MAP_SPAN creation, private scratch buffers, portable codec and database
      regression tests. See [docs/COMPRESSION.md](docs/COMPRESSION.md).
* [ ] physical storage compression: V1 does not shrink file size or PAX runs.
      Further codecs are deferred until the RAW versus encoded performance
      gate justifies them; prioritize avoiding scalar decode overhead.

Historical runs reported two layout problems, both in
[benchmarks/README.md](benchmarks/README.md). The first - a 32-column table
scanning at ~92 ns/row because a wide leaf held only 24 rows - is fixed by the
leaf runs above. The second reported 0.65 versus 13.5 ns/row when another table
shared the file. That measurement predates prepared-plan catalog validation
changes and does not establish allocation policy as the cause. Current repeats
are recorded alongside the historical figures in the benchmark documentation.

The runner now compares SQLite, forced-scalar CybouDB and automatically dispatched
CybouDB on identical data, with materialized checksums and independent timing runs.

---

## Phase 4 - Interactive console

A REPL is not just a loop around the parser. The platform layer now reads
standard input for terminal and pipe use. On Windows a console and a redirected
pipe are different sources with different input APIs; optional editing remains
open.

The embedded C API and console are both implemented. The console supports
multiline input beyond the CLI argument limit, rejects oversized input before
execution and returns a failure status for failed piped SQL scripts.

* [x] platform layer: read a line from standard input (`os_read_stdin`)
* [x] detect whether standard input is a terminal (`os_stdin_isatty`)
* [x] Windows: `ReadConsoleW` for a console, byte reads for a redirected pipe (`os_read_console`, `os_read_stdin`)
* [x] statements continued across lines until `;` (256 KiB accumulator, multiple statements per line, EOF fallback)
* [x] meta-commands, kept syntactically distinct from SQL: `.tables`, `.schema [TABLE]`, `.info`, `.help`, `.quit` / `.exit`
* [x] result formatting: aligned columns, an explicit rendering for NULL, a row count
* [x] non-interactive mode: statements from a pipe or a file, no prompt, so scripts and tests can drive it (`tests/repl_tests.py`)
* [ ] line editing: history and cursor movement, once the plain reader works

The plain line reader comes first and stays useful on its own; editing is a
convenience layered on top, and raw terminal mode is where portability gets
unpleasant.

---

## Phase 5 - Library API

Without this CybouDB is a CLI rather than an embedded database. It comes after
the query layer on purpose: designing the ABI before there is a query path
would mean designing it twice.

* [x] C ABI over pages and over statements (`include/cyboudb.h`, `cyboudb_db`, `cyboudb_stmt`)
* [x] `cyboudb_open`, `cyboudb_close`, `cyboudb_prepare`, `cyboudb_step`, `cyboudb_step_batch`, `cyboudb_reset`, `cyboudb_finalize`, `cyboudb_exec`
* [x] zero-copy scalar row and vectorized batch iteration with raw mapped pointers (`cyboudb_batch_view`, `cyboudb_colview`)
* [x] error codes and error messages carried out of the library, not printed (`cyboudb_errcode`, `cyboudb_errmsg`)
* [x] formal prepared statement lifetime contract: statements remain valid across database mutations and generation changes via slow-path fallback
* [x] static library targets (`build/libcyboudb.a` on Linux, `build\cyboudb.lib` on Windows)
* [x] automated C test suite (`tests/c_api_test.c`) verifying lifecycle, accessors, typed NULLs, `COUNT(*)`, batch stepping, and stale-generation resilience

---

## Phase 6 - x86-64 execution engine

Each kernel is validated against the scalar executor from phase 3 and
justified by a benchmark.

The boundary this phase needs already exists. The binder resolves a predicate
to a kernel pointer once and stores it in the bound expression; the executor
only calls it. Adding a dispatch that hands out `avx2_i32_gt` instead of
`scalar_i32_gt` therefore touches neither the parser, the binder's name
resolution, nor the executor, and `src/sql/kernels_scalar.asm` stays as the
reference the vector kernels are checked against.

* [x] runtime CPU detection (`cpu_has_avx2` via CPUID leaves 1, 7 and XGETBV XCR0 state)
* [x] AVX2 scan kernels (`src/sql/kernels_avx2.asm`: INT32, INT64, FLOAT32, BOOL; 256-bit YMM, signaling NaN-safe integer key classification)
* [x] BMI2 primitives (`src/sql/bmi2.asm`: `pext`, `pdep`, `bzhi`, fast NULL mask compaction; `tzcnt` row dispatch, dynamic CPUID detection and bit-for-bit scalar fallbacks)
* [ ] FMA3 vector operations
* [x] hardware CRC-32C, validated against the scalar reference (`src/core/checksum.asm`: SSE4.2 `crc32` qword unrolled loop with dynamic CPUID detection and bit-for-bit scalar validation)
* [ ] AVX-512 experimental kernels
* [x] reproducible benchmarks (in-process comparative harness across SQLite,
      DuckDB 1.5.5 at 1 and 8 threads, CybouDB Scalar and CybouDB AVX2, identical SQL
      on every engine and checksums compared bit for bit, over two deterministic
      datasets; at 10M rows the AVX2 path is 23.4x over SQLite and 1.43x over
      single-threaded DuckDB on structured filter aggregates, 28.3x / 1.71x on
      high-entropy ones, and 21.7x-23.5x / 4.02x-4.17x on materialized
      projections - see
      [benchmarks/results/2026-09-09-4way-10m.md](benchmarks/results/2026-09-09-4way-10m.md)
      and [the high-entropy run](benchmarks/results/2026-09-09-high-entropy-10m.md))

---

## Phase 7 - ARM64 execution engine

Two independent pieces of work: a platform layer for the operating system, and
an execution backend for the instruction set. A different assembler is
required - NASM targets x86 only.

* [ ] choose the AArch64 toolchain
* [ ] AArch64 platform layer
* [ ] AArch64 implementation of the core contract
* [ ] NEON scan kernels
* [ ] NEON vector operations
* [ ] Linux ARM64 support
* [ ] Apple Silicon support
* [ ] SVE/SVE2 experimental kernels
* [ ] cross-architecture test: the same database file read on both ISAs

---

## Phase 8 - Vector engine

Vectors are planned to live in their own contiguous arena rather than inside
PAX pages; the reasoning is in [ARCHITECTURE.md](ARCHITECTURE.md).

The scalar FLOAT32 dot-product and squared-L2 oracle is implemented and tested;
its ABI and rounding contract are documented in [docs/VECTOR.md](docs/VECTOR.md).

Persistent vector storage is intentionally gated on the relational mutation
contract. The SQL AST now uses a stable `type + payload` header, freeing JOIN,
UPDATE and DELETE to define statement-specific payloads without growing one
universal structure. Fixed-width SQL aliases are accepted; `VECTOR` is a
reserved type name but remains rejected by `CREATE TABLE` until persistence is
defined. Single-table SELECT now carries table namespaces through qualified
projections and WHERE expressions; an explicit alias hides the base table name.
The parser also emits a dedicated `AST_JOIN` descriptor for plain/INNER/LEFT
JOIN with `ON`. The bound plan now records both catalog inputs after validating
the equi-join shape; execution remains deliberately blocked until its
two-input row-production contract lands, preventing partial left-only results.
JOIN binding now normalizes equality order, validates both namespaces and key
types, and records the two physical key indices in the bound plan.
Qualified JOIN projections are also mapped to either input schema using a
source bit in the physical projection descriptor. Wildcard expansion remains
gated until the joined output-schema contract is finalized.
The runtime plan now preserves those source descriptors separately and exposes
compact projection ordinals to result sinks, defining the joined-batch ABI
needed by the nested-loop producer.
A correctness-first nested-loop producer now executes INNER and LEFT equi-joins
for qualified INT32/INT64 keys over raw or compressed PAX inputs. It materializes
compact 64-row output batches, preserves duplicate matches and projected NULLs,
and skips NULL join keys; LEFT JOIN synthesizes NULL right-side values for
unmatched rows. JOIN predicates beyond ON remain gated.
The callback executor also applies `LIMIT count [OFFSET count]` after filtering
or join production through one selection-mask adapter, including early producer
termination at the requested row count. Pull-style C stepping remains gated for
JOIN, while the shared one-input cursor records LIMIT/OFFSET progress for both
row and batch C stepping, including reset.
The SELECT AST and plan have a dedicated single-key ORDER BY descriptor with
ASC/DESC, qualified-name, result-ordinal, and scalar-type metadata. Single-table
callback execution now uses arena-bounded row materialization plus stable typed
insertion sort, with deterministic NULL placement and LIMIT/OFFSET applied after
sorting. JOIN ordering and pull-style C stepping remain explicitly gated.

* [x] runtime-native normalized `FLOAT32` vectors
* [x] caller-owned contiguous vector arena
* [ ] persistent vector extents
* [ ] SQL surface for vector columns and distance expressions
* [x] scalar and AVX2 dot products with runtime dispatch
* [x] normalized cosine similarity
* [x] deterministic filtered streaming top-k
* [x] runtime exact vector search over contiguous candidates
* [ ] reproducible benchmarks

---

## Phase 9 - Transactions

* [x] atomic metadata commit - superblock generations, single writer
* [ ] transaction ids
* [ ] `BEGIN` / `COMMIT` / `ROLLBACK` in the SQL front end
* [ ] evaluate WAL only if later requirements justify it
* [ ] SQL transaction recovery built on Phase 2 COW
* [ ] file locking
* [ ] concurrent readers
* [ ] concurrent writers

The commit protocol that exists today publishes metadata atomically and
survives a torn superblock write. It is **not** a transaction system: there is
no log, no isolation and no coordination between processes.

---

## Phase 10 - Encryption

* [ ] authenticated page encryption
* [ ] ML-KEM integration
* [ ] optimized x86-64 crypto kernels
* [ ] optimized ARM64 crypto kernels
* [ ] test vectors
* [ ] external review

Nothing here should start before the format and the crash model are settled,
and no encryption claim should be made without external review.

---

## Known gaps outside the phases

Small, real, and worth fixing when they are next touched:

* [ ] the Windows command-line parser does not implement the backslash-escape
      rules of `CommandLineToArgvW`
* [ ] `os_write` on Windows does not loop on a partial write, unlike the Linux
      path
* [ ] the double-free guard is a heuristic and will need a real allocation
      bitmap once pages carry data
* [ ] no `NOTICE` file and no per-file licence headers
