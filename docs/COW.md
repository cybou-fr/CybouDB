# Decision: COW before PAX

Status: persisted COW capability, append-only page operations and an allocation
map are implemented and tested. A separate capability now enables the typed
[catalog tree](CATALOG.md) and another enables [PAX row storage](PAX.md);
reclamation is implemented only in the [span map](SPAN_MAP.md) format.

Two checksummed superblocks protect metadata publication, not pages overwritten
through a shared mapping. Both freeing live data and overwriting a reused free
page can destroy the state selected after restart.

## Required invariants

1. A page reachable from either recoverable superblock is immutable.
2. A transaction writes only pages it exclusively owns. Updating a tree copies
   the changed page and the path to its root.
3. Allocation truth lives in a COW bitmap, not in payload magic. Bitmap pages
   themselves require ownership and a bootstrap allocation strategy.
4. Freed pages enter a retired set. Reuse waits until neither recoverable
   generation, nor any supported active reader, can reach them.
5. Flush new pages and allocation metadata before publishing the inactive
   superblock. A failed publication sync has an uncertain outcome; reopen before
   further writes. Generation overflow must fail before mutation.
6. Recovery validates a coherent root and allocation state. A checksummed
   superblock alone is insufficient evidence that its referenced pages are valid.

The implemented mode has one writer, no concurrent readers, and append-only
allocation in the pre-sized file. Return full rather than recycle protected pages. See the span map for reclamation
only after recovery tests cover both surviving generations. The incompatible capability defines the allocation-map root separately from
legacy free-list records. Retired-page metadata requires a future extension.

## Page format proposal

The implemented catalog and PAX headers contain physical page id, owner,
creation generation and a whole-page checksum. PAX adds row and column counts,
canonical column offsets and NULL masks. Current offsets are documented in
[CATALOG.md](CATALOG.md) and [PAX.md](PAX.md); index and overflow pages remain
future extensions.

## Acceptance tests

Use a core-level harness capable of exiting without close or commit, and VFS
fault injection for failed syncs and torn publication. Cover freeing a live
payload, allocating and overwriting a previously free page, root-path updates,
repeated commits, full storage and loss of either superblock. Before publication,
the old generation must retain byte-identical reachable pages; after successful
publication, reopening must find the complete new graph. Process termination
tests complement, but do not simulate, power-loss ordering tests.

## Implemented first stage

The first patch preserves `SB_ROOT_PAGE` through `DB_ROOT`, rejects roots outside
the allocated page range, and tests alloc/free/reopen round trips. This is a
catalog prerequisite, not a catalog implementation or ownership validator.

`src/core/cow.asm` adds the following internal API:

| Entry point | Contract |
| --- | --- |
| `db_open_cow(path, ctx)` | Writable open; require the persisted COW capability |
| `db_cow_alloc_page(ctx, out_id)` | Append and zero a page beyond both checksummed superblocks' high-water marks |
| `db_cow_copy_page(ctx, source_id, out_id)` | Copy a page into a fresh allocation |
| `db_cow_write_page(ctx, id, buffer)` | Copy 4096 bytes into an unpublished allocation only |
| `db_cow_set_root(ctx, id)` | Stage a root id, or zero, for the next commit |

`db_alloc_page` dispatches to append-only allocation on a COW handle;
`db_free_page` refuses that handle. Successful commit advances the immutable
boundary. Either sync failure disables further mutation on the handle, and
generation exhaustion fails before mutation. `db_create` now propagates its
initial sync failure instead of reporting success.

## Persisted format and CLI

Create COW storage explicitly:

```sh
cyboudb create-cow demo.cdb 256
cyboudb alloc demo.cdb 4
cyboudb info demo.cdb
```

`create-cow` supports `--force` with the same non-destructive default as `create`.
It writes `flags_incompat = 0x2` in the immutable header at creation. It never
converts an existing legacy file in place. Older binaries reject this unknown
capability before mutation. Current `db_open`, including the ordinary CLI,
selects COW allocation automatically for flagged files. `free` is refused.
Unflagged files retain their legacy semantics; `db_open_cow` refuses them.

With this capability, superblock offset 48 is a u64 `bitmap_root`; the free-list
root and offset-56 reserved field must be zero. Initial high-water mark is 4,
with page 3 containing the allocation map. Each first allocation after commit
reserves two pages: a map copy and a payload. Later allocations in the same
transaction share that map. A root-only commit reuses the immutable map.

