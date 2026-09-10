# Multi-page PAX tables

Status: a bounded data-page directory, cross-page batch insertion, scalar row
lookup and a scan cursor are implemented. `cyboudb query` drives all of it
through SQL: `CREATE TABLE` writes the schema, `INSERT` batches rows across
pages, and `SELECT ... WHERE` scans through the cursor 64 rows at a time,
materialising only the columns the plan asks for.

## Creation and compatibility

```sh
cyboudb create-pax-multi demo.cyboudb 512
cyboudb info demo.cyboudb
```

The immutable incompatible flags are `0x1E`: COW `0x2`, catalog `0x4`, PAX
`0x8`, and multi-page PAX `0x10`. The new bit requires all three predecessors.
Earlier binaries reject it before mutation. `create-pax` still creates the
single-page `0xE` format; neither command migrates an existing file. As with
other create commands, replacement requires `--force`.

The flat map still supports at most 16112 pages and the catalog at most 251
tables, with 1..64 columns each. One directory page addresses 251 leaves; with
`CybouDB_FEATURE_PAX_TREE` a table that outgrows one grows a root directory of
directory pages instead of stopping, so the table limit is
`251 * 251 * capacity`. Exhausted file space stops insertion earlier, because
old COW pages are reclaimed only in the [span map](SPAN_MAP.md) format - which
is what `create-large` selects, and what a table of this size needs.

With `CybouDB_FEATURE_PAX_RUNS` a leaf is a run of contiguous pages whose length
comes from the schema, so capacity no longer collapses on a wide table: 48192
rows for 64 INT64 columns and 112448 for anything narrower, against 1004 and
16064 when a leaf was one page. [PAX_CAPACITY.md](PAX_CAPACITY.md) has the
arithmetic, what it measured and what it deliberately left alone. A database
written before the bit keeps one page per leaf and its old capacity; `cyboudb
info` says which layout a file uses.

## Directory format

Schema offset 40 now refers to an `ASQD` directory rather than directly to an
`ASQP` leaf. Offset 48 is still the table's u64 row count. Both are zero for an
empty table. The leaf format is unchanged from single-page PAX.

