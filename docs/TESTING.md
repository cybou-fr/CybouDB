# Testing

Every suite listed here runs in CI on both Linux and Windows, on every push,
and the two jobs run the same tests. Over 18,000 automated checks in total.

This file is the manifest the README used to carry. It is written for someone
working on the engine: what each suite drives, and what it would catch.

## Storage and CLI Tests

```sh
sh tests/run_tests.sh
```

Runs the built binary against healthy and deliberately damaged databases and
checks both the exit code and the output. The same script runs on Linux and,
through Git Bash, on Windows. It needs `python3` for `tests/corrupt.py`, which
produces damaged files.

It has two halves. The first drives the canonical `create` - the profile the
command line and `cyboudb_create` actually make - through a database's whole
life: create, check, a table, an index, a queue, a stream, a TEXT row, a DELETE
that proves the tombstone reservation, and the refusals (too few pages, a file
already there, a flag that no longer exists).

The second drives `create-legacy`, which is the pre-COW allocator, and that is
deliberate: those tests are about free lists, in-place mutation and the damage
a file can take, and they need a storage mode that still has a free list. Most
of that half is about what happens to a **broken** database - a bad checksum, a
foreign file, an unsupported version, a destroyed superblock copy, a truncated
file, a corrupt free list. Two cases assert the opposite: that the format
survives losing one superblock copy, and that the newer generation wins.

## Core and Fault-Injection Tests

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

## SQL and Kernel Test Suites

Built with `--sql-tests` (`build/sql_harness`) and `--kernel-tests` (`build/kernel_harness`):

* `tests/sql_tests.py`: 242 end-to-end SQL integration and boundary tests
  covering `CREATE TABLE`, `INSERT INTO`, `SELECT`, expressions, precedence,
  constraints, and rollbacks.
* `tests/sql_api_tests.py`: 193 contract tests verifying error domains, source
  locations, MXCSR preservation, prepared plan fast-path contracts and fallbacks,
  and float literal conversions against an independent rational oracle.
* `tests/sql_pruning_tests.py`: 36 tests verifying required-column pruning and physical layout access.
* `tests/sql_sink_tests.py`: 69 tests covering scalar and batch row delivery.
* `tests/kernel_tests.py`: 13,181 exhaustive predicate kernel tests across all
  comparison operators, types, and NULL permutations, run once per dispatch
  mode so the AVX2 and scalar paths are checked against each other.

## Hardware Optimization Tests

Built with `--hardware-tests` (`build/hardware_harness`):

* `tests/hardware_tests.py`: 3,670 oracle test cases verifying hardware SSE4.2 CRC-32C against reference scalar CRC-32C across buffer sizes (0..8180 bytes) and byte alignments, plus BMI2 `pext`, `pdep`, `bzhi`, and NULL mask compaction routines with bit-for-bit scalar fallbacks.

## Queue, Stream and Cross-Primitive Tests

Built with `--c-tests`:

* `tests/queue_sql_tests.py` (65) and `tests/queue_page_test.c` (75): the queue
  page and its validation at both depths, the shared namespace, segment
  boundaries, and four hundred round trips of a two-page message through a file
  too small to survive a leak.
* `tests/stream_sql_tests.py` (103) and `tests/stream_page_test.c` (63): the
  stream page and its cursors, the type boundary against queues, `APPEND`,
  `READ`, `TRIM`, and the cursor table read back off the disk.
* `tests/queue_api_test.c` (23) and `tests/stream_api_test.c` (30): a message
  and a record through the C ABI, including a buffer too small being refused
  rather than filled.
* `tests/cross_primitive_test.c` (48): one transaction over a table, its index,
  a queue and a stream - committed, rolled back, and failing in the middle.
* `tests/cross_primitive_crash_tests.py` (17): the same transaction, crashed.
  A committed file has its publication put back while every staged page stays
  on the disk - what a machine that lost power between the data sync and the
  publication is left holding - and a reader must find the old state entire.
  Also a torn newest superblock, one that never reached the platter, and the
  mirror case where the *older* copy is the damaged one and the committed
  transaction has to survive. The invariant is that every outcome is wholly
  old or wholly new: never a message taken with no row to show for it.

