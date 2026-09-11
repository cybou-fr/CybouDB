# The paired multi-page allocation map

Status: implemented, and the only format that reclaims pages. `create-large`
produces it; the CLI and every internal API work on it. The flat map keeps its
append-only behaviour and its 63 MiB ceiling.

## Why the flat map ran out

The original COW allocation map is one checksummed page. Two bits per physical
page over the 4028 usable bytes gives 16112 pages, which caps a database at
63 MiB. Making that map bigger is not simply a matter of adding pages: as soon
as the map is itself allocated through the allocator, growing it means copying
it, copying it means allocating, and allocating means marking a page in the
map that is being copied. Sizing the copy also has to be preflighted, and the
old copies leak because nothing is reclaimed.

## What replaces it

`CybouDB_FEATURE_MAP_SPAN` takes the map out of the allocator entirely and treats
it as metadata of the same class as the superblock, which is exactly what it
is. With `K = ceil(total_pages / 16112)`:

```
page 0             file header
pages 1, 2         superblock A, B
pages 3 .. 3+K-1   allocation map copy A
pages 3+K .. 3+2K  allocation map copy B
pages 3+2K ..      payload
```

Copy X belongs to whichever generation is published in superblock X. Leaf `i`
of a copy is always that copy's first page plus `i`, so there is no pointer
structure, no distinctness to validate, nothing to allocate and nothing to
leak. `SB_BITMAP_ROOT` names the first page of the copy a generation owns and
is therefore always 3 or 3+K.

The ceiling becomes `CybouDB_MAP_MAX_LEAVES * 16112` = 16498688 pages, or 63 GiB,
with a map pair of at most 2048 pages. Everything else keeps its existing
limits: 251 tables, 1..64 columns, 251 data pages per table.

## Creation and compatibility

```sh
cyboudb create-large demo.cdb 40000
cyboudb info demo.cdb
```

The immutable incompatible flags are `0x3E`: COW `0x2`, catalog `0x4`, PAX
`0x8`, multi-page PAX `0x10` and the span map `0x20`. The new bit requires all
four predecessors, and earlier binaries reject it before touching the file.
`create-pax-multi` and the other commands still produce the flat layout with
its 4..16112-page range, and nothing migrates between the two.

## Leaf format

Leaf headers reuse the flat field offsets. A leaf is identified by where it
sits rather than by an id it carries, which is what lets an unchanged leaf be
byte-identical in both copies:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `AQMB` |
| 4 | 4 | Header size, 64 |
| 8 | 8 | Zero |
| 16 | 8 | Generation that last wrote this leaf |
| 24 | 8 | Total pages in the file, in every leaf |
| 32 | 8 | High-water mark, in leaf zero only, zero elsewhere |
| 40 | 8 | First page id this leaf describes, `i * 16112` |
| 48 | 16 | Reserved, zero |
| 64 | 4028 | Two bits per page: 00 free, 01 payload, 10 metadata, 11 retired |
| 4092 | 4 | CRC-32C over bytes [0, 4092) |

Pages 0 through 3+2K-1 are metadata in both copies. Every page below the
high-water is payload, metadata or retired; every page at or above it is free,
which also covers the entries past the end of the file in the last leaf.

## Reclamation

Retired is the state that makes reclamation possible without a free list, a
log or anything else to remember. A page is marked retired when this
generation stops reaching it, which in practice is when `db_cow_copy_page`
replaces it with a copy. The generation before this one may still name it, and
that is the only reason it cannot be handed out immediately.

It becomes free one step later, and nothing has to notice: the next
transaction targets the superblock copy holding that older generation, and
overwrites its half of the map pair before doing anything else. That
generation ends there whatever happens next. So every page the live generation
has retired is available to the next writer, and the allocator can decide that
by reading one two-bit entry in the published map - never the staged one,
where a page allocated earlier in the same transaction would look free and a
page retired earlier in it would look reusable.