All directory fields are little-endian; the allocation map classifies the
page as payload:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQD` |
| 4 | 4 | Directory version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owning table id |
| 32 | 4 | Total stored rows, equal to schema row count |
| 36 | 4 | Entry count, 1..251 |
| 40 | 4 | Computed capacity of each PAX leaf |
| 44 | 4 | Level: 0 names leaves, 1 names level-0 directories |
| 48 | 16 | Reserved, zero |
| 64 | 16 per entry | `(u64 page_id, u64 cumulative_row_end)` |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

Unused directory bytes are zero. Leaf ids must be distinct, but their order
is the directory's, not the file's: entry `i` may name any page. Nothing in
the format ties logical position to physical age, so a future copy-on-write
`UPDATE` can move one rewritten leaf to a fresh high id without rewriting the
leaves after it. Every leaf except the last is full. Entry `i` has cumulative end
`min((i + 1) * capacity, table_rows)`; entry count is
`ceil(table_rows / capacity)`. Each leaf's stored row count equals the
difference between its end and the previous end. No empty leaf is referenced.

## Two levels

A directory written before `CybouDB_FEATURE_PAX_TREE` has zero at offset 44,
which is the level it is, so nothing older needs a special case.

A level-1 root is the same page shape with the same entry shape; only what an
entry names changes. Its capacity field still holds the leaf capacity, so a
lookup divides once by the capacity to get a leaf index and once by 251 to
split that into a child and a slot. A child is a *complete* flat directory of
its slice of the table - its row ends are its own, counted from its own first
row - so the level below a root is exactly what a small table already has, and
one routine validates both.

The root's arithmetic is the flat one with a child's span in place of a leaf:
child `i` ends at `min((i + 1) * 251 * capacity, table_rows)` and the child
count is `ceil(table_rows / (251 * capacity))`. A root with one child is
rejected, because that table should be flat.

Promotion happens on the insert that first needs a 252nd leaf. The old flat
directory becomes child 0: shared unchanged when the insert starts past it,
copied when the insert changes it. Nothing rewrites the leaves.

## Insertion and lookup

The public-to-core entry points remain `db_pax_insert` and `db_pax_read` with
the descriptors and scalar/NULL rules in [PAX.md](PAX.md). The file capability
selects the data-root interpretation. A batch may span many pages; it must
fit the remaining table capacity and available COW space.

Insertion validates the complete batch before allocation. It then preflights
space for all changed leaves, one data directory, one schema, one catalog root,
and an allocation-map copy if this is the transaction's first allocation.
If the last leaf is partial it is copied and filled first. Additional rows go
to freshly allocated leaves. Full prefix leaves remain shared. A completely
full last leaf is also shared, so the next batch starts on a new leaf.

The copied directory records the new leaf references and cumulative row ends;
the copied schema and catalog root publish the complete new table graph at
commit. Two appends in one transaction repeat path copying while sharing the
staged allocation map. Intermediate versions remain allocated.

Scalar read uses `row_index / capacity` to select a directory entry and
`row_index % capacity` within its leaf. It returns the same u64 scalar slots
and NULL bytes as single-page PAX, and revalidates the entire graph on every
call. Sequential access goes through the scan cursor in [PAX.md](PAX.md)
instead: it validates once, then walks the directory entry by entry, and a
block never spans two leaves.

`CybouDB_E_ROWS` reports a batch that exceeds the bounded table capacity or an
invalid row index; `CybouDB_E_FULL` reports insufficient physical storage. The
whole batch is rejected before mutation for either condition or invalid input.
Read-only, generation-exhausted and failed-sync handles retain their existing
guards. A populated schema cannot be replaced through `db_catalog_put`.

## Validation and recovery

Open and commit validate directory version, identity, owner, map membership,
counts, capacity, canonical row ends, leaf distinctness and, for a directory
written by the generation being opened, its checksum and zero padding. Every
referenced leaf undergoes the PAX validation in [PAX.md](PAX.md), which reads
a leaf's contents only when that leaf carries the same generation. `cyboudb check`
reads all of them. Generations
must obey `leaf <= data_directory <= schema <= catalog_directory <= superblock`.
Typed references, owner checks and distinct leaf ids reject cycles,
cross-table aliases, metadata references and duplicate leaves.

A damaged directory or leaf rejects the entire superblock candidate, permitting
fallback to the older coherent graph. If both candidates fail, open fails.
Both checksummed superblock allocation ranges remain protected even when a
graph is rejected, so uncommitted writeback cannot resurrect it. Commit retains
the ordered flush protocol; either sync failure disables further writes until
reopen. Fault injection does not simulate every physical power-loss behavior.

## Tests and remaining work

```sh
sh build.sh --core-tests
python3 tests/pax_multi_tests.py ./cyboudb ./build/cow_harness
# Windows: build.bat --core-tests
# python tests/pax_multi_tests.py ./cyboudb.exe ./build/cow_harness.exe
```

The 46 scenarios independently decode directories, leaves, CRCs and values;
exercise cross-page batches and reads, physically reordered leaves,
full-prefix sharing, partial-tail copies,
dense 3520-row leaves, cursor scans across leaf boundaries, two populated
tables, table/file limits and generation exhaustion; and inject
sync failures, torn publication and directory/leaf corruption. Structural
corruption tests reseal checksums to test validation beyond CRCs. The common
test driver supports fixtures of up to 16384 cells per batch; that fixture bound
does not constrain the engine API. Row counts in the suite are derived from the
leaf capacity rather than written as constants, so they follow the schema's run
length instead of pinning one.

Local Windows and Linux/WSL runs pass every storage scenario. The existing
unreadable-file case is skipped on the mounted filesystem. The previous
`92d6a3a` Linux binary rejects multi-page `info`, `alloc` and `free` without
changing the file. Hosted CI runs the suite on Linux and Windows and is green.

What binds now is file space rather than the directory: 251 x 251 leaves of
448 rows is 28 million rows, and reaching it needs `create-large`. A third
level would follow the same shape if it were ever wanted. Updates, deletion,
locking and concurrent readers remain unsupported.
