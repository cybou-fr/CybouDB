# Hardening work from the September 2026 review

Baseline: `ef293296831850fe20db22a6cddb1b3fcf88812c`.
Complete contract and lifetime fixes before adding SQL features or freezing
the public ABI. Review claims about benchmark results are not new measurements.

## Implemented: REPL input and script status

- Reject oversized physical lines and accumulated statements before executing
  truncated input. Current recovery policy is to stop the session with status
  1, rather than discard through a semicolon and resume. Earlier commits remain.
- Reject incomplete Windows console chunks instead of inserting a newline into
  a partial physical line. Console chunk assembly remains future work.
- Preserve SQL failures across subsequent successful statements and `.quit`;
  piped scripts return status 1, interactive SQL error recovery remains intact.
- Regression coverage: line limits 4095/4096/4097 with LF, CRLF and EOF;
  statement sizes 262143/262144/262145; rejected INSERT persistence; recovery
  after SQL error and failure in an unterminated EOF statement.

Validation: Windows and Linux builds; 37 REPL tests on each binary; Linux base
suite 59 passed, with the unreadable-file permission check skipped on the
Windows-mounted filesystem. Native interactive console behavior has not been
tested with an actual terminal.

## Remaining implementation and release gates

- [x] Add CPUID-dispatched POPCNT with a scalar fallback; exercise both paths.
- [x] Preserve AVX2 active/non-NULL lane read guarantees; add guard-page tests
      for sparse, tail and NULL lanes across all supported types.
- [x] Expose batch columns in result projection order, including reordered and
      duplicate projections; keep physical storage details internal or provide
      an explicit public mapping accessor.
- [x] Track live statements and return CybouDB_BUSY from close until finalized.
- [x] Copy result names, types and projection mapping into statement-owned
      storage; test metadata after COW mutations.
- [x] Replace the fixed statement arena with growable storage, preserving AST
      pointer validity; test the documented maximum INSERT dimensions and OOM.
- [x] Resolve cyboudb_exec callback and statement-count contract, update header,
      implementation, callers and tests together before considering an ABI tag.
- [x] Repeat the two-table sharing benchmark before changing allocation policy.
- [x] Run the 10M SQLite/scalar/AVX2 comparison with checksums, COUNT(*) and
      projection widths 1/3/7; retain environment and reproduction commands.
- [x] Reconcile README, ROADMAP and benchmark documentation with measured and
      implemented behavior; distinguish optional phase extensions.
- [x] Run full platform suites and review ABI compatibility before an alpha tag.

No release tag or benchmark claim is established by the initial REPL patch.

## Implemented: CPU portability and kernel read contract

`cyboudb_popcount64` selects POPCNT using CPUID leaf 1 ECX bit 23, otherwise uses
an integer SWAR fallback. Executor, C API and benchmark counts all call this
primitive. Tests force the fallback independently of host CPU capabilities,
including a prepared COUNT(*) reset through the C API.

INT32, INT64 and FLOAT32 kernels use full loads only for fully valid vector
chunks, and integer masked loads for sparse or tail chunks. BOOL kernels use
scalar fallback if either nonempty 32-byte chunk is partially valid.

The kernel harness reserves three pages and marks both outer pages inaccessible
with mprotect or VirtualProtect. Tests place all possible lane boundaries at
either edge, with inactive and NULL lanes inside the inaccessible pages.
The original AVX2 implementation faults on the first new guard-page case;
the corrected implementation passes 10436 cases per dispatch mode (automatic
and forced scalar) on both Windows and Linux. CI now runs both modes.

Hardware oracle suite: 3670 cases on each platform. SQL API suite: 193 on each;
C API: five groups on each, including forced fallback counting. Local host
supports AVX2 and POPCNT; a physical CPU without POPCNT has not been tested.
New throughput measurements remain pending.

## Implemented: C API projection and lifetime contracts

`cyboudb_batch_column(stmt, batch, result_col)` maps logical SELECT indices to
physical zero-copy column views, including repeated columns. The public batch
layout is unchanged. COUNT(*) batch stepping now returns one INT64 aggregate
row, including zero for empty selections, instead of batches of source rows.
Successful calls returning DONE clear the batch pointer and selection mask.

