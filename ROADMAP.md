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

`cyboudb query` runs `CREATE TABLE`, `INSERT`, correctness-first `UPDATE`,
`DELETE FROM ... [WHERE]`, and `SELECT ... WHERE` against real
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

SQL transactions are implemented via Phase 2 COW staging (`BEGIN`,
`COMMIT`, `ROLLBACK`). `DELETE FROM table` removes every row of one table by
publishing a schema page whose data root, statistics root and row count are
back where `CREATE TABLE` left them. `DELETE ... WHERE` counts the matching
rows first and then picks between marking them dead in place and rewriting the
survivors into a fresh graph, which is the difference between a statement that
costs the rows it removes and one that costs the table; a file created without
the `TOMBSTONES` bit always rewrites. A surviving TEXT, BLOB or VECTOR cell
keeps the extent chain it already points at rather than having its payload
copied out and back, the same way an UPDATE carries an untouched cell through
the leaf it rewrites. `UPDATE` supports single-column assignments with a
mandatory predicate across flat and tree-directory PAX tables, including
fixed-width and persisted variable-width TEXT/BLOB columns. `DROP TABLE` drops
tables and stages new catalog roots atomically across both CLI and REPL. An
ARM64 backend remains unimplemented.

Secondary indexes are copy-on-write B+trees over `INT32` and `INT64` columns,
unique or not, kept current by every statement that changes a table and
validated as part of the same commit. A plan reads through one for any single
comparison against an indexed column - `=`, `<`, `<=`, `>`, `>=` - and leaves
a range too wide to be worth the walk to the scan. An `UPDATE` or a marking
`DELETE` patches the entries of the rows it touched instead of rebuilding the
tree, so both cost the rows they change rather than the size of the table.
See [docs/INDEX.md](docs/INDEX.md).

---

## Core v1 is frozen

The storage format, the transaction semantics, the page and copy-on-write
rules, and the error and recovery behaviour are settled and written down:

* [docs/FORMAT.md](docs/FORMAT.md) - the on-disk format, version 1
* [docs/TRANSACTIONS.md](docs/TRANSACTIONS.md) - commit protocol and failure outcomes
* [docs/RECOVERY.md](docs/RECOVERY.md) - generation selection and what survives a crash

What this commits to: work built after this point uses the existing
transaction and storage layer rather than reopening it. A new capability
arrives as a new incompatible feature bit, not as a change to what the bits
already there mean.

Within the 0.5.x series a file written by any 0.5.x build opens in any later
0.5.x build, and the format version stays 1. A newer file may be refused by an
older build, which is the feature-bit mechanism working as designed. Nothing is
promised yet across 0.5 to 0.6 or up to 1.0; format stability across major
versions is a 1.0 commitment.

---

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
* [x] specify versioned TEXT/BLOB cell descriptors, extent pages, ownership, and validation rules
* [x] implement bounded per-chain map/owner/generation/layout/CRC validation
* [x] implement preflighted COW extent-chain allocation, canonical filling, and sealing
* [x] feature-gate catalog varlen types and use 16-byte descriptors in PAX layout arithmetic
* [x] validate every live descriptor chain during the PAX graph walk
* [x] define and populate pointer+length runtime INSERT batches without changing fixed-width slots
* [x] implement two-pass whole-batch validation, extent preflight, and pointer-to-root materialization
* [x] invoke materialization with exact flat/tree PAX structural reserve
* [x] persist `{extent_root,length}` through aligned multi-leaf sub-batch cursors
* [x] define conservative varlen zone-map semantics (NULL/non-NULL only) and
      an internal validate-before-copy extent reader
* [x] expose a caller-owned row copy accessor without leaking extent page ids
* [x] define a selected-cell copy API for non-contiguous varlen batches
* [x] enable the capability for new `create-large` databases with end-to-end
      SQL/CLI coverage; other creators retain their previous feature sets
