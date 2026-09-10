# Leaf capacity

Status: implemented for the multi-page PAX format, behind
`CybouDB_FEATURE_PAX_RUNS`. Databases written by an older build keep the previous
layout and still open.

The benchmarks in [../benchmarks/README.md](../benchmarks/README.md) found that
a 32-column table scanned at ~92 ns/row against ~3 ns/row for a 7-column one,
and that required-column pruning did not change it. This is why, and what was
done about it.

## How a leaf was laid out

One leaf was one 4096-byte page. Of it, 64 bytes are the header, 16 bytes per
column are the leaf's own column directory, and 4 bytes are the CRC. What is
left is the body, and the body holds whole 64-row groups: each column stores
its groups' NULL masks back to back and then its values back to back, so one
group costs `width * 64 + 8` bytes per column.

A 4 KiB page cannot hold one full group of a wide schema at all - 64 rows of
32 `INT32` columns need 8448 bytes - so such a table fell back to a partial
group and stored 24 rows per leaf:

| Schema | Capacity | Rows per table |
| :--- | ---: | ---: |
| 1 x BOOL | 3520 | 883 520 |
| 1 x INT64 | 448 | 112 448 |
| events, 7 mixed | 64 | 16 064 |
| 32 x INT32 | 24 | 6 024 |
| 64 x INT32 | 8 | 2 008 |
| 64 x INT64 | 4 | 1 004 |

Three orders of magnitude between the narrowest and the widest schema, and a
wide table delivering quarter-full batches while faulting a whole page for
every 24 rows it wanted. Pruning cannot help with that: it avoids *reading*
the other 31 columns, but they are interleaved in the same page the scan has
to touch.

## What a leaf is now

A run of contiguous pages. The run length comes from the schema - the smallest
power of two that reaches `PAX_RUN_TARGET` rows, capped at `PAX_RUN_MAX` - so
it is recomputed wherever capacity is and never stored. A narrow table does
not pay a wide table's run length, and the format gains no new field.

| Schema | Run | Leaf size | Capacity | Rows per table |
| :--- | ---: | ---: | ---: | ---: |
| 1 x BOOL | 1 | 4 KiB | 3520 | 883 520 |
| 1 x INT64 | 1 | 4 KiB | 448 | 112 448 |
| events, 7 mixed | 4 | 16 KiB | 448 | 112 448 |
| 32 x INT32 | 16 | 64 KiB | 448 | 112 448 |
| 64 x INT32 | 32 | 128 KiB | 448 | 112 448 |
| 64 x INT64 | 32 | 128 KiB | 192 | 48 192 |

Capacity stays a whole number of 64-row groups for every schema that reaches
one at all, so a batch still breaks where it always did and the executor's
64-row model is untouched.

### What it measured

Same benchmark, same machine, before and after:

| | rows per table | ns/row | rows per batch |
| :--- | ---: | ---: | ---: |
| events, `SELECT id` | 15 872 -> 112 384 | 2.0 -> 0.68 | 64 -> 64 |
| events, `WHERE category = 3` | 15 872 -> 112 384 | 3.3 -> 2.2 | 8 -> 8 |
| wide32, 1 of 32 columns | 5 888 -> 112 384 | 92 -> 14.4 | 23.9 -> 64 |
| wide32, 32 of 32 columns | 5 888 -> 112 384 | 100 -> 16.3 | 23.9 -> 64 |

A 19x larger table and a 6x lower cost per row for the wide schema, and full
batches everywhere. Both tables now stop at 251 x 448 rows, which is the
directory's limit rather than the leaf's - so the two-level directory is now
the thing standing between this and a dataset worth comparing against another
engine.

### What it did not fix

A table still costs an order of magnitude more per row when it shares a
database with another table - 0.65 ns/row alone against 13.5 ns/row sharing,
for the same statement over the same 112 384 rows. Longer runs were expected
to help and did not measurably: a scan of one table still walks its leaves
across a file the other table's leaves are spread through. That belongs to
allocation policy rather than to leaf geometry.

## What was left out

Capacity still rounds down to whole 64-row groups, so a leaf with room for
1.9 groups stores one. That wastes up to half a leaf - `events` uses 52% of
its body - and ending a leaf in a partial group would recover it.

It was left out deliberately. It buys nothing for the wide schemas that were
the problem (24 rows stays 24), and it would break the invariant that a
capacity is a multiple of 64 - which the executor, the batch delivery tests
and every fixture in the suite are built on. A few percent of density is not
worth that.

## Compatibility

Both the capacity and the leaf size change for a given schema, and validation
recomputes capacity and compares it against what a leaf stores, so a changed
formula would reject every existing database. `CybouDB_FEATURE_PAX_RUNS` is what
tells the layout code which arithmetic a file was written with; databases
created before it keep one page per leaf and open unchanged. `cyboudb info`
reports which of the two a file uses.

The bit requires `CybouDB_FEATURE_PAX_MULTI`: a single-leaf PAX database has no
directory to address a run through, and SQL only runs on the multi-page
format anyway.

## What allocating a run costs

A leaf is now allocated and copied as a unit - `db_bitmap_alloc_run`,
`db_cow_alloc_run`, `db_cow_copy_run`. Consecutive ids come from growing the
file, so a run is taken from the growth path whenever the file has room. When
it does not, the span layout looks for a run-shaped hole among the pages it
has reclaimed, which is the shape they come in: a leaf is retired exactly the
way it was allocated.

That second path needed a matching change to the single-page reclaimer. It
used to rely on a rolling cursor to know it never handed the same page out
twice; a run scan starts from the bottom of the file every time, so the two
could overlap. Both now also require a page to be retired in the *staged* map,
which is where a claim made earlier in the same transaction shows up.

## Also found while measuring

`INSERT` of 256 rows into a 64-column table fails with `memory arena capacity
exceeded`. That is the 1 MiB query arena, not storage: 16 384 literals do not
fit. The failure is honest and the database is untouched, but the arena should
be sized from the statement rather than fixed before a public API exists.
