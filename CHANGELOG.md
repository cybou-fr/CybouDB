# Changelog

All notable changes to CybouDB are recorded here. Versions follow
[semantic versioning](https://semver.org/); until 1.0 the minor number moves
when the public C ABI or the SQL surface changes.

The **on-disk format version is separate from the product version** and moves
much more slowly. Format version 1 is frozen, and the compatibility promise runs
in one direction only:

- **A newer release reads a file written by an older one.** A build that
  supports format v1 opens anything an earlier released 0.x build wrote.
- **An older binary is not guaranteed to open a newer file.** New capabilities
  arrive as new `flags_incompat` bits, and a reader that does not know a bit is
  *required* to refuse the file rather than guess at it. That refusal is the
  format working as designed, not a compatibility break - guessing is how a
  storage engine loses data quietly.

Concretely: `INDEX` (8192), `QUEUE` (16384) and `STREAM` (32768) are bits that
did not exist in every earlier build, so a database using them does not open in
one that predates them. See
[docs/FORMAT.md](docs/FORMAT.md#compatibility-promise), which is normative; this
file only restates it.

A change to the format version itself would be announced on its own, with a
migration path, and is not something a minor release does quietly.

## [0.5.0-preview.1] - unreleased

The first release. What follows is what exists rather than what changed, since
there is nothing before it to have changed from.

### The engine

- **On-disk format v1**, frozen and specified in [docs/FORMAT.md](docs/FORMAT.md):
  4 KiB pages, two checksummed superblocks, generation-based recovery, CRC-32C
  over every page a generation reaches. A file written on Linux is read on
  Windows and the other way round.
- **Copy-on-write transactions**. A commit is one superblock publication and
  there is no third outcome a reader can observe. Rollback writes nothing.
  One writer, enforced by an advisory lock; readers are pinned against page
  reuse. See [docs/TRANSACTIONS.md](docs/TRANSACTIONS.md).
- **PAX columnar storage**, up to 28M rows per table through a two-level
  directory, with zone maps, run encoding, NULL masks and a compaction path for
  `DELETE`.
- **Secondary B+tree indexes** on INT32/INT64 columns, unique or not,
  maintained by every statement that changes a table, and used for an equality
  or a range over an indexed column.
- **TEXT and BLOB** through a varlen extent chain, and **VECTOR(FLOAT32, n)**
  columns with exact top-K search in both distance directions, scalar and AVX2.
- **Durable queues**: `CREATE QUEUE`, `ENQUEUE`, `DEQUEUE`, `DROP QUEUE`. A
  transactional FIFO in the same file. What a take does and does not promise is
  spelled out in [docs/QUEUE.md](docs/QUEUE.md); lease semantics are reserved in
  the format and not implemented.
- **Append-only streams**: `CREATE STREAM`, `APPEND`, up to eight named durable
  cursors per stream, `READ FROM s AS reader`, and `TRIM STREAM s BEFORE p`,
  which refuses to pass the slowest reader. See [docs/STREAM.md](docs/STREAM.md).
- **One transaction over all of them.** A table, its index, a queue and a stream
  share a file, an allocation map and a commit, so taking a message, writing the
  row it was for and appending an audit record are atomic together, so no outbox
  is needed between primitives inside the same `.cdb`. An external system is
  separate again. It holds across a crash as well as a rollback: after power
  loss a reader finds the whole old state or the whole new one, never a message
  taken with no row to show for it.

### Interfaces

- **C library** (`cyboudb.h` with `libcyboudb.a` / `cyboudb.lib`):
  `cyboudb_create`, `cyboudb_open`, prepare/step/finalize, borrowed typed batch
  views, `cyboudb_message` for a dequeued message or a stream record.
  `cyboudb_create` makes the canonical profile - everything `create-large` has
  plus the per-row tombstone reservation, which can only be made when the file
  is created and is what lets `DELETE` mark rows instead of rewriting the table.
- **Command line**: `create`, `query`, `info`, `check`, `alloc`, `free`,
  `version`. `cyboudb create` and `cyboudb_create` make the same canonical
  profile. The creators for each stage the format grew through still exist for
  the test suites - `create-legacy` and the rest - and are not in `--help`,
  because choosing among them is choosing which features to do without.
- **Interactive console** with `.schema`, `.tables`, `.indexes`, `.queues`,
  `.streams` and piped-script support.

### Not in this release

Stated rather than left to be inferred: no ARM64 backend, no WAL, no second
writer, no encryption, no ANN index, no queue leases, and no daemon - CybouDB is
a library and a command line, not a server. `TEXT` columns cannot be indexed and
an index covers one column.

### Known performance limitation

Commit validation scales with the number of retained queue and stream segments.
Enqueueing one message per transaction costs 812 us at a queue depth of 500 and
1,193 us at 2,000, where every SQLite configuration measured stays flat.
Correctness, crash safety and corruption detection are unaffected - the commit
still proves the whole staged graph, which is exactly why it costs what it does.

Two workarounds, both effective: batch, which takes a message from 1,120 us to
20.75 us at a hundred per transaction; and keep retained depth bounded with
`DEQUEUE` or `TRIM`. Measured in
[benchmarks/results/2026-09-13-queue.md](benchmarks/results/2026-09-13-queue.md),
cause located, and the proper fix - incremental validation - is the first engine
work after this preview.

### Testing

Over 18,000 automated checks, every one run by CI on Linux and Windows on every
push. The suites are listed under **Test** in [README.md](README.md).

Two of them exist for the promises this file makes. `tests/compat_tests.py`
opens databases frozen by each released build - under `tests/compat/` - runs
`cyboudb check` over them, reads back the rows, the TEXT, BLOB and VECTOR
cells, the message still waiting on a queue and the record a stream cursor has
not reached, and then writes to a copy. `tests/package_consumer.c` is compiled
in a directory holding only what a release ships, so that "the library links"
is tested rather than assumed.

---

CybouDB is not production-ready. A preview is a thing to read and try.
