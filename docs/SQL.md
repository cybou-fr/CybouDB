# CybouDB SQL Dialect and Engine Specification

Status: The Phase 3 SQL MVP engine is fully integrated. It supports CREATE TABLE, INSERT INTO ... VALUES (...), correctness-first UPDATE, and zero-copy scalar SELECT ... FROM ... WHERE ... over COW catalog and PAX columnar table storage.

---

## 1. Syntax & Supported Statements

CybouDB implements a typed, zero-copy subset of SQL tailored for columnar storage.

### 1.1 CREATE TABLE
`sql
CREATE TABLE table_name (
    col_name TYPE [NULL | NOT NULL],
    ...
);
`
- **Table Name**: Up to 31 ASCII characters ([A-Za-z_][A-Za-z0-9_]*). Case-insensitive.
- **Column Count**: 1 to 64 columns per table.
- **Column Name**: Up to 23 ASCII characters ([A-Za-z_][A-Za-z0-9_]*). Case-insensitive within the table.
- **Supported Data Types**:
  - INT32: 32-bit signed integer (-2147483648 to 2147483647).
  - INT64: 64-bit signed integer (-9223372036854775808 to 9223372036854775807).
  - FLOAT32: 32-bit IEEE 754 single-precision float.
  - BOOL: 1-byte boolean (TRUE / FALSE, stored as 1 / 0).
  - TEXT and BLOB have stable internal type IDs and are recognized by the
    grammar. They persist through validated extent chains for databases made
    with `create-large`; fixed-width creators reject them.
  - SQL aliases map to the same physical types: INTEGER -> INT32,
    BIGINT -> INT64, REAL -> FLOAT32, and BOOLEAN -> BOOL.
  - VECTOR is reserved for Phase 8 syntax but is rejected in CREATE TABLE
    until its persistent storage and mutation semantics are defined.
- **Nullability**:
  - By default, columns are **nullable** (CAT_NULLABLE flag set).
  - Specifying NULL explicitly keeps the column nullable.
  - Specifying NOT NULL declares the column non-nullable (CAT_NULLABLE flag cleared).

### 1.2 INSERT INTO
`sql
INSERT INTO table_name VALUES (val1, val2, ...), (val1, val2, ...);
`
- **Rows**: Up to 256 rows in a single multi-row INSERT statement.
- **Values**: Must match schema column count and data types.
- **Literals**:
  - Integer literals: Decimal numbers with optional unary + or -. Checked for 64-bit signed integer overflow.
  - Single-quoted TEXT literals are decoded into arena-owned byte slices;
    doubled quotes (`''`) become one quote byte and persist on `create-large`
    databases.
  - Binary literals use `X'00ff'` syntax (case-insensitive `X`) and require an
    even number of hexadecimal digits. They decode into arena-owned BLOB bytes.
    Both literal kinds fail fixed-width INSERT binding with a type mismatch;
    persistence is active with variable-width storage.
  - Float literals: `digits.digits` with optional unary `+` or `-`. At most 128
    decimal digits, counting leading/trailing zeros but excluding the dot and sign.
    Scientific notation, `.5`, `1.`, NaN and Inf literals are unsupported.
    Identifiers and other expressions in VALUES are rejected, never treated as NULL.
  - FLOAT32 conversion uses exact decimal integer arithmetic and rounds once to
    IEEE 754 binary32, nearest with ties to even, independently of caller MXCSR.
    Overflow to infinity is a syntax error. Underflow rounds to a subnormal or
    signed zero; the sign of negative zero is preserved. No silent integer wrap.
  - Boolean literals: TRUE, FALSE (case-insensitive).
  - Null literal: NULL (case-insensitive). Inserting NULL into a NOT NULL column is rejected at bind time (SQL_ERR_NOT_NULLABLE).
  - Type checking: Float literals cannot be inserted into integer columns. Integers within range are permitted in integer columns.
