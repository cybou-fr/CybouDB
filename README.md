# CybouDB

### One embedded database for data, vectors, work and events.

**CybouDB** is an embedded database for modern applications. Relational tables,
secondary indexes, exact vector search, durable queues and replayable streams
live in one `.cdb` file and share one transaction engine.

```sql
BEGIN;
DEQUEUE FROM inbox;                            -- take the work
INSERT INTO results VALUES (42, 'completed');  -- record the result
APPEND TO audit VALUES ('job 42 completed');   -- and say so
COMMIT;
```

Either the whole state transition commits or none of it does — including across
a crash, and including the index entry the row required. A job cannot vanish
without a result; a result cannot appear without its audit event.

That matters when an application would otherwise combine a database, a vector
store, a work queue and an event log, each with its own persistence and its own
commit boundary. Here there is one storage engine underneath, so **no outbox is
needed between primitives that live in the same `.cdb` transaction.**

CybouDB is implemented from scratch in x86-64 assembly. On Linux it talks to the
kernel through raw system calls; on Windows it uses kernel32. There is no libc,
no CRT and no third-party runtime.

Current release **[`v0.5.0-preview.1`](https://github.com/cybou-fr/CybouDB/releases/tag/v0.5.0-preview.1)** · Linux x86-64 · Windows x64 · Apache-2.0

**Preview software. Not production-ready.**

---

## Why CybouDB

```text
an embedded app today:            CybouDB:

  SQLite                            tables + vectors + queues + streams
  + a vector store                                 ↓
  + a job queue                              one transaction
  + an event log                                   ↓
        ↓                                        .cdb
  several systems,
  several commit boundaries,
  and an outbox to glue them
```

An external system is separate again, and nothing here changes that: a
transaction that takes a message and then calls another service is still two
systems. [docs/QUEUE.md](docs/QUEUE.md) says which order buys which guarantee,
and [docs/TRANSACTIONS.md](docs/TRANSACTIONS.md) covers what a commit does and
does not include.

---

## Quick start

```sh
cyboudb create demo.cdb 4000   # 4000 pages = 16 MiB
cyboudb query  demo.cdb "CREATE TABLE users (id INT32 NOT NULL, score FLOAT32, active BOOL)"
cyboudb query  demo.cdb "INSERT INTO users VALUES (1, 98.5, true), (2, null, false)"
cyboudb query  demo.cdb "SELECT id, score FROM users WHERE active = true AND score > 0.0"
```

```text
id | score
-------- | --------
1 | 98.50
(1 row)
```

`cyboudb create` makes one profile — tables, secondary indexes, TEXT/BLOB,
vectors, per-row tombstones, queues and streams — and never overwrites an
existing file without `--force`. Mutating statements autocommit; `SELECT` opens
read-only.

`cyboudb demo.cdb` opens an interactive console with multiline queries and
meta-commands (`.tables`, `.schema`, `.indexes`, `.queues`, `.streams`,
`.info`, `.help`). A script piped in on stdin runs the same way and exits
nonzero if any statement failed. `cyboudb info` prints validated metadata and
`cyboudb check` reads every page of every generation.

### Embedding

```c
#include "cyboudb.h"

cyboudb_db *db;  cyboudb_stmt *st;
char buf[256];   uint64_t len;

cyboudb_create("app.cdb", 512, &db);
cyboudb_exec(db, "CREATE TABLE results (id INT64, note TEXT)");
cyboudb_exec(db, "CREATE QUEUE inbox");

cyboudb_exec(db, "BEGIN");
cyboudb_exec(db, "ENQUEUE INTO inbox VALUES ('job')");
cyboudb_exec(db, "INSERT INTO results VALUES (42, 'completed')");
cyboudb_exec(db, "COMMIT");

cyboudb_prepare(db, "SELECT note FROM results WHERE id = 42", &st);
while (cyboudb_step(st) == CybouDB_ROW)
    cyboudb_column_bytes(st, 0, buf, sizeof buf, &len);
cyboudb_finalize(st);                 /* before close, or close returns BUSY */
cyboudb_close(db);
```

Build the library with `sh build.sh --lib` or `build.bat --lib`; the public
declarations and the full contract are in
[include/cyboudb.h](include/cyboudb.h). `cyboudb_step_batch` with
`cyboudb_batch_column` gives borrowed typed columns for bulk reads. Two worked
examples are built and run by CI: [`examples/worker.c`](examples/worker.c), a
worker loop with no broker under it, and
[`examples/vector_search.c`](examples/vector_search.c), filtered exact search
through the standalone vector runtime.

---

## Capabilities

| | |
| :--- | :--- |
| **Relational** | `CREATE`/`DROP TABLE`, multi-row `INSERT`, `UPDATE`, `DELETE`, `SELECT` with projection, 3VL predicates, `ORDER BY`, `LIMIT`/`OFFSET`, `INNER`/`LEFT JOIN` on integer equi-keys. `INT32`, `INT64`, `FLOAT32`, `BOOL`, `TEXT`, `BLOB` |
| **Indexes** | Copy-on-write B+tree on INT32/INT64 columns, unique or not, maintained by every statement that changes the table and used for equality and range lookups |
| **Vector** | `VECTOR(FLOAT32, n)` columns with exact top-K through `ORDER BY <distance> LIMIT k`, scalar and AVX2. No ANN index |
| **Queue** | `CREATE`/`DROP QUEUE`, `ENQUEUE`, `DEQUEUE`. A transactional FIFO in the same file, payloads of any length, pages reclaimed as messages are taken |
| **Stream** | `CREATE`/`DROP STREAM`, `APPEND`, `READ`, `TRIM`, and up to eight named durable cursors per stream. A trim refuses to pass the slowest reader |
| **Transactions** | `BEGIN`/`COMMIT`/`ROLLBACK` across all of the above at once, over copy-on-write staging, with two checksummed superblocks and generation-based recovery. One writer; readers pinned against reclamation |
| **C API** | `libcyboudb.a` / `cyboudb.lib` and one public header, with prepared statements, borrowed batch views and no runtime dependency |
| **Platforms** | Linux x86-64 (raw syscalls) and Windows x64 (kernel32). A file written on one is read by the other, and CI proves it on both |

Format details — PAX layout, span maps, catalog limits, tombstone strategies,
the varlen chain — are in [docs/](#documentation) rather than here.

---

## Where it fits, and where it does not

**A good fit today:** local-first and desktop applications, developer tools,
edge and embedded deployments, automation and background workers, and AI
applications that want embeddings beside the rows they describe rather than in
a second system.

**Not the right fit today:** a server database, any multi-writer workload, a
large concurrent service, ANN-heavy vector search over millions of vectors, an
encrypted database, or ARM64. CybouDB is a library and a command line, not a
daemon, and an advisory lock keeps the second writer out.

---

## Performance without benchmark theatre

CybouDB is not built to win every isolated primitive benchmark, and it does not.
Its advantage is transactional composition; the performance profile that comes
with that is uneven, and both halves are measured and published.

| | against | |
| :--- | :--- | ---: |
| Columnar scan and filter | SQLite | **34.6x faster** |
| Reading projected columns | DuckDB, 1 thread | **4.5x faster** |
| Filtering | DuckDB, 8 threads | 0.55x — DuckDB ahead |
| One durable message, one commit | SQLite WAL | 0.27x — SQLite ahead |
| 100 messages per transaction | SQLite WAL | 0.18x — SQLite ahead |

Read that as a shape, not a scoreboard. Analytical scans over columnar storage
are where hand-written AVX2 kernels earn their keep. A single durable queue
commit is where CybouDB is slowest: it flushes twice — the data pages, then the
publication — where SQLite's WAL appends and flushes once, and CybouDB has no
WAL at all. **Batching changes that cost completely: one message per transaction
is 1,120 us, a hundred per transaction is 20.75 us each.**

Full numbers, method and the failed experiments:
[engines](benchmarks/results/2026-09-13-engines-10m.md) ·
[queue](benchmarks/results/2026-09-13-queue.md).

---

## Status and limitations

The on-disk format, the transaction semantics and the recovery behaviour are
frozen as version 1 and written down in [docs/FORMAT.md](docs/FORMAT.md),
[docs/TRANSACTIONS.md](docs/TRANSACTIONS.md) and
[docs/RECOVERY.md](docs/RECOVERY.md). A newer build reads what an earlier
released build wrote, and `tests/compat_tests.py` holds databases frozen by
each release to keep that sentence true.

Stated rather than implied: no ARM64 backend, no WAL, no second writer, no
encryption, no ANN index, no lease semantics on the queue, and no daemon. A
plan uses an index for an equality or a range over an indexed column and for
nothing else. Compression exists for CONST/FOR runs inside fixed-size slots but
does not yet reduce the file size on disk.

**Known performance limitation:** commit validation currently scales with the
number of retained queue and stream segments, so a deep queue makes each commit
more expensive — 812 us a message at depth 500 against 1,193 us at depth 2,000.
Correctness, crash safety and corruption detection are unaffected; the
workarounds are batching and keeping retained depth bounded with `DEQUEUE` or
`TRIM`. It is measured, the cause is located, and fixing it properly is the
first engine work after this preview.

**CybouDB is not production-ready**, and a preview is a thing to read and try
rather than a thing to run a business on.

---

## Build

Nothing but an assembler and a linker is required.

```sh
sudo apt install nasm binutils     # or dnf / pacman / apk
sh build.sh                        # builds cyboudb
sh build.sh --lib                  # builds build/libcyboudb.a
```

```cmd
build.bat                          rem builds cyboudb.exe
build.bat --lib                    rem builds build\cyboudb.lib
```

`build.bat` locates NASM and a linker on its own — GoLink if present, otherwise
the MSVC toolchain through `vswhere` — so no Developer Command Prompt is
needed. Install NASM with `winget install NASM.NASM`. Release archives are built
by `tools/package.sh` and `tools/package.bat`.

---

## Testing

```sh
sh tests/run_tests.sh              # the binary against healthy and damaged files
```

Over 18,000 automated checks run on Linux and Windows, and CI runs every one of
them on both on every push. Most of the storage suite is about what happens to a
**broken** database — a bad checksum, a foreign file, a destroyed superblock
copy, a truncated file — because that is where a storage engine is actually
judged. Beyond it: fault injection on COW pages and syncs, exhaustive predicate
kernels checked scalar against AVX2, a hardware CRC oracle, crash tests that put
a committed file's publication back and demand the old state entire, an
out-of-tree application compiled against only the published package, and a lint
that reads every `.asm` file for arguments passed in the wrong register on one
ABI but not the other.

The suites and what each one covers are listed in
[docs/TESTING.md](docs/TESTING.md).

---

## Documentation

* **[ARCHITECTURE.md](ARCHITECTURE.md)** — the design: layering, the on-disk
  format, the commit protocol and the allocator.
* **[CHANGELOG.md](CHANGELOG.md)** — what is in each release.
* **[ROADMAP.md](ROADMAP.md)** — the phases, and what is actually done.
* **[docs/FORMAT.md](docs/FORMAT.md)** — the on-disk format, version 1, and the
  compatibility promise that goes with it.
* **[docs/TRANSACTIONS.md](docs/TRANSACTIONS.md)** — what a transaction is, the
  commit protocol, and what a failed commit leaves behind.
* **[docs/RECOVERY.md](docs/RECOVERY.md)** — how opening a database selects a
  generation, and what survives a crash.
* **[docs/SQL.md](docs/SQL.md)** — dialect, syntax, 3VL logic, error domains
  and limits.
* **[docs/INDEX.md](docs/INDEX.md)** — secondary B+tree indexes.
* **[docs/QUEUE.md](docs/QUEUE.md)** — durable FIFO queues, what `DEQUEUE` does
  and does not promise, and what is reserved for leases.
* **[docs/STREAM.md](docs/STREAM.md)** — append-only streams, why a stream is
  not a queue with extra readers, and what a trim may not pass.
* **[docs/VARLEN.md](docs/VARLEN.md)** — the TEXT/BLOB extent chain.
* **[docs/TESTING.md](docs/TESTING.md)** — every test suite and what it proves.
* Storage internals: [COW](docs/COW.md) · [CATALOG](docs/CATALOG.md) ·
  [PAX](docs/PAX.md) · [PAX_MULTI](docs/PAX_MULTI.md) ·
  [SPAN_MAP](docs/SPAN_MAP.md) · [COMPRESSION](docs/COMPRESSION.md) ·
  [HARDENING](docs/HARDENING.md).

---

## Licence

Apache-2.0. See [LICENSE](LICENSE).
