# CybouDB

**CybouDB** is an embedded database engine written in assembly, with a portable
on-disk format, copy-on-write transactions, columnar execution, secondary
indexes and native vectors. It has no libc, no CRT and no third-party
dependency: on Linux it talks to the kernel directly, and on Windows it uses
kernel32 and nothing else.

Relational data and vectors live in one file under one transaction model. A
statement that writes rows, updates an index and stores an embedding either
commits as a whole or leaves nothing behind, because there is one storage
engine underneath rather than a database beside a vector store.

The project also explores how far a compact engine can be pushed when its
storage layout and execution model are designed directly around modern CPU and
operating-system primitives: memory-mapped I/O, fixed-size pages,
cache-conscious data layouts, SIMD predicate evaluation and minimal runtime
dependencies.

> **Project status: pre-release.** The on-disk format, the transaction
> semantics and the recovery behaviour are frozen as version 1 and written down
> in [docs/FORMAT.md](docs/FORMAT.md), [docs/TRANSACTIONS.md](docs/TRANSACTIONS.md)
> and [docs/RECOVERY.md](docs/RECOVERY.md). SQL, the columnar executor, exact
> vector search, tombstoned DELETE with compaction and secondary B+tree indexes
> are implemented and tested on Linux and Windows. A plan uses an index for an
> equality or a range over an indexed column, and an ARM64 backend does not
> exist. There is no release, and CybouDB is not production-ready.

---

## What works today

| Area | State |
| --- | --- |
| On-disk format v1, checksummed and validated | working |
| Memory-mapped storage, 4 KiB logical pages | working |
| Page allocator with a free list | working |
| Two-superblock metadata publication | working; page mutations are not crash-safe |
| Persisted COW mode and allocation map | working; `create-cow`, then `alloc` / `info` |
| Typed catalog and COW root-path updates | working; up to 251 tables, 64 columns per table |
| PAX columnar table storage | working; whole 64-row groups, typed columns, NULL masks |
| Multi-page PAX tables | working; two-level directory tree (up to 28M rows per table), cross-page batches |
| Paired multi-page allocation map | working; `create-large`, 63 GiB ceiling, page reclamation |
| SQL engine: parser, binder, executor | working; pure x86-64 scalar and batch execution |
| SQL statements | working; `CREATE TABLE`, `DROP TABLE`, `INSERT INTO` (multi-row), fixed-width flat-PAX `UPDATE ... SET literal WHERE`, `DELETE FROM ... [WHERE]`, `SELECT ... WHERE`, stable single-key `ORDER BY`, `LIMIT [OFFSET]`, correctness-first `INNER JOIN`/`LEFT JOIN` on qualified INT32/INT64 equi-keys, `BEGIN`/`COMMIT`/`ROLLBACK`, `CREATE [UNIQUE] INDEX` / `DROP INDEX` |
| Secondary indexes | working; copy-on-write B+tree on INT32/INT64 columns, unique or not, maintained by every statement that changes a table. A plan uses one for any single comparison against an indexed column, and an UPDATE or a marking DELETE patches the entries of the rows it touched rather than rebuilding the tree: see [docs/INDEX.md](docs/INDEX.md) |
| DELETE strategy | working; truncation, per-row tombstones, or a compacting rewrite, chosen per statement from what the table already holds. No explicit `VACUUM` |
| SQL types and semantics | fixed-width storage working for `INT32`, `INT64`, `FLOAT32`, `BOOL`; persistent `TEXT`/`BLOB` storage working for `create-large` databases |
| CLI: `query` | working; executes statements, autocommits mutations, tabular output |
| CLI: `create`, `info`, `check`, `alloc`, `free` | working |
| Open proportional to the change, not the file | working; `cyboudb check` still reads everything |
| Linux x86-64, raw syscalls, no libc | working |
| Windows x64, kernel32 only | working |
| Storage, fault-injection, and SQL test suites | working; 3,300+ automated tests on Linux and Windows |
| CI on Linux and Windows | working; every push builds and runs the whole suite on both, and the two jobs run the same tests |
| Interactive console (REPL) | working; interactive terminal (`ReadConsoleW` / stdin), piped scripts, multiline queries, meta-commands (Phase 4) |
| Public C library ABI (`cyboudb.h`, `libcyboudb.a`, `cyboudb.lib`) | working; borrowed typed batch views, prepared statement caching (Phase 5) |
| Hardware acceleration & SIMD | working; SSE4.2 hardware CRC-32C, BMI2 primitives (pext/pdep/bzhi), AVX2 256-bit scan kernels, CPUID detection (Phase 6) |
| ARM64 execution backend | not started (Phase 7) |
| Vector engine | working; `VECTOR(FLOAT32, n)` columns, persistent extents, exact top-K through `ORDER BY <distance> LIMIT k` in both directions, scalar and AVX2. No ANN index |
| Multi-statement transactions | working; `BEGIN`/`COMMIT`/`ROLLBACK` over COW staging, one writer, readers pinned against reclamation |
| WAL, multi-writer concurrency | not started; the format defends against neither, and an advisory lock prevents the second writer |
| Encryption | not started (Phase 10) |