## Compatibility and packaging

* `tests/compat_tests.py` (29): databases frozen by each released build, under
  `tests/compat/<version>/`, gzipped and base64-encoded because the repository
  holds text. Each is checked with `cyboudb check`, read back cell by cell -
  rows that survived a `DELETE`, a TEXT value, a vector still searchable, the
  message still waiting on a queue, the record a stream cursor has not reached
  - and then written to on a copy, because a database you can only read is not
  compatible in any useful sense. The fixtures are never regenerated: rebuilt
  with the current engine they would only prove it can read itself.
* `tests/package_consumer.c`: an application compiled in a directory holding
  only what a release ships - `cyboudb.h` and the static library - so that a
  public header including a private one, or a missing exported symbol, fails in
  CI rather than for the first person who downloads the package.

## Attacking the validator

* `tests/validator_attack_test.c` (18): not "is this damage noticed" but "can
  the reasoning be made to reach a false conclusion". Incremental commit
  validation claims that a base proof plus a registered delta is a valid
  candidate proof, so the cases worth writing are the ones where every part
  looks right and the conclusion is still wrong. It found one: a transaction
  could retire a page an inherited object still reached, with the transition
  registered exactly as the engine registers its own and every checksum
  verifying. Each case has its opposite beside it - a retire of a page nothing
  reaches any more must still commit - because a rule that refuses everything
  is not a rule.

  And the page that cannot say who owns it: a continuation page of a
  multi-page run, retired on its own. Both halves are asserted - the commit
  accepts it, the integrity check refuses the result - because asserting only
  that the commit does not catch it would be recording a gap rather than
  testing a guarantee.

  It also forges the change-set itself through `cs_record`, which is the
  only way to attack a structure nothing outside the engine can reach. That
  is the point: the log is part of what a commit trusts now, so a mutation
  recording the wrong transition has to end as a refused commit rather than
  a published one.

* `sh build.sh --cs-overflow` builds with a change-set too small to hold a
  transaction, so the path taken when the log cannot be trusted is one the
  suites walk rather than one nobody reaches. Inheritance has to switch itself
  off there: with the log overflowing, segment visits per commit go back to
  33.42 at depth 2,000 from 1.00, and every suite still passes.

## Integrity, as distinct from recovery

* `tests/integrity_tests.py` (7): a damaged newest generation. An ordinary
  open must still work, on the generation before it, because that is what
  recovery is for; `cyboudb check` must refuse the same file and say it is
  damaged. Before `check` was made integrity-aware it reported `Status: OK`
  here - it was answering "a valid state can be recovered" while looking like
  it answered "this file is healthy". The suite also restores the damaged byte
  and requires the answer to go back, so the damage is provably what changed
  it. See [RECOVERY.md](RECOVERY.md).

## The range a commit flushes

* `tests/flush_range_tests.py` (2): a commit hands the kernel what it wrote and
  not everything between its ends. The interesting case is the second: the same
  database past the point where the file reaches its high-water and the
  allocator starts reusing pages from the bottom, which is where the old hull
  fell off a cliff - 7,999 pages flushed to publish a change of a few. The
  first case is the control, because a regression that always flushed
  everything would otherwise fail only one of them and look like noise. It runs
  in under a second and it fails on the previous engine, which is the only
  reason to keep it.

## The change-set audit

```sh
sh build.sh --audit          # build/cyboudb_audit
```

Builds the ordinary command line with `CybouDB_AUDIT_CHANGESET`, which makes
every commit prove that the transaction's change-set explains every difference
between the published allocation map and the staged one. A mutation that
reaches a page without registering is refused as an inconsistent staged map.

It is not a shipped build - the check walks both maps in full, which is the
cost that `0.5.0-preview.2` exists to remove. Its purpose is that any suite run
against this binary becomes a test of whether the change-set is complete, so
there is no separate suite to maintain:

```sh
sh tests/run_tests.sh ./build/cyboudb_audit
python3 tests/queue_sql_tests.py ./build/cyboudb_audit      # and the rest
```

See [COMMIT_VALIDATION.md](COMMIT_VALIDATION.md).

## The eight bytes a lease clock will want

