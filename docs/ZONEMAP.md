# Zone metadata

`CybouDB_FEATURE_ZONE_MAPS`, `include/zonemap.inc`.

A zone entry summarises one column inside one PAX leaf: whether it holds any
values, whether any of them are NULL, and the range the comparable ones fall
in. With that, a scan can decide a whole leaf against a predicate before it
maps a single column page - the predicate is impossible there, or true for
every row there, or has to be evaluated row by row as it is today.

The 10M-row cross-engine benchmark is what asked for this. DuckDB answered
`WHERE amount > 1000` at 0.37 ns per row against CybouDB's 0.79 by deciding whole
122 880-row blocks from block minima and maxima; on data where those minima and
maxima decide nothing, the same query reversed to 1.05 against 0.85. The
measured gap is block metadata, not vectorization. See
[../benchmarks/results/2026-09-09-4way-10m.md](../benchmarks/results/2026-09-09-4way-10m.md).

## Where it lives

Not inside the leaf. A PAX leaf is byte-for-byte what it was before this
feature, and its checksum covers the same bytes, so no existing database is
rewritten and no existing validation changes.

The statistics hang off the schema page instead, in `CAT_STATS_ROOT` - the
eight bytes at offset 56 that every earlier build wrote as zero and validated
as zero. That is what makes the feature bit necessary: a build without it, on
opening a database that carries statistics, refuses the file rather than
quietly failing to maintain them. A schema page may only carry a non-zero
statistics root in a database created with `CybouDB_FEATURE_ZONE_MAPS`.

```
schema page
 +- CAT_DATA_ROOT   -> PAX directory or leaf     (unchanged)
 +- CAT_TABLE_ROWS                               (unchanged)
 +- CAT_STATS_ROOT  -> zone page
                         level 0: leaf statistics
                         level 1: names level-0 pages
                         level 2: names level-1 pages
```

A table whose statistics fit one page has a level-0 page as its root, exactly
as a small table has a single leaf rather than a directory. Depth is earned,
not assumed.

## What an entry holds

`ZSTAT_SIZE` is 24 bytes per column per leaf: flags, minimum, maximum.

| Type | MIN / MAX | Flags |
| :--- | :--- | :--- |
| INT32, INT64 | the smallest and largest non-NULL value | `HAS_COMPARABLE`, `HAS_NULLS` |
| FLOAT32 | binary32 bit patterns, zero-extended | `HAS_COMPARABLE`, `HAS_NULLS`, `HAS_NAN` |
| BOOL | unused, zero | `HAS_COMPARABLE`, `HAS_NULLS`, `HAS_FALSE`, `HAS_TRUE` |

Two exclusions are deliberate. NULLs never enter a range - `HAS_NULLS` records
them and `IS NULL` / `IS NOT NULL` are answered from that flag and the leaf's
row count. NaN never enters a range either: it compares false against
everything, so admitting it would widen a range that no predicate could then
use. `HAS_NAN` records that it is there, and a range predicate reads MIN and
MAX as a statement about the comparable values only. The comparison semantics
of MIN and MAX are CybouDB's own, described in [PAX.md](PAX.md); statistics that
ordered values differently from the kernels would be worse than no statistics.

## What a scan does with it

The SQL executor calls `db_zone_lookup` and `sql_zone_eval` when entering a
PAX leaf and caches the decision for all of its batch64 groups. SQL semantics
live in `src/sql/zone_predicate.asm`; storage supplies validated statistics and
cursor geometry. The kernel ABI is unchanged.

```
predicate
    |
    v
zone test against the leaf's entry
    |-- ZONE_TEST_NONE     skip the whole leaf, no column views
    |-- ZONE_TEST_ALL      projection views only; no predicate kernel
    +-- ZONE_TEST_UNKNOWN  the existing scalar or AVX2 kernel
```

The first version answers `column OP literal` for `=`, `<`, `<=`, `>`, `>=`,
plus `IS NULL` and `IS NOT NULL`. `AND` and `OR` compose from the children:
under `AND`, one impossible child makes the leaf impossible and two
always-true children make it always true; under `OR`, the reverse. Anything
else answers `ZONE_TEST_UNKNOWN` and uses the existing batch evaluator.
`NOT` always returns UNKNOWN because NONE combines FALSE and SQL UNKNOWN;
inverting it would lose SQL three-valued logic. `!=` also remains a batch
predicate. Comparison with a NULL literal returns NONE, meaning no TRUE rows.

For `COUNT(*)`, an ALL decision adds the leaf's row count directly and advances
to the next leaf without requesting any PAX batch or column view. Ordinary
ALL SELECTs request only projection columns, preserving duplicate projections
and output order. NONE never requests a batch. UNKNOWN requests the original
union of predicate and projection columns. Sink stop/error behavior and cursor
generation checks apply to these paths as well.

