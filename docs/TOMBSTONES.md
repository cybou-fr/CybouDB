# Tombstones

`DELETE ... WHERE` rewrites the rows the predicate did not select into a fresh
graph. That is correct, and it is proportional to the survivors: removing one
row from a million-row table copies 999,999 of them, which measures 177 ms
where the work itself is one row. Tombstones make the cost proportional to
what is removed instead - a bit per row, flipped in place under copy-on-write.

This document fixes the on-disk decisions. What is implemented against it is
stated in [ROADMAP.md](../ROADMAP.md); this file describes the format, not the
state of the code.

## Where the bits live

Inside the PAX leaf, not in a side structure.

A leaf is already a run of contiguous pages that a scan has mapped, validates
once, and checksums as a unit. A dead-row bitmap kept there costs no page of
its own, no directory, no root to publish, and no second graph to validate; a
scan that has the leaf has the bitmap. A side structure hanging off the schema
page - the shape the zone maps use - would cost all four, and would be read on
exactly the same code path as the leaf it describes.

The bitmap occupies the last `ceil(capacity / 8)` bytes of the leaf's body,
immediately before the run's CRC. Column data is laid out from the start of
the body, so reserving the tail leaves every existing column offset alone.

Bit `r` of the bitmap is set when row `r` of that leaf is dead. Bits from
`capacity` upwards are zero and are checked to be zero, as the format does
everywhere it has a tail.

## What that costs a leaf

Capacity is what the bitmap is sized from, and the bitmap is subtracted from
the body capacity is computed against, so the two are defined together:

    body(0)      = run bytes - CRC - header - column directory
    capacity(n)  = whole 64-row groups that fit in body(n)
    body(n+1)    = body(n) - ceil(capacity(n) / 8)

The sequence decreases and is computed until it stops moving, which takes at
most a couple of steps. The result is recorded in the leaf header, as capacity
always has been, and cross-checked on validation against the arithmetic the
file's feature bits say it was written with - so a leaf never has to be
guessed at.

For the seven-column benchmark schema this turns 448 rows per four-page leaf
into 448: the slack the group arithmetic already left is larger than the 56
bytes the bitmap needs. A narrow table pays more of its leaf - a single BOOL
column reserves about an eighth - which is the honest price of addressing
every row individually.

## The live count

`CAT_TABLE_ROWS` keeps meaning what it has always meant: how many rows the
table has physically, which is what the scan iterates and what an append
extends. It is not the answer to `COUNT(*)` once a row can be dead.

Each leaf header carries `PAX_DEAD`, the number of bits set in its bitmap, in
four bytes that were reserved-zero for a leaf. A table's live count is
`CAT_TABLE_ROWS` minus the sum over its leaves, which a `COUNT(*)` with no
predicate reads from the leaf headers without touching column data - the same
trade the zone maps already make for that query.

Validation requires `PAX_DEAD` to equal the population count of the bitmap and
to be no greater than the rows the leaf holds, so the two can never disagree
about a leaf that opens.

## What the rest of the engine has to know

* **Scans** mask the dead rows out of each batch. The mask is one 64-bit
  extract from the bitmap per batch of 64 rows, not per column, and it is
  intersected with the predicate's selection where the NULL semantics already
  meet - so a dead row is invisible to `SELECT`, to `UPDATE` and to the
  predicate kernels alike.
* **Zone maps** stay correct without being rebuilt. They summarise a superset
  of the live rows, so a leaf they rule out has no live match either. A leaf
  they accept in full still has to consult the bitmap, which turns their ALL
  decision into "read the tombstones, skip the predicate".
* **Appends** are unaffected. A new row is written at the physical end with
  its bit clear; nothing moves, so no row index an `UPDATE` or a cursor holds
  can be invalidated by a delete elsewhere.
* **`cyboudb check`** recomputes every `PAX_DEAD` from its bitmap and every
  live count from its leaves, the way it already recomputes statistics.

## Compatibility

`CybouDB_FEATURE_TOMBSTONES` is an incompatible bit: a leaf written with it
reserves bytes an earlier build would read as column data. A file without the
bit is unchanged, is read by this build unchanged, and takes the rewrite path
for `DELETE`. There is no in-place upgrade; a table gains tombstones by being
created in a database that has the bit.

## What this does not solve

A table that is mostly tombstones still scans every physical row, and the
pages of a leaf whose rows are all dead are still allocated. Reclaiming them
means compaction - rewriting a leaf run without its dead rows, or dropping it
and relinking the directory - which is a separate piece of work with its own
decisions about when it is worth doing. Until it exists, a workload that
deletes most of a table repeatedly is better served by the rewrite, and the
executor is where that choice belongs.
