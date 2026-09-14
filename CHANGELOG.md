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
file only restates it. The promise is attached to the format version rather than
the product version, so it does not lapse at 0.6 or at 1.0, and
`tests/compat_tests.py` holds a release to it against databases frozen by every
earlier one.

A change to the format version itself would be announced on its own, with a
migration path, and is not something a minor release does quietly.

## [Unreleased]

### Parameter binding

`INSERT ... VALUES` and `WHERE` comparisons take `?` placeholders, and ten new
C functions supply
their values: `cyboudb_bind_int32`, `_int64`, `_float`, `_bool`, `_text`,
`_blob`, `_vector_f32`, `_null`, `cyboudb_bind_parameter_count`, and
`cyboudb_clear_bindings`.

The three lifetime verbs are separable on purpose - `cyboudb_reset` clears what
an execution did and keeps the bindings, `cyboudb_clear_bindings` clears the
bindings and keeps the statement, `cyboudb_finalize` destroys both. Without the
middle one the only way back to unbound is to prepare again, which is a strange
thing to have to do to a statement that is otherwise fine. Cheap to add now and
an argument after 1.0.

This is additive. No existing function changed, the on-disk format is untouched
and still version 1, and a statement without a `?` behaves and costs exactly
what it did.

Three decisions worth stating, because each one could have gone the other way:

- **The engine copies the bytes** of TEXT, BLOB and VECTOR values. The cheaper
  alternative - keeping the caller's pointer, as `SQLITE_STATIC` does - makes
  the lifetime of the caller's buffer part of this library's contract, and the
  failure when that contract is broken is a use-after-free at commit. Copying
  turns it into `CybouDB_NOMEM` at the call. The buffer is 32 KiB per statement
  and a parameter re-bound to something that fits what it already holds reuses
  those bytes, so binding in a loop does not exhaust it.

- **A bound value is never written into the plan.** It is applied at execution,
  over the values restored from the binder's pristine copy. That keeps the rule
  `include/sql.inc` has held since the prepared-statement work: a prepared plan
  is what prepare produced, across every execution. Bindings survive
  `cyboudb_reset`.

- **Each bind names the type it is for and refuses any other**, rather than
  converting. What gets stored should not depend on which function the caller
  reached for. A parameter nobody bound stops the statement; it does not
  quietly become NULL.

A predicate parameter is applied per execution, over the zero the binder left
in the bound expression node, so the plan still holds no value. The kernel was
never the problem - `sql_kernel_resolve` picks from the column's physical type
and never from the literal's - and zone pruning already read the literal when it
ran rather than when the plan was built. What does not yet work is an index
seek: its key bounds are arithmetic on the literal done at bind time, so a
parameterised predicate declines the seek and scans with zone pruning instead.
Correct, and slower than it should be; recomputing the bounds per execution is
named in `ROADMAP.md` rather than left implied.

`?` is accepted in `INSERT ... VALUES` and on the value side of a `WHERE`
comparison. Anywhere else it is a syntax error that says so.

`tests/bind_test.c` (77 checks) runs on both platforms in CI. Its gate compares
the engine's zone-pruning counters between a bound predicate and the literal
one, not just the rows: a bound predicate that lost its pruning would still
answer correctly and read the whole table to do it.

## [0.5.0-preview.2] - 2026-09-14

One thing, and it is not a feature: **a commit proves the transition from the
generation already validated to the one being published, instead of proving
the retained graph again.**

The on-disk format is unchanged and still version 1. Databases written by
`0.5.0-preview.1` open and are written to; `tests/compat_tests.py` holds this
release to that against the fixtures that release froze. No SQL changed, no C
ABI changed, nothing was added to the command line.

### The change

An `ENQUEUE` changes one slot in one segment. The commit used to walk every
retained segment to prove what it published - 2.14 segment visits at queue
depth 0 and 163.41 at depth 10,000. It now visits **one, at every depth**,
and does the same for a stream `APPEND`.

The licence to skip is copy-on-write: a page the engine did not rewrite has
the content it had when the commit that published it proved it. An object
whose directory entry has not moved is inherited whole; inside an object the
transaction did touch, entries that name the same page at the same position
are inherited and the rest are validated. `cyboudb check` inherits nothing and
still proves every page.