The allocator still grows the file while there is room, and starts reclaiming
only when there is none. That keeps a commit's flush range tight during the
growth phase, and it costs nothing: the file is pre-sized, so the space would
sit unused either way. Once full, the file recycles indefinitely instead of
returning `CybouDB_E_FULL`: a 32-page database sustains a hundred and twenty
commits in the test suite, where before it ran out after five.

`db_bitmap_headroom` is the single answer every space preflight now asks for -
what is left above the high-water plus what the live generation retired - so a
full file reports the space it can actually recycle rather than refusing.

A graph is rebuilt one page at a time, so between copying a page and relinking
its parent the old page is already retired while the parent still names it.
The candidate a writer builds to check its own half-finished graph carries
`SB_STAGED`, which lets the walk accept that. The commit builds a clean
candidate instead, so it applies the strict rule, and a reference left
pointing at a retired page fails the commit rather than surviving into a
published generation. `SB_STAGED` is refused on disk.

## What a transaction costs

The first allocation switches the writer to the inactive copy. Only the leaves
the live generation actually changed are copied: a leaf whose two halves carry
the same creation generation was never rewritten in either, so it is already
identical. A transaction that touches one leaf therefore copies one page,
whatever the size of the file, and the commit reseals only the leaves it
stamped.

The map is published with the superblock rather than before it. It does not
need its own barrier, because a torn map fails its own checksum and that
rejects the superblock candidate, so the reader falls back to the other copy
exactly as it would for a torn superblock.

Because a reclaimed page sits below the high-water, the range a commit has to
flush can no longer be derived from it; the allocator records every page it
hands out instead, and `db_commit` flushes exactly that range, then the
superblock page together with the map copy that superblock names.

## Recovery, and what it costs

Open validates both candidates: header, generation ordering, span base,
high-water and reserved bytes of every leaf. It reads a leaf's checksum and
its page states only when that leaf carries the generation being opened, which
is the same rule the data pages follow - a leaf the last transaction did not
touch was checked by the commit that wrote it. A leaf whose span starts beyond
the high-water is checked as one blank region rather than page by page, so a
mostly empty large file stays cheap either way, and `cyboudb check` reads
everything.

One guarantee is weaker than in the flat layout. There the staged map is a
fresh page and nothing below the high-water is ever written, so the older of
the two recoverable generations survived until commit; here the writer
mutates the inactive copy in place and may overwrite pages only that
generation still reaches, so it ends at the writer's first allocation. The
live generation is untouched throughout - its superblock, its half of the map
pair and every page it reaches are never written - so recovery still has a
coherent graph at every instant, and a crash mid-transaction still opens on
it. This is the trade every shadow-paging engine makes for reclaiming, and it
is why a reclaiming database has one recoverable generation while a writer is
active rather than two.

## Tests

```sh
sh build.sh --core-tests
python3 tests/span_tests.py ./cyboudb ./build/cow_harness
# Windows: build.bat --core-tests
# python tests/span_tests.py ./cyboudb.exe ./build/cow_harness.exe
```

The 22 scenarios decode both halves of the pair independently, check the leaf
count exactly where one map page is exhausted, verify that an allocation
publishes the other half without consuming a page and that the following
generation swaps back, run the catalog, PAX and the scan cursor on a file well
past the flat ceiling, and corrupt each header field and the checksum to
confirm the candidate is rejected and the older generation still opens. For
reclamation they check that a copy retires its source, drive a 32-page file
through 120 commits and 960 rows without it ever growing past its own size,
read and scan the recycled graph back in full, and confirm that a published
page marked retired fails validation.

## Remaining work

A file cannot be resized after creation, because the pair is sized once from
the page count. `db_bitmap_recount` walks the map at open and after every
commit to count what is reusable, which is proportional to the allocated part
of the file rather than to the transaction; maintaining that count
incrementally is the obvious next step. Reclamation also assumes a single
writer and no concurrent readers: a reader holding an older generation would
need the generation pinning that MVCC will want anyway.