* [x] cover persisted TEXT/BLOB through both row and batch C accessors
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
cyboudb query demo.cdb "SELECT id, score FROM runs WHERE score > 90"
```

* [x] tokenizer, with source positions kept for error messages
* [x] expression parser with correct operator precedence
* [x] statement parser: `CREATE TABLE`, `INSERT`, `SELECT ... FROM ... WHERE`
* [x] statement parser and catalog executor: `DROP TABLE`
* [x] statement parser, binder and COW executor: whole-table `DELETE FROM`,
      published as the state `CREATE TABLE` leaves a table in, with the
      affected row count reported and an empty table publishing nothing
* [x] `DELETE ... WHERE`: the predicate is bound exactly as the equivalent
      `SELECT` binds it, matching rows are counted before anything is staged,
      and the survivors are rewritten through the append path so that leaf
      runs, directories and zone maps are rebuilt by the code that already
      writes them
* [x] persisted TEXT, BLOB and VECTOR cells carried across that rewrite by
      their extent root, under a batch flag that tells the append the varlen
      slots already hold roots rather than pointers to bytes
* [x] a benchmark for the rewrite, at 100 000 and 1 000 000 rows and across
      selectivities - see
      [benchmarks/results/2026-09-12-delete.md](benchmarks/results/2026-09-12-delete.md).
      Truncation is under 2 ms whatever the table holds; the rewrite costs
      about 180 ns per surviving row, flat, and stages up to 4.8x the table's
      own pages. The commit that follows tracks what was staged - 470 ms for
      the 172 MiB of a 1% delete at a million rows, 8.6 ms when nothing was
      staged - and an empty commit costs 0.3-1.0 ms on a 16 MiB file and on a
      225 MiB one alike, so `sync_pages` does what its contract says
* [x] identify the per-append cost that makes it quadratic. It is
      `db_catalog_get`, which `db_pax_insert` calls to resolve the schema and
      `catalog_publish_data` calls again to publish it. It revalidates the
      whole typed graph against a synthetic superblock standing at the staged
      generation, so `db_bitmap_deep` deep-verifies exactly the pages this
      transaction has staged, and every append re-checksums what the previous
      appends staged. Measured with `benchmarks/append_probe.c`: cost tracks
      staged pages (45 us at 123 pages, 338 us at 1,281), a control call
      beside it stays flat, committing periodically holds it at 16-26 us, and
      forcing the scalar CRC-32C multiplies it by eighty
* [x] a validated append that does not revalidate, the write side's answer to
      `db_pax_scan_open_bound`: `current_valid` remembers that this writer
      proved the graph and skips the walk for the rest of the transaction, and
      `db_pax_check_new` checks the header of the root it was handed instead
      of walking the table. `db_commit` already validated the typed graph
      before publishing, so the boundary that decides durability is unchanged;
      `tests/commit_guard_test.c` pins it against a staged catalog root, a
      staged leaf, and a row count resealed to keep its checksum valid.
      Appends in one transaction went from 1,091 us at 1,281 staged pages to a
      flat 16 us, 90 000 rows in one transaction from 1,004 ms to 153 ms, and
      `DELETE` of 1% of a million rows from 124,452 ms to 177 ms with the cost
      per surviving row constant across selectivities
Incremental deletion, so that removing a row costs a bit rather than a copy of
everything it is not. The design is in [docs/TOMBSTONES.md](docs/TOMBSTONES.md):
the bitmap lives in the PAX leaf itself, in the last bytes of its body, so a
scan that has the leaf has the bitmap and there is no second graph to publish
or validate.

* [x] `CybouDB_FEATURE_TOMBSTONES` and the leaf arithmetic it changes. Capacity
      and the bitmap that sizes it are each other's input, so the two are
      solved together to a fixed point; `create-tombstones` emits the bit, and
      a database without it is byte-identical to what earlier builds wrote.
      A single BOOL column goes from 3 520 rows a leaf to 3 200; the
      seven-column benchmark schema stays at 448, the group arithmetic's slack
      having already covered the 56 bytes. Pinned by
      `tests/tombstone_layout_test.c` and `tests/tombstone_tests.py`
* [x] `PAX_DEAD` and the bitmap itself. `db_pax_mark_dead` is
      `db_pax_update_one` with a different thing done to the selected rows -
      the same leaf location, preflight, copy, relink and publication, with
      the mode carried in the span group. It publishes as an exact-row
      replacement and keeps the zone maps, which after a mark describe a
      superset of the live rows and are allowed to. Validation recomputes the
      count from the bitmap, requires the two to agree, and refuses a bit set
      past the rows the leaf holds; the zero-tail rule now stops where the
      bitmap starts
* [x] the scan mask. The cursor reports which lanes of the batch it just
      produced are dead - one extraction from the bitmap per batch, not per
      column - and the selection is intersected with it in the one place the
      predicate kernels, LIMIT, the projection and `COUNT(*)` all read from,
      so a dead row is invisible to every one of them. `COUNT(*)` gives up
      the shortcut that counts a zone-accepted leaf without reading it, since
      that would count the dead too. A file without the feature never reaches
      the intersection
* [x] the executor's choice between marking and rewriting. It counts what the
      statement matched, asks the table how much of it is already dead, and
      takes truncation when nothing would survive, marking when at most half
      the table would be dead afterwards, and the rewrite otherwise. Half is
      where the two costs cross: marking is proportional to what is removed
      and the rewrite to what survives
* [x] compaction, which is that rewrite. It leaves behind every dead row, this
      statement's and every earlier one's, so a table reclaims its pages by
      being written to rather than by being asked. The scan reports a leaf's
      tombstones rather than applying them, so the rewrite masks them out
      itself - without that, compaction resurrected everything an earlier
      DELETE had marked
* [ ] an explicit `VACUUM`. Nothing compacts a table that is never written to
      again, and a leaf whose rows are all dead is reclaimed by the rewrite
      around it rather than dropped and unlinked
* [x] statement parser contract: single-column `UPDATE ... SET literal WHERE ...`
* [x] binder contract for typed single-column `UPDATE`
* [x] COW executor for flat multi-leaf, fixed-width `UPDATE`
* [x] coalesce all 64-row predicate spans per leaf into one COW rewrite
* [x] UPDATE recovery tests for ENOSPC, both commit barriers and torn publication
* [x] COW-copy and exactly recompute the affected zone-map column/leaf on UPDATE
* [x] tree-directory and TEXT/BLOB `UPDATE`
* [x] process-level single-writer lock with concurrent read-only opens
* [x] lifetime reader pins and a reclamation barrier for retired pages
* [x] concurrent snapshot/reclamation stress test across repeated generations
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
* [x] runtime-dispatched AVX2 squared-L2 kernel with scalar parity
* [x] atomic in-place AVX2 FLOAT32 normalization with scalar parity
* [x] allocation-free streaming Top-K squared L2 with candidate pruning
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

Vectors are stored persistently via multi-page extent chains linked by 16-byte
descriptors (`CAT_VECTOR`) in PAX leaves, preserving canonical raw IEEE-754
`FLOAT32` vector components with exact length validation (`dimensions * 4` bytes).
For search and computation, vectors are mapped into contiguous caller-owned or
query-owned arenas for high-throughput SIMD kernels (AVX2/scalar dot product,
squared L2, and cosine).

Cosine semantics maintain raw canonical floats on disk to prevent precision drift
or loss of component magnitudes; queries or indexing normalize vectors on the fly
or cache normalized representations in memory.

The scalar and AVX2 FLOAT32 dot-product and squared-L2 kernels are implemented,
tested, and benchmarked; ABI and rounding contracts are documented in
[docs/VECTOR.md](docs/VECTOR.md).

Persistent vector storage, SQL column types (`VECTOR(FLOAT32, n)`), and
distance expression query execution (`ORDER BY <distance_expr> LIMIT k` with
`L2_DISTANCE`, `COSINE_DISTANCE`, `<->`, `<=>`) are fully implemented and
validated for `CREATE TABLE`, `INSERT`, `SELECT`, `WHERE ... IS [NOT] NULL`,
and public C APIs (`cyboudb_column_vector_dimensions`, `cyboudb_column_vector_f32`,
`cyboudb_batch_vector_f32`), with deterministic streaming top-K execution
and O(K) memory overhead.

* [x] runtime-native raw and normalized `FLOAT32` vectors
* [x] caller-owned contiguous vector arena with raw and normalized appends
* [x] persistent vector extents
* [x] SQL surface for vector columns (`VECTOR(FLOAT32, n)`) and distance query execution (`ORDER BY ... LIMIT k`)
* [x] scalar and AVX2 dot products and squared L2 distances with runtime dispatch
* [x] normalized cosine similarity and raw/normalized L2 Top-K
* [x] deterministic filtered streaming Top-K with batch feed API
* [x] runtime exact vector search over contiguous candidates
* [x] reproducible exact-search benchmarks with fixed input generation, raw L2 and cosine scenarios, and result checksums

---

## Phase 9 - Transactions

* [x] atomic metadata commit - superblock generations, single writer
* [x] transaction ids (monotonic per-connection 64-bit transaction id)
* [x] `BEGIN` / `COMMIT` / `ROLLBACK` in the SQL front end (parser, binder, executor, REPL, CLI, and C API)
* [x] evaluate WAL only if later requirements justify it (Phase 2 append-only COW staging provides instant rollback and crash resilience without write-ahead logging overhead)
* [x] SQL transaction recovery built on Phase 2 COW (`db_rollback` restores live superblock state, resets staged allocation maps, auto-rollback on close/disconnect)
* [x] file locking (cross-platform single-writer process-level file locking)
* [x] concurrent readers (shared read-only mappings with lifetime pinning and generation-safe barriers)
* [ ] concurrent writers (single-writer model by design; multiple concurrent writers require multi-version concurrency or distributed locks)

Transactions provide full ACID semantics built on top of the Phase 2
append-only Copy-On-Write storage engine. Staging pages in memory and
allocating beyond the COW floor allows uncommitted mutations to be discarded
instantly on `ROLLBACK` or process termination without disk write amplification,
while `COMMIT` atomically advances the active superblock generation. Single-statement
queries retain backward-compatible autocommit behavior.

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

## Secondary indexes

Implemented, and what is missing is named below rather than implied. The format
decisions are in [docs/INDEX.md](docs/INDEX.md).

The index page layout changed after it was first written - an entry went from
16 bytes to 24 so that it could carry the `(key, row)` pair the order is on -
and that is a change the compatibility promise would not have allowed against a
released series. It is allowed here because there is no release: GitHub
Releases is empty, no file carrying the `INDEX` bit exists outside this
repository, and the bit is what a build that cannot read one refuses on. After
a release the same change would need a new feature bit.

Done: the B+tree - bulk build, descent, one-row insert with splits, one-entry
delete, all under copy-on-write; the index as a third page type in the catalog
directory, validated at every commit and every open, so a tree that did not
survive publication is a file that refuses to open; `CREATE [UNIQUE] INDEX name
ON table (column)` and `DROP INDEX name` over INT32 and INT64 columns, with
uniqueness enforced while the tree is built.

Maintenance is done too: an INSERT reaches every index of the table, a unique
index refuses a row that would break it, a marking DELETE takes the entries of
the rows it marks out of every index, an UPDATE takes the entries of the rows
it writes out and puts them back under the new key, a compacting DELETE
rebuilds every index because every surviving row moved, and DROP TABLE takes
its indexes with it. Every one of those reaches the trees through
`sql_execute_batch`, so the CLI, the REPL and the C ABI get the same behaviour
rather than three copies of it.

What the rest of this section records is measured rather than guessed at -
`benchmarks/index_bench.py` and `tests/index_probe.c` have the numbers - and
says where each thing stands:

* **A commit stops at the generation boundary.** Every node records how many
  entries live at or below it, so validation takes a subtree's size rather than
  walking it whenever that subtree is older than the candidate generation -
  which, under copy-on-write, is every subtree a transaction did not touch.
  `cyboudb check` still walks everything and recomputes the sizes.
* **An indexed INSERT costs tens of microseconds; an indexed database costs
  milliseconds to flush.** Two causes were found by measurement and removed. A
  parent used to call into every child to find out the child was old, which
  costs the page fault the walk exists to avoid; it now asks the allocation map
  whether this transaction wrote the page. And sealing a node used to recompute
  its subtree size from its children - up to 167 random pages on a node that
  was otherwise four page copies - where every writer now adjusts the size
  where it makes the change. That took 33 ms to 2.1 ms at 5000 rows and 47 ms
  to 14.1 ms at 50000, with 44 and 151 nodes visited becoming 4 and 5.

  What was left - about 12 ms at 50000 rows that five page touches could not
  explain - has now been attributed, and none of it is the index. Two things
  were wrong with the question.

  `tests/index_probe.c` called `db_commit` after `cyboudb_exec`, which already
  commits, so every number it had ever printed was the cost of two commits.
  And stubbing `vfs_sync` out collapses what remains: 10.4 ms becomes 0.06 ms
  indexed, and the same table without an index goes 1.3 ms to 0.04 ms. The
  whole difference is the flush. Index maintenance is about twenty microseconds
  a row, which is the four page copies it looked like all along.

  The flush is slower on the indexed file because more of that file has been
  written: 146439 allocated pages against 4306 for the same table without an
  index. Per-INSERT cost tracks that number and not the file's size - the same
  database in a file three times larger flushes in the same time. So the lever
  is the next entry, which is what put 570 MB through the allocator in the
  first place, and not anything on the insert path.
* **An UPDATE and a marking DELETE patch the indexes they change.**
  The rows do not move, so their entries stay right except for the one column
  the statement writes. The entries of the rows it touched come out before the
  write - while the table can still say what keys they carried - and go back
  after it under the one key every touched row now has. A span is a 64-row
  group and a mask of lanes, which is the shape the predicate already
  produced, so the cost is the groups those rows sit in rather than the table.
  An UPDATE of one row of fifty thousand went from 93.7 ms to 1.45 ms, against
  1.30 ms for the same statement on the same table without an index.

  Removing and inserting are separate passes because they sit on either side
  of the write, and because a unique index doing both a row at a time would
  refuse the first row to take a key that a later row is about to give up.

  A marking DELETE is the same thing without the second pass: the rows stay
  where they are and their entries simply go, so an index goes on describing
  live rows and a unique index stops refusing a key the table no longer holds.
  It happens before the marking rather than after, because the keys are read
  out of the table and a row that has been marked is one a scan may skip. A
  DELETE of one row of fifty thousand went from 92.9 ms to 1.50 ms, against
  1.25 ms without an index.

  A compacting DELETE still rebuilds, and has to: every surviving row moved,
  and an entry names a row by position.

  Doing this put the first caller on `db_index_delete` outside its own test,
  and found two defects that had nothing to do with the index: a splitting
  internal node counting a whole child as one row, and a retire that goes
  first in a transaction stamping the allocation map a published generation
  is still reading. Both are fixed, and both are now covered by cases that
  ask for what a statement asks for rather than what a unit test found
  convenient - three levels grown by insertion, and a delete with a commit
  after it.

* **UPDATE through the C ABI did not exist.** `STMT_UPDATE` was missing from
  the step dispatch, so `cyboudb_exec("UPDATE ...")` returned an error with
  no message while the CLI ran the same statement. That is the third time in
  this work that a statement behaved differently depending on which caller
  reached it.
* **CREATE INDEX no longer stages a page a row.** It builds by inserting one
  row at a time, which walks the path from the root once a row - and every
  node on that path used to be copied again, because copy-on-write was asked
  for a copy and gave one. A node this transaction already allocated is
  already its own copy: nothing published reaches it, so writing into it is
  what copy-on-write does to the copy anyway. The second walk down the same
  path now spends nothing.

  Fifty thousand rows left 146439 allocated pages behind them and now leave
  2113, and an INSERT into that table went from 10.4 ms to 1.32 ms - which is
  what the same table costs without an index at all, because the cost was
  never the index but the flush of a file that much of had been written. A
  sort and a bulk build would still stage less, and would no longer be worth
  much.

  `tests/index_sql_tests.py` pins the high-water mark a build moves, which is
  the number the flush followed.
* **A plan consults an index for one comparison against an indexed column**,
  of any of the five shapes `=`, `<`, `<=`, `>`, `>=`. Each becomes a pair of
  inclusive bounds, the tree names the rows between them, the scan is put where
  it said, and the predicate runs over that batch exactly as it would have
  anywhere else - so the index decides where to look and never which rows come
  back, and a stale entry costs a page read rather than a wrong row. The suite
  asks the same questions of two tables with the same rows, one indexed and one
  not, and requires the answers to be identical.

  A unique index names one row and a lookup is one seek. A non-unique one
  names many, spread across the whole table, so the lookup walks the tree with
  the path it descended and moves the scan to each 64-row group the walk
  reaches. What makes that walk possible is that an internal entry carries the
  `(key, row)` pair a child ends at rather than only the key: equal keys span
  several children, and a separator that was only a key sent every one of them
  to the first child - a tree that validated, answered a unique lookup, and
  quietly lost two thirds of the rows under a duplicated key.

  A range names several keys, and their rows are not in row order, so a group
  can be entered more than once. A visit therefore delivers the lanes the walk
  named on that visit rather than the whole batch; each entry is produced once,
  so no row comes back twice. What does change is the order: a range returns
  its rows in key order rather than the order a scan produces. A query that did
  not ask for an order is not owed one, and the cases where an unstated order
  becomes a different answer - `LIMIT`, `ORDER BY`, `COUNT(*)`, vector top-K -
  are the cases where the planner does not reach for an index at all.

  Because a group can be entered once per run of entries landing in it, a wide
  range can cost more reads than reading the table. The plan walks the tree at
  open until either the range ends or it has named more entries than the table
  has 64-row groups, and takes the scan in the second case: entries come 167 to
  a leaf page, so the question costs far less than the reads it decides. An
  equality is never asked, because its rows leave the walk ascending and each
  group is entered once however many rows one key names.

  The seek lives in sql_select_open, where every reader opens its cursor -
  the batch executor and the pull cursor the ABI steps alike. It was written
  in the executor first, which meant the ABI kept scanning; that is the fourth
  time in this work that a second copy of a statement's behaviour has cost a
  bug, and the fix each time is to move the behaviour to the shared path
  rather than to duplicate it.

  `tests/index_plan_test.c` asserts which path ran, not only what it answered,
  by counting the times a plan reached for a tree. A query that is right for
  the wrong reason stops being right when the plan changes, and no assertion
  about results can tell the two apart.

  A prepared plan is cached by its statement text, so a statement first bound
  before an index existed keeps scanning until it is prepared again. That is
  worth fixing and is not a wrong answer. Separately, the ABI's pull cursor
  cannot ORDER BY at all, which is older than any of this.

A prepared plan that chose an index outlives the index. The roadmap already
said a statement bound before an index existed keeps scanning until it is
prepared again, which is slow and not wrong. The other direction was wrong: a
plan holding an index id for a tree that had since been dropped read no rows,
because opening the cursor treated a missing index as an empty one. It now
checks that the id still names this table's index over the column the
predicate is about, and reads the table when it does not - an access path that
has gone is not an empty one. `tests/index_plan_test.c` prepares, drops and
steps the same statement again.

`COUNT(*)` reads through an index too. It had been refused one along with
LIMIT, ORDER BY and vector top-K - those are refused because the order a lookup
returns rows in becomes a different answer there, and counting does not care
what order it counts in. Making it work needed the empty lookup to finish the
scan rather than declare the cursor done, because a count is handed back where
a scan runs out.

Also open: TEXT keys and multi-column keys.

---

## The foundation

Storage, transactions, recovery, the SQL front end, the columnar executor,
vectors, tombstoned DELETE and secondary indexes are implemented, documented
and green on Linux and Windows. Both platform jobs run the same suites, bar
one that tests Windows command-line parsing and has nothing to test elsewhere.
Nothing below this line depends on any of it changing shape.

That is what a new subsystem was waiting for. The order from here is queues,
then streams, then transactions that span more than one primitive, then the
daemon, then the examples, then release hardening - each one finished and
green before the next begins, for the same reason the phases above were.

---

## Phase 11 - Queues

The decisions are fixed in [docs/QUEUE.md](docs/QUEUE.md).

Done: the catalog page that defines a queue, and what a commit proves about
it. `CybouDB_FEATURE_QUEUE` is now accepted at open, because this build can
read a queue page; `create-large` and `create-tombstones` emit it. A queue is a
fourth directory type, sharing the namespace with tables and indexes - a table
may not take a queue's name, and the same directory walk answers both.

Writing the refusals first found a gap in the validator that nothing else
would have: a commit re-checks a page's checksum only when this transaction
wrote it, which is what stops a commit costing the size of the database. So a
field no validator looks at is a field nothing refuses. A directory entry
sitting past the segment count was exactly that until `tests/queue_page_test.c`
asked for it, and the tail is now required to be zero the way every other tail
in this format is.

`CREATE QUEUE name` and `DROP QUEUE name` work from the command line, the
console and the C ABI, through `sql_execute_batch` and not three times over.
`.queues` lists what exists and how deep each one is. The namespace check goes
both ways - a queue may not take a table's or an index's name, and neither may
take a queue's - and no statement resolves an object of the wrong kind:
`DROP QUEUE` will not drop a table, `DROP TABLE` will not drop a queue, and a
queue cannot be selected from.

Adding the statements found a fault older than queues. The command line
reported the result of any statement it did not recognise by reading
`PLAN_DATA1` as an insert batch, so `DROP QUEUE`, which leaves that field
zero, took the process with it. The default is now an explicit `INSERT` case
and a neutral line for anything else: a new statement kind should print the
wrong word at worst.

`ENQUEUE INTO q VALUES ('bytes')` and `DEQUEUE FROM q` work for a payload of
32 bytes or fewer, which is what a slot holds. A message goes into the slot its
position names, a new segment appears when the tail crosses a boundary, and a
segment every one of whose positions is behind the head is retired and its
entry dropped - so a queue drained as fast as it is filled holds the segments
it is using rather than the ones it has used. The first segment the directory
names is derived from the head rather than tracked, which is what keeps it from
ever disagreeing with the validator that requires exactly that.

A segment already allocated by this transaction is written in place rather than
copied again, for the reason an index node is: nothing published reaches it,
and a segment has exactly one parent. Without it an ENQUEUE of many messages
would spend a page each.

Writing it cost one bug, and it was the one this project keeps paying for: a
page id in RDX, then `mov ARG2, ...` which is RDX on Win64, then `mov ARG3,
rdx` handing the superblock pointer on as the page. The rule the index work
arrived at - put call data in a register no argument aliases before touching
the argument registers - is the fix, and it has now been the fix six times.

A payload longer than a slot is a varlen extent chain owned by the queue's id -
the machinery a TEXT cell already needed, rather than a second way to store
bytes. A take retires the chain, and it has to happen there rather than when
the segment goes: a segment is retired once and it carried sixty-two messages,
so a queue filled and drained forever would otherwise spend pages it never gave
back. The test for that is a file too small to survive the leak - a hundred
round trips of a two-page message through three hundred pages - because a
high-water mark cannot show a page coming back and running out of them can.

What limits a message now is the front end, not the queue: the command line
refuses a statement past its own length, and the console past its line. Both
are older than queues.

The refusals are tested at both depths, and the difference between them is the
assertion. A damaged file does not fail to open: the generation holding the
damage stops being selectable and the one before it opens, which is recovery
working. So what the suite measures is which generation the engine picks. A
segment's magic, its owner, the position it starts at and any byte of a slot
are seen by every reader, because a checksum covers the page. A lease on a
message that cannot have one, and an extent id that leads nowhere, are seen
only by `cyboudb check` - and that is visible from outside: `info` still picks
the damaged generation and `check` picks the one before it.

Writing those found a second register clobber in the same function, and it had
been silent: the deep pass computed a slot address from a value an argument
register had already overwritten, so it had been walking somewhere else
entirely and finding nothing wrong. Only damage that the deep pass was
supposed to catch could reveal it, which is the argument for writing the
refusals rather than assuming them.

That was the seventh, and seven of the same mistake is an argument for a
machine. `tests/abi_arg_lint.py` reads every `.asm` file and reports a value
taken out of a register that an earlier argument write in the same run has
already overwritten under one of the two conventions. It is deliberately
narrow - nothing about registers clobbered across calls, nothing about
ordinary scratch use - because a rule that can be kept is worth more than a
warning nobody can silence.

On its first run over the whole codebase it reported two places, both live
bugs and both Windows-only:

* the index bulk builder handed a level's key on where its row belonged, so a
  tree built in bulk over a key spanning several children recorded separators
  that did not rise;
* a qualified column reference passed the pointer where the length belonged.

Neither had a test, and neither could have: the Linux CI is green on both.
`tests/index_tree_test.c` now has the case for the first - a bulk build whose
last two leaves end at the same key, which is the only arrangement where the
row is what separates them, and with a hundred rows a key it passes either way.
That nearly became a test that proved nothing.

CI runs the lint.

`DROP QUEUE` retires what the queue was holding - the extent chain of every
message still in it, then the segments - before the directory entry goes, for
the reason `DROP INDEX` retires its tree. Removing the entry takes the last
reference to those pages with it, and a payload page nothing references is one
nothing will hand out again. Tested the same way: a hundred rounds of create,
fill with three two-page messages, drop, through three hundred pages. Without
the retire it runs out at the forty-eighth.

`DEQUEUE` through the C ABI answers in the vocabulary a step already has:
`CybouDB_ROW` when it took a message, `CybouDB_DONE` when the queue was empty,
and `cyboudb_message` for the bytes. It is not presented as a column, because a
queue holds bytes and no schema to say how to read them, and a synthetic row to
read one out of would be a second representation of what a row is. Stepping the
same statement again asks again - a queue is not a result set that runs out,
and a message enqueued in between is there to be taken.

Each step is its own transaction unless one is already open, which is the
commit-then-work order and therefore at-most-once. A caller that wants the
other order opens a transaction around the step. That is stated in
`include/cyboudb.h` where a caller will read it, rather than only here.

What is decided:

* a queue is a fourth catalog page type, in the same id space and the same
  namespace as tables and indexes;
* a message is addressed by a 64-bit position that is never reused, and where
  it lives is arithmetic on that position - there is no pointer chain, for the
  reason a B+tree here has no sibling pointers and a PAX table has no leaf
  chain;
* a payload of 32 bytes or fewer sits in its slot and a longer one is a varlen
  extent owned by the queue id, which is the machinery TEXT already uses;
* validation costs the segments a queue is holding, not the messages it has
  carried, so a drained queue validates in one page;
* what `DEQUEUE` promises is transactional removal, and nothing about where the
  message goes afterwards. Which guarantee a caller gets is decided by where
  they put the commit - work then commit is at-least-once, commit then work is
  at-most-once - and neither is exactly-once, because the external effect is
  not something a commit can include. An earlier draft called it at-least-once
  and was wrong;
* version 1 has no leases, and that is the one absence it is wrong about. A
  transaction cannot stay open while a worker runs, so a work queue needs a
  claim with an expiry rather than a DEQUEUE. Storage being single-writer is
  not an argument against that: a broker can serialise every mutation and still
  have three workers running at once. The format reserves what leases need - a
  claim cursor on the queue page, and per-message state, deadline and token in
  the slot, at the cost of sixteen bytes of inline payload - so that adding
  them later moves no byte a released file depends on. That is the whole reason
  to decide it before the first ENQUEUE rather than after.

What version 1 does not do, and which of those are postponed rather than
refused, is in the document. Priorities, delays and a dead-letter queue have no
reserved field, which is the format saying they would be a change and not an
addition.

The order of work: the catalog page type and its validation first, because
that is where the last subsystem's bugs hid; then CREATE QUEUE and DROP QUEUE;
then ENQUEUE and DEQUEUE; then the C ABI, with the statements reaching the
engine through sql_execute_batch so there is one implementation rather than
one per caller.

## Phase 12 - Streams

The decisions are fixed in [docs/STREAM.md](docs/STREAM.md).

**Done: the catalog page and what a commit proves about it.** A fifth
directory type, `CAT_STREAM`, in the same id space and namespace as tables,
indexes and queues. `CybouDB_FEATURE_STREAM` is now accepted at open, and
accepted only with `QUEUE`, because a stream's records live in a queue's
segments and the bit means nothing without the bit that defines them - which
is checked before the queue bit is taken out of the combination, since that is
where it is still there to see.

The segment walk is one routine, `db_queue_segments_valid`, called by both
validators through a descriptor: one storage shape, two objects, one walk.
What `stream_page_valid` adds is the part a queue has no equivalent of - no
cursor unnamed, no two cursors the same reader, every cursor within
`[first, end]`, and the slots past the count holding nothing.

`tests/stream_page_test.c` is 63 checks: the page, the shared namespace
against all of a table, a stream and a queue, six shapes the catalog refuses
to publish, eleven fields whose damage must stop a commit, and the three
cursor cases - one standing outside the stream, two sharing a name, and then
two that are genuinely two, which is the control that says the first two
failed for the reason claimed rather than because any cursor at all is
refused.

**Done: `CREATE STREAM` and `DROP STREAM`.** Both reach the engine through
`sql_execute_batch`, and the create binds to the same body a `CREATE QUEUE`
does - the page image is a zeroed page with a name at the offset both use, so
what differs is the feature bit, the statement it answers to, and which shape
check the catalog publishes it through.

`DROP STREAM` retires the segments before the entry that names them, through
the same walk `DROP QUEUE` uses: the two directories sit at different offsets
and everything else about the walk is identical, so it takes the offset as an
argument rather than a copy. A stream has no segments until something appends;
this is written now rather than left to be remembered then.

The console lists them with `.streams`, which reports each stream's depth and
how many readers stand in it - and `.queues`, which was missing from `.help`,
is now in it.

`tests/stream_sql_tests.py` is 38 checks. The ones that earn their place are
the type boundary: a stream and a queue have the same header, so a resolver
going by shape rather than by type would let each drop the other and look
right doing it. `DROP STREAM` on a queue, `DROP QUEUE` on a stream, and
`ENQUEUE`/`DEQUEUE` against a stream are all refused by name.

**Done: `APPEND`.** A record at the end of a stream is the write a message
at the tail of a queue is, so it is that routine: the position decides the
segment and the slot, a payload past 32 bytes goes into the varlen chain a
TEXT cell uses, and nothing already written is touched. Four things differ -
the page type it accepts, where that type's directory starts, how many entries
it has room for, and that a stream has no claim cursor to carry forward - and
they are four numbers rather than a second copy of every boundary case.

That sharing is also where this turn's bug was. The entry points carried their
differences in R10, R11 and R9 - and R9 is `ARG4` on Windows, so the length
argument was destroyed before it was saved. It reads correctly on Linux. The
fix is the rule this project already had: only R10 and R11, which no argument
aliases, and derive the rest after the arguments are somewhere safe.

`tests/abi_arg_lint.py` now looks for that direction too - an argument read
out of a register that scratch has been put into since it arrived - and it
catches the bug when it is put back. Making it quiet on the existing code took
three narrowings, each of which is a fact about the codebase: state resets at a
routine's own label as well as at `call` and `ret`; it is carried along a `jmp`
into the shared body an entry point falls into; an ARG the run has already set
is not an incoming argument any more; and a comment that names a register is a
comment. Six of the seven first reports were the lint reading the comments that
explain why the code below is careful.

`tests/stream_sql_tests.py` is 53 checks now. Seventy-three records cross the
62-slot segment boundary into a second segment, a 200-byte record takes the
extent path, fifty make-and-drop rounds run through a 300-page file that could
not survive a leak, and a rolled back `APPEND` leaves the stream where it was.

**Done: cursors.** `CREATE CURSOR reader ON stream` and `DROP CURSOR reader
ON stream`. A cursor is not a catalog object - it is a field of the stream
that owns it - so it is named relative to one, and the same name on two
streams is two readers.

A new reader stands at `first`, the oldest record still kept, because that is
the only starting point that promises it every record the stream still has.

The binder resolves the stream, because that is a name in the catalog, and
carries the reader's name no further than that: whether a stream already has a
reader of that name and whether it has room for another are facts about the
page, and the page is the core's. `db_stream_cursor_add` asks about the name
before the ceiling, so that a name already there is what a caller is told when
both are true, and asks both before anything is copied, so a refusal costs no
page. The CLI turns the storage codes into sentences about readers; that is
presentation, and it is the only thing about cursors that lives in two places.

`DROP CURSOR` keeps the table dense - the last reader moves into the hole and
the slot it leaves is zeroed - because the validator requires the slots past
the count to hold nothing, and because which slot a reader sits in means
nothing to anyone while its name means everything.

`tests/stream_sql_tests.py` is 74 checks. The cursor ones read the table off
the disk rather than trusting the listing: the names in slot order, the
positions, and that everything past the count is zero. The one worth naming is
that a prefix of a reader's name is not that reader - proved by removing the
check that the stored name stops where the given one does, which fails that
test and only that one.

**Done: `READ`.** `READ FROM stream AS reader` gives that reader the oldest
record it has not seen and then it has seen it. Nothing is removed - another
cursor still gets the same record - and a reader that has seen everything is
answered rather than refused, because being caught up is not an error.

Locating a position and copying a payload out of a slot are now
`queue_slot_at` and `queue_slot_copy`, lifted out of `db_queue_pop` and shared.
The queue's suites are what says the lift was clean.

Two bugs, both mine, both in the same ten lines:

* the edit that moves a cursor forward publishes through `db_catalog_edit`,
  which stamps the page - and stamping clears the span `first` and `end` live
  in. The first version did not put them back, and I had written a comment
  arguing it did not need to. The commit refused the page: a stream that holds
  nothing while naming a segment is not a stream. The validator earned its
  keep.
* fixing that, the save I added reused the register the position was sitting
  in, so the read located the slot at `end` - one past the last record, which
  is empty. Every position advanced correctly and every record came back as
  zero bytes. The lint cannot see this one: the register was not an argument
  register, it was just live.

Finding the second took eight rebuilds of narrowing, and the thing that
finally placed it was making the routine write a sentinel through the pointer
it had been handed: the sentinel arrived, so the plumbing was right and the
slot was wrong. Worth remembering as the cheaper first move.

`tests/stream_sql_tests.py` is 86 checks. Two readers on one stream stand in
different places and both are given every record; a 200-byte record comes back
whole through the extent chain; and a `READ` inside a rolled back transaction
answers and leaves the reader where it was, because a position is state.

`read` is a keyword now, so it is no longer available as an identifier.

**Done: `TRIM`.** `TRIM STREAM name BEFORE position` moves the beginning
forward, retires the extent chain of every record it drops, and then retires
every segment entirely behind the new beginning. A position rather than a
count, so that a caller who has read a cursor's position can trim to it.

A trim may not pass the slowest cursor, and the refusal has a code of its own.
Skipping would lose a record a reader was promised and failing would leave it
stuck forever, so refusing is the only answer that keeps both promises - and
`DROP CURSOR` is the escape hatch, which is explicit rather than a timeout the
engine would have to invent. Trimming to behind the beginning is nothing to do
rather than an error: the records are gone, which is what was asked.

**A queue bug found on the way, and it was an old one.** The block in
`db_queue_pop` that retires the chain a taken message named had no label and
sat after a loop whose only exit jumped past it. It had never run: every
`DEQUEUE` of a message longer than a slot leaked its extent pages, for as long
as the queue has existed.

The test that was meant to catch it ran a hundred round trips of a 4000-byte
message through a 300-page file and said in its comment that only reclamation
could survive that. A hundred fits either way; the file runs out at 290. It is
four hundred now, and fails within thirty round trips of the leak coming back,
which is checked rather than assumed.

That is the third test this project has had that proved nothing, and all three
had the same shape: a number chosen to be comfortably large rather than
computed from what would fail without the thing being tested.

`tests/stream_sql_tests.py` is 103 checks. The trim ones read the shape off the
disk - beginning, end, segment count, first segment - across a trim that
crosses a segment boundary and a trim to the end; and two hundred
append-and-trim rounds of a two-page record run through a 300-page file that
could hold neither the chains nor the segments if either were kept.

Still to come: the C ABI, and then Stream is done.

What is decided:

* a stream is not a queue with extra readers, and collapsing them would make
  the queue's promise accidental. `DEQUEUE` removes the message in the
  transaction that takes it - that is a guarantee, and it is the reason a
  queue inside a database is worth having. `READ` says only that this cursor
  has seen up to here. Two promises, two operations;
* they share the storage, which is where duplication would actually cost. A
  stream's records live in segment pages of the queue's format, validated by
  the same walk, with a long payload in the same varlen chain. One storage
  shape, two objects, one validator - which is why the feature bit depends on
  `QUEUE` rather than on `CATALOG`;
* a cursor is a durable, named reader and there are at most eight of them. A
  process that wants to read without leaving anything behind reads by position
  and keeps its own place. The ceiling is stated rather than discovered;
* a trim may not pass the slowest cursor. Skipping silently loses data a
  reader was promised and failing leaves it stuck, so refusing is the only
  answer that keeps both promises - and the cost, that one abandoned cursor
  stops retention, has an explicit escape hatch in `DROP CURSOR` rather than a
  timeout the engine would have to invent.

Retention by age or by size is absent, and deliberately: age needs a clock the
engine does not have, size needs a policy, and both are `TRIM` with something
above the engine deciding the argument. Sixteen bytes are reserved for what a
policy would need when there is one to defend.

The order of work is the one queues took, because it paid: the catalog page
and its validation first, then `CREATE STREAM` and `DROP STREAM`, then
`APPEND` and cursors, then `READ`, then `TRIM`, then the C ABI - every
statement through `sql_execute_batch`.

---

---

## Known gaps outside the phases

Small, real, and worth fixing when they are next touched:

* [x] the Windows command-line parser does not implement the backslash-escape
      rules of `CommandLineToArgvW`
* [x] `os_write` on Windows does not loop on a partial write, unlike the Linux
      path
* [ ] the double-free guard is a heuristic and will need a real allocation
      bitmap once pages carry data
* [x] no `NOTICE` file and no per-file licence headers
* [x] the tokenizer kept a pending literal token type in the same frame slot
      as saved `RBX`, so any statement containing a TEXT or BLOB literal
      returned to its caller with that register changed. Invisible to a C
      test unless the compiler happened to keep something live there;
      `tests/abi_probe.asm` now checks every callee-saved register across a
      library call so the next one is an ordinary failing assertion