Connections count successfully prepared statements. Close returns CybouDB_BUSY
with a diagnostic until all statements are finalized; reset and exhaustion
retain ownership. Failed prepares do not retain a reference. Connection and
statement calls require caller serialization; this is not concurrent access
support.

Result names, types and physical projection indices are copied into statement
storage at prepare time. Name pointers remain stable through reset and COW
mutations until finalize. CREATE and INSERT report zero result columns.
Prepare error copying is bounded by the actual 72-byte error message buffer,
fixing a stack over-read in the earlier 256-byte copy.

Validation: nine C API test groups pass on Windows and Linux, covering reordered
and duplicate projections, all 64 result columns with 23-byte names, aggregate
batch reset, NULLs, invalid indices, busy-close recovery, parse/bind failures,
and metadata after 40 COW inserts. The ABI is not frozen.

## Implemented: growing statements and single-statement exec

The arena descriptor records allocation failure independently of SQL error
codes, so missing PAX storage or malformed SQL cannot trigger spurious growth.
Prepare starts with 32 KiB, frees an exhausted temporary graph, doubles the
allocation and repeats parse/bind. Growth stops on successful binding or OS
allocation failure; no SQL mutation occurs during retries. Published handles
are never moved, and finalize frees the actual allocation length. Arena size
arithmetic and allocation doubling check integer overflow.

The public signature is now `cyboudb_exec(cyboudb_db *db, const char *sql)`: execute
one statement, discard rows, and always finalize the temporary statement.
The former callback type and arguments were removed; this is a source API
change before ABI freeze. Applications consuming rows use prepare/step or
step_batch. Multiple statements are rejected during prepare, before mutation.

Eleven C API test groups pass on Windows and Linux. The maximum 256-by-64
INSERT is verified cell by cell, including NULLs and reset before execution.
Allocation injection fails every growth allocation in turn, checks CybouDB_NOMEM,
NULL output handles, diagnostic messages, balanced allocations and successful
connection close. A syntax error after growth frees temporary storage without
damaging an existing prepared statement. Exec tests cover discarded rows,
aggregates, parse/bind/step failures, OOM and rejected multi-statement mutation.
Fault injection exists only in --c-tests; --lib uses native OS allocation.

Shared arena regression checks on both platforms: SQL API 193, sink 69,
pruning 36, REPL 37 passed. Linux base suite: 59 passed (one filesystem
permission check skipped).

## Completed: verification runs and performance measurements

1. **Shared-file layout benchmark**: repeated with `run_layout_benchmarks.py`
   using original fixtures (`events.cyboudb`, `wide.cyboudb`, `shared.cyboudb`). Mode 0
   (filter) and Mode 1 (materialize) on 112,384 rows show shared/alone ratios of
   0.94x-1.03x (~1.0x parity), with bit-for-bit identical materialized checksums.
   The historical slowdown was resolved by prepared-plan catalog validation fast paths.
   Raw metrics: `benchmarks/results/2026-09-09-layout.json`.

2. **10,000,000-row out-of-cache comparison**: repeated across 3 independent
   runs with rotating engine order via `run_sqlite_benchmarks.py`. All 13 scenarios
   verified bit-for-bit checksum parity (`MATCH`) across SQLite, CybouDB Scalar, and
   CybouDB AVX2. AVX2 achieved 16x-31x speedups over SQLite on filtered/materialized
   scenarios, 1.0x-2.7x speedups over CybouDB Scalar, and 1.06x on unpredicated count(*).
   Raw log: `benchmarks/results/2026-09-09-hardening-10m.txt`.

3. **Full platform test suite**:
   - Storage/CLI suite: 59 passed
   - Core & COW test suites (bitmap, catalog, PAX, multi-PAX, span, numeric): passed
   - SQL suites (API 193, pruning 36, sink 69): 298 passed
   - Kernel SIMD & scalar guard-page suites: 20,872 passed (10,436 per mode)
   - Hardware oracle suite: 3,670 passed
   - C API test suite: 11 groups passed
   - REPL suite: 37 passed
   - ASCII validation: 100% pure ASCII across all source trees
