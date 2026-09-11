# Typed COW catalog

Status: a fixed-height catalog is implemented. It stores table definitions and
fixed-width column declarations. The separate [PAX capability](PAX.md) adds
row storage and schema data roots. There is no SQL, table deletion,
directory splitting or reclamation yet.

## Creation and compatibility

```sh
cyboudb create-catalog demo.cdb 256
cyboudb info demo.cdb
```

`create-catalog` sets immutable incompatible flags `0x6`: COW (`0x2`) plus
catalog (`0x4`). Catalog without COW is rejected. This is a new file mode, not
an in-place conversion. Earlier COW binaries reject the unknown catalog bit.
Plain `create-cow` retains its untyped root contract and legacy `create` retains
its free-list behavior. `--force` is required to replace an existing file.

The existing COW allocation-map limit of 16112 total pages applies. An empty
catalog has root 0. A populated catalog consists of a single directory page
pointing to one schema page per table. The directory holds at most 251 tables;
each schema contains 1..64 columns. Table ids are nonzero unsigned 64-bit values.

## Page format

All numeric fields are little-endian. Directory and schema pages share this
header; the allocation map classifies them as payload, not map metadata.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `ASQC` |
| 4 | 4 | Page format version, 1 |
| 8 | 8 | Physical page id |
| 16 | 8 | Creation generation |
| 24 | 8 | Owner: 0 for directory, table id for schema |
| 32 | 4 | Type: 1 directory, 2 schema |
| 36 | 4 | Entry count or column count |
| 40 | 24 | Reserved in catalog-only mode; PAX schemas use data root and row count |
| 64 | 4028 | Type-specific body |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

A directory body is an array of 16-byte `(table_id, schema_page_id)` entries,
strictly increasing by table id. Unused bytes through offset 4091 are zero.

A schema stores its table name in bytes 64..95, followed at offset 96 by
32-byte column records:

| Record offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Type: 1 INT32, 2 INT64, 3 FLOAT32, 4 BOOL |
| 4 | 4 | Flags: bit 0 nullable, all other bits zero |
| 8 | 24 | Column name |

Names are case-sensitive ASCII identifiers matching `[A-Za-z_][A-Za-z0-9_]*`,
with a required NUL terminator and zero padding. Table names have at most 31
bytes; column names have at most 23. Table names must be unique in the catalog,
and column names must be unique within their table. Unused schema bytes are
zero. Types and nullability govern row validation when PAX is enabled; SQL
semantics remain pending. See [PAX.md](PAX.md) for the header extension.

## Internal API

`db_catalog_put(ctx, table_id, schema_image)` inserts or replaces a definition.
The readable 4096-byte image supplies column count at offset 36 and the body at
offset 64. The core stamps all other header fields and the checksum. The input
buffer must remain stable for the call. This operation does not commit.
Replacing a PAX schema with stored rows returns `CybouDB_E_STATE`; migration or
row deletion requires a future API. Empty schemas can still be replaced.

`db_catalog_get(ctx, table_id, out_schema_page)` returns a schema page id and
works on read-only handles. Missing ids return `CybouDB_E_NOTFOUND`; the output
is unchanged on failure. Returned pages are immutable once committed. A caller
must not write through the raw mapping or bypass the catalog/COW contracts.

Schema put validates the input and existing graph, checks name uniqueness and
preflights enough space for the full path. It allocates a new schema, copies
or creates the directory, replaces/inserts its entry, seals both pages, then
stages the new root. The first allocation in a transaction also copies the
allocation map. Unchanged schemas are shared. Repeated puts in one transaction
also copy the staged root; unreachable intermediate pages remain allocated.

Invalid input, duplicate names, directory capacity and storage exhaustion fail
before allocation. A full directory still permits replacement of an existing
id. `db_commit` publishes the staged graph using the existing ordered flushes.

## Validation and recovery

For every candidate superblock, open validates the allocation map and complete
catalog graph before selecting a generation. Checks include page checksums,
physical ids, type, owner, generation, padding, counts, names and references.
Schema generations cannot exceed the directory generation; directory generation
cannot exceed the candidate superblock generation. Typed edges and owner checks
reject cycles, aliases between different table ids and metadata references.

Commit performs the same graph checks before publishing the new superblock.
A damaged graph invalidates its candidate and permits fallback to an intact
older graph. Both checksummed superblock ranges remain protected, even when a
graph is rejected, so later allocation cannot resurrect it before commit.

Validation scans the complete graph and compares names for uniqueness. This
bounded implementation favors correctness over query performance; arbitrary
height, incremental validation and indexes need later work.

## Tests and remaining work

```sh
sh build.sh --core-tests
python3 tests/catalog_tests.py ./cyboudb ./build/cow_harness
# Windows: build.bat --core-tests
# python tests/catalog_tests.py ./cyboudb.exe ./build/cow_harness.exe
```

The 45 catalog scenarios cover insertion order, schema replacement, shared
unchanged leaves, read-only lookup, staged writes, both sync failure positions,
torn publication, corrupt staged schemas, graph corruption, capacity limits
and preservation of rejected generations. Python independently decodes pages
and checks whole-page CRCs. These are process/fault tests, not a simulation of
every physical power-loss behavior.

The PAX capabilities implement single-page roots and bounded
[multi-page table directories](PAX_MULTI.md). Next work: scalar scans, larger
catalog trees, deletion and reclamation, then binding
names through the SQL front end. Future reserved-field semantics still require
a persisted format extension.