`tests/queue_page_test.c` gained one damage case, and it is there for a reason
that has nothing to do with today's engine: a queue page whose bytes at offset
120 are not zero is refused.

Nothing writes there. The field is where a lease clock's high-water will go -
see [docs/QUEUE.md](QUEUE.md), *The clock a lease deadline is measured on* -
and until `QUEUE_LEASES` exists it must be zero. The check is not defending
against a failure that happens; it is making a later release possible. A field
that nothing *requires* to be zero is a field the version that starts writing
it cannot use, because it has no way to tell a file that left the field alone
from one that meant something by it.

These eight bytes were unnamed and unchecked through both `0.5` previews. Every
file either of them wrote has them zero - a queue page is allocated zeroed -
which is why the check can be added now without breaking anything, and the
frozen fixtures from both releases are what says so rather than the argument.
A year from now that would not have been true.

## Values that arrive after prepare

`tests/bind_test.c`, 77 checks, built with `--c-tests` and run against a
`create-large` database. A `?` is a hole in a statement, and the suite is
organised around what happens at the edges of the hole rather than in it.

Three claims, kept apart on purpose:

1. **The value gets there.** Every bindable kind - INT32, INT64, FLOAT32, BOOL,
   TEXT, BLOB, VECTOR and NULL - goes in through a bind and comes back out of
   the table as itself.

2. **The plan does not change.** The same prepared statement is bound, stepped,
   reset, bound to something else and stepped again, and both rows have to be
   the values they were bound to rather than one of them being the other's.
   This is `tests/prepared_rerun_test.c`'s argument with a value axis added: the
   rule it defends is the one in `include/sql.inc`, that a prepared plan is
   immutable across executions, and a parameter is the most obvious thing that
   would break it.

3. **What is refused is refused at the call.** A wrong type, an index that is
   not there, a NULL into a `NOT NULL` column, a vector of the wrong width, a
   negative length, a length with no pointer, a null handle, and a value too
   large for the copy buffer - each of those is an error from the bind rather
   than a surprise halfway through an insert, and the statement is still usable
   afterwards. A parameter nobody bound stops the statement and writes no row.

The engine copies the bytes of variable-width values rather than keeping the
caller's pointer, so every varlen case here **overwrites or frees the source
buffer between the bind and the step**. Had the pointer been kept, those checks
would read freed memory - which is the failure the copy exists to make
impossible, and the reason it is worth the copy.

Clearing has its own small group, and the check that matters there is eight
binds of 30 KiB each through a 32 KiB buffer: it passes only if a cleared
parameter actually gives its bytes back, and fails on the second bind if
`cyboudb_clear_bindings` merely marks slots unbound.

**The zone gate is the one worth reading the code for.** A bound predicate and
the literal it stands for have to be the same question all the way down, and
comparing the rows they return only proves the answer. So the suite reads the
engine's own pruning counters - `sql_zone_leaf_total`, `_none`, `_all`,
`_unknown` - around each form and requires all four to match. A bound predicate
that had lost its pruning would still return the right rows, and would read the
table to do it; nothing about the result would say so.

It is guarded against being vacuous, which is the failure mode this kind of
check usually has: before comparing, it requires the *literal* query to have
looked at more than one leaf and skipped at least one. Ten rows would be a
single leaf, and two queries that both look at one leaf agree about pruning
while proving nothing - so `b_pred` holds four thousand rows.

The last two checks are the loop the feature is for: two thousand binds and
steps with lengths that grow and shrink, against a 32 KiB buffer. A slot reuses
the bytes it already owns when the new value fits, so the buffer cursor stops
moving once each slot has held its largest value. Without that, 2,000 rounds of
up to 512 bytes would be sixty times the buffer and the run would end in
`CybouDB_NOMEM`.

## Argument register lint

* `tests/abi_arg_lint.py`: reads every `.asm` file for the one mistake this
  project keeps making - an argument register read after something else has
  taken it, in either direction. ARG1..ARG6 are different machine registers on
  Win64 and System V, so the bug reads correctly on one platform and passes the
  wrong value on the other. Seven such bugs were found by failing tests before
  the lint existed; it has caught six since, two of them already in the tree and
  live on Windows.