Validation time at depth 10,000 went from 115.7 us to 31.7 us on Linux. That
is the honest size of it, and the honest limit is this: the two durability
barriers are 99% of a commit on the hardware measured, they were not touched,
and a deep queue is still slow to commit. What this removes is the part of the
cost that grew with what the database had kept, not the cost.
[benchmarks/results/2026-09-14-preview2-final.md](benchmarks/results/2026-09-14-preview2-final.md)
has the numbers, both platforms, with the previous behaviour beside them.

### Changed: what `cyboudb check` answers

**`cyboudb check` now exits non-zero on a file it used to call `Status: OK`.**

It was an ordinary open with deep verification, and an ordinary open recovers:
when the newest generation did not validate it fell back to the one before and
reported success. So a damaged newest generation was reported as healthy -
exactly the case where someone needs to be told, since the database keeps
working on the older state.

`check` now asks about integrity rather than recoverability. A superblock
whose own checksum verifies while the graph it published does not is reported
as damage. A torn superblock is not: it fails its own checksum, it is the
ordinary residue of an interrupted publication, and it still reports `OK`.

**Nothing about an ordinary open changed.** It still selects the newest valid
generation, still falls back, still reports success. Scripts that treat a
non-zero `check` as "this file is unusable" should read it as "this file is
damaged, and an ordinary open would quietly use an older generation" - which
is a different and more useful statement. See
[docs/RECOVERY.md](docs/RECOVERY.md).

### Changed: what a commit catches

A commit no longer reads into an object it did not touch, so damage to a page
an earlier generation wrote is no longer refused at commit time. That was the
queue's behaviour alone; every other object type has worked this way since
`db_bitmap_deep`. `cyboudb check` is what reports that damage now, and the
change was only made after `check` was able to.

### Fixed

- A commit could retire a page that an inherited object still reached, with
  the transition registered and every checksum verifying - the candidate then
  said both "this object reaches page X" and "page X is retired". Introduced
  by proof inheritance during this cycle and found by
  `tests/validator_attack_test.c`, which attacks the reasoning rather than the
  bytes.
- An overflowed change-set no longer permits inheritance anywhere. It is the
  record of what a transaction did; an incomplete one proves nothing, and the
  commit takes the long proof instead.
- `tools/package.bat` wrote its checksum line with CRLF, so `sha256sum -c`
  looked for a file whose name ended in a carriage return. The sums were
  right; only verifying them was broken.

### Testing

Over 18,000 automated checks on Linux and Windows, and three builds of the
engine in CI rather than one: the ordinary build, `--audit` (every commit
proves the change-set complete against an exhaustive map walk), and
`--cs-overflow` (a change-set too small to hold a transaction, so the fallback
taken when the log cannot be trusted is a path the suites walk). New suites:
`tests/validator_attack_test.c` and `tests/integrity_tests.py`. The manifest
is [docs/TESTING.md](docs/TESTING.md); the design and its limits are
[docs/COMMIT_VALIDATION.md](docs/COMMIT_VALIDATION.md).

### Still open

The flush grows with the size of the file, and is now the larger term in a
commit - found by the instrumentation this cycle added, and not addressed.
No ARM64, no WAL, no second writer, no encryption, no ANN index, no queue
leases, no daemon.

## [0.5.0-preview.1] - 2026-09-14

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
- **Command line**: `create`, `query`, `console`, `info`, `check`, `version` -
  that is the whole user-facing surface. `cyboudb create` and `cyboudb_create`
  make the same canonical profile. The creators for each stage the format grew
  through still exist for the test suites - `create-legacy` and the rest - and
  so do `alloc` and `free`, which are the pre-COW allocator's controls; none of
  them are in `--help`, because choosing among them is choosing which features
  to do without.
- **Interactive console** with `.schema`, `.tables`, `.indexes`, `.queues`,
  `.streams` and piped-script support.

### Not in this release

Stated rather than left to be inferred: no ARM64 backend, no WAL, no second
writer, no encryption, no ANN index, no queue leases, and no daemon - CybouDB is
a library and a command line, not a server. `TEXT` columns cannot be indexed and
an index covers one column.

### Known performance limitation

*(Fixed in 0.5.0-preview.2. Kept as written, because a release note is a record
of what was true when it shipped.)*

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

The measurement that followed corrected one thing in this paragraph: the walk
is a real term and removing it is a real change, but it was 2.4% of a commit on
Linux and 6.1% on Windows. 93% of a commit's growth with depth was the flush.

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
