# On-disk format, version 1

This is the normative description of a `.cdb` file. `include/format.inc` is the
machine-readable version of the same thing and wins on any disagreement; the
per-structure documents ([CATALOG.md](CATALOG.md), [PAX.md](PAX.md),
[VARLEN.md](VARLEN.md), [ZONEMAP.md](ZONEMAP.md), [SPAN_MAP.md](SPAN_MAP.md),
[TOMBSTONES.md](TOMBSTONES.md), [COMPRESSION.md](COMPRESSION.md),
[INDEX.md](INDEX.md)) describe what
lives inside the pages this document allocates.

## Ground rules

Every numeric field is little-endian, every size is fixed, and every 64-bit
field is 8-byte aligned. Nothing in the format depends on the word size,
endianness or alignment rules of the machine that wrote it: a database written
on x86-64 is byte-for-byte the same file an AArch64 build would have written,
and is readable without conversion. The engine has no ARM64 backend today, but
the format is not what stands in the way.

The logical page is 4096 bytes and the file is always a whole number of pages.
A page id is an index into the file, and a page id never changes meaning once
it has been issued.

Checksums are CRC-32C. A structure that carries one stores it in its own last
four bytes and covers everything ahead of it.

## Page map

```
page 0            file header
pages 1, 2        superblock A, superblock B
pages 3 ..        allocation map, then payload
```

Where the allocation map sits depends on which map layout the file uses; see
*Allocation maps* below. The three metadata pages are always present, so
`CybouDB_MIN_PAGES` is 3 and the smallest legal file is 12 KiB.

## File header, page 0

Written once by create and never rewritten. It holds only the identity and
geometry of the file — nothing that changes as the database is used.

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| +0 | 4 | `magic` | `0x4C515341` |
| +4 | 4 | `header_size` | 128 |
| +8 | 4 | `format_version` | 1 |
| +12 | 4 | `page_size` | 4096 |
| +16 | 8 | `flags_incompat` | an unknown bit here means refuse to open |
| +24 | 8 | `flags_compat` | unknown bits here may be ignored |
| +32 | 8 | `sb_page_a` | 1 |
| +40 | 8 | `sb_page_b` | 2 |
| +48 | 16 | `reserved_uuid` | database identity, zero until implemented |
| +64 | 60 | `reserved` | zero |
| +124 | 4 | `crc32c` | over bytes `[0, 124)` |

The rest of page 0 is zero.

Keeping mutable state out of the header is what makes crash recovery possible:
whatever happens during a commit, the header is not involved.

## Superblocks, pages 1 and 2

Everything that changes lives here, in two copies. Each copy carries a
generation number and its own checksum, and a commit writes the copy that is
not currently live.

| Offset | Size | Field | Meaning |
| --- | --- | --- | --- |
| +0 | 4 | `magic` | `0x53515341` |
| +4 | 4 | `sb_size` | 128 |
| +8 | 8 | `generation` | increases on every commit; highest valid copy wins |
| +16 | 8 | `total_pages` | pages in the file as of this generation |
| +24 | 8 | `allocated_pages` | high-water mark |
| +32 | 8 | `freelist_root` | first free-list page, 0 when empty |
| +40 | 8 | `root_page` | catalog root, 0 until the catalog exists |
| +48 | 8 | `bitmap_root` | allocation map root; zero without the COW bit |
| +56 | 8 | `feature_root` | extension directory; must be 0 |
| +64 | 56 | `reserved` | zero |
| +120 | 4 | `staged` | in-memory marker; always 0 on disk |
| +124 | 4 | `crc32c` | over bytes `[0, 124)` |

`allocated_pages` is a high-water mark, not a count of pages in use. Every page
below it has been claimed at least once; freeing a page does not lower it. The
invariant a reader can always check against the file is

```
CybouDB_MIN_PAGES <= allocated_pages <= total_pages
```

`staged` is set only in the in-memory candidate a writer builds to check its own
half-finished graph. An on-disk superblock with it set is rejected, which is
what stops a partially rebuilt graph from ever being mistaken for a published
one.

`feature_root` is reserved and a non-zero value is refused rather than ignored:
it can only mean an extension this build does not implement. The field exists
now because adding it later would mean changing the superblock size, and that
is the disruptive part.

## Free list

Free pages are chained through themselves, so the list costs no extra storage.
The first 16 bytes of a free page are a magic of `0x46515341`, four reserved
zero bytes, and the id of the next free page (0 at the end). The magic is what
lets a corrupt chain be detected instead of silently handing out a page that is
still in use.

The free list is the legacy allocator's structure. A file with the COW bit set
tracks allocation in the map instead.

## Allocation maps

A map entry is two bits per page: `FREE`, `PAYLOAD`, `METADATA`, or — in the
span layout only — `RETIRED`, meaning the page is not reachable from this
generation although the one before it may still reference it.