The executor uses the schema resolved for the current snapshot; it does not
reuse a stale plan's statistics root when the bound-plan fast path fails.
Missing statistics fall back to UNKNOWN for column predicates. An absent
WHERE clause is always ALL without needing statistics.

## Regression and instrumentation

`sql_zone_force_off` is an internal process-wide switch for parity tests and
benchmarks. With it set, leaves use the original batch predicate path. The
`tests/zone_sql_tests.py` suite compares both modes with scalar and automatic
kernel dispatch, checks ordered output against an independent 3VL model, and
exercises raw FLOAT32 literals under unmasked MXCSR, tree promotion, COW append
and generation recovery.

Setting the internal `sql_zone_trace` switch enables diagnostic counters:
`sql_zone_leaf_total`, `sql_zone_leaf_none`, `sql_zone_leaf_all` and
`sql_zone_leaf_unknown`. `sql_zone_batch_total` counts requested batches and
`sql_zone_column_mask` records the union of requested physical columns. Tests
use these to verify that skipping really occurs once per leaf and that ALL
does not request predicate-only columns. Counters are disabled by default,
accumulate until reset, and describe visited leaves (a sink may stop early).
These controls are not part of the public C API; a tracing caller must isolate
its run and reset the process-wide counters before measuring another query.

## When statistics are written

During the insert that produces the rows, from the same batch, in the same
pass. Nothing rescans a finished leaf: the batch's values are already in
registers when they are written into the leaf, and merging them into a leaf's
entry is a comparison per value.

A COW insert copies the leaf it appends to, its directory path and the schema
page. The statistics follow that shape exactly: the affected zone page is
copied, its entry updated, its directory path copied, and the new root written
into the same copied schema page the insert was already publishing. One
publication, one generation, one fsync boundary - statistics cannot be a
generation ahead of or behind the data they describe.

New and copied zone pages are stamped with `DB_GENERATION + 1`, the
candidate generation, just like new PAX pages. Shared, untouched pages retain
their original generation.

FLOAT32 statistics use integer ordering keys, with both signed zeros mapped
to the same key. The stored bounds retain the original binary32 bits (the
first encountered encoding wins a tie). NaNs, including signaling NaNs, are
classified by their bits and excluded from bounds. No floating-point
instruction participates in the merge, so DAZ, FTZ, rounding modes and
exception masks do not affect the result or change MXCSR.

## Space

Statistics cost pages, and those pages are counted by the insert's own
preflight rather than discovered halfway through it: an insert that cannot fit
both its leaves and their statistics fails before it writes anything, leaving
the file byte-identical. At seven columns a statistics page describes 23
leaves, so three million rows of the benchmark schema cost 292 pages against
the 26 788 the data occupies - a little over one percent.

A table too large for two levels of directories, or one whose statistics
cannot be written, keeps none at all rather than partial ones: a leaf without
an entry is evaluated the way it always was, while a stale entry would give a
wrong answer.

## Failure and recovery

A crash between writing the statistics and publishing the superblock leaves
the old generation intact, statistics and data together, since neither is
reachable until the root is published: the new root reaches the schema page in
the same copy that carries the new data root.

`db_zone_validate` runs after PAX validation for each candidate schema. It
checks allocated payload membership before dereferencing a page, then magic,
version, identity, owner, generation, level, stride, reserved fields and unused
tail bytes. Child generations cannot exceed their parent's generation. CRCs
follow the PAX policy: ordinary open checks the candidate generation's pages;
`cyboudb check` checks all generations. A damaged candidate can fall back to the
previous coherent superblock.

The tree must cover exactly `ceil(table_rows / pax_capacity)` logical leaves,
with canonical page counts and consecutive ranges. Missing, duplicate, extra
or overlapping leaves, gaps and cycles are rejected. A zero statistics root
is still valid and means there is no optimization.
Appending to a populated table without statistics preserves that absence:
the incoming batch cannot reconstruct statistics for the earlier rows.

Every column entry is checked for legal flags, canonical bounds and ordered
min/max, including integer-only FLOAT32 ordering. `HAS_COMPARABLE` excludes
both NULL and NaN; its on-disk bit remains 1. Nonnullable columns cannot claim
NULLs, and BOOL truth flags must agree with the comparable flag.

In exhaustive mode, `db_zone_check_leaf` resolves each PAX leaf through the
candidate schema and recomputes every statistic from its actual values and
NULL bitmap. All flags and bound bits must match, including the original
signed-zero encoding. This also detects plausible but false statistics whose
CRC has been recomputed. Failures use the existing catalog-graph validation
and candidate-recovery path; no new public error code is introduced.

SQL pruning and semantic parity tests are implemented. Performance comparison
still requires versioned fixtures and repeated structured/shuffled/randomized
benchmarks; no new cross-engine performance claim is made here.