### Allocation-map page

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 4 | Magic `AQMB` |
| 4 | 4 | Header size, 64 |
| 8 | 8 | Physical page id |
| 16 | 8 | Map creation generation, positive and no newer than its superblock |
| 24 | 8 | Total file pages |
| 32 | 8 | Allocation high-water mark |
| 40 | 24 | Reserved, zero |
| 64 | 4028 | Two-bit allocation states, low bits first |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

For page `i`, byte `64 + i / 4` contains its state at bit position
`2 * (i % 4)`: `00` available, `01` payload, `10` reserved metadata, `11` invalid.
Pages 0..2 and the current map are metadata. Older map pages remain reserved.
Every entry below the high-water mark must be payload or metadata; every entry
at or above it, including entries beyond the file size, must be zero. A nonzero
root must point to payload. Payload magic is never used as allocation truth.

One map limits this mode to **4..16112 total pages** (about 63 MiB). Allocation
fails without mutation if there is insufficient space for both a map and a
payload. More map pages, reclamation and larger files are the [span map](SPAN_MAP.md) extension.
The superblock is 128 bytes: three roots - allocation, catalog and one
extension root reserved for what a database grows later, such as authenticated
page encryption or vector index metadata - then a zero-checked reserved region
and a checksum over everything ahead of it. Nothing writes the extension root
yet, and a non-zero value is refused rather than ignored, because whatever it
points at would govern how the rest of the file is read.
The map classifies reserved space and payload, not object-level ownership.

### Recovery and publication

Opening validates each candidate's geometry, map checksum, identity, generation,
all allocation entries and root membership before selecting a generation. If
the newest candidate has a bad map, recovery can select the older coherent one.
If both fail, open refuses the file. Before flushing, commit seals the staged
map and validates the proposed superblock/map/root together.

The append boundary retains the high-water mark of **every checksummed
superblock**, even a candidate rejected for a damaged map. Reusing that map's
page could otherwise make its stale superblock valid before commit. Gaps held
by an older or rejected generation are conservatively reserved as metadata;
they are never returned as new payload allocations.

Callers must not write through `DB_BASE` or retain writable aliases across
commit. There is still no locking, concurrent reader support, reclamation in this layout,
arbitrary payload checksum or general tree support in plain COW mode. The
additional catalog capability supplies checksummed schema/directory pages,
root-path copying and graph validation. The map checksum alone protects
allocation metadata, not arbitrary payload bytes.

## Validation and CI

Build the independent core driver with `sh build.sh --core-tests` on Linux or
`build.bat --core-tests` on Windows, then run:

```sh
python3 tests/cow_tests.py ./cyboudb ./build/cow_harness
python3 tests/bitmap_tests.py ./cyboudb ./build/cow_harness
python3 tests/catalog_tests.py ./cyboudb ./build/cow_harness
python3 tests/pax_tests.py ./cyboudb ./build/cow_harness
# Windows: python tests/cow_tests.py ./cyboudb.exe ./build/cow_harness.exe
```

The driver links the real OS layer and a test-only sync shim. Tests cover forced
writeback followed by exit without close, close without commit, both sync error
positions, torn metadata publication, protection of both generations, repeated
commits, read-only/closed handles, full storage and generation exhaustion.
Python independently checks checksums, roots and all 4096 payload bytes. These
are deterministic process/fault tests, not a physical power-loss simulation.

The Windows hosted log identified GNU `link.exe` being mistaken for MSVC.
`build.bat` now uses the explicit MSVC tool path, and CI prepends Git's Unix
tools to PATH to retain coverage of that collision. Linux invokes `build.sh`
through `sh` because the tracked script lacks the executable bit.

Local Windows and Linux/WSL validation passes 58 legacy storage tests, 17 COW
scenarios, 29 allocation-map scenarios, 45 catalog scenarios, 53 single-page PAX
scenarios and 43 multi-page PAX scenarios (242 total).
The baseline binary at `86871ce`
was also built and confirmed to reject COW `info`, `alloc` and `free` without
modifying the file. The unreadable-file test is skipped on the mounted filesystem.
Hosted CI remains unverified for these unpushed changes.