**Flat map.** One map page, entries in bytes 64..4091, checksum at the end.
It covers 16112 pages, which caps a flat-map file at about 63 MiB.

**Span map** (`CybouDB_FEATURE_MAP_SPAN`). K consecutive map pages, twice, at
fixed positions right after the superblocks:

```
page 0            file header
pages 1, 2        superblock A, B
pages 3 .. 3+K-1  allocation map copy A
pages 3+K .. 3+2K allocation map copy B
pages 3+2K ..     payload
```

Copy X belongs to whichever generation is published in superblock X. Leaf *i*
of a copy is always that copy's first page plus *i*, so there is no pointer
structure to validate, nothing to leak, and no way for map growth to recurse
into the allocator. A leaf is identified by where it sits: `MAP_PAGE_ID` stays
zero so that an unchanged leaf is byte-identical in both copies.

The span layout is also the only layout that reclaims pages. See
[SPAN_MAP.md](SPAN_MAP.md).

## Feature bits

`flags_incompat` in the header says what the writer used. A reader that does
not understand a bit refuses the file rather than guessing, and the bits are
not independent — the dependencies below are enforced at open time, so a file
claiming a dependent bit without its prerequisite is rejected as malformed
rather than opened in a half-understood state.

| Bit | Name | Requires |
| --- | --- | --- |
| 2 | `COW` | — |
| 4 | `CATALOG` | `COW` |
| 8 | `PAX` | `COW`, `CATALOG` |
| 16 | `PAX_MULTI` | `PAX` |
| 32 | `MAP_SPAN` | `COW` |
| 64 | `PAX_RUNS` | `PAX` |
| 128 | `PAX_TREE` | `PAX_MULTI` |
| 256 | `ZONE_MAPS` | `PAX` |
| 512 | `COMPRESSION` | `PAX` |
| 1024 | `VARLEN` | `PAX` |
| 2048 | `VECTOR` | `PAX` |
| 4096 | `TOMBSTONES` | `PAX` |
| 8192 | `INDEX` | `PAX` |
| 16384 | `QUEUE` | `CATALOG` |

Bit 1 is unassigned and unsupported.

`QUEUE` requires only `CATALOG`, and that is a decision rather than an
oversight: a queue stores no rows, so it needs no PAX table, no leaf and no
directory of its own beyond the catalog's. A database may therefore carry
queues and no tables at all.

What it does need, when a message is longer than a slot holds, is the varlen
extent machinery - the same chains a TEXT cell uses, owned by the queue's id
instead of a table's. A file with `QUEUE` and without `VARLEN` may hold queues
whose messages all fit inline; a message that does not fit is refused rather
than stored some other way. The creators that emit `QUEUE` emit `VARLEN` too,
so this is a contract about what a file may be, not a configuration anyone has
to assemble.

Bits are creation-time decisions. The engine does not upgrade a file in place:
a database created without `TOMBSTONES` keeps rewriting on DELETE for its whole
life, because the reservation those bits describe changes how many rows a leaf
holds and every existing leaf was written to the older shape.

`INDEX` is the one bit that changes no existing structure - a tree node is an
ordinary payload page. What it changes is the catalog: a directory entry may
name a page of a third type, so a build that does not know the type has to
refuse the file rather than read an index page as a schema. The layout of that
page and of the tree is in [INDEX.md](INDEX.md).


`QUEUE` changes no existing structure either, for the same reason and with
the same consequence: a segment page is an ordinary payload page, and what
the bit changes is that a directory entry may name a page of a fourth type.
The layout of the queue page and of a segment is in [QUEUE.md](QUEUE.md).

## What version 1 fixes

These are the things the rest of the engine is allowed to assume, and the
things a change would have to break the version number to alter:

- page size 4096, page 0 the header, pages 1 and 2 the superblocks;
- header and superblock both 128 bytes defined, both CRC-32C over `[0, 124)`;
- the meaning of `generation`, `allocated_pages`, `total_pages` and the
  high-water-mark invariant;
- two-bit allocation map entries and the fixed span-map geometry;
- little-endian, fixed-size, 8-byte-aligned fields throughout;
- an unknown `flags_incompat` bit, a non-zero `feature_root`, or a non-zero
  on-disk `staged` is a refusal, never a warning.

## Compatibility promise

Within the 0.5.x series: a file written by any 0.5.x build opens in any later
0.5.x build, and the format version stays 1. New capabilities arrive as new
`flags_incompat` bits, which means a *newer* file may be refused by an *older*
build — that refusal is the promise working, not a break of it.

No promise is made yet across the 0.5 → 0.6 boundary or up to 1.0. Stability of
the format across major versions is a 1.0 commitment, and claiming it earlier
would be claiming something that has not been earned.
