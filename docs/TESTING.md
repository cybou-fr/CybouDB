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

## Argument register lint

* `tests/abi_arg_lint.py`: reads every `.asm` file for the one mistake this
  project keeps making - an argument register read after something else has
  taken it, in either direction. ARG1..ARG6 are different machine registers on
  Win64 and System V, so the bug reads correctly on one platform and passes the
  wrong value on the other. Seven such bugs were found by failing tests before
  the lint existed; it has caught six since, two of them already in the tree and
  live on Windows.
