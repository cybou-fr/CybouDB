# Single-page PAX storage

Status: fixed-width row batches and scalar row reads are implemented as internal
assembly APIs. The base capability described here has one data page per table.
The [multi-page extension](PAX_MULTI.md) adds up to 251 data pages. SQL,
deletion, updates, reclamation and concurrent access remain pending.

## Creation and compatibility

```sh
cyboudb create-pax demo.cdb 256
cyboudb info demo.cdb
```

This creates a new file with immutable incompatible flags `0xE`: COW `0x2`,
catalog `0x4`, PAX `0x8`. PAX requires both other capabilities. Older binaries
reject the unknown bit. Existing file modes keep their contracts; this command
does not migrate them. `--force` explicitly replaces an existing file.

The CLI creates and inspects files. Table definition, insertion and reading
currently require the internal APIs. Files retain the 4..16112-page COW limit,
251-table directory limit and 1..64 columns per schema.

For a schema in PAX mode, header offset 40 is a u64 data-page id and offset 48
is a u64 row count. Both are zero for an empty table. Offset 56 remains zero.
Directory headers still require all bytes 40..63 to be zero. Catalog-only
files continue to reserve all these fields.

## Data page layout

All fields are little-endian. The allocation map classifies data pages as
payload. A populated table references a page with this header:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQP` |
| 4 | 4 | Page version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owning table id |
| 32 | 4 | Number of stored rows, nonzero |
| 36 | 4 | Number of columns, equal to schema |
| 40 | 4 | Computed row capacity |
| 44 | 20 | Reserved, zero |
| 64 | 16 per column | Column directory |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

Each directory record contains four u32 fields: type, nullable flags, NULL-mask
offset and value-array offset. Types and flags exactly match the schema.
INT32 and FLOAT32 occupy 4 bytes, INT64 8 bytes and BOOL 1 byte.

Starting immediately after the directory, each column stores its NULL masks
and then its values, both contiguous: `8 * groups` mask bytes followed by
`capacity * width` value bytes padded to the next 8-byte boundary. There are
no discretionary offsets or gaps, and a column's values stay contiguous across
the whole page.

A page holds whole 64-row groups. A group is what one NULL mask covers and
what a future vector engine evaluates at a time; it is not a limit on how much
a page may store, and conflating the two wasted most of a page on any narrow
table. `groups` is the largest count whose complete layout still ends before
the checksum, and `capacity` is `64 * groups`. A schema too wide for even one
full group gets a single partial group instead, and capacity is then the
largest row count below 64 that fits. So one BOOL column holds 55 groups and
3520 rows, four mixed columns hold 3 groups and 192 rows, and 64 INT64 columns
fall back to 4 rows. `groups` is `ceil(capacity / 64)`, derived and not stored.

Mask `r / 64`, bit `r % 64`, means row `r` is NULL. Nonnullable columns must
have zero masks.
NULL payloads, unused row slots, unused mask bits, alignment padding and the
remaining page tail are zero. Non-NULL BOOL values are 0 or 1. FLOAT32 values
are stored as raw IEEE-754 binary32 bits, preserving signed zero and NaN payloads;
this layer does not define comparison or SQL arithmetic semantics.

## Internal API

`db_pax_insert(ctx, table_id, batch)` appends a nonempty batch without committing.
The batch descriptor contains three u64 fields:

| Offset | Field |
| ---: | --- |
| 0 | Row count |
| 8 | Pointer to row-major u64 value slots |
| 16 | Pointer to row-major NULL bytes, or zero for all non-NULL |

Each array contains `rows * column_count` cells. INT32 inputs must be
sign-extended to 64 bits, INT64 accepts any 64-bit pattern, FLOAT32 must be
zero-extended from its 32-bit pattern and BOOL must be 0 or 1. NULL bytes must
be 0 or 1; a NULL is permitted only by the column declaration, and its input
value is ignored. The descriptor and arrays must be valid, stable caller-owned
memory outside the database mapping for the duration of the call.

`db_pax_read(ctx, table_id, row_index, output)` materializes one zero-based row.
The output descriptor holds a values pointer at offset 0 and a NULL-bytes
pointer at offset 8. Both arrays are required and have `column_count` entries.
They must be writable, non-overlapping caller-owned memory outside the mapping.
The scalar representation matches insertion; NULL values return zero. Reads
work on read-only handles and on a writer's staged graph. Invalid row indexes
leave output arrays untouched. These entry points are not a stable public ABI.

`db_pax_scan_open(ctx, table_id, cursor)` fills a caller-owned
`CybouDB_SCAN_SIZE`-byte cursor, and `db_pax_scan_next(cursor, output)` returns
`RAX` = an error code and `RDX` = the number of rows produced, zero when the
scan is done. The output descriptor holds a values pointer at offset 0, a
NULL-bytes pointer at offset 8 and the number of rows those buffers hold at
offset 16; the produced rows are row-major and laid out exactly like the input
of `db_pax_insert`. A call stops at the caller's limit or at the end of a leaf,
whichever comes first.

The cursor exists because `db_pax_read` revalidates the entire catalog,
directory and leaf graph on every call, which makes reading a table quadratic
in the size of the database. A cursor validates once, at open, and then reads
leaves directly. What it validated is a snapshot: copy-on-write never rewrites
a published page, so a writer staging an append does not disturb it and the
cursor simply does not see the new rows. A commit ends the snapshot, and the
cursor then returns `CybouDB_E_STATE` until it is reopened.

Errors include `CybouDB_E_ROWS` (empty/oversized batch, invalid row index or a
zero scan limit),
`CybouDB_E_VALUE` (invalid scalar/NULL), `CybouDB_E_FULL` (insufficient COW pages),
`CybouDB_E_NOTFOUND`, `CybouDB_E_READONLY`, `CybouDB_E_STATE` and generation exhaustion.
Input and capacity checks cover the whole batch before allocation, including
the last cell. A full table does not spill to another page.

## Publication and recovery

Insertion copies or initializes a PAX page, copies the schema with its new data
root and row count, then copies the catalog directory and stages its root.
The first allocation in a transaction also copies the allocation map. Space
preflight reserves all three payload pages plus that map when needed.
Unchanged table schemas and data pages remain shared. Multiple staged appends
copy the path again and leave intermediate pages allocated.

`db_commit` validates the complete staged graph before the existing ordered
data/map flush and inactive-superblock publication. Any sync failure poisons
the writer until reopen. The previous graph remains immutable; no pages are
reclaimed. Replacing a populated table through `db_catalog_put` is refused with
`CybouDB_E_STATE`, so a schema replacement cannot silently discard its data.

Open walks every referenced PAX page and checks map membership, owner,
physical id, column layout, capacity and schema row count. It reads a page's
contents - checksum, NULL masks, values, padding and tail - only when that
page carries the generation being opened. A page is written once, by the
generation that created it, and the commit that published it checked it in
full; repeating that for every older page is what made opening a database, and
inserting one row, cost the size of the whole database. Only a page from the
candidate's own generation can be half-written, so this is exactly the set a
torn commit can damage, and rejecting the candidate still falls back to the
intact older graph. `cyboudb check` re-reads everything, for the corruption an
open no longer looks for.

Data generation cannot exceed schema generation; schema cannot exceed directory
generation; directory cannot exceed the candidate superblock generation.
The allocation floor still protects both checksummed superblock ranges,
including rejected generations. If neither graph is valid, open fails.

## Verification and next steps

```sh
sh build.sh --core-tests
python3 tests/pax_tests.py ./cyboudb ./build/cow_harness
# Windows: build.bat --core-tests
# python tests/pax_tests.py ./cyboudb.exe ./build/cow_harness.exe
```

The 54-scenario suite independently decodes layouts and CRCs, compares scalar
and cursor output, covers dense multi-group pages and their boundaries,
tests capacity and validation atomicity, verifies sharing between tables and
injects writeback, sync, torn-superblock and damaged-page failures. Structural
corruption tests recompute checksums to exercise checks beyond CRC validation.
These tests do not simulate all physical power-loss behavior.

Local Windows and Linux/WSL runs pass all 272 storage scenarios (58 legacy,
17 COW, 29 allocation-map, 45 catalog, 54 PAX, 46 multi-page PAX and 22 span
map), and
hosted CI is green on Linux and Windows. The unreadable-file case is
skipped on the mounted filesystem. A Windows-created PAX file was read and
appended on Linux, then both rows were verified on Windows, including signed
INT32, INT64 byte order, a FLOAT32 NaN payload and NULL.

The [multi-page extension](PAX_MULTI.md) implements a versioned data-page
directory with path-copy and recovery tests. The SQL front end is next.
`db_pax_read` still revalidates its table's graph per call, so the cursor
remains the path to use for anything but a single row. On a 240-leaf table an
insert took 182 ms before the generation filter and 23 ms after, most of which
is process startup.