A database file written on one supported platform is read by the other; this
is checked as part of development, not assumed.

---

## Build

Nothing but an assembler and a linker is required. There is no libc, no CRT and
no third-party dependency.

**Linux**

```sh
sudo apt install nasm binutils     # or dnf / pacman / apk
sh build.sh                        # builds cyboudb
sh build.sh --core-tests           # builds build/cow_harness
sh build.sh --sql-tests            # builds build/sql_harness
sh build.sh --hardware-tests       # builds build/hardware_harness
```

**Windows**

```cmd
build.bat                          rem builds cyboudb.exe
build.bat --core-tests             rem builds build\cow_harness.exe
build.bat --sql-tests              rem builds build\sql_harness.exe
build.bat --hardware-tests         rem builds build\hardware_harness.exe
```

`build.bat` locates NASM and a linker on its own - GoLink if it is present,
otherwise the MSVC toolchain through `vswhere` - so no Developer Command
Prompt is needed. Install NASM with `winget install NASM.NASM`.

---

## Use

### SQL Queries

CybouDB queries RAW PAX columns directly from mapped storage. Encoded columns
use temporary decoded batches. [Compression V1](docs/COMPRESSION.md) supports
CONST/FOR inside fixed-size slots; it does not reduce the logical file size.

```sh
# Create a PAX database file (256 pages = 1 MiB)
cyboudb create-pax demo.cdb 256

# Define a table (supports INT32, INT64, FLOAT32, BOOL, NULL / NOT NULL)
cyboudb query demo.cdb "CREATE TABLE users (id INT32 NOT NULL, score FLOAT32, active BOOL)"

# Insert rows (supports multi-row batches up to 256 rows)
cyboudb query demo.cdb "INSERT INTO users VALUES (1, 98.5, true), (2, null, false), (3, -12.25, true)"

# Query data with projection and filtering (3VL logic, comparison operators, IS NULL)
cyboudb query demo.cdb "SELECT id, score FROM users WHERE active = true AND score > 0.0"
```

`TEXT` and `BLOB` are persistently supported for databases created with
`create-large`, which enables the incompatible variable-width extent
capability. Fixed-width creators continue to reject them rather than publish
an unsupported schema. Fixed-width scans can expose borrowed/zero-copy views;
variable-width values are validated and copied into caller-owned buffers. The
versioned on-disk contract is documented in [docs/VARLEN.md](docs/VARLEN.md).

Output:

```text
id | score
-------- | --------
1 | 98.50
(1 row)
```

Mutating statements (`CREATE TABLE`, `INSERT INTO`, `UPDATE`, `DELETE`) automatically commit changes
to disk upon success. `SELECT` statements open the database in read-only mode,
evaluating predicates using Three-Valued Logic (3VL) and pruning unreferenced
columns during columnar batch scans.

