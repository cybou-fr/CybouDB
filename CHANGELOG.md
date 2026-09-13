# Changelog

All notable changes to CybouDB are recorded here. Versions follow
[semantic versioning](https://semver.org/); until 1.0 the minor number moves
when the public C ABI or the SQL surface changes.

The **on-disk format version is separate from the product version** and moves
much more slowly. Format version 1 is frozen: a database written by any 0.x
build is readable by every other one. A format change would be announced on its
own, with a migration path, and is not something a minor release does quietly.

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
  row it was for and appending an audit record are atomic together. This is why
  the outbox pattern is not needed here.

### Interfaces

- **C library** (`cyboudb.h` with `libcyboudb.a` / `cyboudb.lib`):
  `cyboudb_create`, `cyboudb_open`, prepare/step/finalize, borrowed typed batch
  views, `cyboudb_message` for a dequeued message or a stream record.
- **Command line**: `create-*`, `query`, `info`, `check`, `alloc`, `free`,
  `version`.
- **Interactive console** with `.schema`, `.tables`, `.indexes`, `.queues`,
  `.streams` and piped-script support.

### Not in this release

Stated rather than left to be inferred: no ARM64 backend, no WAL, no second
writer, no encryption, no ANN index, no queue leases, and no daemon - CybouDB is
a library and a command line, not a server. `TEXT` columns cannot be indexed and
an index covers one column.

### Testing

Over 18,000 automated checks, every one run by CI on Linux and Windows on every
push. The suites are listed under **Test** in [README.md](README.md).

---

CybouDB is not production-ready. A preview is a thing to read and try.