- **Parameters**: `?` stands in for a value supplied before the statement is
  stepped, through `cyboudb_bind_*`. Placeholders are positional and unnamed -
  the first `?` in a statement is parameter 0 - and a statement reports how many
  it has rather than the caller declaring them. They are accepted only in
  `INSERT ... VALUES`; a `?` anywhere else is a syntax error naming that,
  because the alternative message ("type mismatch") describes the wrong problem.
  A bound value is input to one execution and never enters the plan, so a
  prepared INSERT may be bound, stepped, reset and bound again - see
  [section 5](#5-regression-tests) and the immutability rule in `include/sql.inc`.
  A parameter nobody bound stops the statement at execution; it does not become
  a NULL.

### 1.3 SELECT
```sql
SELECT * FROM table_name;
SELECT col1, col2 FROM table_name;
SELECT col1 FROM table_name WHERE condition;
SELECT COUNT(*) FROM table_name [WHERE condition];
SELECT u.col1 FROM table_name [AS] u WHERE u.col2 > 0;
SELECT col1 FROM table_name [WHERE expression] LIMIT count [OFFSET count];
```
- **Table namespace**: A single table may have an optional `AS` or bare alias.
  Qualified names are accepted in projections and predicates. Once an alias is
  declared, it hides the base table name.
- **JOIN**: `JOIN`, `INNER JOIN`, and `LEFT JOIN` execute a correctness-first
  nested-loop join with a mandatory `ON` equality between qualified `INT32` or `INT64`
  columns. Equality operands may appear in either order. NULL keys never match.
  LEFT JOIN emits one row with NULL right-side values for every unmatched left
  row. JOIN queries with `WHERE`, BOOL/FLOAT32 keys, wildcard expansion, and
  unqualified JOIN projections remain explicitly rejected.
  The callback/CLI execution path is enabled; the public pull-style C stepping
  API returns a state error for JOIN until a resumable join cursor is added.
  Explicit projections are bound against either input schema; unqualified
  projections and `SELECT *` are rejected as ambiguous.
  The bound plan keeps source-aware input descriptors separately from compact
  output ordinals, so joined rows can use the existing result-sink batch ABI.
- **LIMIT**: `LIMIT count` and optional `OFFSET count` accept non-negative INT64
  literals. They are applied after `WHERE` and JOIN row production and stop the
  producer as soon as enough rows have been delivered. `OFFSET` without `LIMIT`
  is rejected. The callback/CLI path supports LIMIT for ordinary SELECT, COUNT,
  INNER JOIN, and LEFT JOIN. Public pull-style C stepping supports LIMIT for
  ordinary SELECT and COUNT; JOIN still awaits a resumable two-input cursor.
- **ORDER BY**: Single-table callback/CLI SELECT accepts one projected
  `[qualifier.]column` with optional `ASC` or `DESC`, followed by optional
  LIMIT/OFFSET. Sorting is stable across equal keys and supports INT32, INT64,
  FLOAT32, and BOOL. NULL sorts last in ASC and first in DESC. Rows are
  materialized in the statement arena; exhaustion fails explicitly rather than
  returning a partial result. ORDER BY for JOIN and the pull-style C stepping
  API remain gated until they own resumable materialized state.
- **Projection**:
  - `*` projects all columns in schema order.
  - Explicit projection: 1 to 64 column names.
  - `COUNT(*)` aggregates the count of matching rows into a single `INT64` result row. When no `WHERE` clause is specified, execution scans only directory metadata without touching column data pages.
- **WHERE Clause**:
  - Optional predicate filtering rows.
  - Comparisons: <column> OP <literal> or <literal> OP <column>.
  - Supported comparison operators: =, != (or <>), <, <=, >, >=.
  - Postfix null checks: <column> IS NULL, <column> IS NOT NULL.
  - Logical operators: AND, OR (with standard precedence: AND binds tighter than OR).
  - Parentheses: Sub-expressions can be nested with ( ... ).

### 1.4 UPDATE

```sql
UPDATE table_name SET column_name = literal WHERE expression;
```

UPDATE accepts exactly one assignment and requires `WHERE`. The target is a
fixed-width INT32, INT64, FLOAT32, or BOOL column in a table whose PAX directory
is flat. NULL obeys the target column's nullability. Predicate matches are
collected from one source snapshot before any mutation, then coalesced by leaf
so each changed leaf is copied, decoded, encoded, and sealed once. TEXT/BLOB
targets and two-level tree directories are not yet supported.

### 1.5 Transactions (BEGIN, COMMIT, ROLLBACK)

```sql
BEGIN [TRANSACTION | WORK];
COMMIT [TRANSACTION | WORK];
ROLLBACK [TRANSACTION | WORK];
```

- **`BEGIN`**: Starts an explicit transaction. Suspends implicit autocommit on subsequent mutating statements (`INSERT`, `UPDATE`, `CREATE TABLE`, `DROP TABLE`). Assigns a monotonic 64-bit transaction ID. Requires a writable database. Calling `BEGIN` while already in an active transaction returns `SQL_ERR_EXEC` ("cannot BEGIN inside active transaction").
- **`COMMIT`**: Flushes all staged dirty pages and atomically advances the active superblock generation via `db_commit`. Resets transaction state to inactive. Calling `COMMIT` without an active transaction returns `SQL_ERR_EXEC` ("no active transaction to COMMIT").
- **`ROLLBACK`**: Discards all uncommitted changes made since `BEGIN` via `db_rollback`. Restores database descriptors (`DB_PAGES`, `DB_ALLOC`, `DB_COW_FLOOR`, `DB_GENERATION`, `DB_FREELIST`, `DB_ROOT`, `DB_BITMAP`), dirty ranges, and span maps directly from the live committed superblock state without disk writes. Resets transaction state to inactive. Calling `ROLLBACK` without an active transaction returns `SQL_ERR_EXEC` ("no active transaction to ROLLBACK").
- **Auto-Rollback on Close / Disconnect**: Closing the database (`db_close` / `cyboudb_close`) or encountering EOF/disconnect in the REPL or piped input while a transaction is active automatically triggers `db_rollback`, guaranteeing that uncommitted mutations are never published.

---

## 2. Type System & Semantics

### 2.1 Identifier Case-Insensitivity
SQL keywords (SELECT, FROM, WHERE, etc.) and identifiers (table names, column names) are matched ASCII case-insensitively (users matches USERS, Users, uSeRs).

### 2.2 Three-Valued Logic (3VL)
- Any comparison (=, !=, <, <=, >, >=) involving a NULL value evaluates to **UNKNOWN**.
- In a WHERE clause filter, UNKNOWN evaluates to false (the row is rejected).
- To test for nullness, use IS NULL or IS NOT NULL.
- Comparisons against IEEE 754 NaN values supplied through storage evaluate to
  FALSE for **all six operators, including `!=`**. `NOT` of such a comparison is
  TRUE. NaN is not NULL; `IS NULL` checks only the null mask. Both quiet and
  signaling NaN are classified by bits before comparison, without raising invalid.
- Stored infinities compare by IEEE ordering; positive and negative zero compare equal.
- `NOT UNKNOWN` remains UNKNOWN. NULL takes precedence if the compared cell is NULL.

### 2.3 Commit & Persistence Policy
- `sql_execute` executes the bound physical plan against the open database context in memory.
- **Autocommit Mode (default)**: When no explicit transaction is active (`DB_TX_ACTIVE == 0`), each mutating statement (`CREATE TABLE`, `DROP TABLE`, `INSERT INTO`, `UPDATE`) is committed immediately upon successful execution via `db_commit`. An `UPDATE` matching no rows does not publish an empty generation.
- **Explicit Transaction Mode**: After `BEGIN`, statements stage changes in memory and across append-only COW pages. Autocommit is suspended until an explicit `COMMIT` publishes the changes or `ROLLBACK` discards them.
- **Read-only statements** (`SELECT`) do not stage mutations or advance superblock generations. Opening a read-only database and executing `BEGIN` is rejected (`SQL_ERR_EXEC`, "database is read-only").

---

## 3. Implementation Limits

| Limit | Maximum | Error Code | Description |
| :--- | :--- | :--- | :--- |
| Table Name Length | 31 bytes | SQL_ERR_SYNTAX | Name exceeds 31 characters |
| Column Name Length | 23 bytes | SQL_ERR_SYNTAX | Name exceeds 23 characters |
| Columns per Table | 64 | SQL_ERR_SYNTAX | Schema column count exceeds 64 |
| Rows per INSERT | 256 | SQL_ERR_SYNTAX | Row count exceeds 256 in VALUES list |
| Projections per SELECT | 64 | SQL_ERR_SYNTAX | Projected column count exceeds 64 |
| Float Literal | 128 decimal digits, finite binary32 result | SQL_ERR_SYNTAX | Excess length or overflow rejected |
| Integer Magnitude | 64-bit signed | SQL_ERR_SYNTAX | Integer literal overflow |
| Expression Nesting | 64 | SQL_ERR_EXPR_DEPTH | Parenthesised or `NOT` nesting deeper than 64 |
| Parameters per Statement | 64 | SQL_ERR_SYNTAX | More than 64 `?` placeholders |
| Bound Bytes per Statement | 32 KiB | CybouDB_NOMEM | Sum over parameters of the largest TEXT, BLOB or VECTOR value each has held |
| Statement Length | 65535 bytes; 4095 characters of Windows command line | (CLI diagnostic) | Oversized statements are refused, never truncated |

Expression nesting is bounded because the parser, the binder and the
evaluator all walk the tree recursively. Without a limit an input such as
`NOT(NOT(NOT(...)))` decides how much stack CybouDB uses. The parser enforces the
limit once, at each descent into a parenthesised group, a `NOT` operand or a
binary right-hand side, and everything downstream inherits a tree it can
safely recurse over.

The statement-length limit is a property of the current CLI rather than of the
engine: statements arrive as a command-line argument. Linux bounds the single
argument at the 64 KiB query buffer; Windows captures the whole command line
into a 4096-character buffer first, so it clips earlier. Both report
`error: SQL statement exceeds the command-line limit` and exit nonzero. A
truncated statement is never executed - half a `WHERE` clause still parses,
and would quietly mean something the user did not write. The console and
library front ends of later phases remove the limit rather than raise it.

## 4. Internal Error Contract

`SQL_ERROR` is 104 bytes. Existing offsets are preserved: code at 0 (u64), source
byte offset at 8 (u64), line at 16 and column at 20 (u32), ASCIIZ message at 24
(72 bytes). The new domain at 96 (u64) determines the meaning of code:

| Domain | Value | Code family |
| :--- | :--- | :--- |
| NONE | 0 | Success, code 0 |
| SQL | 1 | SQL_ERR_* from parser, binder or executor |
| STORAGE | 2 | Unmodified CybouDB_E_* from storage |
| OS | 3 | Reserved; raw OS codes are not exposed by this SQL API |

`sql_parse` and `sql_bind` clear the supplied error on entry and report SQL-domain
failures. `sql_execute(db, plan, arena, row_cb, cb_ctx, out_err)` now takes an
optional sixth pointer to this record. It still returns the numeric code in RAX;
callers must use the domain to interpret a nonzero result. All current callers
pass the sixth argument explicitly. Execution errors have offset UINT64_MAX and
line/column zero (location unavailable); parser locations are token-based and
binder retains its existing statement/expression location granularity.

The CLI routes storage-domain execution errors to storage diagnostics and SQL
errors to SQL diagnostics. A database-open or commit failure outside sql_execute
continues through the storage API. CLI exit codes remain unchanged.

## 5. Regression Tests

`python tests/sql_tests.py <cyboudb>` is the shared CLI suite; shell and PowerShell
entry points are wrappers. `build.sh --core-tests` / `build.bat --core-tests`
builds the fixture driver for `tests/sql_numeric_tests.py <cyboudb> <cow_harness>`.
`build.sh --sql-tests` / `build.bat --sql-tests` builds the API driver for
`tests/sql_api_tests.py <cyboudb> <sql_harness>`. The API suite checks domain/code
pairs, unavailable locations, MXCSR preservation, and literal bits against an
independent rational-number nearest-even oracle, including deterministic random
inputs. Both additional suites run in Linux and Windows CI.

## 6. Required-Column Batch Scans

The 64-byte bound plan stores `PLAN_REQUIRED_COLS` at offset 56. Bit `i`
means physical schema column `i` is referenced by projection or the bound
predicate (including NULL comparisons). Duplicate projections set a bit once;
`SELECT *` sets every schema-column bit, including bit 63 for a 64-column table.

`db_pax_scan_batch(cursor, batch_view, required_cols)` takes this bitmap as its
third argument. It walks only set bits to read leaf column descriptors, derive
value pointers and load NULL masks. Colview slots remain indexed by physical
column number; unrequested slots are untouched and must not be read. The bitmap
must be supplied on each call. A zero mask advances the cursor and returns row
counts without populating any colviews. Out-of-schema bits return CybouDB_E_STATE
before cursor advancement, including on empty/exhausted cursors.

For a valid output pointer, `BATCH_VIEW_ROWS` is zero on end/error. View pointers
retain the existing mapped-snapshot lifetime. Database-open integrity checks
still validate the full storage graph; this optimization targets per-batch view
construction, not those checks. Row compatibility delivery is preserved through the adapter described below.

`python tests/sql_pruning_tests.py <cyboudb> <sql_harness>` checks plan bitmaps,
untouched unrequested slots, mapped pointers, every scalar column width, empty
and zero-mask scans, invalid masks, 63/64/65-row boundaries and multi-leaf wide
tables. Both CI platforms run this suite. No speedup claim is made before the
in-process benchmarks are available.

## 7. Scalar Predicate Kernel ABI v1

`sql_kernel_resolve(type, op)` selects a function once during binding. Unsupported
pairs return NULL. Comparison nodes store the function pointer in `BEXPR_KERNEL`
at offset 56; bound predicate nodes are now 64 bytes. Plans are process-local and
must not be serialized with these pointers. The executor owns expression traversal,
3VL composition and NULL tests; kernels own typed column/literal comparisons.

```
kernel(values_ptr, null_mask, active_mask, literal_bits)
    -> RAX = true_mask, RDX = unknown_mask
```

Arguments use the platform integer calling convention, including FLOAT32 literal
bits in the low 32 bits of the fourth integer argument. INT32 uses the low 32 bits,
INT64 all 64 bits, and BOOL the low byte (canonical 0/1). Kernels preserve platform
callee-saved registers and MXCSR. They do not allocate, access storage metadata,
read the predicate tree, or require padding/alignment.

Only active, non-NULL lane values may be read. Each active lane `i` addresses
`values_ptr + i * width`; no value buffer is needed if no such lanes exist.
Masks may be sparse, including bit 63. Unknown is exactly `active & nulls`;
true is disjoint from unknown and contains no inactive bits. NaN comparisons
remain FALSE for all operators. FLOAT32 scalar kernels classify/order IEEE bits
using integer keys, preserving signed-zero equality and subnormal ordering
regardless of MXCSR rounding/DAZ/FTZ and without signaling-NaN exceptions.

`src/sql/kernels_scalar.asm` contains specialized reference kernels for the six INT32,
INT64 and FLOAT32 comparisons, plus BOOL equality/inequality. Type/operator
selection occurs outside the lane loop.

`src/sql/kernels_avx2.asm` implements the vector predicate kernels using 256-bit
AVX2 instructions (8 lanes per YMM for INT32 and FLOAT32, 4 lanes for INT64, 32 lanes
for BOOL). `sql_kernel_resolve` dynamically queries CPUID and OSXSAVE/XGETBV state via
`cpu_has_avx2`, binding AVX2 kernels when supported and falling back to scalar reference
kernels otherwise (or when forced via `sql_kernel_force_scalar`).

FLOAT32 AVX2 kernels employ signed integer key transformations (abs, canonicalizing
signed zero -0.0 to +0.0, and flipping negative keys), completely immune to signaling NaN
hardware exceptions under unmasked MXCSR and independent of DAZ/FTZ flags.

Build the direct driver with `--kernel-tests` and run
`python tests/kernel_tests.py <kernel_harness> [--scalar]`. The independent oracle covers
signed limits, IEEE special values, sparse/tail/empty/NULL masks, unaligned
buffers, invalid resolver arguments, nondefault/unmasked MXCSR and callee-saved
integer registers across both AVX2 and scalar paths. Both CI platforms run this suite.

### Hardware Optimization: BMI2 Primitives and SSE4.2 CRC-32C

`src/sql/bmi2.asm` implements bit manipulation acceleration routines:
- `bmi2_pext64` (Parallel Extract): compresses bit lanes according to a selection mask.
- `bmi2_pdep64` (Parallel Deposit): expands contiguous packed bits into target mask positions.
- `bmi2_bzhi64` (Zero High Bits): clears high bits above a specified index.
- `bmi2_compact_nulls`: compacts a 64-bit active lane mask against an invert-selection NULL mask.

All BMI2 routines detect hardware support dynamically via `cpu_has_bmi2` (CPUID leaf 7 subleaf 0 EBX bits 8 & 3) and fall back to bit-loop reference implementations when BMI2 is unavailable. Row iteration and dispatch in `src/sql/result_rows.asm` and `benchmarks/bench_harness.asm` use `tzcnt` (compatible with `rep bsf` on legacy CPUs) and hardware `popcnt`.

`src/core/checksum.asm` accelerates database page checksumming using hardware SSE4.2 `crc32` with a 4x unrolled 32-byte loop (`crc32 rax, qword [...]`) and non-branching tail handling. It detects SSE4.2 via CPUID leaf 1 ECX bit 20 and falls back to the canonical scalar bit-loop implementation.

Build the direct driver with `--hardware-tests` and run
`python tests/hardware_tests.py <hardware_harness>`. The suite covers 1,276 oracle test cases testing both hardware and scalar paths across alignments and lengths up to 8,180 bytes.

## 8. Batch Result Sink

`sql_execute_batch(db, plan, arena, batch_cb, cb_ctx, out_err)` is the primary
physical executor. CREATE and INSERT keep their existing semantics. SELECT
requires a callback and reports SQL-domain SQL_ERR_EXEC when it is missing.

```
batch_cb(ctx, batch_view, projection, selection_mask) -> EAX
```

The projection descriptor has a qword count at offset 0, a pointer to physical
u32 column indices at 8, and a pointer to parallel u32 scalar types at 16. It
preserves projection order and duplicates. The mask uses physical row offsets
within the batch; only set bits are result rows. Callbacks receive only nonempty
selections, in scan order.

The return value is one of three:

| Constant | Value | Meaning |
| :--- | :--- | :--- |
| `CybouDB_SINK_CONTINUE` | 0 | Deliver the next batch |
| `CybouDB_SINK_STOP` | 1 | Stop early; the statement succeeded |
| `CybouDB_SINK_ERROR` | -1 | The sink failed; the statement fails with it |

Any nonzero value other than `CybouDB_SINK_STOP` is treated as a sink failure and
surfaces as SQL-domain `SQL_ERR_SINK`, message `result callback reported a
failure`. A consumer needs some way to say "my write failed", "I ran out of
memory", "the pipe closed" - distinctly from "I have seen enough" - and while
this API is still internal, defining that costs nothing. The row callback
answers with the same three values and `src/sql/result_rows.asm` passes its
answer straight through.

View/descriptor pointers are borrowed and read-only. The view is reused by the
next scan; use it synchronously during the callback. Do not retain pointers,
mutate the database, commit/close the context, reset the arena, or change the plan
from a callback. A later API can provide explicit ownership if needed.

The batch path allocates one 1544-byte view from the arena per execution, with no
row projection buffers or per-row callbacks. `sql_execute` remains the six-argument
row compatibility entry point. `src/sql/result_rows.asm` adapts selected rows,
using stack scratch for up to 64 projected values/NULL flags, and preserves the
CLI's exact output and successful early-stop behavior.

`python tests/sql_sink_tests.py <cyboudb> <sql_harness>` compares batch and row
consumers against ordered cell hashes and NULL counts. It covers empty/no-match
queries, 63/64/65 rows, many leaves, 64-column projections, duplicate projections,
early stop, sink-reported failure on both the batch and the row side, missing
sinks, and exact/insufficient arena budgets. The suite runs
on both CI platforms. Callback count reductions are tested; throughput remains
unmeasured until the in-process benchmark harness is available.