Literals are converted to binary32 exactly, by integer arithmetic with
round-to-nearest-even, independently of the caller's MXCSR. Values are stored
as IEEE-754 binary32 bits, signed zeros and NaN payloads included, but the
comparison rules are CybouDB's own: a comparison against NaN is FALSE for all six
operators, `!=` included, rather than unordered. See [docs/SQL.md](docs/SQL.md) for the full
syntax, type system, conversion and comparison semantics, and the
implementation limits.

### Interactive Console (REPL) & Scripts

CybouDB includes an interactive console (REPL) for exploratory queries and SQL script execution:

```sh
# Start interactive console
cyboudb demo.cdb
# or explicitly:
cyboudb console demo.cdb
```

Within the console, queries can span multiple lines until terminated with a semicolon (`;`). Meta-commands provide catalog and database inspection:

```text
cyboudb> .help
Available commands:
  .tables              List tables in the database
  .schema [TABLE]      Show CREATE TABLE statement(s)
  .info                Display database metadata and status
  .help                Show this help message
  .quit / .exit        Exit the console

cyboudb> .tables
users

cyboudb> .schema users
CREATE TABLE users (
  id  INT32 NOT NULL,
  score  FLOAT32,
  active  BOOL
);

cyboudb> SELECT id, score
  ...> FROM users
  ...> WHERE active = true;
id | score
-------- | --------
1 | 98.50
(1 row)

cyboudb> .quit
```

Non-interactive scripts can also be piped directly into CybouDB:

```sh
cat script.sql | cyboudb demo.cdb
```

Piped scripts continue after SQL errors but return a nonzero exit status if
any SQL statement failed, including a trailing statement at EOF. Interactive
sessions continue after SQL errors without changing their normal exit status.

Stream input allows 4095 bytes per physical line (excluding LF or CRLF) and
262143 bytes per accumulated statement (including inserted newlines). Input
overflow stops the session with an error before the truncated input executes;
earlier autocommitted statements remain committed. The Windows interactive
console also rejects incomplete `ReadConsoleW` chunks (its input buffer holds
1023 UTF-16 code units). Split longer console input across lines.

### Embedding through the C API

Build the static library with `sh build.sh --lib` or `build.bat --lib`; the
public declarations are in [include/cyboudb.h](include/cyboudb.h).

The standalone vector runtime needs no open database handle. Build and run its
filtered exact-search example with `sh build.sh --vector-example &&
./build/vector_search_example` (Windows: `build.bat --vector-example` followed
by `build\vector_search_example.exe`).
Use `cyboudb_prepare` and `cyboudb_step` for row access, or `cyboudb_step_batch` followed
by `cyboudb_batch_column(stmt, batch, result_col)` for borrowed typed access in SELECT
order. The accessor preserves reordered and duplicate projections; direct
`batch->columns` indices refer to physical schema slots. COUNT(*) produces one
INT64 aggregate row in either stepping mode.

`cyboudb_exec(db, sql)` executes exactly one statement and discards its results.
The earlier four-argument callback form has been removed before ABI freeze;
replace calls ending in `NULL, NULL` with the two-argument form, and use
prepare/step to consume rows. Multiple statements are rejected before execution.

Prepared statement storage starts small and grows during parse/bind; returned
handles and metadata do not move. The C API supports the documented maximum
INSERT of 256 rows by 64 columns. Allocation failure returns `CybouDB_NOMEM` and
leaves no statement handle. `--c-tests` enables allocation fault injection;
use `--lib` to build a library without test hooks.

Finalize every statement before closing its connection: `cyboudb_close` returns
`CybouDB_BUSY` while any statement remains alive, including exhausted statements.
Result names and types are captured at prepare time; returned name pointers
remain valid until finalize. Batch pointers expire on the next step, reset,
finalize or mutation on the connection. Serialize access to a connection and
its statements. The ABI remains experimental; see the remaining
[hardening work](docs/HARDENING.md).

### Page-level Commands

Low-level storage inspection and page allocation commands operate directly
against database pages:

```sh
cyboudb create demo.cdb 256     # a database of 256 pages (1 MiB)
cyboudb info   demo.cdb         # metadata, validated before it is printed
cyboudb alloc  demo.cdb 4       # hand out four pages and commit
cyboudb free   demo.cdb 5       # return page 5 to the free list and commit
```

```text
$ cyboudb info demo.cdb
CybouDB Database Info
------------------
  Magic:           CybouDB
  Format Version:  1
  Page Size:       4096 bytes
  Total Pages:     256
  Allocated Pages: 7
  Free List Root:  5
  Generation:      3
  Superblock:      page 1
  File Size:       1048576 bytes
  Status:          OK
```

Use `cyboudb create-cow demo.cdb 256` for the experimental COW mode. Its
allocation map protects committed pages and persists the storage mode, so
`alloc` automatically follows the COW path after reopen. `free` is not supported
in this mode. The current single-map limit is 4..16112 total pages; see
[the format and limits](docs/COW.md).

`cyboudb create-catalog demo.cdb 256` enables the typed catalog as well. Its
internal API stores table names and column declarations with COW schema/root
updates. See [the catalog contract](docs/CATALOG.md).

`cyboudb create-pax demo.cdb 256` additionally enables fixed-width row batches,
per-column NULL masks and scalar reads. The first stage holds one PAX page per
table. A page stores as many whole 64-row groups as its schema allows - 3520
rows for a single BOOL column - so the 64-row group stays the unit a NULL mask
and future vector kernels work on without capping what a page may hold.

`cyboudb create-pax-multi demo.cdb 512` enables a directory of PAX pages per
table, scaling through a two-level directory tree up to 63,001 leaf runs
(up to 28 million rows) with cross-page batch insertion.

`cyboudb create-large demo.cdb 40000` adds the paired multi-page allocation map,
which takes the map out of the allocator and raises the file limit from 63 MiB
to 63 GiB. It is also the only format that reclaims pages: once the file is
full it recycles what previous generations retired instead of refusing.

Creating a database never overwrites an existing file; `--force` is required
for that.

---

## Test

### Storage and CLI Tests

```sh
sh tests/run_tests.sh
```

Runs the built binary against healthy and deliberately damaged databases and
checks both the exit code and the output. The same script runs on Linux and,
through Git Bash, on Windows. It needs `python3` for `tests/corrupt.py`, which
produces damaged files.

Most of the suite is about what happens to a **broken** database: a bad
checksum, a foreign file, an unsupported version, a destroyed superblock copy,
a truncated file, a corrupt free list. Two cases assert the opposite - that the
format survives losing one superblock copy, and that the newer generation wins.

### Core and Fault-Injection Tests

Built with `--core-tests` (`build/cow_harness`):

* `tests/cow_tests.py`: COW page copies, pre-commit writeback, torn superblocks,
  and injected sync errors.
* `tests/bitmap_tests.py`: Two-bit allocation map validation and recovery.
* `tests/catalog_tests.py`: Typed catalog root-path updates and schema validation.
* `tests/zone_validation_tests.py`: Zone graph corruption, generation recovery and exhaustive statistics recomputation.
* `tests/zone_sql_tests.py`: SQL zone ON/OFF parity, FLOAT32 and 3VL semantics, and per-leaf pruning counters.
* `tests/pax_tests.py`: Single-page PAX layout, NULL masks, and boundary limits.
* `tests/pax_multi_tests.py`: Multi-page directory traversal, two-level trees, and cross-page batches.
* `tests/concurrency_tests.py`: Single-writer exclusion, read-only coexistence, and reader-pinned reclamation.
* `tests/span_tests.py`: Paired span maps, 63 GiB scaling, and page recycling.
* `tests/sql_numeric_tests.py`: IEEE 754 floats, signed zeros, subnormals,
  infinities, and 3VL NaN predicate evaluation.
* `tests/varlen_tests.py`: TEXT/BLOB extent round-trips, corruption rejection,
  CRC and chain topology validation, canonical descriptors, and unchanged
  output buffers on failed reads.
* `tests/varlen_fragmentation_tests.py`: non-contiguous extent allocation after
  alternating retired-page holes.

Build the varlen drivers with `sh build.sh --varlen-tests` and
`sh build.sh --varlen-fragmentation-tests` (or the corresponding
`build.bat` targets on Windows).

### SQL and Kernel Test Suites

Built with `--sql-tests` (`build/sql_harness`) and `--kernel-tests` (`build/kernel_harness`):

* `tests/sql_tests.py` (also callable via `tests/sql_tests.ps1` / `.sh`):
  78 end-to-end SQL integration and boundary tests covering `CREATE TABLE`,
  `INSERT INTO`, `SELECT`, expressions, precedence, constraints, and rollbacks.
* `tests/sql_api_tests.py`: 193 contract tests verifying error domains, source
  locations, MXCSR preservation, prepared plan fast-path contracts and fallbacks,
  and float literal conversions against an independent rational oracle.
* `tests/sql_pruning_tests.py`: 36 tests verifying required-column pruning and physical layout access.
* `tests/sql_sink_tests.py`: 69 tests covering scalar and batch row delivery.
* `tests/kernel_tests.py`: 2,756 exhaustive scalar predicate kernel tests across all comparison operators, types, and NULL permutations.

### Hardware Optimization Tests

Built with `--hardware-tests` (`build/hardware_harness`):

* `tests/hardware_tests.py`: 1,276 oracle test cases verifying hardware SSE4.2 CRC-32C against reference scalar CRC-32C across buffer sizes (0..8180 bytes) and byte alignments, plus BMI2 `pext`, `pdep`, `bzhi`, and NULL mask compaction routines with bit-for-bit scalar fallbacks.

All test suites run in CI on both Linux and Windows.

---

## Documentation

* **[ARCHITECTURE.md](ARCHITECTURE.md)** - the design: layering, the on-disk
  format, the commit protocol, the allocator, and how one format is meant to
  serve several hardware-native execution engines.
* **[ROADMAP.md](ROADMAP.md)** - the phases, and what is actually done.
* **[docs/FORMAT.md](docs/FORMAT.md)** - the on-disk format, version 1, and the
  compatibility promise that goes with it.
* **[docs/TRANSACTIONS.md](docs/TRANSACTIONS.md)** - what a transaction is, the
  commit protocol, and what a failed commit leaves behind.
* **[docs/RECOVERY.md](docs/RECOVERY.md)** - how opening a database selects a
  generation, and what survives a crash.
* **[docs/SQL.md](docs/SQL.md)** - SQL dialect, statement syntax, 3VL logic,
  error domains, and limits.
* **[docs/CATALOG.md](docs/CATALOG.md)** - typed catalog specification and schema pages.
* **[docs/COW.md](docs/COW.md)** - copy-on-write design and allocation map.
* **[docs/PAX.md](docs/PAX.md)** - PAX layout and single-page row storage.
* **[docs/PAX_MULTI.md](docs/PAX_MULTI.md)** - multi-page table directory format.
* **[docs/SPAN_MAP.md](docs/SPAN_MAP.md)** - paired multi-page allocation map and recycling.
* **[docs/INDEX.md](docs/INDEX.md)** - secondary B+tree indexes: the page
  layout, what a row id means, and when an index is rebuilt.
* **[docs/QUEUE.md](docs/QUEUE.md)** - durable FIFO queues: the page layout,
  why a message is addressed by position rather than threaded on pointers,
  what `DEQUEUE` does and does not promise, and what is reserved for leases.
  `CREATE QUEUE`, `DROP QUEUE`, `ENQUEUE` and `DEQUEUE` work, with a longer
  payload carried by the same extent chain a TEXT cell uses.

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
